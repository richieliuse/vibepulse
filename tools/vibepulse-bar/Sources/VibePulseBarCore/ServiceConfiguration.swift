import Foundation

/// How to launch the tokenserver. Mirrors the LaunchAgent's shape so an
/// existing `se.torget.tokenserver.plist` imports without translation.
public struct ServiceConfiguration: Codable, Equatable, Sendable {
    public static let defaultPort = 8737
    public static let launchAgentLabel = "se.torget.tokenserver"

    public var pythonPath: String
    /// `tokenserver.py`, or a wrapper script that runs it.
    public var scriptPath: String
    public var workingDirectory: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var port: Int
    public var logPath: String

    public init(pythonPath: String, scriptPath: String, workingDirectory: String? = nil,
                arguments: [String] = [], environment: [String: String] = [:],
                port: Int = ServiceConfiguration.defaultPort,
                logPath: String = ServiceConfiguration.defaultLogPath) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.environment = environment
        self.port = port
        self.logPath = logPath
    }

    /// The same file launchd writes, so `smoke.py`, the comb routine and
    /// Console.app keep finding the service log in one place.
    public static var defaultLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/torget-tokenserver.log").path
    }

    public static var launchAgentPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist").path
    }

    /// `python -u script [args] [--port N]`: unbuffered, like the LaunchAgent,
    /// so a crash's last line reaches the log before the process is gone.
    public var commandLine: [String] {
        var arguments = self.arguments
        if Self.portArgument(in: arguments) == nil, self.port != Self.defaultPort {
            arguments += ["--port", String(self.port)]
        }
        return [self.pythonPath, "-u", self.scriptPath] + arguments
    }

    /// `commandLine` run through the app's launcher (see `ServiceGuard`).
    public func supervisedCommandLine(guardPath: String) -> [String] {
        let command = self.commandLine
        return [command[0], "-u", guardPath] + command.dropFirst(2)
    }

    public var resolvedWorkingDirectory: String {
        if let workingDirectory, !workingDirectory.isEmpty { return workingDirectory }
        return (self.scriptPath as NSString).deletingLastPathComponent
    }

    /// The port the server will actually bind: an explicit `--port` wins.
    public var effectivePort: Int {
        Self.portArgument(in: self.arguments) ?? self.port
    }

    /// A GUI app inherits launchd's minimal PATH; the service shells out to
    /// `git`, `codex` and friends, so the usual per-user tool directories are
    /// appended (never prepended: system tools keep precedence).
    public func processEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        for (key, value) in self.environment {
            environment[key] = value
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        var path = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        for extra in extras where !path.contains(extra) {
            path.append(extra)
        }
        environment["PATH"] = path.joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    public enum Issue: Equatable, Sendable {
        case pythonMissing(String)
        case scriptMissing(String)
        case invalidPort(Int)

        public var message: String {
            switch self {
            case let .pythonMissing(path): "Python not found or not executable: \(path)"
            case let .scriptMissing(path): "Server script not found: \(path)"
            case let .invalidPort(port): "Invalid port \(port)"
            }
        }
    }

    public func validate(fileManager: FileManager = .default) -> [Issue] {
        var issues: [Issue] = []
        if !fileManager.isExecutableFile(atPath: self.pythonPath) {
            issues.append(.pythonMissing(self.pythonPath))
        }
        if !fileManager.fileExists(atPath: self.scriptPath) {
            issues.append(.scriptMissing(self.scriptPath))
        }
        if !(1...65535).contains(self.effectivePort) {
            issues.append(.invalidPort(self.effectivePort))
        }
        return issues
    }

    static func portArgument(in arguments: [String]) -> Int? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--port", index + 1 < arguments.count {
                return Int(arguments[index + 1])
            }
            if argument.hasPrefix("--port=") {
                return Int(argument.dropFirst("--port=".count))
            }
        }
        return nil
    }
}

// MARK: - Discovery of a sensible default

extension ServiceConfiguration {
    public enum ImportError: Error, Equatable, LocalizedError {
        case missing
        case unreadable
        case notVibePulse
        case unrecognizedCommand

        public var errorDescription: String? {
            switch self {
            case .missing: "No LaunchAgent at \(ServiceConfiguration.launchAgentPath)"
            case .unreadable: "The LaunchAgent is not a readable property list"
            case .notVibePulse: "The LaunchAgent is not labelled \(ServiceConfiguration.launchAgentLabel)"
            case .unrecognizedCommand: "The LaunchAgent does not run `python -u <script>`"
            }
        }
    }

    /// Reads the command an installed LaunchAgent runs, with the same shape
    /// check `tools/vibepulse_macos_service.py` applies before touching one.
    public static func fromLaunchAgent(at path: String = launchAgentPath) throws -> ServiceConfiguration {
        guard let data = FileManager.default.contents(atPath: path) else { throw ImportError.missing }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else { throw ImportError.unreadable }
        guard dictionary["Label"] as? String == launchAgentLabel else { throw ImportError.notVibePulse }
        guard let argv = dictionary["ProgramArguments"] as? [String], argv.count >= 3, argv[1] == "-u" else {
            throw ImportError.unrecognizedCommand
        }
        var arguments = Array(argv.dropFirst(3))
        var port = defaultPort
        if let explicit = portArgument(in: arguments) {
            port = explicit
            arguments = Self.removingPortArgument(arguments)
        }
        let script = argv[2]
        let workdir = dictionary["WorkingDirectory"] as? String
        let absoluteScript = script.hasPrefix("/") || workdir == nil
            ? script
            : (workdir! as NSString).appendingPathComponent(script)
        return ServiceConfiguration(
            pythonPath: argv[0],
            scriptPath: absoluteScript,
            workingDirectory: workdir,
            arguments: arguments,
            environment: dictionary["EnvironmentVariables"] as? [String: String] ?? [:],
            port: port,
            logPath: dictionary["StandardErrorPath"] as? String ?? defaultLogPath)
    }

    /// A checkout-relative default: `<repo>/.venv/bin/python` when present,
    /// otherwise the first Python on the usual install paths.
    public static func fromRepository(_ root: URL, fileManager: FileManager = .default) -> ServiceConfiguration {
        let script = root.appendingPathComponent("tools/tokenserver/tokenserver.py").path
        let venv = root.appendingPathComponent(".venv/bin/python").path
        let candidates = [venv, "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        let python = candidates.first { fileManager.isExecutableFile(atPath: $0) } ?? venv
        return ServiceConfiguration(
            pythonPath: python,
            scriptPath: script,
            workingDirectory: (script as NSString).deletingLastPathComponent)
    }

    /// Walks up from `start` until a directory holds `tools/tokenserver/tokenserver.py`.
    public static func findRepository(from start: URL, fileManager: FileManager = .default) -> URL? {
        var current = start.standardizedFileURL
        for _ in 0..<12 {
            let marker = current.appendingPathComponent("tools/tokenserver/tokenserver.py").path
            if fileManager.fileExists(atPath: marker) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    static func removingPortArgument(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if argument == "--port" {
                skipNext = true
                continue
            }
            if argument.hasPrefix("--port=") { continue }
            result.append(argument)
        }
        return result
    }
}
