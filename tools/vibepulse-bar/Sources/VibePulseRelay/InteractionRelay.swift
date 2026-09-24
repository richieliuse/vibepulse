import Foundation

public enum InteractionRelayLimits {
    public static let maxResponseBytes = 4096
    public static let queueCapacity = 8
    public static let deleteCapacity = 8
    public static let minBackoff: TimeInterval = 0.5
    public static let maxBackoff: TimeInterval = 5
    public static let pollInterval: TimeInterval = 0.5
    public static let statusPublishInterval: TimeInterval = 5
    public static let statusExpirySeconds = 15
    public static let defaultConnectTimeout: TimeInterval = 2
    public static let defaultReadTimeout: TimeInterval = 5
}

public struct RelayAdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(message: String) { self.message = message }
}

public struct RelayOrigin: Equatable, Sendable {
    public let origin: String
    public let host: String
    public let port: Int

    /// HTTPS origin only. `:0` is treated as 443, matching `urlsplit().port or 443`.
    public static func parse(_ baseURL: String) throws -> RelayOrigin {
        guard let components = URLComponents(string: baseURL) else {
            throw RelayAdapterError(message: portish(baseURL) ? "invalid relay port" : "relay URL must be an HTTPS origin")
        }
        guard components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              (components.query ?? "").isEmpty,
              (components.fragment ?? "").isEmpty
        else {
            throw RelayAdapterError(message: "relay URL must be an HTTPS origin")
        }
        let port: Int
        if let parsed = components.port {
            port = parsed == 0 ? 443 : parsed
        } else if portish(baseURL) {
            throw RelayAdapterError(message: "invalid relay port")
        } else {
            port = 443
        }
        guard (1...65535).contains(port) else {
            throw RelayAdapterError(message: "invalid relay port")
        }
        let lower = host.lowercased()
        var authority = lower.contains(":") ? "[\(lower)]" : lower
        if port != 443 { authority += ":\(port)" }
        return RelayOrigin(origin: "https://\(authority)", host: lower, port: port)
    }

    private static func portish(_ baseURL: String) -> Bool {
        guard let schemeEnd = baseURL.range(of: "://") else { return false }
        let rest = baseURL[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else {
            return rest.contains(":")
        }
        return rest[..<slash].contains(":")
    }
}

public struct RelayHTTPRequest: Equatable, Sendable {
    public var method: String
    public var url: String
    public var headers: [(String, String)]
    public var body: Data
    public var connectTimeout: TimeInterval
    public var readTimeout: TimeInterval

    public init(method: String, url: String, headers: [(String, String)], body: Data,
                connectTimeout: TimeInterval, readTimeout: TimeInterval) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
    }

    public static func == (lhs: RelayHTTPRequest, rhs: RelayHTTPRequest) -> Bool {
        lhs.method == rhs.method && lhs.url == rhs.url && lhs.body == rhs.body
            && lhs.headers.elementsEqual(rhs.headers, by: ==)
            && lhs.connectTimeout == rhs.connectTimeout && lhs.readTimeout == rhs.readTimeout
    }
}

public struct RelayHTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func == (lhs: RelayHTTPResponse, rhs: RelayHTTPResponse) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body
            && lhs.headers.elementsEqual(rhs.headers, by: ==)
    }
}

public enum RelayAuditField: Equatable, Sendable {
    case text(String)
    case number(Int)
}

public struct RelayPublishJob: Equatable, Sendable {
    public var requestID: String
    public var challenge: Data
    public var viewBytes: Data
    public var viewSHA256: Data
    public var expiresAt: UInt32
    public var provider: String
    public var canApprove: Bool

    public init(requestID: String, challenge: Data, viewBytes: Data, viewSHA256: Data,
                expiresAt: UInt32, provider: String, canApprove: Bool) {
        self.requestID = requestID
        self.challenge = challenge
        self.viewBytes = viewBytes
        self.viewSHA256 = viewSHA256
        self.expiresAt = expiresAt
        self.provider = provider
        self.canApprove = canApprove
    }
}

