import Foundation

/// What the in-process server needs from Settings. There is no Python
/// interpreter, script, or argument list: this process is the server.
public struct ServiceConfiguration: Codable, Equatable, Sendable {
    public static let defaultPort = 8737
    public static let launchAgentLabel = "se.torget.tokenserver"

    public var port: Int
    public var claudePlan: String
    public var codexPlan: String
    public var relayURL: String
    public var relayMailbox: String
    public var publishInteractions: Bool
    public var publishAgentStatus: Bool
    public var githubRepo: String
    public var logPath: String

    public init(port: Int = ServiceConfiguration.defaultPort,
                claudePlan: String = "",
                codexPlan: String = "",
                relayURL: String = "",
                relayMailbox: String = "",
                publishInteractions: Bool = false,
                publishAgentStatus: Bool = false,
                githubRepo: String = "",
                logPath: String = ServiceConfiguration.defaultLogPath) {
        self.port = port
        self.claudePlan = claudePlan
        self.codexPlan = codexPlan
        self.relayURL = relayURL
        self.relayMailbox = relayMailbox
        self.publishInteractions = publishInteractions
        self.publishAgentStatus = publishAgentStatus
        self.githubRepo = githubRepo
        self.logPath = logPath
    }

    public static var defaultLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/torget-tokenserver.log").path
    }

    public static var launchAgentPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist").path
    }

    /// Plan names the engine's value meter and Max Tracker read. Blank fields are omitted.
    public var plans: [String: String] {
        var plans: [String: String] = [:]
        let claude = self.claudePlan.trimmingCharacters(in: .whitespacesAndNewlines)
        let codex = self.codexPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        if !claude.isEmpty { plans["claude"] = claude }
        if !codex.isEmpty { plans["codex"] = codex }
        return plans
    }

    public var trimmedGitHubRepo: String? {
        let repo = self.githubRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        return repo.isEmpty ? nil : repo
    }

    public var trimmedRelayURL: String? {
        let url = self.relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    public var trimmedRelayMailbox: String? {
        let mailbox = self.relayMailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        return mailbox.isEmpty ? nil : mailbox
    }

    public enum Issue: Equatable, Sendable {
        case invalidPort(Int)

        public var message: String {
            switch self {
            case let .invalidPort(port): "Port must be between 1 and 65535 (got \(port))."
            }
        }
    }

    public func validate() -> [Issue] {
        (1...65535).contains(self.port) ? [] : [.invalidPort(self.port)]
    }
}
