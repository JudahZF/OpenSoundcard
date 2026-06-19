import Darwin
import Foundation

struct EngineStatus {
  var state: OscEngineState
  var sampleRate: Double
  var channelCount: UInt32
  var capacityFrames: UInt32
  var readIndex: UInt64
  var writeIndex: UInt64
  var packetCount: UInt64
  var decodedFrameCount: UInt64
  var underrunCount: UInt64
  var overrunCount: UInt64
  var lastErrorCode: Int32
}

enum OscEngineState: Int32 {
  case stopped = 0
  case starting = 1
  case running = 2
  case underrun = 3
  case error = 4

  var displayName: String {
    switch self {
    case .stopped:
      "Stopped"
    case .starting:
      "Starting"
    case .running:
      "Running"
    case .underrun:
      "Underrun"
    case .error:
      "Error"
    }
  }
}

private struct OscStatusSnapshot {
  var state: Int32 = 0
  var sampleRate: Double = 0
  var channelCount: UInt32 = 0
  var capacityFrames: UInt32 = 0
  var readIndex: UInt64 = 0
  var writeIndex: UInt64 = 0
  var packetCount: UInt64 = 0
  var decodedFrameCount: UInt64 = 0
  var underrunCount: UInt64 = 0
  var overrunCount: UInt64 = 0
  var lastErrorCode: Int32 = 0

  static var hasExpectedLayout: Bool {
    MemoryLayout<OscStatusSnapshot>.stride == 80
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.state) == 0
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.sampleRate) == 8
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.channelCount) == 16
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.capacityFrames) == 20
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.readIndex) == 24
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.writeIndex) == 32
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.packetCount) == 40
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.decodedFrameCount) == 48
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.underrunCount) == 56
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.overrunCount) == 64
      && MemoryLayout<OscStatusSnapshot>.offset(of: \.lastErrorCode) == 72
  }
}

final class OpenSoundcardEngine {
  private let library: OpenSoundcardLibrary
  private var engine: UnsafeMutableRawPointer?
  private var tonePhase: Double = 0

  let availabilityMessage: String

  init?() {
    guard OscStatusSnapshot.hasExpectedLayout else {
      return nil
    }

    guard let loadedLibrary = OpenSoundcardLibrary.load() else {
      return nil
    }

    library = loadedLibrary
    engine = library.create(64, 48_000, 48_000.0)
    guard engine != nil else {
      availabilityMessage = "Rust engine unavailable"
      return nil
    }

    availabilityMessage = "Rust engine connected"
  }

  deinit {
    library.destroy(engine)
    engine = nil
  }

  func setRunning(_ running: Bool) {
    library.setRunning(engine, running)
  }

  func status() -> EngineStatus? {
    guard engine != nil else {
      return nil
    }

    var snapshot = OscStatusSnapshot()
    withUnsafeMutablePointer(to: &snapshot) { pointer in
      library.getStatus(engine, UnsafeMutableRawPointer(pointer))
    }

    return EngineStatus(
      state: OscEngineState(rawValue: snapshot.state) ?? .error,
      sampleRate: snapshot.sampleRate,
      channelCount: snapshot.channelCount,
      capacityFrames: snapshot.capacityFrames,
      readIndex: snapshot.readIndex,
      writeIndex: snapshot.writeIndex,
      packetCount: snapshot.packetCount,
      decodedFrameCount: snapshot.decodedFrameCount,
      underrunCount: snapshot.underrunCount,
      overrunCount: snapshot.overrunCount,
      lastErrorCode: snapshot.lastErrorCode
    )
  }

  func writeDemoTone(frames: Int) {
    guard frames > 0, engine != nil else {
      return
    }

    let channelCount = 64
    let sampleRate = 48_000.0
    let frequency = 440.0
    let amplitude: Float = 0.16
    var samples = Array(repeating: Float.zero, count: frames * channelCount)

    for frame in 0..<frames {
      let sample = sin(tonePhase) * Double(amplitude)
      let offset = frame * channelCount
      samples[offset] = Float(sample)
      samples[offset + 1] = Float(sample)
      tonePhase += 2.0 * Double.pi * frequency / sampleRate
    }

    tonePhase.formTruncatingRemainder(dividingBy: 2.0 * Double.pi)
    samples.withUnsafeBufferPointer { buffer in
      library.writeInterleaved(engine, buffer.baseAddress, UInt32(frames))
    }
  }
}

private final class OpenSoundcardLibrary {
  typealias CreateFunction = @convention(c) (UInt32, UInt32, Double) -> UnsafeMutableRawPointer?
  typealias DestroyFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias GetStatusFunction =
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
  typealias SetRunningFunction = @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void
  typealias WriteInterleavedFunction =
    @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<Float>?, UInt32) -> Void

  private let handle: UnsafeMutableRawPointer
  let create: CreateFunction
  let destroy: DestroyFunction
  let getStatus: GetStatusFunction
  let setRunning: SetRunningFunction
  let writeInterleaved: WriteInterleavedFunction

  private init(
    handle: UnsafeMutableRawPointer,
    create: CreateFunction,
    destroy: DestroyFunction,
    getStatus: GetStatusFunction,
    setRunning: SetRunningFunction,
    writeInterleaved: WriteInterleavedFunction
  ) {
    self.handle = handle
    self.create = create
    self.destroy = destroy
    self.getStatus = getStatus
    self.setRunning = setRunning
    self.writeInterleaved = writeInterleaved
  }

  deinit {
    dlclose(handle)
  }

  static func load() -> OpenSoundcardLibrary? {
    for path in candidateLibraryPaths() {
      guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        continue
      }

      guard
        let create: CreateFunction = symbol("osc_engine_create", in: handle),
        let destroy: DestroyFunction = symbol("osc_engine_destroy", in: handle),
        let getStatus: GetStatusFunction = symbol("osc_engine_get_status", in: handle),
        let setRunning: SetRunningFunction = symbol("osc_engine_set_running", in: handle),
        let writeInterleaved: WriteInterleavedFunction = symbol(
          "osc_engine_write_interleaved", in: handle)
      else {
        dlclose(handle)
        continue
      }

      return OpenSoundcardLibrary(
        handle: handle,
        create: create,
        destroy: destroy,
        getStatus: getStatus,
        setRunning: setRunning,
        writeInterleaved: writeInterleaved
      )
    }

    return nil
  }

  private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
    guard let rawSymbol = dlsym(handle, name) else {
      return nil
    }

    return unsafeBitCast(rawSymbol, to: T.self)
  }

  private static func candidateLibraryPaths() -> [String] {
    let fileManager = FileManager.default
    var paths: [String] = []

    if let overridePath = ProcessInfo.processInfo.environment["OSC_ENGINE_DYLIB_PATH"],
      !overridePath.isEmpty
    {
      paths.append(overridePath)
    }

    if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
      paths.append(executableDirectory.appendingPathComponent("libopensoundcard_core.dylib").path)
    }

    if let resourceDirectory = Bundle.main.resourceURL {
      paths.append(resourceDirectory.appendingPathComponent("libopensoundcard_core.dylib").path)
    }

    let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    paths.append(
      currentDirectory.appendingPathComponent("target/release/libopensoundcard_core.dylib").path)

    var probeURL = currentDirectory
    for _ in 0..<6 {
      paths.append(
        probeURL.appendingPathComponent("target/release/libopensoundcard_core.dylib").path)
      probeURL.deleteLastPathComponent()
    }

    return Array(NSOrderedSet(array: paths)) as? [String] ?? paths
  }
}
