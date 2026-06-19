import Foundation

struct DiagnosticsSnapshot {
  var generatedAt: Date
  var macOSVersion: String
  var appVersion: String
  var installState: DeviceInstallState
  var abletonValidationNotes: String
  var selectedNetworkInterface: String
  var streamStatus: [String]
  var stageboxIdentification: [String]
  var logLines: [String]
}

enum DiagnosticsExporter {
  static func defaultFilename(generatedAt date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    let timestamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    return "OpenSoundcardDiagnostics-\(timestamp).txt"
  }

  static func write(_ snapshot: DiagnosticsSnapshot, to outputURL: URL) throws {
    try report(for: snapshot).write(to: outputURL, atomically: true, encoding: .utf8)
  }

  static func report(for snapshot: DiagnosticsSnapshot) -> String {
    """
    OpenSoundcard Diagnostics
    Generated: \(snapshot.generatedAt)

    macOS version
    \(snapshot.macOSVersion)

    app version
    \(snapshot.appVersion)

    plug-in installed path/version
    \(pluginSummary(snapshot.installState))

    CoreAudio device visible yes/no
    \(snapshot.installState.deviceVisible ? "yes" : "no")

    Ableton validation notes
    \(notesText(snapshot.abletonValidationNotes))

    selected network interface
    \(snapshot.selectedNetworkInterface)

    stream status snapshot
    \(joinedLines(snapshot.streamStatus))

    stagebox identification snapshot
    \(joinedLines(snapshot.stageboxIdentification))

    last 200 log lines
    \(joinedLines(snapshot.logLines))
    """
  }

  static func collectLastLogLines(limit: Int = 200) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "show",
      "--style",
      "compact",
      "--last",
      "24h",
      "--predicate",
      "process == \"OpenSoundcardManager\" OR eventMessage CONTAINS[c] \"OpenSoundcard\"",
    ]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return ["Unable to collect unified log lines: \(error.localizedDescription)"]
    }

    let output = String(
      data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    let errorOutput = String(
      data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""

    guard process.terminationStatus == 0 else {
      let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      return ["Unable to collect unified log lines: \(message)"]
    }

    let lines = output
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .suffix(limit)

    if lines.isEmpty {
      return ["No matching OpenSoundcard log lines found in the last 24 hours."]
    }

    return Array(lines)
  }

  private static func pluginSummary(_ state: DeviceInstallState) -> String {
    guard !state.installedPlugins.isEmpty else {
      return "Not installed"
    }

    var lines = state.installedPlugins.map { plugin in
      "\(plugin.url.path) - \(plugin.displayVersion)"
    }
    lines.append("Expected manager version: \(state.expectedVersion)")
    lines.append("Version match: \(state.versionMatches ? "yes" : "no")")

    if let recommendation = state.restartRecommendation {
      lines.append("Restart suggestion: \(recommendation)")
    }

    lines.append("Scripts:")
    lines += state.scriptPaths.map { "\($0.label): \($0.url.path)" }
    return joinedLines(lines)
  }

  private static func notesText(_ notes: String) -> String {
    let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "None entered" : trimmed
  }

  private static func joinedLines(_ lines: [String]) -> String {
    lines.isEmpty ? "None" : lines.joined(separator: "\n")
  }
}
