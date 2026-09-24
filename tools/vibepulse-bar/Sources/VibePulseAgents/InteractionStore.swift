import CryptoKit
import Foundation

private let interactionKinds: Set<String> = ["question", "approval"]
private let pendingBudgetBytes = 640
private let maxPending = 8
private let maxHoldSeconds = 4_294_967.295
private let recommendedSuffix = "(recommended)"
private let approvableTools: Set<String> = ["read", "glob", "grep", "notebookread"]
private let commandChaining = try! NSRegularExpression(pattern: #"[;&|><`$\n]"#)
private let approvableCommand = try! NSRegularExpression(
    pattern: #"^(?:\s*)(?:\./test/run\.sh|pytest|python3?\s+-m\s+unittest|npm\s+(?:run\s+)?test|cargo\s+test|go\s+test|ctest|cmake\s+--build|ninja|make|cargo\s+build|npm\s+run\s+build|idf\.py\s+build|git\s+(?:status|diff|log|show|branch)|ls|cat|head|tail|wc|grep|rg)(?:\s|$)"#,
    options: [.caseInsensitive])

/// Relay handoff the server can read after `park`. `VibePulseRelay` already
/// depends on this module, so this value does not conform to `RelayResolving`.
public struct ParkedRelayJob: Sendable, Equatable {
    public var requestID: String
    /// 32 random bytes.
    public var challenge: Data
    /// Canonical JSON of the stable view: sorted keys, no whitespace, UTF-8.
    public var canonicalViewBytes: Data
    public var canApprove: Bool

    public init(requestID: String, challenge: Data, canonicalViewBytes: Data, canApprove: Bool) {
        self.requestID = requestID
        self.challenge = challenge
        self.canonicalViewBytes = canonicalViewBytes
        self.canApprove = canApprove
    }
}

private struct ParkedInteraction {
    var requestID: String
    var provider: String
    var kind: String
    var project: String?
    var view: [(String, WireValue)]
    var recommendedIndex: Int?
    var viewSHA256: String
    var holdMS: Int
    var createdAt: TimeInterval
    var expiresAt: TimeInterval
    var arrivalIndex: Int
    var canApprove: Bool
    var requiresV2: Bool
    var relayJob: ParkedRelayJob
}

/// Parks Claude hooks and normalized Codex events for the panel.
/// A non-empty `secret` makes `answer` require a fresh HMAC: v2 over the canonical
/// view, or v1 (`requestID|verdict|timestamp`) for an item from `parkLegacy`.
public final class InteractionStore: @unchecked Sendable {
    private let revealDetail: Bool
    private let secret: String
    private let now: @Sendable () -> TimeInterval
    private let wall: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private let verdictLock = NSCondition()
    private var pending: [String: ParkedInteraction] = [:]
    private var verdicts: [String: InteractionResult] = [:]
    private var onParkHandler: (@Sendable (ParkedRelayJob) -> Void)?
    private var arrival = 0
    private var issued: [String] = []

    public init(revealDetail: Bool = false,
                secret: String = "",
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                wall: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.revealDetail = revealDetail
        self.secret = secret
        self.now = now
        self.wall = wall
    }

    /// Returns the request id, or nil when the event cannot be shown.
    /// The published item includes `provider` and `view_sha256`. That is the v2
    /// shape; a legacy Claude panel v1 payload uses `parkLegacy`.
    public func park(kind: String, eventJSON: String, holdSeconds: TimeInterval) -> String? {
        parkClaude(kind: kind, eventJSON: eventJSON, holdSeconds: holdSeconds, requiresV2: true)
    }

    /// Legacy Claude panel v1. Same Claude event as `park`, but the published
    /// item omits `provider` and `view_sha256`, and a configured secret checks
    /// the v1 HMAC. Codex is unchanged and stays on `park(_:)`.
    public func parkLegacy(kind: String, eventJSON: String, holdSeconds: TimeInterval) -> String? {
        parkClaude(kind: kind, eventJSON: eventJSON, holdSeconds: holdSeconds, requiresV2: false)
    }

    /// Runs after a v2 item is parked, without the store lock. `parkLegacy` does not call it.
    public func setOnPark(_ handler: (@Sendable (ParkedRelayJob) -> Void)?) {
        lock.lock()
        onParkHandler = handler
        lock.unlock()
    }

    /// Challenge, canonical view bytes, and `canApprove` for an item that is still parked.
    public func relayJob(for requestID: String) -> ParkedRelayJob? {
        let moment = now()
        lock.lock()
        defer { lock.unlock() }
        sweep(at: moment)
        return pending[requestID]?.relayJob
    }

    /// Denies every parked item and returns how many were denied.
    @discardableResult
    public func panic() -> Int {
        let moment = now()
        lock.lock()
        sweep(at: moment)
        let entries = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        guard let denied = try? InteractionResult(verdict: "deny") else { return entries.count }
        recordVerdicts(entries.map { ($0.requestID, denied) })
        return entries.count
    }

    /// Blocks the calling thread until `answer` or `panic` stores a result for
    /// `requestID`, or until `timeout` elapses. Does not start a thread.
    public func awaitVerdict(requestID: String, timeout: TimeInterval) -> InteractionResult? {
        let seconds = timeout.isFinite ? max(0, timeout) : 0
        let deadline = Date().addingTimeInterval(seconds)
        verdictLock.lock()
        defer { verdictLock.unlock() }
        while verdicts[requestID] == nil {
            if seconds == 0 || !verdictLock.wait(until: deadline) { break }
        }
        return verdicts.removeValue(forKey: requestID)
    }

    /// Park a Codex question or permission that `normalizeCodexQuestion` / `normalizeCodexPermission` produced.
    public func park(_ normalized: NormalizedInteraction, holdSeconds: TimeInterval) -> String? {
        guard normalized.provider == "codex", interactionKinds.contains(normalized.kind) else { return nil }
        guard codexNormalizedIsAcceptable(normalized) else { return nil }
        return commit(provider: "codex", kind: normalized.kind, project: normalized.project, view: normalized.view,
                      recommendedIndex: normalized.recommendedIndex, holdSeconds: holdSeconds)
    }

    /// Consume a parked item. Approve is refused when the view cannot be approved.
    /// With a secret, a v2 item needs a fresh HMAC over the canonical view digest.
    /// A `parkLegacy` item needs the v1 HMAC. A bad MAC, the wrong digest, the wrong
    /// provider, or a timestamp outside 90 seconds leaves the item parked.
    public func answer(requestID: String, verdict: String, mac: String? = nil, timestamp: Int? = nil) -> InteractionResult? {
        guard (try? InteractionResult(verdict: verdict)) != nil else { return nil }
        let moment = now()
        lock.lock()
        sweep(at: moment)
        guard let entry = pending[requestID] else {
            lock.unlock()
            return nil
        }
        // An empty secret keeps the in-process verdict. A configured secret, or any
        // presented MAC, is checked and a failure leaves the item parked.
        if !secret.isEmpty || mac != nil {
            guard verifyAnswer(entry: entry, verdict: verdict, mac: mac, timestamp: timestamp) else {
                lock.unlock()
                return nil
            }
        }
        if verdict == "approve" && !entry.canApprove {
            lock.unlock()
            return nil
        }
        pending.removeValue(forKey: requestID)
        let option = verdict == "approve" ? entry.recommendedIndex : nil
        lock.unlock()
        guard let result = try? InteractionResult(verdict: verdict, optionIndex: option) else { return nil }
        recordVerdict(requestID: requestID, result: result)
        return result
    }

    /// Oldest live item, or nil when nothing is parked or the wire form exceeds 640 bytes.
    public func pendingPublic() -> WireObject? {
        let moment = now()
        lock.lock()
        sweep(at: moment)
        let entry = pending.values.min { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.arrivalIndex < rhs.arrivalIndex
        }
        lock.unlock()
        guard let entry else { return nil }
        let remaining = max(0, Int((entry.expiresAt - moment) * 1000))
        var pairs: [(String, WireValue)] = [("request_id", .string(entry.requestID))]
        if let project = entry.project { pairs.append(("project", .string(project))) }
        pairs.append(("expires_in_ms", .int(remaining)))
        pairs.append(("hold_ms", .int(entry.holdMS)))
        if entry.requiresV2 {
            pairs.append(("provider", .string(entry.provider)))
        }
        pairs.append(contentsOf: entry.view.filter { if case .null = $0.1 { return false }; return true })
        if entry.requiresV2 {
            pairs.append(("view_sha256", .string(entry.viewSHA256)))
        }
        if pythonWireByteCount(pairs) > pendingBudgetBytes { return nil }
        return WireObject(pairs)
    }
}

func canonicalViewBytes(_ pairs: [(String, WireValue)]) -> Data {
    var fields: [String: WireValue] = [:]
    for (key, value) in pairs where key != "expires_in_ms" && key != "view_sha256" {
        if case .null = value { continue }
        fields[key] = value
    }
    return Data(canonicalJSONObject(fields).utf8)
}

func viewDigest(_ pairs: [(String, WireValue)]) -> String {
    SHA256.hash(data: canonicalViewBytes(pairs)).map { String(format: "%02x", $0) }.joined()
}

func canonicalJSONObject(_ fields: [String: WireValue]) -> String {
    let body = fields.keys.sorted().map { key in
        "\(canonicalString(key)):\(canonicalValue(fields[key] ?? .null))"
    }.joined(separator: ",")
    return "{\(body)}"
}

private func canonicalValue(_ value: WireValue) -> String {
    switch value {
    case .null: return "null"
    case let .bool(flag): return flag ? "true" : "false"
    case let .int(number): return String(number)
    case let .string(text): return canonicalString(text)
    case let .object(object):
        return canonicalJSONObject(Dictionary(uniqueKeysWithValues: object.pairs))
    case let .array(values):
        return "[\(values.map(canonicalValue).joined(separator: ","))]"
    }
}

private func canonicalString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}

