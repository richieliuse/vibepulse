import CryptoKit
import Foundation

public let agentLeaseSeconds: TimeInterval = 120
public let agentWaitingLeaseSeconds: TimeInterval = 7_200
public let agentPublicJobLimit = 4
public let agentTrackedJobLimit = 16

let agentStates: Set<String> = ["idle", "working", "waiting", "done", "error", "unknown"]
let agentActivities: Set<String> = [
    "thinking", "reading", "editing", "searching", "running", "testing",
    "building", "waiting_input", "waiting_approval",
]
let agentStatePriority: [String: Int] = [
    "waiting": 5, "error": 4, "working": 3, "done": 2, "idle": 1, "unknown": 0,
]
private let modelLabels: [String: String] = [
    "claude-fable-5": "FABLE 5",
    "claude-opus-5": "OPUS 5",
    "claude-sonnet-5": "SONNET 5",
    "gpt-5.6-luna": "GPT-5.6 LUNA",
    "gpt-5.6-sol": "GPT-5.6 SOL",
    "gpt-5.6-terra": "GPT-5.6 TERRA",
]

private let datedSuffix = try! NSRegularExpression(
    pattern: #"-(?:20\d{6}|20\d\d-\d\d-\d\d|\d{4})(?=-|$)"#)
private let versionToken = try! NSRegularExpression(pattern: #"^\d+(?:\.\d+)*$"#)
private let testCommand = try! NSRegularExpression(
    pattern: #"(?:^|[\s;&|])(?:\./test/run\.sh|pytest|python3?\s+-m\s+unittest|npm\s+(?:run\s+)?test|cargo\s+test|go\s+test|ctest)(?:\s|$)"#,
    options: [.caseInsensitive])
private let buildCommand = try! NSRegularExpression(
    pattern: #"(?:^|[\s;&|])(?:cmake\s+--build|ninja|make|cargo\s+build|npm\s+run\s+build|idf\.py\s+build)(?:\s|$)"#,
    options: [.caseInsensitive])

public struct AgentEvent: Sendable, Equatable {
    public var state: String
    public var activity: String?
    public var taskID: String
    public var sourceID: String
    public var project: String?
    public var model: String?
    public var effort: String?

    public init(state: String, activity: String?, taskID: String, sourceID: String,
                project: String?, model: String? = nil, effort: String? = nil) {
        self.state = state
        self.activity = activity
        self.taskID = taskID
        self.sourceID = sourceID
        self.project = project
        self.model = model
        self.effort = effort
    }
}

public enum AgentStatusError: Error, Equatable, Sendable {
    case unsupportedProvider(String)
    case unsupportedState(String)
    case unsupportedActivity(String)
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func isCCategory(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned:
        return true
    default:
        return false
    }
}

func utf8Prefix(_ text: String, maxBytes: Int) -> String {
    var used = 0
    var kept: [Unicode.Scalar] = []
    for scalar in text.unicodeScalars {
        let bytes = String(scalar).utf8.count
        if used + bytes > maxBytes { break }
        kept.append(scalar)
        used += bytes
    }
    return String(String.UnicodeScalarView(kept))
}

func boundedDisplay(_ value: Any?, maxBytes: Int) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { !isCCategory($0) }))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = utf8Prefix(clean, maxBytes: maxBytes)
    return prefix.isEmpty ? nil : prefix
}

/// POSIX `Path.name`: drop empty and `.` parts, keep `..`, return the last part.
func pathBasename(_ value: String) -> String {
    let parts = value.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
    return parts.last.map(String.init) ?? ""
}

public func sanitizeProject(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    let name = pathBasename(text)
    let clean = String(String.UnicodeScalarView(name.unicodeScalars.filter { !isCCategory($0) }))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = utf8Prefix(clean, maxBytes: 16)
    return prefix.isEmpty ? nil : prefix
}

func boundedTaskID(_ value: String) -> String {
    let hasControls = value.unicodeScalars.contains(where: isCCategory)
    if value.utf8.count <= 64 && !hasControls { return value }
    return sha256Hex(value)
}

