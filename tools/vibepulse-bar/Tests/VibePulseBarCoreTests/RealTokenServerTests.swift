import XCTest
@testable import VibePulseBarCore

/// The supervisor against the real `tools/tokenserver/tokenserver.py`, in a
/// scratch HOME on a free port, so no credentials, state files or log of the
/// user's own service are read or touched.
///
/// Opt-in: `VPBAR_REAL_TOKENSERVER=1 swift test` (Python 3.11+ as
/// `VPBAR_PYTHON`, default `/opt/homebrew/bin/python3`).
@MainActor
final class RealTokenServerTests: XCTestCase {
    nonisolated(unsafe) private var home: URL!
    nonisolated(unsafe) private var python = ""
    nonisolated(unsafe) private var script = ""

    nonisolated override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["VPBAR_REAL_TOKENSERVER"] == "1", "set VPBAR_REAL_TOKENSERVER=1")
        self.python = environment["VPBAR_PYTHON"] ?? "/opt/homebrew/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: self.python), "no \(self.python)")
        let repository = try XCTUnwrap(
            ServiceConfiguration.findRepository(from: URL(fileURLWithPath: #filePath)))
        self.script = repository.appendingPathComponent("tools/tokenserver/tokenserver.py").path
        self.home = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpbar-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: self.home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
    }

    nonisolated override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private var logPath: String { self.home.appendingPathComponent("tokenserver.log").path }

    private func logText() -> String {
        (try? String(contentsOfFile: self.logPath, encoding: .utf8)) ?? ""
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    /// The app is SIGKILLed (a crash, Force Quit): the real server must still
    /// stop, through its own SIGINT cleanup, with nobody left to ask it.
    func testServerStopsCleanlyWhenTheAppIsKilled() async throws {
        let port = try SupervisorIntegrationTests.freePort()
        let guardURL = try ServiceGuard.install(in: self.home)
        let serverPidFile = self.home.appendingPathComponent("server.pid").path
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sh")
        app.arguments = ["-c", #""$0" -u "$1" "$2" --port "$3" >>"$4" 2>&1 & echo $! >"$5"; wait"#,
                         self.python, guardURL.path, self.script, String(port), self.logPath, serverPidFile]
        app.environment = ["HOME": self.home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        try app.run()
        let client = TokenServerClient(port: port)
        var up = false
        let deadline = Date().addingTimeInterval(60)
        while !up, Date() < deadline {
            up = (try? await client.diagnostics())?.isTokenServer == true
            if !up { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        XCTAssertTrue(up, self.logText())
        let server = try XCTUnwrap(Int32(String(contentsOfFile: serverPidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))

        kill(app.processIdentifier, SIGKILL)
        let gone = await self.waitUntil(15) { !SupervisorIntegrationTests.isRunning(server) }
        XCTAssertTrue(gone, self.logText())
        let log = self.logText()
        XCTAssertTrue(log.contains("app pid \(app.processIdentifier) is gone; stopping tokenserver pid \(server)"), log)
        XCTAssertFalse(log.contains("SIGKILL"), "the graceful path was enough:\n\(log)")
        XCTAssertFalse(log.contains("Traceback"), log)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: self.home.appendingPathComponent("Library/Application Support/VibePulse/max-tracker.json").path),
            "the server's finally block ran its final flush")
    }

    func testStartServeStopRestartQuit() async throws {
        // The app ignores SIGINT/SIGTERM so its dispatch sources can take
        // them, and an ignored disposition survives exec into the child.
        let previous = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previous) }
        let port = try SupervisorIntegrationTests.freePort()
        let configuration = ServiceConfiguration(
            pythonPath: self.python, scriptPath: self.script,
            arguments: ["--port", String(port)],
            environment: ["HOME": self.home.path], logPath: self.logPath)
        var timing = ServiceSupervisor.Timing()
        timing.startingPoll = 0.25
        timing.runningPoll = 1
        var dependencies = ServiceSupervisor.Dependencies.live
        dependencies.launchAgentStatus = { .absent }
        dependencies.ownershipURL = self.home.appendingPathComponent("owner.json")
        let supervisor = ServiceSupervisor(configuration: configuration, timing: timing,
                                           dependencies: dependencies)

        await supervisor.bootstrap(startService: true)
        var running = await self.waitUntil(60) { supervisor.phase == .running }
        XCTAssertTrue(running, "phase \(supervisor.phase); log:\n\(self.logText())")
        XCTAssertEqual(supervisor.diagnostics?.isTokenServer, true)
        XCTAssertNotNil(supervisor.diagnostics?.rev)
        let firstPid = try XCTUnwrap(supervisor.pid)

        let client = supervisor.client
        let tokens = try await client.tokens()
        XCTAssertNil(tokens.claudeWeek.usedPercent, "no credentials in a fresh HOME: a dash, never 0")
        XCTAssertNil(tokens.codexWeek.usedPercent)
        let agents = try await client.agentStatus()
        XCTAssertEqual(agents.totalActive, 0)

        let pauseStarted = Date()
        await supervisor.stop()
        XCTAssertEqual(supervisor.phase, .idle)
        XCTAssertFalse(ProcessInspector.isAlive(firstPid), "pause leaves no process behind")
        XCTAssertEqual(supervisor.lastExit?.expected, true)
        XCTAssertEqual(supervisor.lastExit?.status, 0, "SIGINT ends the server with its own clean exit")
        XCTAssertLessThan(Date().timeIntervalSince(pauseStarted), 10, "SIGINT alone was enough")

        await supervisor.start()
        running = await self.waitUntil(60) { supervisor.phase == .running }
        XCTAssertTrue(running, "second start; log:\n\(self.logText())")
        let secondPid = try XCTUnwrap(supervisor.pid)
        XCTAssertNotEqual(firstPid, secondPid)

        await supervisor.shutdown()
        XCTAssertFalse(ProcessInspector.isAlive(secondPid), "quit stops the server the app started")
        XCTAssertFalse(supervisor.ownsProcess)

        let log = self.logText()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: self.home.appendingPathComponent("Library/Application Support/VibePulse/max-tracker.json").path),
            "the server's finally block ran its final flush")
        XCTAssertEqual(log.components(separatedBy: "serving http://").count - 1, 2, log)
        XCTAssertFalse(log.contains("Traceback"), log)
        XCTAssertFalse(log.contains("ignored SIGINT"), "never escalated to SIGTERM:\n\(log)")
        XCTAssertEqual(log.components(separatedBy: "exited cleanly").count - 1, 2, log)
    }
}