private func pythonWireByteCount(_ pairs: [(String, WireValue)]) -> Int {
    let body = pairs.map { key, value in
        "\(asciiJSONString(key)): \(asciiJSONValue(value))"
    }.joined(separator: ", ")
    return Data("{\(body)}".utf8).count
}

private func asciiJSONValue(_ value: WireValue) -> String {
    switch value {
    case .null: return "null"
    case let .bool(flag): return flag ? "true" : "false"
    case let .int(number): return String(number)
    case let .string(text): return asciiJSONString(text)
    case let .object(object): return "{\(object.pairs.map { "\(asciiJSONString($0.0)): \(asciiJSONValue($0.1))" }.joined(separator: ", "))}"
    case let .array(values): return "[\(values.map(asciiJSONValue).joined(separator: ", "))]"
    }
}

private func asciiJSONString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 || scalar.value > 0x7E {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}

public func signAnswerV2(secret: String, provider: String, requestID: String, digest: String,
                         verdict: String, timestamp: Int) -> String {
    let message = Data("v2|\(provider)|\(requestID)|\(digest)|\(verdict)|\(timestamp)".utf8)
    let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
    return code.map { String(format: "%02x", $0) }.joined()
}

/// The device key file, stripped. Nil when the file is absent, empty, or not UTF-8.
public func readDeviceKey(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
    let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return stripped.isEmpty ? nil : stripped
}

