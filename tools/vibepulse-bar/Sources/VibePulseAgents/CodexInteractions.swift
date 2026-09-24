import Foundation

public struct CodexOption: Equatable, Sendable {
    public var label: String
    public var description: String?
    public var recommended: Bool?

    public init(label: String, description: String? = nil, recommended: Bool? = nil) {
        self.label = label
        self.description = description
        self.recommended = recommended
    }
}

public struct CodexPermissionEvent: Equatable, Sendable {
    public var sessionID: String
    public var turnID: String
    public var cwd: String
    public var toolName: String
    public var command: String?
    public var descriptionText: String?

    public init(sessionID: String, turnID: String, cwd: String, toolName: String,
                command: String? = nil, descriptionText: String? = nil) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.toolName = toolName
        self.command = command
        self.descriptionText = descriptionText
    }
}

/// A Codex question or permission reduced to the provider-neutral view.
public struct NormalizedInteraction: Sendable {
    public var provider: String
    public var kind: String
    public var project: String?
    public var sessionID: String
    public var turnID: String
    public var options: [CodexOption]
    public var recommendedIndex: Int?
    public var view: [(String, WireValue)]
    public var permission: CodexPermissionEvent?

    public init(provider: String, kind: String, project: String?, sessionID: String, turnID: String,
                options: [CodexOption], recommendedIndex: Int?, view: [(String, WireValue)],
                permission: CodexPermissionEvent?) {
        self.provider = provider
        self.kind = kind
        self.project = project
        self.sessionID = sessionID
        self.turnID = turnID
        self.options = options
        self.recommendedIndex = recommendedIndex
        self.view = view
        self.permission = permission
    }

    public static func == (lhs: NormalizedInteraction, rhs: NormalizedInteraction) -> Bool {
        lhs.provider == rhs.provider && lhs.kind == rhs.kind && lhs.project == rhs.project
            && lhs.sessionID == rhs.sessionID && lhs.turnID == rhs.turnID
            && lhs.options == rhs.options && lhs.recommendedIndex == rhs.recommendedIndex
            && lhs.permission == rhs.permission && sameView(lhs.view, rhs.view)
    }
}

private func sameView(_ lhs: [(String, WireValue)], _ rhs: [(String, WireValue)]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (left, right) in zip(lhs, rhs) where left.0 != right.0 || left.1 != right.1 {
        return false
    }
    return true
}

private let questionFields: Set<String> = ["question", "header", "options"]
private let optionFields: Set<String> = ["label", "description", "recommended"]
private let safeBuildTargets: Set<String> = ["all", "build", "test", "check"]
private let safeNPMFlags: Set<String> = ["--silent", "--if-present", "--ignore-scripts"]
private let safeGitStatusFlags: Set<String> = ["--short", "-s", "--branch", "-b", "--porcelain"]
private let safeGitLogFlags: Set<String> = ["--oneline", "--decorate", "--graph", "--stat", "--patch", "--no-color"]
private let safeGitDiffFlags: Set<String> = ["--stat", "--name-only", "--name-status", "--check", "--no-color", "--cached", "--staged"]

