import Foundation

/// The per-user LaunchAgent, observed and — only on an explicit take-over —
/// paused. The plist file itself is never edited: `launchctl disable` is a
/// reversible override, so handing the service back restores exactly what
/// `tools/vibepulse_macos_service.py install` wrote.
public struct LaunchAgentStatus: Sendable, Equatable {
    public var plistExists: Bool
    public var loaded: Bool
    public var pid: Int32?
    public var disabled: Bool

    public init(plistExists: Bool, loaded: Bool, pid: Int32?, disabled: Bool) {
        self.plistExists = plistExists
        self.loaded = loaded
        self.pid = pid
        self.disabled = disabled
    }

    public static let absent = LaunchAgentStatus(plistExists: false, loaded: false, pid: nil, disabled: false)
}

public enum LaunchAgentControl {
    static var domain: String { "gui/\(getuid())" }
    static var target: String { "\(domain)/\(ServiceConfiguration.launchAgentLabel)" }

    public static func status(plistPath: String = ServiceConfiguration.launchAgentPath) async -> LaunchAgentStatus {
        let exists = FileManager.default.fileExists(atPath: plistPath)
        let printed = await CommandRunner.run("/bin/launchctl", ["print", self.target], timeout: 5)
        let disabled = await CommandRunner.run("/bin/launchctl", ["print-disabled", self.domain], timeout: 5)
        return LaunchAgentStatus(
            plistExists: exists,
            loaded: printed.succeeded,
            pid: printed.succeeded ? self.parsePID(printed.stdout) : nil,
            disabled: self.parseDisabled(disabled.stdout, label: ServiceConfiguration.launchAgentLabel))
    }

    /// Step one of a take-over: launchd must not respawn what we stop next.
    public static func disable() async -> CommandRunner.Result {
        await CommandRunner.run("/bin/launchctl", ["disable", self.target], timeout: 5)
    }

    public static func bootout() async -> CommandRunner.Result {
        await CommandRunner.run("/bin/launchctl", ["bootout", self.target], timeout: 15)
    }

    public static func enable() async -> CommandRunner.Result {
        await CommandRunner.run("/bin/launchctl", ["enable", self.target], timeout: 5)
    }

    public static func bootstrap(plistPath: String = ServiceConfiguration.launchAgentPath) async -> CommandRunner.Result {
        await CommandRunner.run("/bin/launchctl", ["bootstrap", self.domain, plistPath], timeout: 15)
    }

    /// Re-enables and reloads the installed LaunchAgent.
    public static func handBack(plistPath: String = ServiceConfiguration.launchAgentPath) async -> CommandRunner.Result {
        _ = await self.enable()
        return await self.bootstrap(plistPath: plistPath)
    }

    static func parsePID(_ printed: String) -> Int32? {
        for line in printed.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = ") else { continue }
            return Int32(trimmed.dropFirst("pid = ".count))
        }
        return nil
    }

    static func parseDisabled(_ printed: String, label: String) -> Bool {
        for line in printed.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"\(label)\"") else { continue }
            return trimmed.contains("=> disabled") || trimmed.contains("=> true")
        }
        return false
    }
}