private extension InteractionStore {
    func commit(provider: String, kind: String, project: String?, view: [(String, WireValue)],
                recommendedIndex: Int?, holdSeconds: TimeInterval, requiresV2: Bool = true) -> String? {
        guard let duration = acceptedHold(holdSeconds) else { return nil }
        let moment = now()
        guard moment.isFinite else { return nil }
        lock.lock()
        let parked = insert(provider: provider, kind: kind, project: project, view: view,
                            recommendedIndex: recommendedIndex, duration: duration, moment: moment,
                            requiresV2: requiresV2)
        let handler = parked == nil || !requiresV2 ? nil : onParkHandler
        lock.unlock()
        if let parked, let handler {
            handler(parked.relayJob)
        }
        return parked?.requestID
    }

    func insert(provider: String, kind: String, project: String?, view: [(String, WireValue)],
                recommendedIndex: Int?, duration: TimeInterval, moment: TimeInterval,
                requiresV2: Bool) -> ParkedInteraction? {
        sweep(at: moment)
        guard pending.count < maxPending, let requestID = mintID() else { return nil }
        let holdMS = Int(duration * 1000)
        var stable: [(String, WireValue)] = [
            ("provider", .string(provider)),
            ("request_id", .string(requestID)),
        ]
        if let project { stable.append(("project", .string(project))) }
        stable.append(("hold_ms", .int(holdMS)))
        stable.append(contentsOf: view.filter { if case .null = $0.1 { return false }; return true })
        let viewBytes = canonicalViewBytes(stable)
        let digest = SHA256.hash(data: viewBytes).map { String(format: "%02x", $0) }.joined()
        arrival += 1
        let canApprove = view.first { $0.0 == "can_approve" }.flatMap { if case let .bool(flag) = $0.1 { return flag }; return nil } ?? false
        let entry = ParkedInteraction(
            requestID: requestID, provider: provider, kind: kind, project: project, view: view,
            recommendedIndex: recommendedIndex, viewSHA256: digest, holdMS: holdMS, createdAt: moment,
            expiresAt: moment + duration, arrivalIndex: arrival, canApprove: canApprove, requiresV2: requiresV2,
            relayJob: ParkedRelayJob(
                requestID: requestID, challenge: makeChallenge(), canonicalViewBytes: viewBytes,
                canApprove: canApprove))
        pending[requestID] = entry
        return entry
    }