public func deriveModelLabel(_ modelID: String) -> String {
    var base = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if base.hasPrefix("ft:") {
        let rest = base.dropFirst(3)
        if let colon = rest.firstIndex(of: ":") {
            base = String(rest[..<colon])
        } else {
            base = String(rest)
        }
    }
    let full = NSRange(base.startIndex..., in: base)
    base = datedSuffix.stringByReplacingMatches(in: base, range: full, withTemplate: "")
    let tokens = base.split(separator: "-").map(String.init).filter { !$0.isEmpty }
    if tokens.isEmpty { return modelID.uppercased() }
    if tokens[0] == "claude", tokens.count > 1 {
        let rest = tokens.dropFirst()
        let names = rest.filter { !matches(versionToken, $0) }
        let version = rest.filter { matches(versionToken, $0) }.joined(separator: ".")
        let label = names.map { $0.uppercased() }.joined(separator: " ")
        return version.isEmpty ? label : "\(label) \(version)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if tokens[0] == "gpt", tokens.count > 1 {
        var parts = ["GPT-\(tokens[1].uppercased())"]
        parts.append(contentsOf: tokens.dropFirst(2).map { $0.uppercased() })
        return parts.joined(separator: " ")
    }
    return tokens.map { $0.uppercased() }.joined(separator: " ")
}

public func normalizeModel(_ value: Any?) -> String? {
    guard let raw = boundedDisplay(value, maxBytes: 64) else { return nil }
    let label = modelLabels[raw.lowercased()] ?? deriveModelLabel(raw)
    return boundedDisplay(label, maxBytes: 24)
}

public func normalizeEffort(_ value: Any?) -> String? {
    boundedDisplay(value, maxBytes: 12)?.uppercased()
}

public func stableEventID(provider: String, event: AgentEvent) -> String {
    let raw = "\(provider)|\(event.taskID)|\(event.state)|\(event.sourceID)"
    return String(sha256Hex(raw).prefix(32))
}

private func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return expression.firstMatch(in: text, range: range) != nil
}

