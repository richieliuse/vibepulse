import CryptoKit
import Foundation
import VibePulseAgents
import VibePulseRelay

/// Calls the public store API, then the relay's `onRemove`, after a verdict is accepted.
/// The store does not conform to `RelayResolving`; relay fields are read back from it.
final class StoreRelayBridge: RelayResolving, @unchecked Sendable {
    let store: InteractionStore
    let secret: String
    let wall: @Sendable () -> TimeInterval
    weak var relay: InteractionRelay?

    init(store: InteractionStore, secret: String, wall: @escaping @Sendable () -> TimeInterval) {
        self.store = store
        self.secret = secret
        self.wall = wall
    }

    func setRelayListener(_ listener: InteractionRelay?) {
        relay = listener
    }

    /// `setOnPark` runs after a v2 park. Re-read the job so the relay sees the store's fields.
    func handoffParked(_ job: ParkedRelayJob) {
        guard let relay else { return }
        guard let parked = store.relayJob(for: job.requestID) else { return }
        guard let publish = relayPublishJob(from: parked, wall: wall()) else { return }
        relay.onPark(publish)
    }

    /// LAN and relay verdicts share `answer`. `onRemove` runs only after it accepts.
    func commit(requestID: String, verdict: String, mac: String?, timestamp: Int?, reason: String) -> InteractionResult? {
        let mapped = verdict == "terminal" ? "leave_it" : verdict
        guard mapped == "approve" || mapped == "deny" || mapped == "leave_it" else { return nil }
        guard let result = store.answer(requestID: requestID, verdict: mapped, mac: mac, timestamp: timestamp) else {
            return nil
        }
        relay?.onRemove(requestID: requestID, reason: reason)
        return result
    }

    func resolve(
        _ result: RelayResolution,
        verify: (RelayPublishJob, RelayResolution) -> Bool
    ) -> (accepted: Bool, reason: String) {
        guard let parked = store.relayJob(for: result.requestID) else {
            return (false, "no relay job")
        }
        guard let job = relayPublishJob(from: parked, wall: wall()) else {
            return (false, "no relay job")
        }
        guard verify(job, result) else { return (false, "signature rejected") }
        if result.verdict == "panic" {
            _ = store.panic()
            relay?.onRemove(requestID: result.requestID, reason: "panic")
            return (true, "panic")
        }
        let mapped = result.verdict == "terminal" ? "leave_it" : result.verdict
        guard mapped == "approve" || mapped == "deny" || mapped == "leave_it" else {
            return (false, "bad request")
        }
        let mac: String?
        let timestamp: Int?
        if secret.isEmpty {
            mac = nil
            timestamp = nil
        } else {
            let stamp = Int(wall().rounded(.towardZero))
            let digest = sha256Hex(parked.canonicalViewBytes)
            mac = signAnswerV2(
                secret: secret, provider: job.provider, requestID: parked.requestID,
                digest: digest, verdict: mapped, timestamp: stamp)
            timestamp = stamp
        }
        let reason = result.verdict == "terminal" ? "terminal" : "resolved"
        if commit(requestID: result.requestID, verdict: mapped, mac: mac, timestamp: timestamp, reason: reason) != nil {
            return (true, "ok")
        }
        return (false, "rejected")
    }
}

/// Build the relay handoff from the store's parked job. `expiresAt` is the wall hold.
func relayPublishJob(from parked: ParkedRelayJob, wall: TimeInterval) -> RelayPublishJob? {
    guard parked.challenge.count == 32, !parked.requestID.isEmpty else { return nil }
    guard case let .success(.object(fields)) = CanonicalJSON.parse(parked.canonicalViewBytes) else { return nil }
    guard case let .string(provider) = fields["provider"], provider == "claude" || provider == "codex" else {
        return nil
    }
    guard case let .int(holdMS) = fields["hold_ms"], holdMS > 0 else { return nil }
    let expiry = (wall + Double(holdMS) / 1000).rounded(.up)
    guard expiry.isFinite, expiry > 0, expiry <= Double(UInt32.max) else { return nil }
    guard let expiresAt = UInt32(exactly: expiry) else { return nil }
    return RelayPublishJob(
        requestID: parked.requestID,
        challenge: parked.challenge,
        viewBytes: parked.canonicalViewBytes,
        viewSHA256: Data(SHA256.hash(data: parked.canonicalViewBytes)),
        expiresAt: expiresAt,
        provider: provider,
        canApprove: parked.canApprove
    )
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
