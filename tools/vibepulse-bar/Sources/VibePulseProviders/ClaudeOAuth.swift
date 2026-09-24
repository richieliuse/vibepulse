import Foundation

public struct ClaudeOAuthCandidate: Equatable {
    public var token: String
    /// Keychain `expiresAt` in milliseconds. The process source has no expiry.
    public var expiresAtMilliseconds: Double?

    public init(token: String, expiresAtMilliseconds: Double? = nil) {
        self.token = token
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }
}

public struct ClaudeCredentialSnapshot: Equatable {
    public var status: String
    public var expiresInMin: Int?
    /// Set only when the keychain itself explains an empty candidate list.
    public var reason: String?

    public init(status: String, expiresInMin: Int? = nil, reason: String? = nil) {
        self.status = status
        self.expiresInMin = expiresInMin
        self.reason = reason
    }
}

public struct ClaudeKeychainRead: Equatable {
    public var token: String?
    public var expiresAtMilliseconds: Double?
    /// Nil on success. Otherwise one of the `keychain_*` reason words.
    public var reason: String?

    public init(token: String? = nil, expiresAtMilliseconds: Double? = nil, reason: String? = nil) {
        self.token = token
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.reason = reason
    }
}

/// Orders already-fetched Claude OAuth material. The process token is first.
/// The keychain token is second only when it differs. This type never runs `security`.
public enum ClaudeOAuthCandidates {
    public static let credentialWarningSeconds: TimeInterval = 1800
    public static let desktopCommand = #"^/Users/[^/\s]+/Library/Application Support/Claude/claude-code/[^/\s]+/claude\.app/Contents/MacOS/claude(?: |$)"#
    public static let processTokenPattern = #"(?:^|\s)CLAUDE_CODE_OAUTH_TOKEN=([^\s]+)"#
    public static let keychainService = "Claude Code-credentials"

    public static func ordered(processToken: String?, keychainToken: String?, keychainExpiresAtMilliseconds: Double?) -> [ClaudeOAuthCandidate] {
        var candidates: [ClaudeOAuthCandidate] = []
        if let processToken, !processToken.isEmpty {
            candidates.append(ClaudeOAuthCandidate(token: processToken, expiresAtMilliseconds: nil))
        }
        if let keychainToken, !keychainToken.isEmpty, keychainToken != processToken {
            candidates.append(ClaudeOAuthCandidate(token: keychainToken, expiresAtMilliseconds: keychainExpiresAtMilliseconds))
        }
        return candidates
    }

    public static func ordered(processToken: String?, keychain: KeychainCommandResult) -> [ClaudeOAuthCandidate] {
        let read = interpret(keychain)
        return ordered(processToken: processToken, keychainToken: read.token, keychainExpiresAtMilliseconds: read.expiresAtMilliseconds)
    }

    public static func interpret(_ result: KeychainCommandResult) -> ClaudeKeychainRead {
        if let failure = result.failure {
            switch failure {
            case .binaryMissing:
                return ClaudeKeychainRead(reason: "keychain_security_missing")
            case .timeout:
                return ClaudeKeychainRead(reason: "keychain_timeout")
            case .spawnFailed:
                let name = result.spawnErrorName ?? "OSError"
                return ClaudeKeychainRead(reason: "keychain_spawn_failed: \(name)")
            }
        }
        if result.exitCode == 44 {
            return ClaudeKeychainRead(reason: "keychain_no_entry")
        }
        if result.exitCode != 0 {
            let code = result.exitCode ?? -1
            return ClaudeKeychainRead(reason: "keychain_denied_or_locked (exit \(code))")
        }
        guard let body = JSON.object(from: Data(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) else {
            return ClaudeKeychainRead(reason: "keychain_malformed")
        }
        let oauthValue = body["claudeAiOauth"]
        if oauthValue == nil || oauthValue is NSNull {
            return ClaudeKeychainRead(reason: "keychain_entry_without_token")
        }
        guard let oauth = JSON.dictionary(oauthValue) else {
            return ClaudeKeychainRead(reason: "keychain_malformed")
        }
        let token = JSON.string(oauth["accessToken"])
        let expires = JSON.finite(oauth["expiresAt"])
        if token == nil || token?.isEmpty == true {
            return ClaudeKeychainRead(reason: "keychain_entry_without_token")
        }
        return ClaudeKeychainRead(token: token, expiresAtMilliseconds: expires, reason: nil)
    }

    /// `_oauth_credential_snapshot`. Never returns the token strings.
    public static func credentialSnapshot(_ candidates: [ClaudeOAuthCandidate], now: TimeInterval) -> ClaudeCredentialSnapshot {
        if candidates.isEmpty {
            return ClaudeCredentialSnapshot(status: "unavailable")
        }
        let expiries = candidates.compactMap { candidate -> TimeInterval? in
            guard let raw = candidate.expiresAtMilliseconds, raw.isFinite else { return nil }
            let seconds = raw / 1000
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
        guard let latest = expiries.max() else {
            return ClaudeCredentialSnapshot(status: "unknown")
        }
        let remaining = latest - now
        if remaining <= 0 {
            return ClaudeCredentialSnapshot(status: "expired", expiresInMin: 0)
        }
        let minutes = max(1, Int(ceil(remaining / 60)))
        let status = remaining <= credentialWarningSeconds ? "expiring" : "ready"
        return ClaudeCredentialSnapshot(status: status, expiresInMin: minutes)
    }

    /// Token embedded in an already-fetched `ps eww` command line, after the Desktop path check.
    public static func processToken(in commandLine: String) -> String? {
        guard commandLine.range(of: desktopCommand, options: .regularExpression) != nil else { return nil }
        guard let expression = try? NSRegularExpression(pattern: processTokenPattern) else { return nil }
        let range = NSRange(commandLine.startIndex..., in: commandLine)
        guard let match = expression.firstMatch(in: commandLine, options: [], range: range),
              let tokenRange = Range(match.range(at: 1), in: commandLine) else { return nil }
        return String(commandLine[tokenRange])
    }

    public static func processToken(using processes: any ProcessInspecting) -> String? {
        let pattern = "/Library/Application Support/Claude/claude-code/.*/claude.app/Contents/MacOS/claude"
        for raw in processes.processIDs(matching: pattern) {
            let pid = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pid.isEmpty, pid.allSatisfy(\.isNumber) else { continue }
            guard let command = processes.commandLine(pid: pid) else { continue }
            if let token = processToken(in: command) {
                return token
            }
        }
        return nil
    }
}
