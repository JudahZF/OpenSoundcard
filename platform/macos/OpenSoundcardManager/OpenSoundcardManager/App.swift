import SwiftUI

@main
struct OpenSoundcardManagerApp: App {
  @StateObject private var statusModel = StatusModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(statusModel)
    }
    .windowStyle(.titleBar)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Export Diagnostics") {
          statusModel.exportDiagnostics()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
      }
    }

    MenuBarExtra("OpenSoundcard", systemImage: "waveform.path.ecg") {
      StatusPopoverView()
        .environmentObject(statusModel)
    }
    .menuBarExtraStyle(.window)
  }
}
