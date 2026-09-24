import CryptoKit
import Foundation

/// Plain-JSON numbers publisher (`/api/tokens`, `/api/max-tracker`, `/api/github`).
/// The POST is injected. This slice does not open a socket and does not follow redirects.
public enum NumbersPublish {
    public static let checkEvery: TimeInterval = 30
    public static let heartbeatEvery: TimeInterval = 300
    public static let userAgent = "vibepulse-publisher/1"

    public static func minSendInterval(path: String) -> TimeInterval {
        switch path {
        case "/api/tokens": return 300
        case "/api/max-tracker", "/api/github": return 1800
        default: return heartbeatEvery
        }
    }

    public static func fingerprint(_ payload: CanonicalJSON.Value) throws -> String {
        let body = try CanonicalJSON.encodePublisher(payload)
        return SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    public static func isStartupPlaceholder(_ payload: CanonicalJSON.Value) -> Bool {
        guard case let .object(fields) = payload,
              case let .object(totals) = fields["usageTotals"] else { return false }
        return totals["placeholder"] == .bool(true)
    }

    public static func staleFields(_ payload: CanonicalJSON.Value) -> Set<String> {
        guard case let .object(fields) = payload else { return [] }
        return Set(fields.compactMap { key, value in
            key.hasSuffix("Stale") && value == .bool(true) ? key : nil
        })
    }

    public static func shouldSend(
        lastFingerprint: String?,
        lastSentAt: TimeInterval,
        fingerprint: String,
        now: TimeInterval,
        minInterval: TimeInterval = 0
    ) -> Bool {
        guard let lastFingerprint else { return true }
        let elapsed = now - lastSentAt
        if elapsed < minInterval { return false }
        if fingerprint != lastFingerprint { return true }
        return elapsed >= max(heartbeatEvery, minInterval)
    }
}

public struct PublishRequest: Equatable, Sendable {
    public var url: String
    public var body: Data
    public var contentType: String
    public var userAgent: String
    public var publisher: String

    public init(url: String, body: Data, contentType: String, userAgent: String, publisher: String) {
        self.url = url
        self.body = body
        self.contentType = contentType
        self.userAgent = userAgent
        self.publisher = publisher
    }
}

public final class NumbersPublisher {
    public let relayURL: String
    public let machine: String
    private let producers: [(String, () throws -> CanonicalJSON.Value)]
    private let post: (PublishRequest) -> Bool
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var stopped = false
    private var state: [String: Sent] = [:]

    public init(
        relayURL: String,
        machine: String,
        producers: [(String, () throws -> CanonicalJSON.Value)],
        post: @escaping (PublishRequest) -> Bool,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        var trimmed = relayURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.relayURL = trimmed
        self.machine = machine
        self.producers = producers
        self.post = post
        self.clock = clock
    }

    /// No further POST. Safe if `publishOnce` never ran. A second call is a no-op.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
    }

    /// One pass, in producer order. Returns how many POSTs succeeded.
    /// A producer or encode failure skips that path and leaves its state unchanged.
    public func publishOnce() -> Int {
        lock.lock()
        let halted = stopped
        lock.unlock()
        if halted { return 0 }
        var sends = 0
        for (path, produce) in producers {
            let payload: CanonicalJSON.Value
            do { payload = try produce() } catch { continue }
            if path == "/api/tokens", NumbersPublish.isStartupPlaceholder(payload) { continue }
            let body: Data
            let fingerprint: String
            do {
                body = try CanonicalJSON.encodePublisher(payload)
                fingerprint = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            } catch { continue }
            let currentStale = NumbersPublish.staleFields(payload)
            let previous = state[path]
            let now = clock()
            let minimum = NumbersPublish.minSendInterval(path: path)
            let fields = payload.objectFields
            let recovered = path == "/api/tokens" && previous.map { sent in
                sent.stale.contains { fields?[$0] == .bool(false) }
            } ?? false
            if !recovered && !NumbersPublish.shouldSend(
                lastFingerprint: previous?.fingerprint,
                lastSentAt: previous?.sentAt ?? 0,
                fingerprint: fingerprint,
                now: now,
                minInterval: minimum
            ) { continue }
            let request = PublishRequest(
                url: relayURL + path,
                body: body,
                contentType: "application/json",
                userAgent: NumbersPublish.userAgent,
                publisher: machine
            )
            if post(request) {
                state[path] = Sent(fingerprint: fingerprint, sentAt: now, stale: currentStale)
                sends += 1
            }
        }
        return sends
    }
}

private struct Sent {
    var fingerprint: String
    var sentAt: TimeInterval
    var stale: Set<String>
}

private extension CanonicalJSON.Value {
    var objectFields: [String: CanonicalJSON.Value]? {
        if case let .object(fields) = self { return fields }
        return nil
    }
}