    func recordVerdict(requestID: String, result: InteractionResult) {
        recordVerdicts([(requestID, result)])
    }

    func recordVerdicts(_ results: [(String, InteractionResult)]) {
        guard !results.isEmpty else { return }
        verdictLock.lock()
        for (requestID, result) in results {
            verdicts[requestID] = result
        }
        verdictLock.broadcast()
        verdictLock.unlock()
    }

    func makeChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }

    func parkClaude(kind: String, eventJSON: String, holdSeconds: TimeInterval, requiresV2: Bool) -> String? {
        guard interactionKinds.contains(kind), let event = jsonObject(from: eventJSON) else { return nil }
        if kind == "approval", let tool = event["tool_name"] as? String,
           tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "askuserquestion" {
            return nil
        }
        guard claudeTextIsSafe(kind: kind, event: event), claudeDisplayFits(kind: kind, event: event, reveal: revealDetail) else {
            return nil
        }
        let project = sanitizeProject(event["cwd"])
        let toolInput = event["tool_input"] as? [String: Any]
        let view: [(String, WireValue)]
        let recommended: Int?
        if kind == "question" {
            guard let question = firstQuestion(toolInput) else { return nil }
            let built = questionView(question, reveal: revealDetail)
            view = built.view
            recommended = built.index
        } else {
            view = approvalView(toolName: event["tool_name"], toolInput: toolInput, reveal: revealDetail)
            recommended = nil
        }
        return commit(provider: "claude", kind: kind, project: project, view: view,
                      recommendedIndex: recommended, holdSeconds: holdSeconds, requiresV2: requiresV2)
    }

    func verifyAnswer(entry: ParkedInteraction, verdict: String, mac: String?, timestamp: Int?) -> Bool {
        if entry.requiresV2 {
            return verifyAnswerV2(entry: entry, verdict: verdict, mac: mac, timestamp: timestamp)
        }
        return verifyAnswerV1(entry: entry, verdict: verdict, mac: mac, timestamp: timestamp)
    }

    func verifyAnswerV2(entry: ParkedInteraction, verdict: String, mac: String?, timestamp: Int?) -> Bool {
        guard !secret.isEmpty, let mac, let timestamp, timestamp >= 0, let macData = hexMAC(mac) else { return false }
        let moment = wall()
        guard moment.isFinite, abs(moment - Double(timestamp)) <= 90 else { return false }
        let message = Data("v2|\(entry.provider)|\(entry.requestID)|\(entry.viewSHA256)|\(verdict)|\(timestamp)".utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(
            macData, authenticating: message, using: SymmetricKey(data: Data(secret.utf8)))
    }

    func verifyAnswerV1(entry: ParkedInteraction, verdict: String, mac: String?, timestamp: Int?) -> Bool {
        guard !secret.isEmpty, let mac, let timestamp, timestamp >= 0, let macData = hexMAC(mac) else { return false }
        let moment = wall()
        guard moment.isFinite, abs(moment - Double(timestamp)) <= 90 else { return false }
        let message = Data("\(entry.requestID)|\(verdict)|\(timestamp)".utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(
            macData, authenticating: message, using: SymmetricKey(data: Data(secret.utf8)))
    }

    func codexNormalizedIsAcceptable(_ item: NormalizedInteraction) -> Bool {
        guard !item.sessionID.isEmpty, !item.turnID.isEmpty else { return false }
        if let project = item.project {
            guard isSafeText(project), sanitizeProject(project) == project else { return false }
        }
        if let recommended = item.recommendedIndex, recommended < 0 { return false }
        if item.kind == "approval", item.recommendedIndex != nil { return false }
        guard normalizedViewIsAcceptable(kind: item.kind, pairs: item.view) else { return false }
        if item.kind == "question" { return codexQuestionIsNormalized(item) }
        guard let permission = item.permission,
              let again = normalizeCodexPermission(permission, reveal: revealDetail) else { return false }
        return again == item
    }

    func acceptedHold(_ hold: TimeInterval) -> TimeInterval? {
        guard hold.isFinite, hold > 0, hold <= maxHoldSeconds else { return nil }
        return max(1, hold)
    }

    func mintID() -> String? {
        for _ in 0..<32 {
            var bytes = [UInt8](repeating: 0, count: 16)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            var text = Data(bytes).base64EncodedString()
            text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            while text.hasSuffix("=") { text.removeLast() }
            if !issued.contains(text) {
                issued.append(text)
                if issued.count > 256 { issued.removeFirst(issued.count - 256) }
                return text
            }
        }
        return nil
    }

    func sweep(at moment: TimeInterval) {
        for (key, entry) in pending where entry.expiresAt <= moment {
            pending.removeValue(forKey: key)
        }
    }
}

private let questionViewFields: Set<String> = [
    "kind", "options_total", "marked", "prompt", "title", "subtitle", "can_approve",
]
private let approvalViewFields: Set<String> = ["kind", "tool", "title", "subtitle", "can_approve"]
private let viewTextLimits = ["prompt": 96, "title": 64, "subtitle": 64, "tool": 24]

private func normalizedViewIsAcceptable(kind: String, pairs: [(String, WireValue)]) -> Bool {
    let allowed = kind == "question" ? questionViewFields : approvalViewFields
    var seen = Set<String>()
    var values: [String: WireValue] = [:]
    for (key, value) in pairs {
        if case .null = value { continue }
        guard allowed.contains(key), seen.insert(key).inserted else { return false }
        values[key] = value
    }
    guard case let .string(kindValue) = values["kind"], kindValue == kind else { return false }
    guard case let .bool(canApprove) = values["can_approve"] else { return false }
    for (field, limit) in viewTextLimits {
        guard let value = values[field] else { continue }
        guard case let .string(text) = value, !text.isEmpty, isSafeText(text),
              Data(text.utf8).count <= limit else { return false }
    }
    if kind == "question" {
        guard case let .int(total) = values["options_total"], (1...255).contains(total) else { return false }
        guard case .bool = values["marked"] else { return false }
        if canApprove {
            guard case let .bool(marked) = values["marked"], marked, values["prompt"] != nil, values["title"] != nil else {
                return false
            }
        }
    } else if canApprove, values["title"] == nil {
        return false
    }
    return true
}

private func codexQuestionIsNormalized(_ item: NormalizedInteraction) -> Bool {
    let options = item.options
    guard options.count == 2 || options.count == 3 else { return false }
    guard case let .int(total) = wireValue(item.view, "options_total"), total == options.count else { return false }
    if let recommended = item.recommendedIndex, recommended >= total { return false }
    var marked: [Int] = []
    for (index, option) in options.enumerated() {
        guard isSafeText(option.label), !option.label.isEmpty else { return false }
        if let description = option.description {
            guard isSafeText(description), !description.isEmpty else { return false }
        }
        if option.recommended == true { marked.append(index) }
    }
    let recommended = marked.count == 1 ? marked[0] : nil
    guard marked.count <= 1, item.recommendedIndex == recommended else { return false }
    guard case let .bool(viewMarked) = wireValue(item.view, "marked"), viewMarked == (recommended != nil) else {
        return false
    }
    guard case let .bool(canApprove) = wireValue(item.view, "can_approve"), canApprove == (recommended != nil) else {
        return false
    }
    if let recommended {
        guard case let .string(title) = wireValue(item.view, "title"), title == options[recommended].label else {
            return false
        }
        let subtitle = wireValue(item.view, "subtitle")
        if let description = options[recommended].description {
            guard case let .string(text) = subtitle, text == description else { return false }
        } else if subtitle != nil {
            return false
        }
    }
    return true
}

private func wireValue(_ pairs: [(String, WireValue)], _ key: String) -> WireValue? {
    pairs.first { $0.0 == key }?.1
}

private func hexMAC(_ text: String) -> Data? {
    guard text.unicodeScalars.count == 64 else { return nil }
    var data = Data()
    data.reserveCapacity(32)
    var high: UInt8?
    for scalar in text.unicodeScalars {
        guard let nibble = hexNibble(scalar) else { return nil }
        if let current = high {
            data.append((current << 4) | nibble)
            high = nil
        } else {
            high = nibble
        }
    }
    return high == nil && data.count == 32 ? data : nil
}

private func hexNibble(_ scalar: Unicode.Scalar) -> UInt8? {
    switch scalar {
    case "0"..."9": return UInt8(scalar.value - 48)
    case "a"..."f": return UInt8(scalar.value - Unicode.Scalar("a").value + 10)
    default: return nil
    }
}

private func collapse(_ text: String) -> String {
    text.split { $0.isWhitespace }.map(String.init).joined(separator: " ")
}

private func cleanText(_ value: Any?, limit: Int) -> String? {
    guard let text = value as? String else { return nil }
    var collapsed = collapse(text)
    if collapsed.isEmpty { return nil }
    if collapsed.unicodeScalars.count > limit {
        let budget = limit - 3
        var kept: [Unicode.Scalar] = []
        var used = 0
        for scalar in collapsed.unicodeScalars {
            let bytes = String(scalar).utf8.count
            if used + bytes > budget { break }
            kept.append(scalar)
            used += bytes
        }
        let prefix = String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        collapsed = prefix + "…"
    }
    if Data(collapsed.utf8).count > limit { return nil }
    return collapsed
}

private func isTruncated(_ value: Any?, limit: Int) -> Bool {
    guard let text = value as? String else { return false }
    let collapsed = collapse(text)
    return collapsed.unicodeScalars.count > limit || Data(collapsed.utf8).count > limit
}

private func byteOverflowInsideCharacterLimit(_ value: Any?, limit: Int) -> Bool {
    guard let text = value as? String else { return false }
    let collapsed = collapse(text)
    return collapsed.unicodeScalars.count <= limit && Data(collapsed.utf8).count > limit
}

func isSafeText(_ value: Any?) -> Bool {
    guard let text = value as? String else { return false }
    return !text.unicodeScalars.contains(where: isCCategory)
}

private func optionalTextIsSafe(_ value: Any?) -> Bool {
    guard value is String else { return true }
    return isSafeText(value)
}

private func firstQuestion(_ toolInput: [String: Any]?) -> [String: Any]? {
    guard let toolInput, let questions = toolInput["questions"] as? [Any], questions.count == 1,
          let question = questions[0] as? [String: Any],
          let options = question["options"] as? [Any], (1...255).contains(options.count),
          question["question"] is String, !isTruthy(question["multiSelect"]) else { return nil }
    for option in options {
        guard let option = option as? [String: Any], option["label"] is String else { return nil }
    }
    return question
}

private func isTruthy(_ value: Any?) -> Bool {
    if value == nil || value is NSNull { return false }
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        return number.doubleValue != 0
    }
    if let text = value as? String { return !text.isEmpty }
    if let list = value as? [Any] { return !list.isEmpty }
    if let object = value as? [String: Any] { return !object.isEmpty }
    return true
}

