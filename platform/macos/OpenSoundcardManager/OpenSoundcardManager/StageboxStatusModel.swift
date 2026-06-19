import Foundation

struct StageboxStatusModel {
  enum ProbeState: Equatable {
    case disabled
    case probing
    case responding
    case noResponse
    case error(String)

    var displayName: String {
      switch self {
      case .disabled:
        "Disabled"
      case .probing:
        "Probing"
      case .responding:
        "Response detected"
      case .noResponse:
        "No response"
      case .error:
        "Error"
      }
    }
  }

  var state: ProbeState = .disabled
  var activeVariant: StageboxIdentityVariant?
  var responseCount: UInt64 = 0
  var lastConsoleMAC: String?
  var allenHeathOUIDetected = false
  var lastResponseDate: Date?
  var lastError: String?
  var probeEndsAt: Date?
  var transmittedFrames: UInt64 = 0

  static let safetyWarning =
    "Isolated SLink/GigaACE test link only. Do not use probe transmit on a normal LAN."

  var responseAgeText: String {
    guard let lastResponseDate else {
      return "None"
    }

    let age = max(Date().timeIntervalSince(lastResponseDate), 0)
    if age < 1 {
      return "Just now"
    }
    return "\(Int(age))s ago"
  }

  var remainingText: String {
    guard let probeEndsAt else {
      return "None"
    }

    let remaining = max(probeEndsAt.timeIntervalSinceNow, 0)
    return "\(Int(ceil(remaining)))s"
  }
}

struct StageboxIdentityVariant: Identifiable, Hashable {
  let id: UInt8
  let name: String
  let note: String
  let ethertype: UInt16
  let streamType: UInt8
  let frameLength: Int
  let packetRate: Double

  var displayName: String {
    "\(id) \(name)"
  }

  static let all: [StageboxIdentityVariant] = [
    StageboxIdentityVariant(
      id: 0,
      name: "gx4816-slink-48k",
      note: "GX4816/SLink reference shape at 48k packets/s.",
      ethertype: 0x04EE,
      streamType: 0x02,
      frameLength: 1276,
      packetRate: 48000
    ),
    StageboxIdentityVariant(
      id: 1,
      name: "gx4816-slink-96k",
      note: "GX4816/SLink reference header at 96k packets/s.",
      ethertype: 0x04EE,
      streamType: 0x02,
      frameLength: 1276,
      packetRate: 96000
    ),
    StageboxIdentityVariant(
      id: 2,
      name: "avantis-header-gx-mac",
      note: "Console-style header with GX4816 source MAC.",
      ethertype: 0x04EE,
      streamType: 0x02,
      frameLength: 1276,
      packetRate: 48000
    ),
    StageboxIdentityVariant(
      id: 3,
      name: "gx4816-stream01",
      note: "GX4816 header with stream type 0x01.",
      ethertype: 0x04EE,
      streamType: 0x01,
      frameLength: 1276,
      packetRate: 48000
    ),
    StageboxIdentityVariant(
      id: 4,
      name: "gx4816-zero-prefix",
      note: "GX4816 MAC and stream 0x02 with zeroed prefix bytes.",
      ethertype: 0x04EE,
      streamType: 0x02,
      frameLength: 1276,
      packetRate: 48000
    ),
    StageboxIdentityVariant(
      id: 5,
      name: "short-gace-identity",
      note: "Short experimental ASCII GACE/GX4816 identity frame.",
      ethertype: 0x04EE,
      streamType: 0xF0,
      frameLength: 64,
      packetRate: 1000
    ),
  ]
}
