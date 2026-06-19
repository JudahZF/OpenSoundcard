import AppKit
import CoreAudio
import Foundation

@MainActor
final class StatusModel: ObservableObject {
  @Published private(set) var pluginInstalled = false
  @Published private(set) var deviceLoaded = false
  @Published private(set) var captureInterfaces: [CaptureInterface] = []
  @Published private(set) var selectedInterfaceID = ""
  @Published private(set) var selectedInterface = "No interface selected"
  @Published private(set) var stageboxIdentification = "Disabled"
  @Published private(set) var activeVariant = "None"
  @Published private(set) var consoleResponseFrames: UInt64 = 0
  @Published private(set) var lastConsoleMAC = "None"
  @Published private(set) var allenHeathOUIDetected = false
  @Published private(set) var lastResponseAge = "None"
  @Published private(set) var lastProbeError = "None"
  @Published private(set) var safetyWarning = "None"
  @Published private(set) var status = EngineStatus.empty
  @Published private(set) var packetsPerSecond: Double = 0
  @Published private(set) var decodedFramesPerSecond: Double = 0
  @Published private(set) var demoToneEnabled = false
  @Published var selectedStageboxVariantID: UInt8 = 0
  @Published var probeDurationSeconds: Double = 10

  private let halBridge = OpenSoundcardHALBridge()
  private let captureController = CaptureController()
  private let stageboxController = StageboxIdentityController()
  private var captureSnapshot = CaptureControllerSnapshot()
  private var stageboxStatus = StageboxStatusModel()
  private var pollTimer: Timer?
  private var previousPacketCount: UInt64 = 0
  private var previousDecodedFrameCount: UInt64 = 0
  private var previousRateDate = Date()

