import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var statusModel: StatusModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header

        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
          DeviceSection()
          CaptureSection()
          StageboxSection()
          BufferSection()
          ControlsSection()
          DiagnosticsSection()
        }
      }
      .padding(24)
    }
    .frame(minWidth: 820, minHeight: 640)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var columns: [GridItem] {
    [
      GridItem(.flexible(minimum: 300), spacing: 14, alignment: .top),
      GridItem(.flexible(minimum: 300), spacing: 14, alignment: .top),
    ]
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("OpenSoundcard GigaACE")
        .font(.system(size: 28, weight: .semibold))
      HStack(spacing: 10) {
        StatePill(text: statusModel.captureState, tone: statusModel.captureTone)
        StatePill(text: statusModel.ffiAvailability, tone: statusModel.ffiTone)
        if statusModel.demoToneEnabled {
          StatePill(text: "Demo Tone", tone: .accent)
        }
      }
    }
  }
}

struct StatusPopoverView: View {
  @EnvironmentObject private var statusModel: StatusModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("OpenSoundcard GigaACE")
        .font(.headline)

      StatusRow(label: "CoreAudio Plug-in", value: statusModel.pluginStatus)
      StatusRow(label: "CoreAudio Device", value: statusModel.deviceStatus)
      StatusRow(label: "Capture", value: statusModel.captureState)
      StatusRow(label: "Packets/sec", value: statusModel.packetsPerSecondText)
      StatusRow(label: "Decoded frames/sec", value: statusModel.decodedFramesPerSecondText)
      StatusRow(label: "Buffer", value: statusModel.fillEstimateText)

      Divider()

      HStack {
        Button(statusModel.captureButtonTitle) {
          statusModel.toggleCapture()
        }
        Button(statusModel.demoToneButtonTitle) {
          statusModel.toggleDemoTone()
        }
      }
    }
    .padding(16)
    .frame(width: 300)
  }
}

private struct DeviceSection: View {
  @EnvironmentObject private var statusModel: StatusModel

  var body: some View {
    PanelSection(title: "Device") {
      StatusRow(label: "CoreAudio Plug-in", value: statusModel.pluginStatus)
      StatusRow(label: "Plug-in Path", value: statusModel.pluginPathText)
      StatusRow(label: "Plug-in Version", value: statusModel.pluginVersionText)
      StatusRow(label: "Version Match", value: statusModel.pluginVersionMatchText)
      StatusRow(label: "CoreAudio Device", value: statusModel.deviceStatus)
      if let restartSuggestion = statusModel.installRestartSuggestion {
        StatusRow(label: "Restart Suggestion", value: restartSuggestion)
      }
      ForEach(statusModel.installScriptPaths) { scriptPath in
        StatusRow(label: scriptPath.label, value: scriptPath.url.path)
      }
      StatusRow(label: "Sample Rate", value: statusModel.sampleRateText)
      StatusRow(label: "Channels", value: statusModel.channelsText)
    }
  }
}

private struct CaptureSection: View {
  @EnvironmentObject private var statusModel: StatusModel

