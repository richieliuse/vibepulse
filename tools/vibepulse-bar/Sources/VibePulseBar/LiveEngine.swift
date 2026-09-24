import Darwin
import Foundation
import VibePulseBarCore
import VibePulseProviders
import VibePulseRelay
import VibePulseServer
import VibePulseState

/// The app's `VibePulseEngine`. A busy port is reported by `start` and does not bind.
final class LiveMenuEngine: MenuEngine, @unchecked Sendable {
    private let gate = NSLock()
    private var current: VibePulseEngine
    private var settings: ServiceConfiguration
    let quotaTransport = URLSessionQuotaTransport()
    let relayTransport = RelayURLSessionTransport()
    let githubTransport = URLSessionGitHubTransport()

    init(configuration: ServiceConfiguration) {
        self.settings = configuration
        self.current = LiveMenuEngine.dormant(port: configuration.port)
    }

    var engine: VibePulseEngine {
        self.gate.lock()
        defer { self.gate.unlock() }
        return self.current
    }

    var configuration: ServiceConfiguration {
        get {
            self.gate.lock()
            defer { self.gate.unlock() }
            return self.settings
        }
        set {
            self.gate.lock()
            self.settings = newValue
            self.gate.unlock()
        }
    }

    var snapshot: [String: Any] { self.engine.snapshot }
    var agentStatus: [String: Any] { self.engine.agentJSON }
    var diagnostics: [String: Any] { self.engine.diagnosticsJSON }

    func start() -> MenuEngineStart {
        let configuration = self.configuration
        let probe = Self.dormant(port: configuration.port)
        switch probe.start() {
        case let .portBusy(pid, command):
            return .portBusy(pid: pid, command: command)
        case let .failed(message):
            return .failed(message)
        case .started:
            probe.stop()
            let live = self.makeLive(configuration)
            self.gate.lock()
            let previous = self.current
            self.current = live
            self.gate.unlock()
            previous.stop()
            let result = live.start()
            if case .started = result {
                return Self.map(result)
            }
            live.stop()
            return Self.map(result)
        }
    }

    func stop() {
        self.engine.stop()
    }

    private static func dormant(port: Int) -> VibePulseEngine {
        var environment = EngineEnvironment()
        environment.automaticWorkers = false
        environment.trapSignals = false
        return VibePulseEngine(port: port, environment: environment)
    }

    private func makeLive(_ configuration: ServiceConfiguration) -> VibePulseEngine {
        var environment = EngineEnvironment()
        environment.trapSignals = false
        environment.automaticWorkers = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        environment.stateDirectory = home.appendingPathComponent(
            "Library/Application Support/VibePulse", isDirectory: true)
        environment.projectsDirectory = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { value -> URL? in
            value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        } ?? home.appendingPathComponent(".codex", isDirectory: true)
        environment.codexSessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        environment.codexAuthPath = codexHome.appendingPathComponent("auth.json")
        environment.plans = configuration.plans
        environment.quotaTransport = self.quotaTransport
        environment.claudeCandidates = { LiveCredentials.claudeCandidates() }
        environment.deviceKeyURL = home.appendingPathComponent(".vibepulse-device-key")
        let quota = self.quotaTransport
        environment.grokFetch = { wall in
            let root = ProcessInfo.processInfo.environment["GROK_HOME"].flatMap { value -> URL? in
                value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
            } ?? home.appendingPathComponent(".grok", isDirectory: true)
            let auth = GrokBilling.loadAuth(path: root.appendingPathComponent("auth.json"), now: wall)
            return SubscriptionFetch.grok(auth: auth, now: wall, transport: quota)
        }
        environment.cursorFetch = { wall in
            let database = home.appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            let loaded = CursorUsage.load(data: CursorDatabase.tokenData(at: database), now: wall)
            return SubscriptionFetch.cursor(
                status: loaded.status, token: loaded.token, now: wall, transport: quota)
        }
        if let saved = try? VibePulseConfig.load(from: environment.stateDirectory.appendingPathComponent("config.json")) {
            environment.claudeInteractions = saved.claudeInteractions
            environment.codexInteractions = saved.codexInteractions
            environment.interactionDetail = saved.interactionDetail
            environment.legacyClaudePanelV1 = saved.legacyClaudePanelV1
        }
        if let repo = configuration.trimmedGitHubRepo {
            environment.githubRepo = repo
            environment.githubToken = GitHubTokenSource.token(
                environment: ProcessInfo.processInfo.environment,
                homeDirectory: home,
                repoRoot: Self.repositoryRoot() ?? home)
            let github = self.githubTransport
            environment.githubTransport = { try github.send($0) }
        }
        if let relay = self.relayConfig(configuration, home: home) {
            environment.relay = relay
        }
        return VibePulseEngine(port: configuration.port, environment: environment)
    }

