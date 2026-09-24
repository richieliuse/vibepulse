import Darwin
import XCTest
@testable import VibePulseBarCore

/// Drives the real supervisor against a small Python stand-in that answers
/// `GET /` like the tokenserver and, like it, cleans up only on SIGINT.
@MainActor
final class SupervisorIntegrationTests: XCTestCase {
    nonisolated static let fakeServer = #"""
    import http.server, json, os, signal, subprocess, sys, time

    port = int(sys.argv[sys.argv.index("--port") + 1])
    mode = os.environ.get("FAKE_MODE", "")
    if os.environ.get("HELPER_PID_FILE"):
        # Like the codex app-server probe, but never cleaned up by the server.
        helper = subprocess.Popen(["/bin/sleep", "300"])
        with open(os.environ["HELPER_PID_FILE"], "w") as f:
            f.write(str(helper.pid))
    if mode == "crash":
        print("fake crash: boom", file=sys.stderr)
        sys.exit(3)
    if mode == "hard-crash":
        time.sleep(0.3)
        os._exit(3)
    if mode == "stubborn":
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({"service": "torget-tokenserver", "rev": "fake"}).encode()
            self.send_response(200 if self.path == "/" else 404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    print(f"serving http://127.0.0.1:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        if mode == "slow-cleanup":
            time.sleep(1)
        print("fake: SIGINT cleanup ran")
    finally:
        server.server_close()
    """#

    nonisolated(unsafe) private var directory: URL!
    nonisolated(unsafe) private var port = 0

    nonisolated override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs python3")
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpbar-sup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try Self.fakeServer.write(to: self.scriptURL, atomically: true, encoding: .utf8)
        self.port = try Self.freePort()
    }

    nonisolated override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    nonisolated private var scriptURL: URL { self.directory.appendingPathComponent("tokenserver.py") }
    nonisolated private var logPath: String { self.directory.appendingPathComponent("service.log").path }

    nonisolated private var helperPidFile: String { self.directory.appendingPathComponent("helper.pid").path }
    nonisolated private var ownershipURL: URL { self.directory.appendingPathComponent("owner.json") }

    private func makeSupervisor(environment: [String: String] = [:],
                                adjust: (inout ServiceSupervisor.Timing) -> Void = { _ in }) -> ServiceSupervisor {
        let configuration = ServiceConfiguration(
            pythonPath: "/usr/bin/python3", scriptPath: self.scriptURL.path,
            arguments: ["--port", String(self.port)], environment: environment, logPath: self.logPath)
        var timing = ServiceSupervisor.Timing()
        timing.startingPoll = 0.2
        timing.runningPoll = 0.5
        timing.idlePoll = 0.5
        timing.gracefulStop = 5
        timing.restart = RestartPolicy(initialDelay: 0.3, maximumDelay: 1, stableRuntime: 60)
        adjust(&timing)
        var dependencies = ServiceSupervisor.Dependencies.live
        dependencies.launchAgentStatus = { .absent }
        dependencies.ownershipURL = self.ownershipURL
        return ServiceSupervisor(configuration: configuration, timing: timing, dependencies: dependencies)
    }

    private func helperPid() async -> Int32? {
        _ = await self.waitUntil(5) { FileManager.default.fileExists(atPath: self.helperPidFile) }
        return (try? String(contentsOfFile: self.helperPidFile, encoding: .utf8)).flatMap { Int32($0) }
    }

    /// Alive and not a zombie waiting for its parent to reap it.
    nonisolated static func isRunning(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func logText() -> String {
        (try? String(contentsOfFile: self.logPath, encoding: .utf8)) ?? ""
    }

    func testStartServePauseLifecycle() async throws {
        let supervisor = self.makeSupervisor()
        await supervisor.bootstrap(startService: true)
        let running = await self.waitUntil { supervisor.phase == .running }
        XCTAssertTrue(running, "phase stuck at \(supervisor.phase); log:\n\(self.logText())")
        XCTAssertTrue(supervisor.ownsProcess)
        XCTAssertTrue(supervisor.isServing)
        XCTAssertEqual(supervisor.diagnostics?.rev, "fake")
        let pid = try XCTUnwrap(supervisor.pid)
        XCTAssertNotNil(OwnershipRecord.load(from: self.directory.appendingPathComponent("owner.json")))

        await supervisor.stop()
        XCTAssertEqual(supervisor.phase, .idle)
        XCTAssertFalse(ProcessInspector.isAlive(pid))
        XCTAssertEqual(supervisor.lastExit?.expected, true)
        XCTAssertNil(OwnershipRecord.load(from: self.directory.appendingPathComponent("owner.json")))
        let log = self.logText()
        XCTAssertTrue(log.contains("serving http://127.0.0.1:\(self.port)"), "child output reaches the log")
        XCTAssertTrue(log.contains("fake: SIGINT cleanup ran"), "pause must take the SIGINT path")
        XCTAssertTrue(log.contains("vibepulse-bar: stopping tokenserver pid \(pid) (paused): SIGINT"))
        await supervisor.shutdown()
    }

    func testCrashIsReportedAndRestartedWithBackoff() async throws {
        let supervisor = self.makeSupervisor(environment: ["FAKE_MODE": "crash"])
        await supervisor.bootstrap(startService: true)
        let crashed = await self.waitUntil { supervisor.phase == .crashed && supervisor.nextRestartAt != nil }
        XCTAssertTrue(crashed, "phase \(supervisor.phase); log:\n\(self.logText())")
        let exit = try XCTUnwrap(supervisor.lastExit)
        XCTAssertEqual(exit.status, 3)
        XCTAssertFalse(exit.expected)
        XCTAssertEqual(exit.lastLines, ["fake crash: boom"], "the excerpt is the server's own last words")

        let retried = await self.waitUntil { supervisor.restartAttempt >= 2 }
        XCTAssertTrue(retried, "the crash loop keeps retrying, slower each time")

        await supervisor.stop()
        XCTAssertEqual(supervisor.phase, .idle)
        XCTAssertNil(supervisor.nextRestartAt, "pause cancels the pending restart")
        let attempts = supervisor.restartAttempt
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(supervisor.restartAttempt, attempts)
        XCTAssertEqual(supervisor.phase, .idle)
        await supervisor.shutdown()
    }

    func testExternalInstanceIsObservedThenTakenOver() async throws {
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        external.arguments = ["-u", self.scriptURL.path, "--port", String(self.port)]
        external.standardOutput = FileHandle.nullDevice
        external.standardError = FileHandle.nullDevice
        try external.run()
        defer { if external.isRunning { external.terminate() } }
        let client = TokenServerClient(port: self.port)
        var up = false
        for _ in 0..<100 where !up {
            up = (try? await client.diagnostics()) != nil
            if !up { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(up)

        let supervisor = self.makeSupervisor()
        await supervisor.bootstrap(startService: true)
        XCTAssertEqual(supervisor.phase, .external)
        XCTAssertFalse(supervisor.ownsProcess)
        XCTAssertEqual(supervisor.foreign?.pid, external.processIdentifier)
        XCTAssertEqual(supervisor.foreign?.looksLikeTokenServer, true)
        let serving = await self.waitUntil { supervisor.isServing }
        XCTAssertTrue(serving, "an external server still feeds the menu")

        await supervisor.takeOverExternal()
        XCTAssertFalse(external.isRunning, "take over stops the foreign server first")
        let running = await self.waitUntil { supervisor.phase == .running }
        XCTAssertTrue(running, "phase \(supervisor.phase); log:\n\(self.logText())")
        XCTAssertTrue(supervisor.ownsProcess)

        await supervisor.shutdown()
        XCTAssertFalse(supervisor.ownsProcess)
    }

    func testQuitLeavesForeignServerRunning() async throws {
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        external.arguments = ["-u", self.scriptURL.path, "--port", String(self.port)]
        external.standardOutput = FileHandle.nullDevice
        try external.run()
        defer { external.terminate() }
        let client = TokenServerClient(port: self.port)
        for _ in 0..<100 {
            if (try? await client.diagnostics()) != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let supervisor = self.makeSupervisor()
        await supervisor.bootstrap(startService: true)
        XCTAssertEqual(supervisor.phase, .external)
        await supervisor.shutdown()
        XCTAssertTrue(external.isRunning, "quit never stops a process this app did not start")
    }

    // MARK: - Nothing outlives the app

    func testServerStopsItselfWhenTheAppDies() async throws {
        let guardURL = try ServiceGuard.install(in: self.directory)
        let serverPidFile = self.directory.appendingPathComponent("server.pid").path
        // A stand-in app that dies without any chance to clean up.
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sh")
        app.arguments = ["-c", #"/usr/bin/python3 -u "$0" "$1" --port "$2" >>"$3" 2>&1 & echo $! >"$4"; wait"#,
                         guardURL.path, self.scriptURL.path, String(self.port), self.logPath, serverPidFile]
        app.environment = ["PATH": "/usr/bin:/bin", "HELPER_PID_FILE": self.helperPidFile]
        try app.run()
        let client = TokenServerClient(port: self.port)
        var up = false
        for _ in 0..<100 where !up {
            up = (try? await client.diagnostics()) != nil
            if !up { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(up, self.logText())
        let server = try XCTUnwrap(Int32(String(contentsOfFile: serverPidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let recorded = await self.helperPid()
        let helper = try XCTUnwrap(recorded)

        kill(app.processIdentifier, SIGKILL)
        let gone = await self.waitUntil(8) { !Self.isRunning(server) && !Self.isRunning(helper) }
        XCTAssertTrue(gone, "server \(Self.isRunning(server)), helper \(Self.isRunning(helper)):\n\(self.logText())")
        let log = self.logText()
        XCTAssertTrue(log.contains("vibepulse-bar: app pid \(app.processIdentifier) is gone"), log)
        XCTAssertTrue(log.contains("fake: SIGINT cleanup ran"), "the orphan still takes the graceful path")
    }

    func testPauseTakesTheServersHelpersDown() async throws {
        let supervisor = self.makeSupervisor(environment: ["HELPER_PID_FILE": self.helperPidFile])
        await supervisor.bootstrap(startService: true)
        let running = await self.waitUntil { supervisor.phase == .running }
        XCTAssertTrue(running, self.logText())
        let recorded = await self.helperPid()
        let helper = try XCTUnwrap(recorded)
        await supervisor.stop()
        let gone = await self.waitUntil(3) { !Self.isRunning(helper) }
        XCTAssertTrue(gone, "a helper the server never cleaned up outlived the pause")
        XCTAssertEqual(supervisor.lastExit?.status, 0)
    }

    func testStubbornServerIsKilledTogetherWithItsHelpers() async throws {
        let supervisor = self.makeSupervisor(
            environment: ["FAKE_MODE": "stubborn", "HELPER_PID_FILE": self.helperPidFile]) {
                $0.gracefulStop = 0.5
                $0.terminateStop = 0.5
            }
        await supervisor.bootstrap(startService: true)
        let running = await self.waitUntil { supervisor.phase == .running }
        XCTAssertTrue(running, self.logText())
        let pid = try XCTUnwrap(supervisor.pid)
        let recorded = await self.helperPid()
        let helper = try XCTUnwrap(recorded)

        await supervisor.stop()
        XCTAssertFalse(Self.isRunning(pid))
        XCTAssertFalse(Self.isRunning(helper), "SIGKILL goes to the whole group")
        XCTAssertEqual(supervisor.lastExit?.bySignal, true)
        XCTAssertTrue(self.logText().contains("pid \(pid) ignored SIGTERM: SIGKILL"))
    }

    func testHardCrashTakesItsHelpersDown() async throws {
        let supervisor = self.makeSupervisor(
            environment: ["FAKE_MODE": "hard-crash", "HELPER_PID_FILE": self.helperPidFile]) {
                $0.restart = RestartPolicy(initialDelay: 60, maximumDelay: 60, stableRuntime: 60)
            }
        await supervisor.bootstrap(startService: true)
        let recorded = await self.helperPid()
        let helper = try XCTUnwrap(recorded)
        let crashed = await self.waitUntil { supervisor.phase == .crashed }
        XCTAssertTrue(crashed, self.logText())
        let gone = await self.waitUntil(3) { !Self.isRunning(helper) }
        XCTAssertTrue(gone, "os._exit skipped every cleanup; the supervisor still clears the group")
        let noted = await self.waitUntil(2) { self.logText().contains("cleared helpers left in pid") }
        XCTAssertTrue(noted, self.logText())
        await supervisor.shutdown()
    }

    func testQuitDuringPauseJoinsItInsteadOfInterruptingTheCleanup() async throws {
        let supervisor = self.makeSupervisor(environment: ["FAKE_MODE": "slow-cleanup"])
        await supervisor.bootstrap(startService: true)
        let running = await self.waitUntil { supervisor.phase == .running }
        XCTAssertTrue(running, self.logText())

        let pause = Task { await supervisor.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await supervisor.shutdown()
        await pause.value
        let log = self.logText()
        XCTAssertEqual(log.components(separatedBy: "): SIGINT").count - 1, 1, log)
        XCTAssertTrue(log.contains("fake: SIGINT cleanup ran"), log)
        XCTAssertEqual(supervisor.lastExit?.status, 0)
    }

    func testTheLauncherStaysInTheProcess() async throws {
        let supervisor = self.makeSupervisor()
        await supervisor.bootstrap(startService: true)
        let running = await self.waitUntil { supervisor.phase == .running }
        XCTAssertTrue(running, self.logText())
        let pid = try XCTUnwrap(supervisor.pid)
        let command = await ProcessInspector.describe(pid)?.command ?? ""
        XCTAssertTrue(command.contains(ServiceGuard.fileName), command)
        XCTAssertEqual(getpgid(pid), pid, "the server leads its own process group")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(supervisor.lastError)
        await supervisor.shutdown()
    }

    func testAWrapperThatExecsIsCalledOut() async throws {
        let wrapper = self.directory.appendingPathComponent("exec-wrapper.py")
        try """
        import os, sys
        os.execv(sys.executable, [sys.executable, "-u", \(String(reflecting: self.scriptURL.path)), *sys.argv[1:]])
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        let configuration = ServiceConfiguration(
            pythonPath: "/usr/bin/python3", scriptPath: wrapper.path,
            arguments: ["--port", String(self.port)], logPath: self.logPath)
        let supervisor = self.makeSupervisor()
        supervisor.configuration = configuration
        await supervisor.bootstrap(startService: true)
        let warned = await self.waitUntil { supervisor.lastError?.contains("(exec)") == true }
        XCTAssertTrue(warned, "lastError \(supervisor.lastError ?? "nil"); log:\n\(self.logText())")
        XCTAssertTrue(self.logText().contains("would outlive an app crash"))
        await supervisor.shutdown()
    }

    func testLeftoverFromACrashedAppIsStoppedAndReplaced() async throws {
        let leftover = Process()
        leftover.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        leftover.arguments = ["-u", self.scriptURL.path, "--port", String(self.port)]
        leftover.standardOutput = FileHandle.nullDevice
        try leftover.run()
        defer { if leftover.isRunning { leftover.terminate() } }
        let client = TokenServerClient(port: self.port)
        for _ in 0..<100 {
            if (try? await client.diagnostics()) != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let started = try XCTUnwrap(ProcessInspector.startTime(of: leftover.processIdentifier))
        OwnershipRecord(pid: leftover.processIdentifier, startTime: started, port: self.port)
            .save(to: self.ownershipURL)

        let supervisor = self.makeSupervisor()
        await supervisor.bootstrap(startService: false)
        XCTAssertFalse(leftover.isRunning, "a leftover this app started is stopped, not trusted")
        let running = await self.waitUntil { supervisor.phase == .running }
        XCTAssertTrue(running, self.logText())
        XCTAssertTrue(supervisor.ownsProcess, "it was running, so a fresh child replaces it")
        XCTAssertNotEqual(supervisor.pid, leftover.processIdentifier)
        XCTAssertTrue(self.logText().contains("outlived the previous run of the app; stopping it: SIGINT"))
        await supervisor.shutdown()
    }

    nonisolated static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
