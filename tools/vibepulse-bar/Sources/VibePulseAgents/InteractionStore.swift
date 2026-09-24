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
}

/// Parks one Claude hook at a time for the panel. `answer` is the in-process verdict.
public final class InteractionStore: @unchecked Sendable {
    private let revealDetail: Bool
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var pending: [String: ParkedInteraction] = [:]
    private var arrival = 0
    private var issued: [String] = []

    public init(revealDetail: Bool = false,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.revealDetail = revealDetail
        self.now = now
    }

    /// Returns the request id, or nil when the event cannot be shown.
    public func park(kind: String, eventJSON: String, holdSeconds: TimeInterval) -> String? {
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
        guard let duration = acceptedHold(holdSeconds) else { return nil }
        let moment = now()
        guard moment.isFinite else { return nil }
        lock.lock()
        defer { lock.unlock() }
        sweep(at: moment)
        guard pending.count < maxPending, let requestID = mintID() else { return nil }
        let holdMS = Int(duration * 1000)
        var stable: [(String, WireValue)] = [
            ("provider", .string("claude")),
            ("request_id", .string(requestID)),
        ]
        if let project { stable.append(("project", .string(project))) }
        stable.append(("hold_ms", .int(holdMS)))
        stable.append(contentsOf: view.filter { if case .null = $0.1 { return false }; return true })
        let digest = viewDigest(stable)
        arrival += 1
        let canApprove = view.first { $0.0 == "can_approve" }.flatMap { if case let .bool(flag) = $0.1 { return flag }; return nil } ?? false
        pending[requestID] = ParkedInteraction(
            requestID: requestID, provider: "claude", kind: kind, project: project, view: view,
            recommendedIndex: recommended, viewSHA256: digest, holdMS: holdMS, createdAt: moment,
            expiresAt: moment + duration, arrivalIndex: arrival, canApprove: canApprove)
        return requestID
    }

    /// Consume a parked item. Approve is refused when the view cannot be approved.
    public func answer(requestID: String, verdict: String) -> InteractionResult? {
        guard let result = try? InteractionResult(verdict: verdict) else { return nil }
        let moment = now()
        lock.lock()
        defer { lock.unlock() }
        sweep(at: moment)
        guard let entry = pending[requestID] else { return nil }
        if verdict == "approve" && !entry.canApprove { return nil }
        pending.removeValue(forKey: requestID)
        let option = verdict == "approve" ? entry.recommendedIndex : nil
        return try? InteractionResult(verdict: verdict, optionIndex: option)
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
        pairs.append(("provider", .string(entry.provider)))
        pairs.append(contentsOf: entry.view.filter { if case .null = $0.1 { return false }; return true })
        pairs.append(("view_sha256", .string(entry.viewSHA256)))
        if pythonWireByteCount(pairs) > pendingBudgetBytes { return nil }
        return WireObject(pairs)
    }
}

func viewDigest(_ pairs: [(String, WireValue)]) -> String {
    var fields: [String: WireValue] = [:]
    for (key, value) in pairs where key != "expires_in_ms" && key != "view_sha256" {
        if case .null = value { continue }
        fields[key] = value
    }
    let canonical = canonicalJSONObject(fields)
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
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

private extension InteractionStore {
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

private func isSafeText(_ value: Any?) -> Bool {
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

private func approvalView(toolName: Any?, toolInput: [String: Any]?, reveal: Bool) -> [(String, WireValue)] {
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

private func approvableTool(_ toolName: Any?, _ toolInput: [String: Any]?) -> Bool {
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