    private func relayConfig(_ configuration: ServiceConfiguration, home: URL) -> EngineRelayConfig? {
        guard let url = configuration.trimmedRelayURL,
              let mailbox = configuration.trimmedRelayMailbox,
              configuration.publishInteractions || configuration.publishAgentStatus,
              let macToken = LiveSecrets.macToken(home: home),
              let deviceKey = LiveSecrets.deviceKey(home: home)
        else { return nil }
        let transport = self.relayTransport
        return EngineRelayConfig(
            baseURL: url,
            mailbox: mailbox,
            macToken: macToken,
            deviceKeyHex: deviceKey,
            publishInteractions: configuration.publishInteractions,
            publishAgentStatus: configuration.publishAgentStatus,
            transport: { try transport.send($0) })
    }

    private static func map(_ result: EngineStart) -> MenuEngineStart {
        switch result {
        case let .started(port): .started(port: port)
        case let .portBusy(pid, command): .portBusy(pid: pid, command: command)
        case let .failed(message): .failed(message)
        }
    }

    private static func repositoryRoot() -> URL? {
        let starts = [
            Bundle.main.bundleURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        ]
        for start in starts {
            var current = start.standardizedFileURL
            for _ in 0..<12 {
                if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                    return current
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        return nil
    }
}

struct SystemLaunchControl: LaunchAgentControlling {
    func status() async -> LaunchAgentStatus { await LaunchAgentControl.status() }
    func disable() async -> CommandRunner.Result { await LaunchAgentControl.disable() }
    func bootout() async -> CommandRunner.Result { await LaunchAgentControl.bootout() }
    func enable() async -> CommandRunner.Result { await LaunchAgentControl.enable() }
    func bootstrap() async -> CommandRunner.Result { await LaunchAgentControl.bootstrap() }
}

struct DarwinProcessSignals: ProcessSignaling {
    func send(signal: Int32, to pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, signal)
    }

    func isAlive(_ pid: Int32) -> Bool {
        ProcessInspector.isAlive(pid)
    }
}

final class URLSessionQuotaTransport: QuotaHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirector: RedirectBlocker

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let redirector = RedirectBlocker()
        self.redirector = redirector
        self.session = URLSession(configuration: configuration, delegate: redirector, delegateQueue: nil)
    }

    func send(_ request: QuotaHTTPRequest) throws -> QuotaHTTPResponse {
        guard let url = URL(string: request.url) else { return QuotaHTTPResponse(status: 0) }
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        let box = HTTPBodyBox()
        let finished = DispatchSemaphore(value: 0)
        let task = self.session.dataTask(with: urlRequest) { data, response, _ in
            box.store(data: data, response: response, limit: QuotaHTTP.maxBodyBytes)
            finished.signal()
        }
        task.resume()
        if finished.wait(timeout: .now() + request.timeout + 1) == .timedOut {
            task.cancel()
            return QuotaHTTPResponse(status: 0)
        }
        return box.quota()
    }
}

final class URLSessionGitHubTransport: @unchecked Sendable {
    private let session: URLSession
    private let redirector: RedirectBlocker

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let redirector = RedirectBlocker()
        self.redirector = redirector
        self.session = URLSession(configuration: configuration, delegate: redirector, delegateQueue: nil)
    }

    func send(_ request: GitHubHTTPRequest) throws -> GitHubHTTPResponse {
        guard let url = URL(string: request.url) else {
            return GitHubHTTPResponse(status: 0, body: Data())
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 20)
        urlRequest.httpShouldHandleCookies = false
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        let box = HTTPBodyBox()
        let finished = DispatchSemaphore(value: 0)
        let task = self.session.dataTask(with: urlRequest) { data, response, _ in
            box.store(data: data, response: response, limit: 1024 * 1024)
            finished.signal()
        }
        task.resume()
        if finished.wait(timeout: .now() + 21) == .timedOut {
            task.cancel()
            return GitHubHTTPResponse(status: 0, body: Data())
        }
        return box.github()
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class HTTPBodyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 0
    private var headers: [String: String] = [:]
    private var body = Data()

    func store(data: Data?, response: URLResponse?, limit: Int) {
        guard let http = response as? HTTPURLResponse else { return }
        var headerFields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String {
                headerFields[name] = text
            }
        }
        let payload = data ?? Data()
        self.lock.lock()
        if payload.count > limit {
            self.status = 0
            self.body = Data()
        } else {
            self.status = http.statusCode
            self.headers = headerFields
            self.body = payload
        }
        self.lock.unlock()
    }

    func quota() -> QuotaHTTPResponse {
        self.lock.lock()
        defer { self.lock.unlock() }
        return QuotaHTTPResponse(status: self.status, headers: self.headers, body: self.body)
    }

    func github() -> GitHubHTTPResponse {
        self.lock.lock()
        defer { self.lock.unlock() }
        return GitHubHTTPResponse(status: self.status, headers: self.headers, body: self.body)
    }
}

