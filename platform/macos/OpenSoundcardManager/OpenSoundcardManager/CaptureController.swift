import Darwin
import Foundation

typealias PcapHandle = OpaquePointer

struct CaptureInterface: Identifiable, Hashable {
  let name: String
  let detail: String?

  var id: String {
    name
  }

  var displayName: String {
    if let detail, !detail.isEmpty {
      return "\(name) - \(detail)"
    }
    return name
  }
}

struct CaptureControllerSnapshot {
  enum State: Equatable {
    case stopped
    case starting
    case capturing
    case error(String)

    var displayName: String {
      switch self {
      case .stopped:
        "Stopped"
      case .starting:
        "Starting"
      case .capturing:
        "Capturing"
      case .error:
        "Error"
      }
    }
  }

  var state: State = .stopped
  var interfaceName: String?
  var packetCount: UInt64 = 0
  var decodedFrameCount: UInt64 = 0
  var consoleResponseCount: UInt64 = 0
  var lastConsoleMAC: String?
  var allenHeathOUIDetected = false
  var lastConsoleResponseDate: Date?
  var lastError: String?
  var startedAt: Date?

  var isCapturing: Bool {
    state == .capturing || state == .starting
  }

  var packetsPerSecond: Double {
    guard let startedAt else {
      return 0
    }

    let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
    return Double(packetCount) / elapsed
  }

  var decodedFramesPerSecond: Double {
    guard let startedAt else {
      return 0
    }

    let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
    return Double(decodedFrameCount) / elapsed
  }
}

final class CaptureController {
  private let queue = DispatchQueue(label: "org.opensoundcard.manager.capture")
  private var current = CaptureControllerSnapshot()
  private var shouldStop = false

  var snapshot: CaptureControllerSnapshot {
    queue.sync {
      current
    }
  }

  func listInterfaces() -> Result<[CaptureInterface], Error> {
    Result {
      try PcapLibrary.shared.listInterfaces()
    }
  }

  func start(interfaceName: String) {
    queue.async {
      guard !self.current.isCapturing else {
        return
      }

      self.shouldStop = false
      self.current = CaptureControllerSnapshot(
        state: .starting,
        interfaceName: interfaceName,
        startedAt: Date()
      )

      DispatchQueue.global(qos: .userInitiated).async {
        self.captureLoop(interfaceName: interfaceName)
      }
    }
  }

  func stop() {
    queue.async {
      self.shouldStop = true
      if self.current.isCapturing {
        self.current.state = .stopped
      }
    }
  }

  private func captureLoop(interfaceName: String) {
    do {
      let pcap = try PcapLibrary.shared.openLive(interfaceName: interfaceName)
      queue.async {
        self.current.state = .capturing
        self.current.lastError = nil
      }

      while !stopRequested() {
        switch try PcapLibrary.shared.nextPacket(handle: pcap) {
        case let .packet(data):
          observePacket(data)
        case .timeout:
          continue
        case .finished:
          break
        }
      }

      try? PcapLibrary.shared.close(pcap)
      queue.async {
        if case .error = self.current.state {
          return
        }
        self.current.state = .stopped
      }
    } catch {
      queue.async {
        self.current.state = .error(error.localizedDescription)
        self.current.lastError = error.localizedDescription
      }
    }
  }

  private func stopRequested() -> Bool {
    queue.sync {
      shouldStop
    }
  }

  private func observePacket(_ data: Data) {
    let decoded = Self.isDecodedGigaAceFrame(data)
    let response = Self.consoleResponse(from: data)
    queue.async {
      self.current.packetCount += 1
      if decoded {
        self.current.decodedFrameCount += 1
      }
      if let response {
        self.current.consoleResponseCount += 1
        self.current.lastConsoleMAC = response.mac
        self.current.allenHeathOUIDetected = response.allenHeathOUI
        self.current.lastConsoleResponseDate = Date()
      }
    }
  }