public struct RelayResolution: Equatable, Sendable {
    public var requestID: String
    public var challenge: Data
    public var viewSHA256: Data
    public var verdict: String
    public var mac: Data

    public init(requestID: String, challenge: Data, viewSHA256: Data, verdict: String, mac: Data) {
        self.requestID = requestID
        self.challenge = challenge
        self.viewSHA256 = viewSHA256
        self.verdict = verdict
        self.mac = mac
    }
}

public protocol RelayResolving: AnyObject {
    func setRelayListener(_ listener: InteractionRelay?)
    func resolve(
        _ result: RelayResolution,
        verify: (RelayPublishJob, RelayResolution) -> Bool
    ) -> (accepted: Bool, reason: String)
}

/// Outbound interaction and agent-status relay. HTTP is injected.
/// `runOnce()` is one synchronous cycle. Python's daemon threads are not started.
public final class InteractionRelay {
    public typealias Transport = (RelayHTTPRequest) throws -> RelayHTTPResponse
    public typealias Audit = (String, [String: RelayAuditField]) -> Void
    public typealias StatusSource = () throws -> CanonicalJSON.Value

    public var publishQueueSize: Int {
        queueLock.lock()
        defer { queueLock.unlock() }
        return events.count
    }

    private let store: RelayResolving?
    private let publishInteractions: Bool
    private let publishAgentStatus: Bool
    private let statusSource: StatusSource?
    private let mailbox: String
    private let macToken: String
    private let keys: RelayKeys
    private let origin: String
    private let transport: Transport
    private let now: () -> TimeInterval
    private let wall: () -> TimeInterval
    private let randomBytes: @Sendable (Int) -> Data
    private let jitter: () -> Double
    private let auditHook: Audit?
    private let connectTimeout: TimeInterval
    private let readTimeout: TimeInterval

    private let queueLock = NSLock()
    private var events: [RelayEvent] = []
    private var publishes: [String: PublishState] = [:]
    private var publishOrder: [String] = []
    private var deletes: [String: DeleteState] = [:]
    private var deleteOrder: [String] = []
    private var nextPoll: TimeInterval = 0
    private var pollFailures = 0
    private var statusState: StatusState?
    private var nextStatus: TimeInterval = 0
    private var lastPublicationID: UInt64 = 0
    private var statusPrepareFailures = 0
    private var stopped = false