private func recommendedIndex(_ options: [Any]) -> Int {
    for (index, option) in options.enumerated() {
        guard let option = option as? [String: Any], let label = option["label"] as? String else { continue }
        if label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(recommendedSuffix) {
            return index
        }
    }
    return 0
}

private func hasRecommendation(_ options: [Any]) -> Bool {
    options.contains { option in
        guard let option = option as? [String: Any], let label = option["label"] as? String else { return false }
        return label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(recommendedSuffix)
    }
}

private func stripRecommended(_ label: String) -> String {
    var stripped = label.trimmingCharacters(in: .whitespacesAndNewlines)
    if stripped.lowercased().hasSuffix(recommendedSuffix) {
        stripped = String(stripped.dropLast(recommendedSuffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return stripped
}

private func questionView(_ question: [String: Any], reveal: Bool) -> (view: [(String, WireValue)], index: Int) {
    let options = question["options"] as? [Any] ?? []
    let marked = hasRecommendation(options)
    let index = recommendedIndex(options)
    let selected = options[index] as? [String: Any]
    let label = stripRecommended(selected?["label"] as? String ?? "")
    var view: [(String, WireValue)] = [
        ("kind", .string("question")),
        ("options_total", .int(options.count)),
        ("marked", .bool(marked)),
    ]
    if reveal {
        let prompt = cleanText(question["question"], limit: 96)
        let title = cleanText(label, limit: 64)
        let subtitle = cleanText(selected?["description"], limit: 64)
        view.append(("prompt", prompt.map(WireValue.string) ?? .null))
        view.append(("title", title.map(WireValue.string) ?? .null))
        view.append(("subtitle", subtitle.map(WireValue.string) ?? .null))
        let canApprove = marked && prompt != nil && title != nil
            && !isTruncated(question["question"], limit: 96)
            && !isTruncated(label, limit: 64)
            && !isTruncated(selected?["description"], limit: 64)
        view.append(("can_approve", .bool(canApprove)))
    } else {
        view.append(("can_approve", .bool(false)))
    }
    return (view, index)
}

func approvalView(toolName: Any?, toolInput: [String: Any]?, reveal: Bool) -> [(String, WireValue)] {
    let command = toolInput?["command"] as? String
    var view: [(String, WireValue)] = [
        ("kind", .string("approval")),
        ("tool", cleanText(toolName, limit: 24).map(WireValue.string) ?? .null),
    ]
    if reveal {
        let tool = cleanText(toolName, limit: 24)
        let title = cleanText(command ?? "", limit: 64) ?? tool
        let description = toolInput?["description"]
        view.append(("title", title.map(WireValue.string) ?? .null))
        view.append(("subtitle", cleanText(description, limit: 64).map(WireValue.string) ?? .null))
        let readable = command.map { !$0.isEmpty && !isTruncated($0, limit: 64) } ?? false
        let canApprove = readable && !isTruncated(description, limit: 64) && approvableTool(toolName, toolInput)
        view.append(("can_approve", .bool(canApprove)))
    } else {
        view.append(("can_approve", .bool(false)))
    }
    return view
}

func approvableTool(_ toolName: Any?, _ toolInput: [String: Any]?) -> Bool {
    guard let name = (toolName as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return false
    }
    if approvableTools.contains(name) { return true }
    guard name == "bash" || name == "shell" else { return false }
    guard let command = toolInput?["command"] as? String, !command.isEmpty else { return false }
    let range = NSRange(command.startIndex..., in: command)
    if commandChaining.firstMatch(in: command, range: range) != nil { return false }
    return approvableCommand.firstMatch(in: command, range: range) != nil
}

private func claudeTextIsSafe(kind: String, event: [String: Any]) -> Bool {
    guard optionalTextIsSafe(event["cwd"]) else { return false }
    let toolInput = event["tool_input"] as? [String: Any]
    if kind == "question" {
        guard let question = firstQuestion(toolInput) else { return false }
        var fields: [Any?] = [question["question"], question["header"]]
        for option in question["options"] as? [Any] ?? [] {
            let option = option as? [String: Any]
            fields.append(option?["label"])
            fields.append(option?["description"])
        }
        return fields.allSatisfy(optionalTextIsSafe)
    }
    var fields: [Any?] = [event["tool_name"]]
    fields.append(toolInput?["command"])
    fields.append(toolInput?["description"])
    return fields.allSatisfy(optionalTextIsSafe)
}

private func claudeDisplayFits(kind: String, event: [String: Any], reveal: Bool) -> Bool {
    let toolInput = event["tool_input"] as? [String: Any]
    if kind == "question" {
        if !reveal { return true }
        guard let question = firstQuestion(toolInput), let options = question["options"] as? [Any] else { return false }
        let selected = options[recommendedIndex(options)] as? [String: Any]
        let label = stripRecommended(selected?["label"] as? String ?? "")
        return !byteOverflowInsideCharacterLimit(question["question"], limit: 96)
            && !byteOverflowInsideCharacterLimit(label, limit: 64)
            && !byteOverflowInsideCharacterLimit(selected?["description"], limit: 64)
    }
    if byteOverflowInsideCharacterLimit(event["tool_name"], limit: 24) { return false }
    if !reveal { return true }
    return !byteOverflowInsideCharacterLimit(toolInput?["command"], limit: 64)
        && !byteOverflowInsideCharacterLimit(toolInput?["description"], limit: 64)
}
