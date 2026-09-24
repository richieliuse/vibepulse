import Darwin
import Foundation
import XCTest
import VibePulseProviders
import VibePulseState
@testable import VibePulseServer

/// Opt-in comparison of `tokenserver.py` and `VibePulseEngine` on two copies of one fixture HOME.
/// A normal `swift test` skips this and does not start Python. It never binds port 8737 and never
/// signals the live tokenserver (pid 36670).
final class ParityTests: XCTestCase {
    private let livePID: Int32 = 36670
    private let livePort = 8737

    func testOptInHomeParity() throws {
        guard ProcessInfo.processInfo.environment["VPBAR_PARITY"] == "1" else {
            throw XCTSkip("VPBAR_PARITY is not 1, so this test does not start Python")
        }
        let root = repositoryRoot()
        let script = root.appendingPathComponent("tools/tokenserver/tokenserver.py")
        let prices = root.appendingPathComponent("tools/tokenserver/prices.json")
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            XCTFail("tokenserver.py is not in this checkout")
            return
        }
        guard let python = pythonExecutable() else {
            throw XCTSkip("local python cannot import the tokenserver dependencies (no python3 interpreter found)")
        }
        let importFailure = try pythonImportFailure(python, scriptDirectory: script.deletingLastPathComponent())
        if let importFailure {
            throw XCTSkip("local python cannot import the tokenserver dependencies: \(importFailure)")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpbar-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let started = Started()
        defer {
            started.engine?.stop()
            stopPython(started.python)
            try? FileManager.default.removeItem(at: work)
        }

        let fixture = work.appendingPathComponent("fixture", isDirectory: true)
        try makeFixtureHome(fixture)
        let pythonHome = work.appendingPathComponent("python-home", isDirectory: true)
        let swiftHome = work.appendingPathComponent("swift-home", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: pythonHome)
        try FileManager.default.copyItem(at: fixture, to: swiftHome)

        let blocker = work.appendingPathComponent("py-path", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try "raise ImportError('parity test keeps mDNS off')\n"
            .write(to: blocker.appendingPathComponent("zeroconf.py"), atomically: true, encoding: .utf8)
        let stubs = work.appendingPathComponent("stubs", isDirectory: true)
        try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        try writeExecutable(stubs.appendingPathComponent("security"), "#!/bin/sh\nexit 44\n")
        try writeExecutable(stubs.appendingPathComponent("pgrep"), "#!/bin/sh\nexit 1\n")
        try writeExecutable(stubs.appendingPathComponent("codex"), "#!/bin/sh\nexit 0\n")
        if try pythonCanImportZeroconf(python, blocker: blocker) {
            XCTFail("refusing to start tokenserver.py because zeroconf still imports; that would advertise mDNS")
            return
        }

        let pythonPort = try ephemeralPort()
        let enginePort = try ephemeralPort(avoiding: pythonPort)
        XCTAssertNotEqual(pythonPort, livePort)
        XCTAssertNotEqual(enginePort, livePort)
        XCTAssertNotEqual(pythonPort, enginePort)

        let stderrURL = work.appendingPathComponent("python-stderr.txt")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        let pythonProcess = Process()
        pythonProcess.executableURL = URL(fileURLWithPath: python)
        pythonProcess.arguments = [
            script.path, "--port", String(pythonPort),
            "--dir", pythonHome.appendingPathComponent(".claude/projects").path,
        ]
        pythonProcess.currentDirectoryURL = script.deletingLastPathComponent()
        pythonProcess.environment = pythonEnvironment(home: pythonHome, stubs: stubs, blocker: blocker)
        pythonProcess.standardInput = FileHandle.nullDevice
        pythonProcess.standardOutput = FileHandle.nullDevice
        pythonProcess.standardError = stderr
        started.python = pythonProcess
        try pythonProcess.run()
        if pythonProcess.processIdentifier == livePID {
            XCTFail("spawned python reused the live tokenserver pid; leaving it untouched")
            return
        }

        let engine = try makeEngine(port: enginePort, home: swiftHome, prices: prices)
        started.engine = engine
        guard case let .started(bound) = engine.start() else {
            XCTFail("VibePulseEngine did not bind an ephemeral port")
            return
        }
        if bound == livePort || bound == pythonPort {
            engine.stop()
            started.engine = nil
            XCTFail("engine bound \(bound); parity refuses the live port and the python port")
            return
        }

        let paths = ["/api/tokens", "/api/agent-status", "/api/max-tracker", "/api/github", "/"]
        try waitUntilSettled(pythonPort: pythonPort, enginePort: bound, python: pythonProcess, stderr: stderrURL)
        var mismatches: [String] = []
        for path in paths {
            let pythonBody = try get(port: pythonPort, path: path)
            let swiftBody = try get(port: bound, path: path)
            if pythonBody.status != swiftBody.status {
                mismatches.append("\(path) status python \(pythonBody.status) swift \(swiftBody.status)")
                continue
            }
            let left = normalize(node(from: pythonBody.json))
            let right = normalize(node(from: swiftBody.json))
            let found = differences(path, left, right)
            if !found.isEmpty { mismatches.append(contentsOf: found.prefix(12)) }
        }
        if !mismatches.isEmpty {
            XCTFail(mismatches.prefix(40).joined(separator: "\n"))
        }
    }

    private func makeEngine(port: Int, home: URL, prices: URL) throws -> VibePulseEngine {
        var environment = EngineEnvironment()
        environment.stateDirectory = home.appendingPathComponent("Library/Application Support/VibePulse", isDirectory: true)
        environment.projectsDirectory = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        environment.codexSessions = codex.appendingPathComponent("sessions", isDirectory: true)
        environment.codexAuthPath = codex.appendingPathComponent("auth.json")
        environment.claudePlanUsageURL = home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        environment.claudeCandidates = { [] }
        environment.keychainReason = "keychain_no_entry"
        environment.priceTable = try PriceTable.load(from: prices)
        environment.codexAppServer = { _ in CodexQuota() }
        environment.automaticWorkers = true
        environment.trapSignals = false
        environment.discoveryRegistrar = nil
        let grokAuth = home.appendingPathComponent(".grok/auth.json")
        let offline = OfflineTransport()
        environment.grokFetch = { wall in
            let auth = GrokBilling.loadAuth(path: grokAuth, now: wall)
            return SubscriptionFetch.grok(auth: auth, now: wall, transport: offline)
        }
        environment.cursorFetch = { _ in
            SubscriptionSample(auth: "missing", summary: "skipped", sand: "skipped")
        }
        return VibePulseEngine(port: port, environment: environment)
    }

    private func waitUntilSettled(pythonPort: Int, enginePort: Int, python: Process, stderr: URL) throws {
        let deadline = Date().addingTimeInterval(12)
        var lastPython = ""
        var lastSwift = ""
        while Date() < deadline {
            if !python.isRunning {
                throw ParityError("tokenserver.py exited \(python.terminationStatus): \(tail(stderr))")
            }
            if let pythonRoot = try? get(port: pythonPort, path: "/"),
               let swiftRoot = try? get(port: enginePort, path: "/"),
               let pythonTokens = try? get(port: pythonPort, path: "/api/tokens"),
               let swiftTokens = try? get(port: enginePort, path: "/api/tokens") {
                lastPython = String(describing: pythonRoot.json)
                lastSwift = String(describing: swiftRoot.json)
                if discoveryReady(pythonRoot.json) {
                    stopPython(python)
                    throw ParityError("tokenserver.py advertised mDNS; stopped that process without touching pid \(livePID)")
                }
                if settled(pythonRoot.json, tokens: pythonTokens.json), settled(swiftRoot.json, tokens: swiftTokens.json) {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ParityError("servers did not settle on the fixture HOME\npython \(lastPython)\nswift \(lastSwift)\n\(tail(stderr))")
    }

    private func settled(_ root: Any, tokens: Any) -> Bool {
        guard let root = root as? [String: Any], let tokens = tokens as? [String: Any] else { return false }
        guard (root["claudeProbe"] as? String)?.hasPrefix("no_claude_oauth_token") == true else { return false }
        guard (root["codexProbe"] as? String)?.contains("cli_empty") == true else { return false }
        guard root["grokProbe"] as? String == "no_grok_oauth_token" else { return false }
        guard root["cursorProbe"] as? String == "no_cursor_session" else { return false }
        guard (root["discovery"] as? [String: Any])?["status"] as? String == "unavailable" else { return false }
        guard let totals = tokens["usageTotals"] as? [String: Any] else { return false }
        guard totals["state"] as? String == "ready" else { return false }
        guard totals["placeholder"] as? Bool == false else { return false }
        return true
    }

    private func discoveryReady(_ json: Any) -> Bool {
        ((json as? [String: Any])?["discovery"] as? [String: Any])?["status"] as? String == "ready"
    }

    private func get(port: Int, path: String) throws -> (status: Int, json: Any) {
        guard port != livePort else { throw ParityError("refusing live port \(livePort)") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 2)
        request.setValue("usage-totals", forHTTPHeaderField: "x-vibepulse-accepts")
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 4) == .success,
              let http = box.response as? HTTPURLResponse,
              let data = box.data else {
            throw box.error ?? ParityError("no response for \(path)")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        return (http.statusCode, json)
    }

    private func pythonEnvironment(home: URL, stubs: URL, blocker: URL) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var path = "\(stubs.path):/usr/bin:/bin:/usr/sbin:/sbin"
        if let brew = inherited["HOMEBREW_PREFIX"] ?? (FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git") ? "/opt/homebrew" : nil) {
            path += ":\(brew)/bin"
        }
        var env = [
            "HOME": home.path,
            "TMPDIR": inherited["TMPDIR"] ?? "/tmp",
            "LANG": "en_US.UTF-8",
            "PATH": path,
            "CODEX_HOME": home.appendingPathComponent(".codex").path,
            "GROK_HOME": home.appendingPathComponent(".grok").path,
            "PYTHONPATH": blocker.path,
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUNBUFFERED": "1",
        ]
        if let user = inherited["USER"] { env["USER"] = user }
        if let logname = inherited["LOGNAME"] { env["LOGNAME"] = logname }
        return env
    }

    private func stopPython(_ process: Process?) {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0, pid != livePID else { return }
        Darwin.kill(pid, SIGINT)
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning, process.processIdentifier != livePID {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func makeFixtureHome(_ root: URL) throws {
        let manager = FileManager.default
        for relative in [
            ".claude/projects",
            ".codex/sessions",
            ".grok",
            "Library/Application Support/VibePulse",
        ] {
            try manager.createDirectory(at: root.appendingPathComponent(relative, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    private func pythonExecutable() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["VPBAR_PYTHON"],
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func pythonImportFailure(_ python: String, scriptDirectory: URL) throws -> String? {
        let result = try run(python, ["-c", "import tokenserver"], directory: scriptDirectory, environment: [
            "HOME": FileManager.default.temporaryDirectory.path,
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
        ])
        if result.status == 0 { return nil }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "import tokenserver failed" : text
    }

    private func pythonCanImportZeroconf(_ python: String, blocker: URL) throws -> Bool {
        let result = try run(python, ["-c", "import zeroconf"], directory: blocker, environment: [
            "PYTHONPATH": blocker.path,
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PATH": "/usr/bin:/bin",
        ])
        return result.status == 0
    }

    private func run(_ executable: String, _ arguments: [String], directory: URL, environment: [String: String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        try process.run()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + 30) == .timedOut {
            if process.processIdentifier != livePID { Darwin.kill(process.processIdentifier, SIGKILL) }
            return (1, "timed out")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func ephemeralPort(avoiding other: Int = 0) throws -> Int {
        for _ in 0..<32 {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { continue }
            defer { Darwin.close(fd) }
            var reuse: Int32 = 1
            _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound != 0 { continue }
            var resolved = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &resolved) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fd, $0, &length)
                }
            }
            if named != 0 { continue }
            let port = Int(UInt16(bigEndian: resolved.sin_port))
            if port > 0, port != livePort, port != other { return port }
        }
        throw ParityError("no ephemeral port")
    }

    private func writeExecutable(_ url: URL, _ body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func tail(_ url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if text.count <= 1500 { return text }
        return String(text.suffix(1500))
    }

    private func normalize(_ node: JSONNode) -> JSONNode {
        switch node {
        case .array(let items):
            return .array(items.map(normalize))
        case .object(let pairs):
            return .object(pairs.map { key, value in
                (key, normalizeField(key, value))
            })
        default:
            return normalizeField(nil, node)
        }
    }

    /// pid, build identity (`rev` and its companion `srcFingerprint`), timestamps, and
    /// elapsed clocks. A null stays null, so a missing timestamp still fails the comparison.
    private func normalizeField(_ key: String?, _ value: JSONNode) -> JSONNode {
        if key == "pid" { return .string("<pid>") }
        if key == "rev" || key == "srcFingerprint" { return .string("<build>") }
        if let key, isTimestamp(key), !isNull(value) { return .string("<timestamp>") }
        if let key, isElapsed(key), !isNull(value) { return .string("<elapsed>") }
        if case let .string(text) = value, isISOTimestamp(text) { return .string("<timestamp>") }
        switch value {
        case .array, .object:
            return normalize(value)
        default:
            return value
        }
    }

    private func isTimestamp(_ key: String) -> Bool {
        key == "at" || key == "startedAt" || key.hasSuffix("At")
    }

    private func isElapsed(_ key: String) -> Bool {
        key == "ageS" || key == "sinceS" || key.hasSuffix("AgeS")
            || key.hasSuffix("CooldownLeftS") || key.hasSuffix("FailingForS")
    }

    private func isISOTimestamp(_ text: String) -> Bool {
        text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil
    }

    private func node(from value: Any) -> JSONNode {
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let text = value as? String { return .string(text) }
        if let list = value as? [Any] { return .array(list.map(node(from:))) }
        if let object = value as? [String: Any] {
            return .object(object.keys.sorted().map { ($0, node(from: object[$0] as Any)) })
        }
        return .string(String(describing: value))
    }

    private func differences(_ path: String, _ left: JSONNode, _ right: JSONNode, limit: Int = 12) -> [String] {
        var found: [String] = []
        walk(path, left, right, into: &found, limit: limit)
        return found
    }

    private func walk(_ path: String, _ left: JSONNode, _ right: JSONNode, into found: inout [String], limit: Int) {
        if found.count >= limit { return }
        switch (left, right) {
        case (.null, .null):
            break
        case let (.bool(lhs), .bool(rhs)):
            if lhs != rhs { found.append("\(path): python \(render(left)) swift \(render(right))") }
        case let (.number(lhs), .number(rhs)):
            if lhs != rhs, abs(lhs - rhs) > 1e-9 * max(1, abs(lhs), abs(rhs)) {
                found.append("\(path): python \(render(left)) swift \(render(right))")
            }
        case let (.string(lhs), .string(rhs)):
            if lhs != rhs { found.append("\(path): python \(render(left)) swift \(render(right))") }
        case let (.array(lhs), .array(rhs)):
            if lhs.count != rhs.count {
                found.append("\(path): python count \(lhs.count) swift count \(rhs.count)")
                return
            }
            for (index, pair) in zip(lhs, rhs).enumerated() {
                walk("\(path)[\(index)]", pair.0, pair.1, into: &found, limit: limit)
            }
        case let (.object(lhs), .object(rhs)):
            let leftKeys = lhs.map(\.0)
            let rightKeys = rhs.map(\.0)
            if leftKeys != rightKeys {
                let missing = Set(leftKeys).subtracting(rightKeys).sorted()
                let extra = Set(rightKeys).subtracting(leftKeys).sorted()
                if !missing.isEmpty { found.append("\(path): swift missing \(missing.joined(separator: ", "))") }
                if !extra.isEmpty { found.append("\(path): swift extra \(extra.joined(separator: ", "))") }
            }
            let rightMap = Dictionary(uniqueKeysWithValues: rhs)
            for (key, value) in lhs {
                guard let other = rightMap[key] else { continue }
                walk("\(path).\(key)", value, other, into: &found, limit: limit)
            }
        default:
            found.append("\(path): python \(render(left)) swift \(render(right))")
        }
    }

    private func render(_ node: JSONNode) -> String {
        switch node {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        case .string(let value): return "\"\(value)\""
        case .array(let items): return "[\(items.count)]"
        case .object(let pairs): return "{\(pairs.count)}"
        }
    }
}

private final class Started {
    var engine: VibePulseEngine?
    var python: Process?
}

private final class ResponseBox: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}

private struct OfflineTransport: QuotaHTTPTransport, Sendable {
    func send(_ request: QuotaHTTPRequest) throws -> QuotaHTTPResponse {
        throw ParityError("offline transport refused \(request.url)")
    }
}

private struct ParityError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private enum JSONNode {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONNode])
    case object([(String, JSONNode)])
}

private func isNull(_ node: JSONNode) -> Bool {
    if case .null = node { return true }
    return false
}
