import Foundation

struct StageboxProbeSnapshot {
  enum State: Equatable {
    case idle
    case starting
    case transmitting
    case finished
    case error(String)

    var isActive: Bool {
      self == .starting || self == .transmitting
    }
  }

  var state: State = .idle
  var variant: StageboxIdentityVariant?
  var interfaceName: String?
  var startedAt: Date?
  var endsAt: Date?
  var transmittedFrames: UInt64 = 0
  var lastError: String?
}

final class StageboxIdentityController {
  private let queue = DispatchQueue(label: "org.opensoundcard.manager.stagebox-identity")
  private var current = StageboxProbeSnapshot()
  private var shouldStop = false

  var snapshot: StageboxProbeSnapshot {
    queue.sync {
      current
    }
  }

  func start(interfaceName: String, variant: StageboxIdentityVariant, duration: TimeInterval) {
    let boundedDuration = min(max(duration, 1), 30)
    queue.async {
      guard !self.current.state.isActive else {
        return
      }

      self.shouldStop = false
      let now = Date()
      self.current = StageboxProbeSnapshot(
        state: .starting,
        variant: variant,
        interfaceName: interfaceName,
        startedAt: now,
        endsAt: now.addingTimeInterval(boundedDuration)
      )

      DispatchQueue.global(qos: .userInitiated).async {
        self.transmitLoop(
          interfaceName: interfaceName,
          variant: variant,
          duration: boundedDuration
        )
      }
    }
  }

  func stop() {
    queue.async {
      self.shouldStop = true
      if self.current.state.isActive {
        self.current.state = .finished
      }
    }
  }

  private func transmitLoop(
    interfaceName: String,
    variant: StageboxIdentityVariant,
    duration: TimeInterval
  ) {
    do {
      let pcap = try PcapLibrary.shared.openLive(interfaceName: interfaceName)
      defer {
        try? PcapLibrary.shared.close(pcap)
      }

      let frame = try Self.identityFrame(for: variant)
      let deadline = Date().addingTimeInterval(duration)
      let sleepMicros = max(1, UInt32((1_000_000 / max(variant.packetRate, 1)).rounded()))

      queue.async {
        self.current.state = .transmitting
      }

      while Date() < deadline, !stopRequested() {
        try PcapLibrary.shared.inject(handle: pcap, frame: frame)
        queue.async {
          self.current.transmittedFrames += 1
        }
        usleep(sleepMicros)
      }

      queue.async {
        if case .error = self.current.state {
          return
        }
        self.current.state = .finished
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

  private static func identityFrame(for variant: StageboxIdentityVariant) throws -> Data {
    guard let spec = FrameSpec.specs[variant.id] else {
      throw StageboxProbeError.unknownVariant
    }

    var frame = [UInt8](repeating: 0, count: variant.frameLength)
    frame[0 ..< 6] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    frame[6 ..< 12] = [0x00, 0x04, 0xC4, 0x06, 0xCF, 0xE8]
    frame[12] = UInt8((variant.ethertype >> 8) & 0xFF)
    frame[13] = UInt8(variant.ethertype & 0xFF)
    frame[14 ..< 19] = ArraySlice(spec.header)
    frame[19] = 0
    frame[20] = variant.streamType

    if spec.shortIdentity && frame.count >= 52 {
      frame[24 ..< 28] = ArraySlice([0x47, 0x41, 0x43, 0x45])
      frame[28 ..< 36] = ArraySlice([0x01, 0x48, 0x00, 0x40, 0x00, 0x01, 0x77, 0x00])
      frame[36 ..< 42] = ArraySlice([0x47, 0x58, 0x34, 0x38, 0x31, 0x36])
    }

    return Data(frame)
  }
}

private enum StageboxProbeError: LocalizedError {
  case unknownVariant

  var errorDescription: String? {
    "Unknown stagebox identity variant"
  }
}

private struct FrameSpec {
  let header: [UInt8]
  let shortIdentity: Bool

  static let specs: [UInt8: FrameSpec] = [
    0: FrameSpec(header: [0x00, 0x0A, 0x04, 0xEA, 0x00], shortIdentity: false),
    1: FrameSpec(header: [0x00, 0x0A, 0x04, 0xEA, 0x00], shortIdentity: false),
    2: FrameSpec(header: [0x00, 0x00, 0x04, 0xEA, 0x00], shortIdentity: false),
    3: FrameSpec(header: [0x00, 0x0A, 0x04, 0xEA, 0x00], shortIdentity: false),
    4: FrameSpec(header: [0x00, 0x00, 0x00, 0x00, 0x00], shortIdentity: false),
    5: FrameSpec(header: [0x00, 0x00, 0x00, 0x00, 0x00], shortIdentity: true),
  ]
}
