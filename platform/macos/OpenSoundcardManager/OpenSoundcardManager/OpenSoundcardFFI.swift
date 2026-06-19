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

struct OscStatusSnapshot {
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

  var engineStatus: EngineStatus {
    EngineStatus(
      state: OscEngineState(rawValue: state) ?? .error,
      sampleRate: sampleRate,
      channelCount: channelCount,
      capacityFrames: capacityFrames,
      readIndex: readIndex,
      writeIndex: writeIndex,
      packetCount: packetCount,
      decodedFrameCount: decodedFrameCount,
      underrunCount: underrunCount,
      overrunCount: overrunCount,
      lastErrorCode: lastErrorCode
    )
  }
}

final class OpenSoundcardHALBridge {
  private let controlURL = URL(fileURLWithPath: "/tmp/opensoundcard_manager_control")
  private let statusURL = URL(fileURLWithPath: "/tmp/opensoundcard_manager_status")

  var statusAvailable: Bool {
    FileManager.default.fileExists(atPath: statusURL.path)
  }

  var availabilityMessage: String {
    statusAvailable ? "HAL bridge connected" : "HAL bridge unavailable"
  }

  func setDemoToneEnabled(_ enabled: Bool) {
    let value = enabled ? "demo_tone_enabled=1\n" : "demo_tone_enabled=0\n"
    do {
      try value.write(to: controlURL, atomically: true, encoding: .utf8)
    } catch {
      // The manager must remain usable even if the HAL bridge is not writable.
    }
  }

  func status() -> EngineStatus? {
    guard OscStatusSnapshot.hasExpectedLayout,
      let data = try? Data(contentsOf: statusURL),
      data.count >= MemoryLayout<OscStatusSnapshot>.stride
    else {
      return nil
    }

    var snapshot = OscStatusSnapshot()
    _ = withUnsafeMutableBytes(of: &snapshot) { destination in
      data.copyBytes(to: destination)
    }
    return snapshot.engineStatus
  }
}
