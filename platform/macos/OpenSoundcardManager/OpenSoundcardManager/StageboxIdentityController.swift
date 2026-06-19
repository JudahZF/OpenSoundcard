import Foundation

struct StageboxProbeSnapshot {
  enum State: Equatable {
    case idle
    case starting
    case transmitting
    case stopping
    case finished
    case error(String)

    var isActive: Bool {
      self == .starting || self == .transmitting || self == .stopping
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
  private var activeRunID: UUID?
  private var cancelledRunIDs: Set<UUID> = []

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

      let runID = UUID()
      self.activeRunID = runID
      self.cancelledRunIDs.remove(runID)
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
          runID: runID,
          interfaceName: interfaceName,
          variant: variant,
          duration: boundedDuration
        )
      }
    }
  }

  func stop() {
    queue.async {
      guard let runID = self.activeRunID, self.current.state.isActive else {
        return
      }

      self.cancelledRunIDs.insert(runID)
      self.current.state = .stopping
    }
  }

  private func transmitLoop(
    runID: UUID,
    interfaceName: String,
    variant: StageboxIdentityVariant,
    duration: TimeInterval
  ) {
    do {
      let frame = try Self.identityFrame(for: variant)
      let pcap = try PcapLibrary.shared.openLive(interfaceName: interfaceName)
      let deadline = Date().addingTimeInterval(duration)
      let sleepMicros = max(1, UInt32((1_000_000 / max(variant.packetRate, 1)).rounded()))

      setRunTransmitting(runID)

      do {
        while Date() < deadline, !stopRequested(runID) {
          try PcapLibrary.shared.inject(handle: pcap, frame: frame)
          queue.async {
            guard self.activeRunID == runID else {
              return
            }

            self.current.transmittedFrames += 1
          }
          usleep(sleepMicros)
        }
      } catch {
        try? PcapLibrary.shared.close(pcap)
        failRun(runID, error: error)
        return
      }

      try? PcapLibrary.shared.close(pcap)
      finishRun(runID)
    } catch {
      failRun(runID, error: error)
    }
  }

  private func stopRequested(_ runID: UUID) -> Bool {
    queue.sync {
      activeRunID != runID || cancelledRunIDs.contains(runID)
    }
  }

  private func setRunTransmitting(_ runID: UUID) {
    queue.async {
      guard self.activeRunID == runID, !self.cancelledRunIDs.contains(runID) else {
        return
      }

      self.current.state = .transmitting
    }
  }

  private func finishRun(_ runID: UUID) {
    queue.async {
      guard self.activeRunID == runID else {
        return
      }

      self.cancelledRunIDs.remove(runID)
      self.activeRunID = nil
      if case .error = self.current.state {
        return
      }
      self.current.state = .finished
    }
  }

  private func failRun(_ runID: UUID, error: Error) {
    queue.async {
      guard self.activeRunID == runID else {
        return
      }

      self.cancelledRunIDs.remove(runID)
      self.activeRunID = nil
      self.current.state = .error(error.localizedDescription)
      self.current.lastError = error.localizedDescription
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