public func normalizeCodexQuestion(payload: [String: Any], cwd: String, sessionID: String,
                                   turnID: String) -> NormalizedInteraction? {
    guard let identity = codexIdentity(cwd: cwd, sessionID: sessionID, turnID: turnID) else { return nil }
    guard Set(payload.keys).isSubset(of: questionFields),
          payload["question"] != nil, payload["options"] != nil else { return nil }
    guard codexTextIsValid(payload["question"], maxBytes: 96) else { return nil }
    if payload.keys.contains("header"), !codexTextIsValid(payload["header"], maxBytes: 64) { return nil }
    guard let rawOptions = payload["options"] as? [Any], rawOptions.count == 2 || rawOptions.count == 3 else {
        return nil
    }

    var options: [CodexOption] = []
    var recommended: Int?
    for (index, raw) in rawOptions.enumerated() {
        guard let raw = raw as? [String: Any], Set(raw.keys).isSubset(of: optionFields), raw["label"] != nil else {
            return nil
        }
        guard let label = raw["label"] as? String, codexTextIsValid(label, maxBytes: 64) else { return nil }
        var option = CodexOption(label: label)
        if raw.keys.contains("description") {
            guard let description = raw["description"] as? String, codexTextIsValid(description, maxBytes: 64) else {
                return nil
            }
            option.description = description
        }
        if raw.keys.contains("recommended") {
            guard let flag = strictBool(raw["recommended"]) else { return nil }
            option.recommended = flag
            if flag {
                if recommended != nil { return nil }
                recommended = index
            }
        }
        options.append(option)
    }

    var view: [(String, WireValue)] = [
        ("kind", .string("question")),
        ("options_total", .int(options.count)),
        ("marked", .bool(recommended != nil)),
        ("prompt", .string(payload["question"] as? String ?? "")),
        ("can_approve", .bool(recommended != nil)),
    ]
    if let recommended {
        let selected = options[recommended]
        view.append(("title", .string(selected.label)))
        if let description = selected.description {
            view.append(("subtitle", .string(description)))
        }
    }
    return NormalizedInteraction(
        provider: "codex", kind: "question", project: identity.project, sessionID: sessionID, turnID: turnID,
        options: options, recommendedIndex: recommended, view: view, permission: nil)
}

public func normalizeCodexPermission(event: [String: Any], reveal: Bool) -> NormalizedInteraction? {
    guard event["hook_event_name"] as? String == "PermissionRequest" else { return nil }
    guard codexTextIsValid(event["session_id"]), codexTextIsValid(event["turn_id"]),
          codexTextIsValid(event["cwd"]), codexTextIsValid(event["tool_name"]),
          event["tool_input"] is [String: Any] else { return nil }
    guard let sessionID = event["session_id"] as? String,
          let turnID = event["turn_id"] as? String,
          let cwd = event["cwd"] as? String,
          let toolName = event["tool_name"] as? String,
          let rawInput = event["tool_input"] as? [String: Any],
          let identity = codexIdentity(cwd: cwd, sessionID: sessionID, turnID: turnID) else { return nil }

    var command: String?
    var description: String?
    for field in ["command", "description"] {
        guard let value = rawInput[field] else { continue }
        guard let text = value as? String, isControlFree(text) else { return nil }
        if field == "command" { command = text } else { description = text }
    }
    let permission = CodexPermissionEvent(
        sessionID: sessionID, turnID: turnID, cwd: cwd, toolName: toolName,
        command: command, descriptionText: description)
    return normalizeCodexPermission(permission, reveal: reveal, project: identity.project)
}

public func normalizeCodexPermission(_ event: CodexPermissionEvent, reveal: Bool,
                                     project: String? = nil) -> NormalizedInteraction? {
    guard let identity = codexIdentity(cwd: event.cwd, sessionID: event.sessionID, turnID: event.turnID) else {
        return nil
    }
    let resolvedProject = project ?? identity.project
    if let command = event.command, !isControlFree(command) { return nil }
    if let description = event.descriptionText, !isControlFree(description) { return nil }
    var toolInput: [String: Any] = [:]
    if let command = event.command { toolInput["command"] = command }
    if let description = event.descriptionText { toolInput["description"] = description }
    let base = approvalView(toolName: event.toolName, toolInput: toolInput, reveal: reveal)
    let viewCan = boolValue(base, "can_approve") ?? false
    var allowed = viewCan && approvableTool(event.toolName, toolInput)
    let folded = event.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if folded == "bash" || folded == "shell" {
        allowed = allowed && codexShellCommandIsSafe(toolInput["command"])
    }
    return NormalizedInteraction(
        provider: "codex", kind: "approval", project: resolvedProject, sessionID: event.sessionID,
        turnID: event.turnID, options: [], recommendedIndex: nil,
        view: replacingCanApprove(base, allowed), permission: event)
}

func posixShellTokens(_ command: String) -> [String]? {
    var splitter = PosixShellSplitter(command)
    return splitter.split()
}