  private static func isDecodedGigaAceFrame(_ data: Data) -> Bool {
    guard data.count >= 24 else {
      return false
    }

    return data.withUnsafeBytes { bytes in
      guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else {
        return false
      }

      let isBroadcast = (0 ..< 6).allSatisfy { base[$0] == 0xFF }
      let ethertype = UInt16(base[12]) << 8 | UInt16(base[13])
      return isBroadcast && ethertype == 0x04EE
    }
  }

  private static func consoleResponse(from data: Data) -> (mac: String, allenHeathOUI: Bool)? {
    guard data.count >= 24 else {
      return nil
    }

    return data.withUnsafeBytes { bytes in
      guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else {
        return nil
      }

      let ethertype = UInt16(base[12]) << 8 | UInt16(base[13])
      guard ethertype == 0x04EE else {
        return nil
      }

      let gx4816: [UInt8] = [0x00, 0x04, 0xC4, 0x06, 0xCF, 0xE8]
      let src = Array(UnsafeBufferPointer(start: base + 6, count: 6))
      guard src != gx4816 else {
        return nil
      }

      let knownAvantis = src == [0x00, 0x04, 0xC4, 0x08, 0xC8, 0x54]
      let allenHeathOUI = src.prefix(3).elementsEqual([0x00, 0x04, 0xC4])
      let consoleHeader = Array(UnsafeBufferPointer(start: base + 14, count: 5))
        == [0x00, 0x00, 0x04, 0xEA, 0x00]
      guard knownAvantis || (allenHeathOUI && consoleHeader) else {
        return nil
      }

      return (macAddress(src), allenHeathOUI)
    }
  }

  static func macAddress(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
  }
}

enum PcapPacketReadResult {
  case packet(Data)
  case timeout
  case finished
}

enum PcapError: LocalizedError {
  case libraryUnavailable
  case symbolMissing(String)
  case listFailed(String)
  case openFailed(String)
  case readFailed(String)
  case injectFailed(String)

  var errorDescription: String? {
    switch self {
    case .libraryUnavailable:
      "libpcap is unavailable on this host"
    case let .symbolMissing(symbol):
      "libpcap symbol missing: \(symbol)"
    case let .listFailed(message):
      "Interface list failed: \(message)"
    case let .openFailed(message):
      "Interface open failed: \(message)"
    case let .readFailed(message):
      "Packet read failed: \(message)"
    case let .injectFailed(message):
      "Packet inject failed: \(message)"
    }
  }
}

struct PcapInterfaceRecord {
  var next: UnsafeMutablePointer<PcapInterfaceRecord>?
  var name: UnsafeMutablePointer<CChar>?
  var description: UnsafeMutablePointer<CChar>?
  var addresses: UnsafeMutableRawPointer?
  var flags: UInt32
}

struct PcapPacketHeader {
  var ts: timeval
  var caplen: UInt32
  var len: UInt32
}

final class PcapLibrary {
  static var shared: PcapLibrary {
    get throws {
      try sharedResult.get()
    }
  }

  private static let sharedResult = Result {
    try PcapLibrary()
  }

  private typealias FindAllDevs =
    @convention(c) (
      UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
      UnsafeMutablePointer<CChar>?
    ) -> Int32
  private typealias FreeAllDevs = @convention(c) (UnsafeMutableRawPointer?) -> Void
  private typealias OpenLive =
    @convention(c) (UnsafePointer<CChar>?, Int32, Int32, Int32, UnsafeMutablePointer<CChar>?)
      -> PcapHandle?
  private typealias Close = @convention(c) (PcapHandle?) -> Void
  private typealias NextEx =
    @convention(c) (
      PcapHandle?,
      UnsafeMutablePointer<UnsafeRawPointer?>?,
      UnsafeMutablePointer<UnsafePointer<UInt8>?>?
    ) -> Int32
  private typealias Inject = @convention(c) (PcapHandle?, UnsafeRawPointer?, Int) -> Int
  private typealias GetErr = @convention(c) (PcapHandle?) -> UnsafePointer<CChar>?

  private let library: UnsafeMutableRawPointer
  private let findAllDevs: FindAllDevs
  private let freeAllDevs: FreeAllDevs
  private let openLivePointer: OpenLive
  private let closePointer: Close
  private let nextEx: NextEx
  private let injectPointer: Inject
  private let getErr: GetErr

