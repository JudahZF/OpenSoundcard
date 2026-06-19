import CoreAudio
import Foundation

struct InstalledHALPlugin: Identifiable, Hashable {
  let url: URL
  let version: String?

  var id: String {
    url.path
  }

  var displayVersion: String {
    version ?? "Unknown"
  }
}

struct InstallScriptPath: Identifiable, Hashable {
  let label: String
  let url: URL

  var id: String {
    label
  }
}

struct DeviceInstallState {
  static let deviceName = "OpenSoundcard GigaACE"

  var installedPlugins: [InstalledHALPlugin]
  var expectedVersion: String
  var deviceVisible: Bool
  var scriptPaths: [InstallScriptPath]

  static var empty: DeviceInstallState {
    DeviceInstallState(
      installedPlugins: [],
      expectedVersion: "Unknown",
      deviceVisible: false,
      scriptPaths: []
    )
  }

  var pluginInstalled: Bool {
    !installedPlugins.isEmpty
  }

  var versionMatches: Bool {
    pluginInstalled && installedPlugins.allSatisfy { $0.version == expectedVersion }
  }

  var pluginStatusText: String {
    pluginInstalled ? "Installed" : "Not installed"
  }

  var deviceStatusText: String {
    deviceVisible ? "Loaded" : "Missing"
  }

  var installedPathText: String {
    guard !installedPlugins.isEmpty else {
      return "Not installed"
    }

    return installedPlugins.map(\.url.path).joined(separator: "\n")
  }

  var installedVersionText: String {
    guard !installedPlugins.isEmpty else {
      return "Not installed"
    }

    return installedPlugins
      .map { "\($0.displayVersion) at \($0.url.lastPathComponent)" }
      .joined(separator: "\n")
  }

  var versionMatchText: String {
    guard pluginInstalled else {
      return "Not installed"
    }

    return versionMatches
      ? "All installed plug-ins match app \(expectedVersion)"
      : "Mismatch or unknown version against app \(expectedVersion)"
  }

  var restartRecommendation: String? {
    guard pluginInstalled, !deviceVisible else {
      return nil
    }

    if let restartScript = scriptPaths.first(where: { $0.label == "Restart CoreAudio" }) {
      return "Installed but device is missing. Run \(restartScript.url.path)."
    }

    return "Installed but device is missing. Restart coreaudiod."
  }

  func scriptPath(for label: String) -> URL? {
    scriptPaths.first { $0.label == label }?.url
  }
}

final class DeviceInstallController {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func inspect(repositoryRoot: URL, expectedVersion: String) -> DeviceInstallState {
    DeviceInstallState(
      installedPlugins: installedPlugins(),
      expectedVersion: expectedVersion,
      deviceVisible: isOpenSoundcardDeviceVisible(),
      scriptPaths: scriptPaths(repositoryRoot: repositoryRoot)
    )
  }

  private func installedPlugins() -> [InstalledHALPlugin] {
    halBundleURLs().compactMap { url in
      guard fileManager.fileExists(atPath: url.path) else {
        return nil
      }

      return InstalledHALPlugin(url: url, version: bundleVersion(at: url))
    }
  }

  private func halBundleURLs() -> [URL] {
    [
      fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Audio/Plug-Ins/HAL/OpenSoundcard.driver"),
      URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/OpenSoundcard.driver"),
    ]
  }

  private func bundleVersion(at url: URL) -> String? {
    if let bundle = Bundle(url: url),
       let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       !version.isEmpty
    {
      return version
    }

    let infoURL = url.appendingPathComponent("Contents/Info.plist")
    guard
      let data = try? Data(contentsOf: infoURL),
      let plist = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: Any],
      let version = plist["CFBundleShortVersionString"] as? String,
      !version.isEmpty
    else {
      return nil
    }

    return version
  }

  private func scriptPaths(repositoryRoot: URL) -> [InstallScriptPath] {
    let scriptsURL = repositoryRoot.appendingPathComponent("platform/macos/scripts")
    return [
      InstallScriptPath(
        label: "Install script",
        url: scriptsURL.appendingPathComponent("install-plugin.sh")
      ),
      InstallScriptPath(
        label: "Uninstall script",
        url: scriptsURL.appendingPathComponent("uninstall-plugin.sh")
      ),
      InstallScriptPath(
        label: "Restart CoreAudio",
        url: scriptsURL.appendingPathComponent("restart-coreaudiod.sh")
      ),
    ]
  }

  private func isOpenSoundcardDeviceVisible() -> Bool {
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
      coreAudioDeviceName(deviceID) == DeviceInstallState.deviceName
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
}