private enum LiveCredentials {
    static func claudeCandidates() -> [ClaudeOAuthCandidate] {
        let processToken = ClaudeOAuthCandidates.processToken(using: LiveProcesses())
        return ClaudeOAuthCandidates.ordered(processToken: processToken, keychain: self.keychain())
    }

    private static func keychain() -> KeychainCommandResult {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/security") else {
            return KeychainCommandResult(failure: .binaryMissing)
        }
        let result = Self.run("/usr/bin/security",
                              ["find-generic-password", "-s", ClaudeOAuthCandidates.keychainService, "-w"],
                              timeout: 10)
        if result.timedOut { return KeychainCommandResult(failure: .timeout) }
        if result.spawnFailed {
            return KeychainCommandResult(failure: .spawnFailed, spawnErrorName: result.spawnName)
        }
        return KeychainCommandResult(exitCode: result.status, stdout: result.stdout)
    }

    fileprivate static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return CommandOutput(status: -1, stdout: "", spawnFailed: true,
                                 spawnName: String(describing: type(of: error)))
        }
        let group = DispatchGroup()
        group.enter()
        nonisolated(unsafe) var data = Data()
        DispatchQueue.global().async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            _ = group.wait(timeout: .now() + 1)
            return CommandOutput(status: -1, stdout: "", timedOut: true)
        }
        _ = group.wait(timeout: .now() + 1)
        return CommandOutput(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }
}

private struct CommandOutput {
    var status: Int32
    var stdout: String
    var timedOut = false
    var spawnFailed = false
    var spawnName: String?
}

private struct LiveProcesses: ProcessInspecting {
    func processIDs(matching pattern: String) -> [String] {
        let result = LiveCredentials.run("/usr/bin/pgrep", ["-f", pattern], timeout: 5)
        guard result.status == 0 || result.status == 1 else { return [] }
        return result.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func commandLine(pid: String) -> String? {
        let result = LiveCredentials.run("/bin/ps", ["eww", "-p", pid, "-o", "command="], timeout: 5)
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private enum LiveSecrets {
    static func macToken(home: URL) -> String? {
        if let value = ProcessInfo.processInfo.environment["VIBEPULSE_INTERACTION_MAC_TOKEN"],
           Self.validMacToken(value) {
            return value
        }
        guard let text = Self.privateFile(home.appendingPathComponent(".vibepulse-interaction-relay-token")) else {
            return nil
        }
        return Self.validMacToken(text) ? text : nil
    }

    static func deviceKey(home: URL) -> String? {
        for name in ["VIBEPULSE_DEVICE_KEY", "TK_VIBEPULSE_DEVICE_KEY"] {
            if let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        if let text = Self.privateFile(home.appendingPathComponent(".vibepulse-device-key")) {
            return text
        }
        return nil
    }

    private static func validMacToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 43, trimmed.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value)
                || $0.value == 45 || $0.value == 95
        }) else { return false }
        return true
    }

    /// A regular file mode 0600. Anything else is left unread.
    private static func privateFile(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard (info.st_mode & 0o777) == 0o600 else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Read-only `cursorAuth/accessToken` from Cursor's state database. The token
/// is not logged. A WAL beside the file means the snapshot is still being written,
/// so the open is not immutable.
enum CursorDatabase {
    static func tokenData(at url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let immutable = !FileManager.default.fileExists(atPath: url.path + "-wal")
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        var uri = "file:\(encoded)?mode=ro"
        if immutable { uri += "&immutable=1" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [uri, "SELECT hex(value) FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, text.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