  var body: some View {
    PanelSection(title: "Capture") {
      HStack(spacing: 8) {
        Picker(
          "Interface",
          selection: Binding(
            get: { statusModel.selectedInterfaceID },
            set: { statusModel.selectInterface($0) }
          )
        ) {
          if statusModel.captureInterfaces.isEmpty {
            Text("No interfaces").tag("")
          }
          ForEach(statusModel.captureInterfaces) { captureInterface in
            Text(captureInterface.displayName).tag(captureInterface.id)
          }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .disabled(statusModel.isInterfaceSelectionDisabled)

        Button {
          statusModel.refreshCaptureInterfaces()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh interfaces")
        .disabled(statusModel.isInterfaceSelectionDisabled)
      }
      StatusRow(label: "State", value: statusModel.captureState)
      StatusRow(label: "Packets/sec", value: statusModel.packetsPerSecondText)
      StatusRow(label: "Decoded frames/sec", value: statusModel.decodedFramesPerSecondText)
      if statusModel.lastErrorText != "None" {
        StatusRow(label: "Last error", value: statusModel.lastErrorText)
      }
    }
  }
}

private struct StageboxSection: View {
  @EnvironmentObject private var statusModel: StatusModel

  var body: some View {
    PanelSection(title: "Stagebox / Console") {
      Picker("Variant", selection: $statusModel.selectedStageboxVariantID) {
        ForEach(StageboxIdentityVariant.all) { variant in
          Text(variant.displayName).tag(variant.id)
        }
      }
      Stepper(
        "Duration: \(Int(statusModel.probeDurationSeconds))s",
        value: $statusModel.probeDurationSeconds,
        in: 1 ... 30,
        step: 1
      )
      ControlButton(
        title: statusModel.stageboxProbeButtonTitle,
        systemImage: statusModel.stageboxProbeSystemImage
      ) {
        statusModel.stageboxProbe()
      }
      StatusRow(label: "Identification", value: statusModel.stageboxIdentification)
      StatusRow(label: "Active variant", value: statusModel.activeVariant)
      StatusRow(label: "Probe remaining", value: statusModel.probeRemainingText)
      StatusRow(label: "Transmitted frames", value: statusModel.transmittedFramesText)
      StatusRow(label: "Console response frames", value: statusModel.consoleResponseFramesText)
      StatusRow(label: "Last console MAC", value: statusModel.lastConsoleMAC)
      StatusRow(label: "Allen & Heath OUI detected", value: statusModel.allenHeathOUIDetectedText)
      StatusRow(label: "Last response age", value: statusModel.lastResponseAgeText)
      StatusRow(label: "Last probe error", value: statusModel.lastProbeError)
      StatusRow(label: "Safety warning", value: statusModel.safetyWarning)
    }
  }
}

private struct BufferSection: View {
  @EnvironmentObject private var statusModel: StatusModel

  var body: some View {
    PanelSection(title: "Buffer") {
      StatusRow(label: "Fill estimate", value: statusModel.fillEstimateText)
      StatusRow(label: "Read index", value: statusModel.readIndexText)
      StatusRow(label: "Write index", value: statusModel.writeIndexText)
      StatusRow(label: "Underruns", value: statusModel.underrunsText)
      StatusRow(label: "Overruns", value: statusModel.overrunsText)
    }
  }
}

private struct ControlsSection: View {
  @EnvironmentObject private var statusModel: StatusModel

  var body: some View {
    PanelSection(title: "Controls") {
      VStack(alignment: .leading, spacing: 10) {
        ControlButton(title: "Start Capture", systemImage: "play.fill") {
          statusModel.startCapture()
        }
        .disabled(statusModel.isRunning)

        ControlButton(title: "Stop Capture", systemImage: "stop.fill") {
          statusModel.stopCapture()
        }
        .disabled(!statusModel.isRunning && !statusModel.demoToneEnabled)

        ControlButton(title: statusModel.demoToneButtonTitle, systemImage: "waveform") {
          statusModel.toggleDemoTone()
        }

        ControlButton(
          title: "Show install/repair script instructions", systemImage: "wrench.and.screwdriver"
        ) {
          statusModel.showInstallInstructions()
        }

        ControlButton(title: "Export Diagnostics", systemImage: "square.and.arrow.up") {
          statusModel.exportDiagnostics()
        }

        ControlButton(title: "Open Logs", systemImage: "doc.text.magnifyingglass") {
          statusModel.openLogs()
        }
      }
    }
  }
}

private struct DiagnosticsSection: View {
  @EnvironmentObject private var statusModel: StatusModel

  var body: some View {
    PanelSection(title: "Diagnostics") {
      VStack(alignment: .leading, spacing: 6) {
        Text("Ableton validation notes")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
        TextEditor(text: $statusModel.abletonValidationNotes)
          .font(.system(size: 13))
          .frame(minHeight: 76)
          .overlay {
            RoundedRectangle(cornerRadius: 6)
              .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
          }
      }
      StatusRow(label: "Export Status", value: statusModel.diagnosticsExportStatus)
    }
  }
}

private struct PanelSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)
      VStack(alignment: .leading, spacing: 8) {
        content
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct StatusRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 150, alignment: .leading)
      Text(value)
        .fontWeight(.medium)
        .textSelection(.enabled)
        .lineLimit(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 13))
  }
}

private struct ControlButton: View {
  let title: String
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .controlSize(.regular)
    .help(title)
  }
}

private struct StatePill: View {
  let text: String
  let tone: StatusTone

  var body: some View {
    Text(text)
      .font(.system(size: 12, weight: .semibold))
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .foregroundStyle(tone.foreground)
      .background(tone.background, in: Capsule())
  }
}

enum StatusTone {
  case neutral
  case good
  case warning
  case error
  case accent

  var foreground: Color {
    switch self {
    case .neutral:
      Color(nsColor: .labelColor)
    case .good:
      Color(nsColor: .systemGreen)
    case .warning:
      Color(nsColor: .systemOrange)
    case .error:
      Color(nsColor: .systemRed)
    case .accent:
      Color(nsColor: .controlAccentColor)
    }
  }

  var background: Color {
    foreground.opacity(0.14)
  }
}