  private init() throws {
    guard let library = Self.openLibrary() else {
      throw PcapError.libraryUnavailable
    }

    self.library = library
    findAllDevs = try Self.load("pcap_findalldevs", from: library)
    freeAllDevs = try Self.load("pcap_freealldevs", from: library)
    openLivePointer = try Self.load("pcap_open_live", from: library)
    closePointer = try Self.load("pcap_close", from: library)
    nextEx = try Self.load("pcap_next_ex", from: library)
    injectPointer = try Self.load("pcap_inject", from: library)
    getErr = try Self.load("pcap_geterr", from: library)
  }

  deinit {
    dlclose(library)
  }

  func listInterfaces() throws -> [CaptureInterface] {
    var devices: UnsafeMutableRawPointer?
    var errbuf = [CChar](repeating: 0, count: 256)
    let result = errbuf.withUnsafeMutableBufferPointer { buffer in
      findAllDevs(&devices, buffer.baseAddress)
    }

    guard result == 0 else {
      throw PcapError.listFailed(Self.errbufString(errbuf))
    }

    defer {
      freeAllDevs(devices)
    }

    var interfaces: [CaptureInterface] = []
    var cursor = devices
    while let record = cursor {
      let interface = record.assumingMemoryBound(to: PcapInterfaceRecord.self).pointee
      if let namePointer = interface.name {
        let name = String(cString: namePointer)
        let detail = interface.description.map { String(cString: $0) }
        interfaces.append(CaptureInterface(name: name, detail: detail))
      }
      cursor = UnsafeMutableRawPointer(interface.next)
    }

    return interfaces
  }

  func openLive(interfaceName: String) throws -> PcapHandle {
    var errbuf = [CChar](repeating: 0, count: 256)
    let handle = interfaceName.withCString { namePointer in
      errbuf.withUnsafeMutableBufferPointer { buffer in
        openLivePointer(namePointer, 65535, 1, 250, buffer.baseAddress)
      }
    }

    guard let handle else {
      throw PcapError.openFailed(Self.errbufString(errbuf))
    }

    return handle
  }

  func close(_ handle: PcapHandle) {
    closePointer(handle)
  }

  func nextPacket(handle: PcapHandle) throws -> PcapPacketReadResult {
    var header: UnsafeRawPointer?
    var data: UnsafePointer<UInt8>?
    let result = nextEx(handle, &header, &data)

    switch result {
    case 1:
      guard let header, let data else {
        return .timeout
      }
      let packetHeader = header.assumingMemoryBound(to: PcapPacketHeader.self).pointee
      return .packet(Data(bytes: data, count: Int(packetHeader.caplen)))
    case 0:
      return .timeout
    case -2:
      return .finished
    default:
      throw PcapError.readFailed(errorString(handle))
    }
  }

  func inject(handle: PcapHandle, frame: Data) throws {
    let sent = frame.withUnsafeBytes { bytes in
      injectPointer(handle, bytes.baseAddress, frame.count)
    }

    guard sent == frame.count else {
      throw PcapError.injectFailed(errorString(handle))
    }
  }

  private func errorString(_ handle: PcapHandle) -> String {
    guard let pointer = getErr(handle) else {
      return "unknown pcap error"
    }
    return String(cString: pointer)
  }

  private static func openLibrary() -> UnsafeMutableRawPointer? {
    for path in ["/usr/lib/libpcap.A.dylib", "/usr/lib/libpcap.dylib", "libpcap.dylib"] {
      if let library = dlopen(path, RTLD_NOW) {
        return library
      }
    }
    return nil
  }

  private static func load<T>(_ symbol: String, from library: UnsafeMutableRawPointer) throws -> T {
    guard let pointer = dlsym(library, symbol) else {
      throw PcapError.symbolMissing(symbol)
    }

    return unsafeBitCast(pointer, to: T.self)
  }

  private static func errbufString(_ errbuf: [CChar]) -> String {
    errbuf.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress, base.pointee != 0 else {
        return "unknown pcap error"
      }
      return String(cString: base)
    }
  }
}
