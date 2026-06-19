import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class StatusModel: ObservableObject {
  @Published private(set) var pluginInstalled = false
  @Published private(set) var deviceLoaded = false
  @Published private(set) var installState = DeviceInstallState.empty
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
  @Published private(set) var diagnosticsExportStatus = "Not exported"
  @Published var abletonValidationNotes = ""
  @Published var selectedStageboxVariantID: UInt8 = 0
  @Published var probeDurationSeconds: Double = 10

  private let halBridge = OpenSoundcardHALBridge()
  private let deviceInstallController = DeviceInstallController()
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
    installState.pluginStatusText
  }

  var deviceStatus: String {
    installState.deviceStatusText
  }

  var pluginPathText: String {
    installState.installedPathText
  }

  var pluginVersionText: String {
    installState.installedVersionText
  }

  var pluginVersionMatchText: String {
    installState.versionMatchText
  }

  var installRestartSuggestion: String? {
    installState.restartRecommendation
  }

  var installScriptPaths: [InstallScriptPath] {
    installState.scriptPaths
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
    case .starting, .stopping:
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
    switch stageboxController.snapshot.state {
    case .stopping:
      "Stopping Stagebox Probe"
    case .starting, .transmitting:
      "Stop Stagebox Probe"
    case .idle, .finished, .error:
      "Start Stagebox Probe"
    }
  }

  var stageboxProbeSystemImage: String {
    stageboxController.snapshot.state.isActive ? "stop.fill" : "dot.radiowaves.left.and.right"
  }

  var isInterfaceSelectionDisabled: Bool {
    isRunning || stageboxController.snapshot.state.isActive
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
    guard !isInterfaceSelectionDisabled else {
      lastProbeError = "Stop capture and stagebox probe before changing interface"
      return
    }

    selectedInterfaceID = interfaceID
    selectedInterface = interfaceID.isEmpty ? "No interface selected" : interfaceID
  }

  func refreshCaptureInterfaces() {
    switch captureController.listInterfaces() {
    case let .success(interfaces):
      captureInterfaces = interfaces
      guard !isInterfaceSelectionDisabled else {
        return
      }

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
    } else if captureSnapshot.interfaceName != selectedInterfaceID {
      lastProbeError = "Capture is active on \(captureSnapshot.interfaceName ?? "another interface")"
      stageboxIdentification = "Error"
      return
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
    let scriptURL = installState.scriptPath(for: "Install script") ?? repositoryRoot()
      .appendingPathComponent("platform/macos/scripts/install-plugin.sh")
    safetyWarning = "Run install-plugin.sh from a trusted checkout, then restart CoreAudio."
    NSWorkspace.shared.activateFileViewerSelecting([scriptURL])
  }

  func exportDiagnostics() {
    let generatedAt = Date()
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [.plainText]
    savePanel.canCreateDirectories = true
    savePanel.isExtensionHidden = false
    savePanel.nameFieldStringValue = DiagnosticsExporter.defaultFilename(generatedAt: generatedAt)
    savePanel.title = "Export OpenSoundcard Diagnostics"

    savePanel.begin { [weak self] response in
      Task { @MainActor in
        guard let self else {
          return
        }

        guard response == .OK, let outputURL = savePanel.url else {
          self.diagnosticsExportStatus = "Export cancelled"
          return
        }

        self.diagnosticsExportStatus = "Collecting diagnostics..."
        let snapshotBase = self.diagnosticsSnapshot(generatedAt: generatedAt, logLines: [])

        DispatchQueue.global(qos: .userInitiated).async {
          var snapshot = snapshotBase
          snapshot.logLines = DiagnosticsExporter.collectLastLogLines(limit: 200)

          do {
            try DiagnosticsExporter.write(snapshot, to: outputURL)
            DispatchQueue.main.async {
              Task { @MainActor in
                self.diagnosticsExportStatus = "Exported \(outputURL.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
              }
            }
          } catch {
            DispatchQueue.main.async {
              Task { @MainActor in
                self.diagnosticsExportStatus =
                  "Diagnostics export failed: \(error.localizedDescription)"
              }
            }
          }
        }
      }
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
    case .stopping:
      next.state = .stopping
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
    installState = deviceInstallController.inspect(
      repositoryRoot: repositoryRoot(),
      expectedVersion: appVersion
    )
    pluginInstalled = installState.pluginInstalled
    deviceLoaded = installState.deviceVisible
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "0.1.0"
  }

  private func diagnosticsSnapshot(generatedAt: Date, logLines: [String]) -> DiagnosticsSnapshot {
    DiagnosticsSnapshot(
      generatedAt: generatedAt,
      macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      appVersion: appVersion,
      installState: installState,
      abletonValidationNotes: abletonValidationNotes,
      selectedNetworkInterface: selectedInterface,
      streamStatus: [
        "FFI: \(ffiAvailability)",
        "Capture state: \(captureState)",
        "Sample rate: \(sampleRateText)",
        "Channels: \(channelsText)",
        "Packets/sec: \(packetsPerSecondText)",
        "Decoded frames/sec: \(decodedFramesPerSecondText)",
        "Buffer fill estimate: \(fillEstimateText)",
        "Read index: \(readIndexText)",
        "Write index: \(writeIndexText)",
        "Underruns: \(underrunsText)",
        "Overruns: \(overrunsText)",
        "Last error: \(lastErrorText)",
      ],
      stageboxIdentification: [
        "Identification: \(stageboxIdentification)",
        "Active variant: \(activeVariant)",
        "Probe remaining: \(probeRemainingText)",
        "Transmitted frames: \(transmittedFramesText)",
        "Console response frames: \(consoleResponseFramesText)",
        "Last console MAC: \(lastConsoleMAC)",
        "Allen & Heath OUI detected: \(allenHeathOUIDetectedText)",
        "Last response age: \(lastResponseAgeText)",
        "Last probe error: \(lastProbeError)",
        "Safety warning: \(safetyWarning)",
      ],
      logLines: logLines
    )
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