  init() {
    refreshInstallState()
    refreshCaptureInterfaces()
    poll()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.poll()
      }
    }
  }

  deinit {
    pollTimer?.invalidate()
  }

  var ffiAvailability: String {
    halBridge.availabilityMessage
  }

  var ffiTone: StatusTone {
    halBridge.statusAvailable ? .good : .warning
  }

  var pluginStatus: String {
    pluginInstalled ? "Installed" : "Not installed"
  }

  var deviceStatus: String {
    deviceLoaded ? "Loaded" : "Missing"
  }

  var sampleRateText: String {
    status.sampleRate > 0 ? "\(Int(status.sampleRate / 1000)) kHz" : "48 kHz"
  }

  var channelsText: String {
    "\(max(status.channelCount, 64))"
  }

  var captureState: String {
    switch captureSnapshot.state {
    case let .error(message):
      return message.isEmpty ? "Error" : "Error"
    default:
      return captureSnapshot.state.displayName
    }
  }

  var captureTone: StatusTone {
    switch captureSnapshot.state {
    case .capturing:
      .good
    case .starting:
      .warning
    case .error:
      .error
    case .stopped:
      halBridge.statusAvailable ? .neutral : .warning
    }
  }

  var isRunning: Bool {
    captureSnapshot.isCapturing
  }

  var captureButtonTitle: String {
    isRunning ? "Stop Capture" : "Start Capture"
  }

  var demoToneButtonTitle: String {
    demoToneEnabled ? "Stop Demo Tone" : "Demo Tone"
  }

  var selectedStageboxVariant: StageboxIdentityVariant {
    StageboxIdentityVariant.all.first { $0.id == selectedStageboxVariantID }
      ?? StageboxIdentityVariant.all[0]
  }

  var stageboxProbeButtonTitle: String {
    stageboxController.snapshot.state.isActive ? "Stop Stagebox Probe" : "Start Stagebox Probe"
  }

  var stageboxProbeSystemImage: String {
    stageboxController.snapshot.state.isActive ? "stop.fill" : "dot.radiowaves.left.and.right"
  }

  var packetsPerSecondText: String {
    packetsPerSecond.formatted(.number.precision(.fractionLength(0)))
  }

  var decodedFramesPerSecondText: String {
    decodedFramesPerSecond.formatted(.number.precision(.fractionLength(0)))
  }

  var consoleResponseFramesText: String {
    "\(consoleResponseFrames)"
  }

  var allenHeathOUIDetectedText: String {
    allenHeathOUIDetected ? "Yes" : "No"
  }

  var lastResponseAgeText: String {
    lastResponseAge
  }

  var probeRemainingText: String {
    stageboxStatus.remainingText
  }

  var transmittedFramesText: String {
    "\(stageboxStatus.transmittedFrames)"
  }

  var fillEstimateText: String {
    guard status.capacityFrames > 0 else {
      return "0%"
    }

    let fillFrames =
      status.writeIndex >= status.readIndex ? status.writeIndex - status.readIndex : 0
    let fill = min(Double(fillFrames) / Double(status.capacityFrames), 1.0)
    return fill.formatted(.percent.precision(.fractionLength(0)))
  }

  var readIndexText: String {
    "\(status.readIndex)"
  }

  var writeIndexText: String {
    "\(status.writeIndex)"
  }

  var underrunsText: String {
    "\(status.underrunCount)"
  }

  var overrunsText: String {
    "\(status.overrunCount)"
  }

  var lastErrorText: String {
    if let captureError = captureSnapshot.lastError {
      return captureError
    }
    return status.lastErrorCode == 0 ? "None" : "\(status.lastErrorCode)"
  }

  func toggleCapture() {
    isRunning ? stopCapture() : startCapture()
  }

  func selectInterface(_ interfaceID: String) {
    selectedInterfaceID = interfaceID
    selectedInterface = interfaceID.isEmpty ? "No interface selected" : interfaceID
  }

  func refreshCaptureInterfaces() {
    switch captureController.listInterfaces() {
    case let .success(interfaces):
      captureInterfaces = interfaces
      if selectedInterfaceID.isEmpty, let first = interfaces.first {
        selectInterface(first.id)
      } else if !selectedInterfaceID.isEmpty,
                !interfaces.contains(where: { $0.id == selectedInterfaceID })
      {
        selectInterface(interfaces.first?.id ?? "")
      }
    case let .failure(error):
      captureInterfaces = []
      selectedInterfaceID = ""
      selectedInterface = "No interface selected"
      lastProbeError = error.localizedDescription
    }
  }

  func startCapture() {
    guard !selectedInterfaceID.isEmpty else {
      lastProbeError = "Select a capture interface first"
      return
    }
    captureController.start(interfaceName: selectedInterfaceID)
    selectedInterface = selectedInterfaceID
    poll()
  }

  func stopCapture() {
    captureController.stop()
    poll()
  }

  func toggleDemoTone() {
    demoToneEnabled ? stopDemoTone() : startDemoTone()
  }

  func stageboxProbe() {
    if stageboxController.snapshot.state.isActive {
      stageboxController.stop()
      poll()
      return
    }

    guard !selectedInterfaceID.isEmpty else {
      lastProbeError = "Select a capture interface first"
      stageboxIdentification = "Error"
      return
    }

    if !isRunning {
      startCapture()
    }

    let variant = selectedStageboxVariant
    stageboxStatus = StageboxStatusModel(
      state: .probing,
      activeVariant: variant,
      lastError: nil,
      probeEndsAt: Date().addingTimeInterval(probeDurationSeconds)
    )
    safetyWarning = StageboxStatusModel.safetyWarning
    stageboxController.start(
      interfaceName: selectedInterfaceID,
      variant: variant,
      duration: probeDurationSeconds
    )
    poll()
  }

  func showInstallInstructions() {
    let scriptURL = repositoryRoot()
      .appendingPathComponent("platform/macos/scripts/install-plugin.sh")
    safetyWarning = "Run install-plugin.sh from a trusted checkout, then restart CoreAudio"
    NSWorkspace.shared.activateFileViewerSelecting([scriptURL])
  }

  func exportDiagnostics() {
    let formatter = ISO8601DateFormatter()
    let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let outputURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Desktop")
      .appendingPathComponent("OpenSoundcardDiagnostics-\(timestamp).txt")

    let report = diagnosticsReport()
    do {
      try report.write(to: outputURL, atomically: true, encoding: .utf8)
      NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    } catch {
      lastProbeError = "Diagnostics export failed: \(error.localizedDescription)"
    }
  }

  func openLogs() {
    let logsURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs")
    NSWorkspace.shared.open(logsURL)
  }

  private func startDemoTone() {
    demoToneEnabled = true
    halBridge.setDemoToneEnabled(true)
    poll()
  }

  private func stopDemoTone() {
    demoToneEnabled = false
    halBridge.setDemoToneEnabled(false)
    poll()
  }

  private func poll() {
    refreshInstallState()

    captureSnapshot = captureController.snapshot
    status = halBridge.status() ?? .empty
    syncStageboxStatus()

    updateRates()
  }

  private func updateRates() {
    packetsPerSecond = captureSnapshot.packetsPerSecond
    decodedFramesPerSecond = captureSnapshot.decodedFramesPerSecond
    previousPacketCount = captureSnapshot.packetCount
    previousDecodedFrameCount = captureSnapshot.decodedFrameCount
    previousRateDate = Date()
  }

  private func syncStageboxStatus() {
    let probe = stageboxController.snapshot
    var next = stageboxStatus
    next.responseCount = captureSnapshot.consoleResponseCount
    next.lastConsoleMAC = captureSnapshot.lastConsoleMAC
    next.allenHeathOUIDetected = captureSnapshot.allenHeathOUIDetected
    next.lastResponseDate = captureSnapshot.lastConsoleResponseDate
    next.transmittedFrames = probe.transmittedFrames

    if let variant = probe.variant {
      next.activeVariant = variant
    } else if next.activeVariant == nil {
      next.activeVariant = selectedStageboxVariant
    }

    switch probe.state {
    case .idle:
      next.state = next.responseCount > 0 ? .responding : .disabled
      next.probeEndsAt = nil
    case .starting, .transmitting:
      next.state = .probing
      next.probeEndsAt = probe.endsAt
    case .finished:
      next.state = next.responseCount > 0 ? .responding : .noResponse
      next.probeEndsAt = nil
    case let .error(message):
      next.state = .error(message)
      next.lastError = message
      next.probeEndsAt = nil
    }

    if let captureError = captureSnapshot.lastError {
      next.lastError = captureError
    }

    stageboxStatus = next
    stageboxIdentification = stageboxStatus.state.displayName
    activeVariant = stageboxStatus.activeVariant?.displayName ?? "None"
    consoleResponseFrames = stageboxStatus.responseCount
    lastConsoleMAC = stageboxStatus.lastConsoleMAC ?? "None"
    allenHeathOUIDetected = stageboxStatus.allenHeathOUIDetected
    lastResponseAge = stageboxStatus.responseAgeText
    lastProbeError = stageboxStatus.lastError ?? "None"
    safetyWarning = StageboxStatusModel.safetyWarning
  }

  private func refreshInstallState() {
    let fileManager = FileManager.default
    let systemPlugin = "/Library/Audio/Plug-Ins/HAL/OpenSoundcard.driver"
    let userPlugin = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Audio/Plug-Ins/HAL/OpenSoundcard.driver")
      .path
    pluginInstalled =
      fileManager.fileExists(atPath: systemPlugin) || fileManager.fileExists(atPath: userPlugin)
    deviceLoaded = isOpenSoundcardDeviceLoaded()
  }

  private func isOpenSoundcardDeviceLoaded() -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0

    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize
      ) == noErr,
      dataSize > 0
    else {
      return false
    }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var devices = Array(repeating: AudioDeviceID(0), count: deviceCount)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        &devices
      ) == noErr
    else {
      return false
    }

    return devices.contains { deviceID in
      coreAudioDeviceName(deviceID) == "OpenSoundcard GigaACE"
    }
  }

  private func coreAudioDeviceName(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString = "" as CFString
    var dataSize = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &name) { namePointer in
      AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
        namePointer
      )
    }

    guard status == noErr else {
      return nil
    }

    return name as String
  }

  private func diagnosticsReport() -> String {
    """
    OpenSoundcard Diagnostics
    Generated: \(Date())

    Device
    CoreAudio Plug-in: \(pluginStatus)
    CoreAudio Device: \(deviceStatus)
    Sample Rate: \(sampleRateText)
    Channels: \(channelsText)

    Capture
    Interface: \(selectedInterface)
    State: \(captureState)
    Packets/sec: \(packetsPerSecondText)
    Decoded frames/sec: \(decodedFramesPerSecondText)
    Last error: \(lastErrorText)

    Stagebox / Console
    Identification: \(stageboxIdentification)
    Active variant: \(activeVariant)
    Console response frames: \(consoleResponseFramesText)
    Last console MAC: \(lastConsoleMAC)
    Allen & Heath OUI detected: \(allenHeathOUIDetectedText)
    Last response age: \(lastResponseAgeText)
    Last probe error: \(lastProbeError)
    Safety warning: \(safetyWarning)

    Buffer
    Fill estimate: \(fillEstimateText)
    Read index: \(readIndexText)
    Write index: \(writeIndexText)
    Underruns: \(underrunsText)
    Overruns: \(overrunsText)

    FFI: \(ffiAvailability)
    """
  }

  private func repositoryRoot() -> URL {
    var probeURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0 ..< 8 {
      if FileManager.default.fileExists(atPath: probeURL.appendingPathComponent("Cargo.toml").path) {
        return probeURL
      }
      probeURL.deleteLastPathComponent()
    }

    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  }
}

private extension EngineStatus {
  static var empty: EngineStatus {
    EngineStatus(
      state: .stopped,
      sampleRate: 48000,
      channelCount: 64,
      capacityFrames: 48000,
      readIndex: 0,
      writeIndex: 0,
      packetCount: 0,
      decodedFrameCount: 0,
      underrunCount: 0,
      overrunCount: 0,
      lastErrorCode: 0
    )
  }
}