func codexShellCommandIsSafe(_ command: Any?) -> Bool {
    guard let command = command as? String else { return false }
    guard let tokens = posixShellTokens(command), let program = tokens.first else { return false }
    if program == "./test/run.sh" { return tokens.count == 1 }
    let family = program.lowercased()
    let arguments = Array(tokens.dropFirst())
    switch family {
    case "make", "ninja":
        return arguments.allSatisfy { safeBuildTargets.contains($0.lowercased()) }
    case "cmake":
        return cmakeBuildIsSafe(arguments)
    case "npm":
        return npmIsSafe(arguments)
    case "git":
        return gitIsSafe(arguments)
    case "ls", "cat", "head", "tail", "wc", "grep", "rg", "pytest", "ctest":
        return plainArguments(arguments)
    case "python", "python3":
        return arguments.count >= 2 && Array(arguments.prefix(2)) == ["-m", "unittest"]
            && plainArguments(Array(arguments.dropFirst(2)))
    case "cargo":
        return !arguments.isEmpty && ["test", "build"].contains(arguments[0].lowercased())
            && plainArguments(Array(arguments.dropFirst()))
    case "go":
        return !arguments.isEmpty && arguments[0].lowercased() == "test"
            && plainArguments(Array(arguments.dropFirst()))
    case "idf.py":
        return arguments.count == 1 && arguments[0].lowercased() == "build"
    default:
        return false
    }
}

private struct CodexIdentity {
    var project: String?
}

private func codexIdentity(cwd: Any?, sessionID: Any?, turnID: Any?) -> CodexIdentity? {
    guard codexTextIsValid(cwd), codexTextIsValid(sessionID), codexTextIsValid(turnID) else { return nil }
    return CodexIdentity(project: sanitizeProject(cwd))
}

private func codexTextIsValid(_ value: Any?, maxBytes: Int? = nil) -> Bool {
    guard let text = value as? String else { return false }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
    if !isControlFree(text) { return false }
    if let maxBytes, Data(text.utf8).count > maxBytes { return false }
    return true
}

private func isControlFree(_ text: String) -> Bool {
    !text.unicodeScalars.contains(where: isCCategory)
}