private func jsonObject(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
private func jsonString(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    return text
}
private func jsonArray(_ value: Any?) -> [Any]? { value as? [Any] }

private func jsonBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber else { return nil }
    guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

func hasExplicitError(_ record: [String: Any]) -> Bool {
    if jsonBool(record["is_error"]) == true { return true }
    if let error = record["error"], !(error is NSNull) { return true }
    return false
}

private func claudeIdentity(_ record: [String: Any]) -> (String, String, String?)? {
    guard let session = jsonString(record["sessionId"]), !session.isEmpty else { return nil }
    guard let source = jsonString(record["uuid"]), !source.isEmpty else { return nil }
    return (sha256Hex(session), source, sanitizeProject(record["cwd"]))
}

private func claudeEvent(_ record: [String: Any], state: String, activity: String?) -> AgentEvent? {
    guard let (taskID, sourceID, project) = claudeIdentity(record) else { return nil }
    var model: String?
    var effort: String?
    if let message = jsonObject(record["message"]) {
        model = normalizeModel(message["model"])
        effort = normalizeEffort(message["effort"])
    }
    if effort == nil { effort = normalizeEffort(record["effort"]) }
    return AgentEvent(state: state, activity: activity, taskID: taskID, sourceID: sourceID,
                      project: project, model: model, effort: effort)
}

private func claudeToolActivity(_ tool: [String: Any]) -> (String, String)? {
    guard let name = jsonString(tool["name"]), !name.isEmpty else { return nil }
    let normalized = name.lowercased()
    if normalized == "askuserquestion" { return ("waiting", "waiting_input") }
    if normalized.contains("permission") { return ("waiting", "waiting_approval") }
    if ["edit", "write", "apply_patch"].contains(normalized) { return ("working", "editing") }
    if normalized == "read" { return ("working", "reading") }
    if ["glob", "grep", "websearch", "web_search"].contains(normalized) { return ("working", "searching") }
    if ["bash", "shell", "exec", "exec_command"].contains(normalized) {
        let command = jsonObject(tool["input"]).flatMap { jsonString($0["command"]) }
        guard let command else { return ("working", "running") }
        if matches(testCommand, command) { return ("working", "testing") }
        if matches(buildCommand, command) { return ("working", "building") }
        return ("working", "running")
    }
    return nil
}

public func classifyClaude(_ record: Any?) -> AgentEvent? {
    guard let record = jsonObject(record) else { return nil }
    let entryType = jsonString(record["type"])
    if entryType == "user" { return claudeEvent(record, state: "working", activity: "thinking") }
    if entryType == "result" {
        let subtype = jsonString(record["subtype"])
        if hasExplicitError(record) { return claudeEvent(record, state: "error", activity: nil) }
        if subtype == "success" { return claudeEvent(record, state: "done", activity: nil) }
        if subtype == "error" || subtype == "failure" || subtype == "failed" {
            return claudeEvent(record, state: "error", activity: nil)
        }
        return nil
    }
    if entryType == "system" {
        let values = [record["subtype"], record["status"]]
        let waiting = values.contains { value in
            guard let text = jsonString(value) else { return false }
            return text.lowercased().contains("permission")
        }
        return waiting ? claudeEvent(record, state: "waiting", activity: "waiting_approval") : nil
    }
    if entryType != "assistant" { return nil }
    guard let message = jsonObject(record["message"]) else { return nil }
    let content = jsonArray(message["content"])
    if let content {
        var found: [(String, String)] = []
        for item in content {
            guard let tool = jsonObject(item), jsonString(tool["type"]) == "tool_use" else { continue }
            if let activity = claudeToolActivity(tool) { found.append(activity) }
        }
        for preferred in [("waiting", "waiting_input"), ("waiting", "waiting_approval")] {
            if found.contains(where: { $0 == preferred }) {
                return claudeEvent(record, state: preferred.0, activity: preferred.1)
            }
        }
        if let last = found.last {
            return claudeEvent(record, state: last.0, activity: last.1)
        }
    }
    if jsonString(message["stop_reason"]) == "end_turn" {
        return claudeEvent(record, state: "waiting", activity: nil)
    }
    if let content, content.contains(where: { item in
        guard let object = jsonObject(item), let type = jsonString(object["type"]) else { return false }
        return type == "thinking" || type == "text"
    }) {
        return claudeEvent(record, state: "working", activity: "thinking")
    }
    return nil
}

private func codexResponseActivity(_ payload: [String: Any]) -> String? {
    let kind = jsonString(payload["type"])
    if kind == "reasoning" || kind == "function_call_output" || kind == "custom_tool_call_output" {
        return "thinking"
    }
    if kind != "function_call" && kind != "custom_tool_call" { return nil }
    guard let name = jsonString(payload["name"]), !name.isEmpty else { return "running" }
    let normalized = name.lowercased()
    if ["apply_patch", "edit", "write"].contains(normalized) { return "editing" }
    if ["read", "view_image"].contains(normalized) { return "reading" }
    if normalized.contains("search") || ["web", "web__run", "find"].contains(normalized) {
        return "searching"
    }
    return "running"
}

public func classifyCodex(_ record: Any?) -> AgentEvent? {
    guard let record = jsonObject(record), let payload = jsonObject(record["payload"]) else { return nil }
    let entryType = jsonString(record["type"])
    if entryType == "turn_context" {
        guard let turnID = jsonString(payload["turn_id"]), !turnID.isEmpty else { return nil }
        return AgentEvent(
            state: "working", activity: "thinking", taskID: boundedTaskID(turnID), sourceID: turnID,
            project: sanitizeProject(payload["cwd"]), model: normalizeModel(payload["model"]),
            effort: normalizeEffort(payload["effort"]))
    }
    if entryType == "response_item" {
        guard let sourceID = jsonString(payload["id"]), !sourceID.isEmpty else { return nil }
        guard let activity = codexResponseActivity(payload) else { return nil }
        var turnID = sourceID
        if let metadata = jsonObject(payload["internal_chat_message_metadata_passthrough"]),
           let nested = jsonString(metadata["turn_id"]), !nested.isEmpty {
            turnID = nested
        }
        return AgentEvent(state: "working", activity: activity, taskID: boundedTaskID(turnID),
                          sourceID: sourceID, project: nil)
    }
    if entryType != "event_msg" { return nil }
    guard let turnID = jsonString(payload["turn_id"]), !turnID.isEmpty else { return nil }
    let kind = jsonString(payload["type"])
    if kind == "task_started" {
        return AgentEvent(state: "working", activity: "thinking", taskID: boundedTaskID(turnID),
                          sourceID: turnID, project: nil)
    }
    if kind == "task_complete" {
        let state = hasExplicitError(payload) ? "error" : "done"
        return AgentEvent(state: state, activity: nil, taskID: boundedTaskID(turnID),
                          sourceID: turnID, project: nil)
    }
    return nil
}

public func classifyClaudeLine(_ line: String) -> AgentEvent? {
    classifyClaude(jsonObject(from: line))
}

public func classifyCodexLine(_ line: String) -> AgentEvent? {
    classifyCodex(jsonObject(from: line))
}

func jsonObject(from line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return jsonObject(object)
}