    public init(
        store: RelayResolving?,
        baseURL: String,
        mailbox: String,
        macToken: String,
        deviceKeyHex: String,
        transport: @escaping Transport,
        publishInteractions: Bool = true,
        publishAgentStatus: Bool = false,
        statusSource: StatusSource? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wall: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        randomBytes: @escaping @Sendable (Int) -> Data = { count in
            var bytes = [UInt8](repeating: 0, count: count)
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
            }
            return Data(bytes)
        },
        jitter: @escaping () -> Double = { Double.random(in: 0..<1) },
        audit: Audit? = nil,
        connectTimeout: TimeInterval = InteractionRelayLimits.defaultConnectTimeout,
        readTimeout: TimeInterval = InteractionRelayLimits.defaultReadTimeout
    ) throws {
        let parsed = try RelayOrigin.parse(baseURL)
        let token = try InteractionRelayCrypto.b64URLDecode(macToken)
        guard token.count == 32 else {
            throw RelayAdapterError(message: "relay token must encode 32 bytes")
        }
        guard connectTimeout.isFinite, readTimeout.isFinite, connectTimeout > 0, readTimeout > 0 else {
            throw RelayAdapterError(message: "invalid relay timeout")
        }
        guard publishInteractions || publishAgentStatus else {
            throw RelayAdapterError(message: "at least one relay feature must be enabled")
        }
        if publishInteractions && store == nil {
            throw RelayAdapterError(message: "interaction relay requires a store")
        }
        if publishAgentStatus && statusSource == nil {
            throw RelayAdapterError(message: "status relay requires a source")
        }
        let deviceKey = try InteractionRelayCrypto.decodeDeviceKey(deviceKeyHex)
        self.keys = try InteractionRelayCrypto.deriveKeys(deviceKey: deviceKey, mailbox: mailbox)
        self.store = store
        self.publishInteractions = publishInteractions
        self.publishAgentStatus = publishAgentStatus
        self.statusSource = statusSource
        self.mailbox = mailbox
        self.macToken = macToken
        self.origin = parsed.origin
        self.transport = transport
        self.now = now
        self.wall = wall
        self.randomBytes = randomBytes
        self.jitter = jitter
        self.auditHook = audit
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        if publishInteractions {
            store?.setRelayListener(self)
        }
    }

    public func onPark(_ job: RelayPublishJob) {
        guard publishInteractions else { return }
        queueLock.lock()
        let full = events.count >= InteractionRelayLimits.queueCapacity
        if !full { events.append(.park(job)) }
        queueLock.unlock()
        if full { audit("queue_full", "put_request", nil) }
    }

    public func onRemove(requestID: String, reason: String) {
        guard publishInteractions else { return }
        queueLock.lock()
        var dropped = false
        if events.count < InteractionRelayLimits.queueCapacity {
            events.append(.remove(requestID, reason))
        } else if let index = events.firstIndex(where: { $0.requestID == requestID }) {
            events[index] = .remove(requestID, reason)
        } else {
            dropped = true
        }
        queueLock.unlock()
        if dropped { audit("queue_full", "delete_request", nil) }
    }

    /// No further `runOnce`. Safe if a cycle never ran. A second call is a no-op.
    public func stop() {
        queueLock.lock()
        defer { queueLock.unlock() }
        stopped = true
    }

    public func runOnce() {
        queueLock.lock()
        let halted = stopped
        queueLock.unlock()
        guard !halted else { return }
        if publishInteractions { runInteractionsOnce() }
        if publishAgentStatus { runStatusOnce() }
    }

    private func runInteractionsOnce() {
        guard let now = cycleTime() else { return }
        drain(now: now)
        processDeletes(now: now)
        processPublishes(now: now)
        if publishes.values.contains(where: \.published), now >= nextPoll {
            poll(now: now)
        }
    }

    private func runStatusOnce() {
        guard let now = cycleTime() else { return }
        processStatus(now: now)
    }

    private func cycleTime() -> TimeInterval? {
        let value = now()
        return value.isFinite ? value : nil
    }

    private func backoff(_ failures: Int) -> TimeInterval {
        let shift = max(0, failures - 1)
        let power = shift >= 16 ? 65536.0 : Double(1 << shift)
        let base = min(InteractionRelayLimits.maxBackoff, InteractionRelayLimits.minBackoff * power)
        var sample = jitter()
        if !sample.isFinite { sample = 0 }
        sample = min(1, max(0, sample))
        return min(InteractionRelayLimits.maxBackoff, base * (1 + sample * 0.2))
    }

    private func drain(now: TimeInterval) {
        let batch: [RelayEvent] = {
            queueLock.lock()
            defer { queueLock.unlock() }
            let copy = events
            events.removeAll()
            return copy
        }()
        for event in batch {
            switch event {
            case let .park(job):
                do {
                    let makeBytes = randomBytes
                    let envelope = try InteractionRelayCrypto.encodeRequest(
                        keys: keys,
                        mailbox: mailbox,
                        requestID: job.requestID,
                        challenge: job.challenge,
                        expiresAt: job.expiresAt,
                        viewBytes: job.viewBytes,
                        nonce: makeBytes(InteractionRelayCrypto.gcmNonceBytes),
                        padding: { makeBytes($0) }
                    )
                    removeDelete(job.requestID)
                    upsertPublish(PublishState(job: job, envelope: envelope, nextAttempt: now))
                } catch {
                    audit("encode_failed", "put_request", nil)
                }
            case let .remove(requestID, _):
                removePublish(requestID)
                scheduleDelete(requestID, now: now)
            }
        }
    }

    private func scheduleDelete(_ requestID: String, now: TimeInterval) {
        if deletes[requestID] != nil { return }
        if deletes.count >= InteractionRelayLimits.deleteCapacity, let oldest = deleteOrder.first {
            deletes.removeValue(forKey: oldest)
            deleteOrder.removeFirst()
            audit("backlog_full", "delete_request", nil)
        }
        deletes[requestID] = DeleteState(nextAttempt: now)
        deleteOrder.append(requestID)
    }

    private func processDeletes(now: TimeInterval) {
        for requestID in Array(deleteOrder) {
            guard var state = deletes[requestID], now >= state.nextAttempt else { continue }
            let route = "/v1/mailboxes/\(quote(mailbox))/requests/\(quote(requestID))"
            do {
                let response = try request(method: "DELETE", route: route)
                try validate(response, jsonBody: false)
                guard response.status == 204, response.body.isEmpty else {
                    throw RelayAdapterError(message: "relay delete rejected")
                }
                removeDelete(requestID)
                audit("ok", "delete_request", response.status)
            } catch {
                state.failures += 1
                state.nextAttempt = now + backoff(state.failures)
                deletes[requestID] = state
                audit("failed", "delete_request", nil)
            }
        }
    }

    private func processPublishes(now: TimeInterval) {
        for requestID in publishOrder {
            guard var state = publishes[requestID], !state.published, now >= state.nextAttempt else { continue }
            let route = "/v1/mailboxes/\(quote(mailbox))/requests/\(quote(requestID))"
            do {
                let response = try request(method: "PUT", route: route, body: state.envelope)
                try validate(response, jsonBody: false)
                guard response.status == 200 || response.status == 201, response.body.isEmpty else {
                    throw RelayAdapterError(message: "relay publish rejected")
                }
                state.published = true
                state.failures = 0
                publishes[requestID] = state
                nextPoll = min(nextPoll, now)
                audit("ok", "put_request", response.status)
            } catch {
                state.failures += 1
                state.nextAttempt = now + backoff(state.failures)
                publishes[requestID] = state
                audit("failed", "put_request", nil)
            }
        }
    }

    private func poll(now: TimeInterval) {
        let route = "/v1/mailboxes/\(quote(mailbox))/verdicts"
        do {
            let response = try request(method: "GET", route: route)
            if response.status == 204 {
                try validate(response, jsonBody: false)
                guard response.body.isEmpty else {
                    throw RelayAdapterError(message: "unexpected relay response body")
                }
            } else if response.status == 200 {
                try validate(response, jsonBody: true)
                try consumeVerdict(response.body)
            } else {
                throw RelayAdapterError(message: "relay poll rejected")
            }
            pollFailures = 0
            nextPoll = now + InteractionRelayLimits.pollInterval
            audit("ok", "list_verdicts", response.status)
        } catch {
            pollFailures += 1
            nextPoll = now + backoff(pollFailures)
            audit("failed", "list_verdicts", nil)
        }
    }

    private func consumeVerdict(_ raw: Data) throws {
        guard !raw.isEmpty, raw.count <= InteractionRelayLimits.maxResponseBytes else {
            throw RelayAdapterError(message: "invalid response JSON")
        }
        guard case let .success(.object(root)) = CanonicalJSON.parse(raw) else {
            throw RelayAdapterError(message: "invalid response JSON")
        }
        guard Set(root.keys) == ["verdicts"],
              case let .array(items) = root["verdicts"], items.count == 1
        else { throw RelayAdapterError(message: "invalid verdict list") }
        guard case let .object(item) = items[0],
              Set(item.keys) == ["envelope", "requestId", "verdictAtMs"],
              case let .object(envelope) = item["envelope"],
              case let .string(requestID) = item["requestId"],
              case let .int(verdictAt) = item["verdictAtMs"],
              (0...9_007_199_254_740_991).contains(verdictAt)
        else { throw RelayAdapterError(message: "invalid verdict item") }
        do {
            let decoded = try InteractionRelayCrypto.b64URLDecode(requestID)
            guard decoded.count == 16 else {
                throw RelayAdapterError(message: "invalid verdict request id")
            }
        } catch let error as RelayAdapterError {
            throw error
        } catch {
            throw RelayAdapterError(message: "invalid verdict request id")
        }
        let envelopeBytes = try CanonicalJSON.encode(.object(envelope))
        guard let state = publishes[requestID], state.published else {
            scheduleDelete(requestID, now: 0)
            return
        }
        let verdict: RelayVerdict
        do {
            verdict = try InteractionRelayCrypto.decodeVerdict(
                keys: keys, mailbox: mailbox, requestID: requestID, envelope: envelopeBytes)
        } catch {
            scheduleDelete(requestID, now: 0)
            return
        }
        let result = RelayResolution(
            requestID: verdict.requestID, challenge: verdict.challenge,
            viewSHA256: verdict.viewSHA256, verdict: verdict.verdict, mac: verdict.mac)
        let accepted = store?.resolve(result, verify: { job, resolution in
            self.verify(job: job, result: resolution)
        }).accepted ?? false
        if !accepted { scheduleDelete(requestID, now: 0) }
    }

    private func verify(job: RelayPublishJob, result: RelayResolution) -> Bool {
        let request = RelayRequest(
            requestID: job.requestID, challenge: job.challenge, expiresAt: job.expiresAt,
            viewBytes: job.viewBytes, viewSHA256: job.viewSHA256)
        let verdict = RelayVerdict(
            requestID: result.requestID, challenge: result.challenge, viewSHA256: result.viewSHA256,
            verdict: result.verdict, mac: result.mac)
        return InteractionRelayCrypto.verifyVerdictMAC(
            keys: keys, mailbox: mailbox, request: request, verdict: verdict)
    }

    private func processStatus(now: TimeInterval) {
        prepareStatus(now: now)
        guard var state = statusState, now >= state.nextAttempt else { return }
        let route = "/v1/mailboxes/\(quote(mailbox))/status"
        do {
            let response = try request(method: "PUT", route: route, body: state.envelope)
            try validate(response, jsonBody: false)
            guard response.status == 201, response.body.isEmpty else {
                throw RelayAdapterError(message: "relay status publish rejected")
            }
            statusState = nil
            nextStatus = now + InteractionRelayLimits.statusPublishInterval
            audit("ok", "put_status", response.status)
        } catch {
            state.failures += 1
            state.nextAttempt = now + backoff(state.failures)
            statusState = state
            audit("failed", "put_status", nil)
        }
    }

    private func prepareStatus(now: TimeInterval) {
        guard statusState == nil, now >= nextStatus, let statusSource else { return }
        do {
            let wall = wall()
            guard wall.isFinite, wall > 0, wall <= Double(UInt32.max) else {
                throw RelayAdapterError(message: "invalid wall clock")
            }
            guard let whole = UInt64(exactly: wall.rounded(.towardZero)),
                  let milliseconds = UInt64(exactly: (wall * 1000).rounded(.towardZero))
            else { throw RelayAdapterError(message: "invalid wall clock") }
            let snapshot = try statusSource()
            guard case var .object(fields) = snapshot else {
                throw RelayAdapterError(message: "invalid status snapshot")
            }
            fields.removeValue(forKey: "pending")
            let statusBytes = try CanonicalJSON.encode(.object(fields))
            guard (1...InteractionRelayCrypto.maxStatusBytes).contains(statusBytes.count) else {
                throw RelayAdapterError(message: "status snapshot is too large")
            }
            guard lastPublicationID < UInt64.max else {
                throw RelayAdapterError(message: "status clock is out of range")
            }
            let publication = max(lastPublicationID + 1, milliseconds)
            guard whole <= UInt64(UInt32.max) - UInt64(InteractionRelayLimits.statusExpirySeconds) else {
                throw RelayAdapterError(message: "status clock is out of range")
            }
            let expires = UInt32(whole) + UInt32(InteractionRelayLimits.statusExpirySeconds)
            let makeBytes = randomBytes
            let envelope = try InteractionRelayCrypto.encodeStatus(
                keys: keys, mailbox: mailbox, publicationID: publication, expiresAt: expires,
                statusBytes: statusBytes, nonce: makeBytes(InteractionRelayCrypto.gcmNonceBytes),
                padding: { makeBytes($0) })
            lastPublicationID = publication
            statusPrepareFailures = 0
            statusState = StatusState(envelope: envelope, publicationID: publication, nextAttempt: now)
        } catch {
            statusPrepareFailures += 1
            nextStatus = now + backoff(statusPrepareFailures)
            audit("encode_failed", "put_status", nil)
        }
    }

    private func request(method: String, route: String, body: Data = Data()) throws -> RelayHTTPResponse {
        var headers = [
            ("Authorization", "Bearer \(macToken)"),
            ("Accept", "application/json"),
        ]
        if !body.isEmpty { headers.append(("Content-Type", "application/json")) }
        return try transport(RelayHTTPRequest(
            method: method, url: origin + route, headers: headers, body: body,
            connectTimeout: connectTimeout, readTimeout: readTimeout))
    }

    private func validate(_ response: RelayHTTPResponse, jsonBody: Bool) throws {
        guard response.body.count <= InteractionRelayLimits.maxResponseBytes else {
            throw RelayAdapterError(message: "invalid HTTP response")
        }
        guard headerValues(response, "Cache-Control") == ["no-store"] else {
            throw RelayAdapterError(message: "relay response is cacheable")
        }
        let types = headerValues(response, "Content-Type")
        if jsonBody {
            guard types.count == 1 else {
                throw RelayAdapterError(message: "missing response media type")
            }
            let parts = types[0].split(separator: ";", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            guard let media = parts.first, media == "application/json" else {
                throw RelayAdapterError(message: "untrusted response media type")
            }
            for part in parts.dropFirst() where part != "charset=utf-8" && part != "charset=\"utf-8\"" {
                throw RelayAdapterError(message: "untrusted response media type")
            }
        } else if !types.isEmpty {
            throw RelayAdapterError(message: "unexpected response media type")
        }
    }

    private func headerValues(_ response: RelayHTTPResponse, _ name: String) -> [String] {
        response.headers.compactMap { key, value in
            key.lowercased() == name.lowercased()
                ? value.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
    }

    private func audit(_ event: String, _ route: String, _ status: Int?) {
        guard let auditHook else { return }
        var fields: [String: RelayAuditField] = [
            "origin": .text(origin),
            "route": .text(route),
        ]
        if let status { fields["status"] = .number(status) }
        auditHook(event, fields)
    }

    private func upsertPublish(_ state: PublishState) {
        if publishes[state.job.requestID] == nil { publishOrder.append(state.job.requestID) }
        publishes[state.job.requestID] = state
    }

    private func removePublish(_ requestID: String) {
        guard publishes.removeValue(forKey: requestID) != nil else { return }
        publishOrder.removeAll { $0 == requestID }
    }

    private func removeDelete(_ requestID: String) {
        guard deletes.removeValue(forKey: requestID) != nil else { return }
        deleteOrder.removeAll { $0 == requestID }
    }

    private func quote(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            let unreserved = (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x7E
            if unreserved {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

private enum RelayEvent {
    case park(RelayPublishJob)
    case remove(String, String)

    var requestID: String {
        switch self {
        case let .park(job): return job.requestID
        case let .remove(requestID, _): return requestID
        }
    }
}

private struct PublishState {
    var job: RelayPublishJob
    var envelope: Data
    var published = false
    var nextAttempt: TimeInterval
    var failures = 0
}

private struct DeleteState {
    var nextAttempt: TimeInterval
    var failures = 0
}

private struct StatusState {
    var envelope: Data
    var publicationID: UInt64
    var nextAttempt: TimeInterval
    var failures = 0
}