private func strictBool(_ value: Any?) -> Bool? {
    guard let value else { return nil }
    if type(of: value) == Bool.self { return value as? Bool }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

private func plainArguments(_ arguments: [String]) -> Bool {
    arguments.allSatisfy { !$0.hasPrefix("-") }
}

private func cmakeBuildIsSafe(_ arguments: [String]) -> Bool {
    guard arguments.count >= 2, arguments[0].lowercased() == "--build", !arguments[1].hasPrefix("-") else {
        return false
    }
    var index = 2
    while index < arguments.count {
        let argument = arguments[index].lowercased()
        if argument == "--verbose" {
            index += 1
        } else if argument == "--parallel" || argument == "-j" {
            index += 1
            if index < arguments.count && !arguments[index].hasPrefix("-") {
                guard isDecimalDigits(arguments[index]) else { return false }
                index += 1
            }
        } else if argument == "--config" {
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("-") else { return false }
            index += 1
        } else if argument == "--target" {
            index += 1
            var targets = 0
            while index < arguments.count && !arguments[index].hasPrefix("-") {
                guard safeBuildTargets.contains(arguments[index].lowercased()) else { return false }
                targets += 1
                index += 1
            }
            if targets == 0 { return false }
        } else if argument.hasPrefix("--target=") {
            let value = String(argument.dropFirst("--target=".count))
            guard safeBuildTargets.contains(value) else { return false }
            index += 1
        } else {
            return false
        }
    }
    return true
}

private func npmIsSafe(_ arguments: [String]) -> Bool {
    guard !arguments.isEmpty else { return false }
    let flags: ArraySlice<String>
    if arguments[0].lowercased() == "test" {
        flags = arguments.dropFirst()
    } else if arguments.count >= 2, arguments[0].lowercased() == "run",
              ["test", "build"].contains(arguments[1].lowercased()) {
        flags = arguments.dropFirst(2)
    } else {
        return false
    }
    return flags.allSatisfy { safeNPMFlags.contains($0.lowercased()) }
}

private func gitIsSafe(_ arguments: [String]) -> Bool {
    guard let subcommand = arguments.first?.lowercased() else { return false }
    let tail = Array(arguments.dropFirst())
    if subcommand == "status" {
        return tail.allSatisfy { safeGitStatusFlags.contains($0.lowercased()) }
    }
    if subcommand == "branch" {
        return tail.isEmpty || tail == ["--show-current"]
    }
    if subcommand == "log" || subcommand == "show" {
        return tail.allSatisfy { argument in
            !argument.hasPrefix("-") || safeGitLogFlags.contains(argument.lowercased())
        }
    }
    if subcommand != "diff" { return false }
    var pathsOnly = false
    for argument in tail {
        if pathsOnly { continue }
        if argument == "--" {
            pathsOnly = true
        } else if argument.hasPrefix("-"), !safeGitDiffFlags.contains(argument.lowercased()) {
            return false
        }
    }
    return true
}

private func isDecimalDigits(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { $0.properties.numericType == .decimal }
}

private func boolValue(_ pairs: [(String, WireValue)], _ key: String) -> Bool? {
    guard let value = pairs.first(where: { $0.0 == key })?.1 else { return nil }
    if case let .bool(flag) = value { return flag }
    return nil
}

private func replacingCanApprove(_ pairs: [(String, WireValue)], _ flag: Bool) -> [(String, WireValue)] {
    pairs.map { key, value in
        key == "can_approve" ? (key, .bool(flag)) : (key, value)
    }
}

/// POSIX `shlex.split` (`posix=True`, `whitespace_split=True`, comments off).
private struct PosixShellSplitter {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var state: ShellState = .space
    private var token = ""
    private var quoted = false

    private enum ShellState: Equatable {
        case space
        case word
        case quote(Unicode.Scalar)
        case escape
        case done
    }

    private enum Read {
        case token(String)
        case eof
        case error
    }

    private static let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\r", "\n"]

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    mutating func split() -> [String]? {
        var tokens: [String] = []
        while true {
            switch readToken() {
            case .error: return nil
            case .eof: return tokens
            case let .token(value): tokens.append(value)
            }
        }
    }

    private mutating func readChar() -> Unicode.Scalar? {
        guard index < scalars.count else { return nil }
        let value = scalars[index]
        index += 1
        return value
    }

    private mutating func finish() -> Read {
        let result = token
        token = ""
        if !quoted && result.isEmpty { return .eof }
        return .token(result)
    }

    private mutating func readToken() -> Read {
        quoted = false
        var escapedState: ShellState = .word
        token = ""
        while true {
            let next = readChar()
            switch state {
            case .done:
                token = ""
                quoted = false
                return .eof
            case .space:
                guard let next else {
                    state = .done
                    return finish()
                }
                if Self.whitespace.contains(next) {
                    if !token.isEmpty || quoted { return finish() }
                    continue
                }
                if next == "\\" {
                    escapedState = .word
                    state = .escape
                } else if next == "'" || next == "\"" {
                    state = .quote(next)
                } else {
                    token = String(next)
                    state = .word
                }
            case let .quote(mark):
                guard let next else { return .error }
                quoted = true
                if next == mark {
                    state = .word
                } else if mark == "\"", next == "\\" {
                    escapedState = .quote(mark)
                    state = .escape
                } else {
                    token.append(String(next))
                }
            case .escape:
                guard let next else { return .error }
                if case let .quote(mark) = escapedState, next != "\\", next != mark {
                    token.append("\\")
                }
                token.append(String(next))
                state = escapedState
            case .word:
                guard let next else {
                    state = .done
                    return finish()
                }
                if Self.whitespace.contains(next) {
                    state = .space
                    if !token.isEmpty || quoted { return finish() }
                    continue
                }
                if next == "'" || next == "\"" {
                    state = .quote(next)
                } else if next == "\\" {
                    escapedState = .word
                    state = .escape
                } else {
                    token.append(String(next))
                }
            }
        }
    }
}
