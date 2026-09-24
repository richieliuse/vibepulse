import Darwin
import XCTest
import VibePulseServer
@testable import VibePulseBarCore

@MainActor
final class EngineSessionTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!

    nonisolated override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpbar-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    nonisolated override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    func testMenuReadsTheEngineSnapshotInMemory() async {
        let engine = FakeEngine()
        engine.snapshot = [
            "v": 2,
            "dayTokens": 12,
            "claudeSessionPct": 41.0,
            "claudeSessionResetMin": 9,
            "usageTotals": ["state": "ready", "placeholder": false, "ageS": 3],
        ]
        engine.agentStatus = [
            "v": 2,
            "seq": 4,
            "agents": [
                "claude": ["active_count": 1, "jobs": [[
                    "task_id": "task-1",
                    "state": "working",
                ]]],
                "codex": ["active_count": 0, "jobs": []],
            ],
        ]
        let session = self.session(engine: engine)
        await session.bootstrap(startService: true)
        XCTAssertEqual(session.phase, .running)
        let tokens = MenuReading.tokens(engine.snapshot)
        XCTAssertEqual(tokens?.dayTokens, 12)
        XCTAssertEqual(tokens?.claudeSession.usedPercent, 41)
        XCTAssertEqual(tokens?.usageTotals?.placeholder, false)
        let agents = MenuReading.agents(engine.agentStatus)
        XCTAssertEqual(agents?.claude.activeCount, 1)
        XCTAssertEqual(agents?.claude.jobs.first?.taskID, "task-1")
        XCTAssertTrue(session.serviceSnapshot.isServing)

        engine.snapshot["claudeSessionPct"] = 55.0
        XCTAssertEqual(MenuReading.tokens(engine.snapshot)?.claudeSession.usedPercent, 55)
    }

    func testBusyPortShowsTheOwnerAndDoesNotStart() async {
        let engine = FakeEngine()
        engine.results = [.portBusy(pid: 4242, command: "python tokenserver.py")]
        let signals = FakeSignals()
        let session = self.session(engine: engine, signals: signals)
        await session.bootstrap(startService: true)

        XCTAssertEqual(session.phase, .external)
        XCTAssertEqual(session.serviceSnapshot.foreign?.pid, 4242)
        XCTAssertEqual(session.serviceSnapshot.foreign?.command, "python tokenserver.py")
        XCTAssertTrue(session.serviceSnapshot.detail(now: Date()).contains("4242"))
        XCTAssertFalse(session.ownsEngine)
        XCTAssertFalse(session.isServing)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertEqual(signals.sent, [])
    }

    func testTakeOverOfAForeignPidSignalsThenStarts() async {
        let engine = FakeEngine()
        engine.results = [
            .portBusy(pid: 4242, command: "tokenserver.py"),
            .started(port: 9),
        ]
        let signals = FakeSignals()
        signals.alive = [4242]
        let order = OrderLog()
        engine.events = order
        signals.events = order
        let session = self.session(engine: engine, signals: signals, signalTimeout: 1)
        await session.bootstrap(startService: true)
        await session.takeOverExternal()

        XCTAssertEqual(signals.sent, [SignalRecord(signal: SIGINT, pid: 4242)])
        XCTAssertFalse(signals.sent.contains { $0.pid == 36_670 })
        XCTAssertEqual(order.events, ["start", "signal", "start"])
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(session.serviceSnapshot.port, 9)
        XCTAssertTrue(session.ownsEngine)
        XCTAssertNotEqual(session.serviceSnapshot.port, 8737)
    }

    func testTakeOverWaitsAndStillStartsWhenThePidStaysUp() async {
        let engine = FakeEngine()
        engine.results = [
            .portBusy(pid: 4242, command: "tokenserver"),
            .portBusy(pid: 4242, command: "tokenserver"),
        ]
        let signals = FakeSignals()
        signals.alive = [4242]
        signals.dieOnSignal = false
        let session = self.session(engine: engine, signals: signals, signalTimeout: 0.05, signalPoll: 0.02)
        await session.bootstrap(startService: true)
        await session.takeOverExternal()

        XCTAssertEqual(signals.sent, [SignalRecord(signal: SIGINT, pid: 4242)])
        XCTAssertEqual(engine.startCount, 2)
        XCTAssertEqual(session.phase, .external)
        XCTAssertEqual(session.lastError, "pid 4242 did not exit")
        XCTAssertEqual(session.foreign?.pid, 4242)
    }

    func testAForeignProcessThatIsNotATokenserverIsLeftAlone() async {
        let engine = FakeEngine()
        engine.results = [.portBusy(pid: 4242, command: "nginx")]
        let signals = FakeSignals()
        let session = self.session(engine: engine, signals: signals)
        await session.bootstrap(startService: true)
        await session.takeOverExternal()
        XCTAssertEqual(signals.sent, [])
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(session.phase, .external)
    }

    func testTakeOverOfTheLaunchAgentDisablesBootsOutThenStarts() async {
        let engine = FakeEngine()
        let launch = FakeLaunch()
        launch.statusValue = LaunchAgentStatus(plistExists: true, loaded: true, pid: 4242, disabled: false)
        let order = OrderLog()
        engine.events = order
        launch.events = order
        let session = self.session(engine: engine, launch: launch)
        await session.bootstrap(startService: true)
        XCTAssertEqual(session.phase, .launchAgent)
        XCTAssertEqual(engine.startCount, 0)

        launch.statusValue.loaded = false
        launch.statusValue.disabled = true
        await session.takeOverLaunchAgent()
        XCTAssertEqual(order.events, ["disable", "bootout", "start"])
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(engine.stopCount, 0)
    }

    func testHandBackStopsThenEnablesAndBootstraps() async {
        let engine = FakeEngine()
        let launch = FakeLaunch()
        let order = OrderLog()
        engine.events = order
        launch.events = order
        let session = self.session(engine: engine, launch: launch)
        await session.bootstrap(startService: true)
        XCTAssertEqual(session.phase, .running)

        launch.statusValue = LaunchAgentStatus(plistExists: true, loaded: true, pid: 4242, disabled: false)
        await session.handBack()
        XCTAssertEqual(order.events, ["start", "stop", "enable", "bootstrap"])
        XCTAssertEqual(session.phase, .launchAgent)
        XCTAssertFalse(session.ownsEngine)
    }

    func testQuitStopsTheEngineAndDoesNotSignal() async {
        let engine = FakeEngine()
        let signals = FakeSignals()
        let session = self.session(engine: engine, signals: signals)
        await session.bootstrap(startService: true)
        await session.shutdown()
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(signals.sent, [])
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.ownsEngine)

        await session.shutdown()
        XCTAssertEqual(engine.stopCount, 2)
    }

    func testQuitLeavesAForeignListenerUntouched() async {
        let engine = FakeEngine()
        engine.results = [.portBusy(pid: 4242, command: "tokenserver")]
        let signals = FakeSignals()
        let session = self.session(engine: engine, signals: signals)
        await session.bootstrap(startService: true)
        await session.shutdown()
        XCTAssertEqual(signals.sent, [])
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(session.phase, .external)
        XCTAssertEqual(session.foreign?.pid, 4242)
    }

    func testInvalidPortDoesNotStart() async {
        let engine = FakeEngine()
        let session = self.session(engine: engine)
        session.configuration.port = 0
        await session.start()
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertEqual(session.serviceSnapshot.detail(now: Date()), "Port must be between 1 and 65535 (got 0).")
    }

    func testInProcessEngineOnAnEphemeralPortFeedsTheMenu() async throws {
        var environment = EngineEnvironment()
        environment.automaticWorkers = false
        environment.trapSignals = false
        let engine = VibePulseEngine(port: 0, environment: environment)
        let adapter = LiveEngineAdapter(engine)
        let session = self.session(engine: adapter)
        await session.bootstrap(startService: true)
        defer { engine.stop() }

        guard case .running = session.phase else {
            return XCTFail("phase \(session.phase) \(session.lastError ?? "")")
        }
        let port = try XCTUnwrap(session.boundPort)
        XCTAssertNotEqual(port, 8737)
        XCTAssertGreaterThan(port, 0)
        let tokens = try XCTUnwrap(MenuReading.tokens(engine.snapshot))
        XCTAssertEqual(tokens.usageTotals?.placeholder, true)
        let agents = try XCTUnwrap(MenuReading.agents(engine.agentJSON))
        XCTAssertEqual(agents.claude.activeCount, 0)
        XCTAssertEqual(agents.codex.activeCount, 0)
        XCTAssertNotNil(MenuReading.diagnostics(engine.diagnosticsJSON))

        await session.shutdown()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.ownsEngine)
    }

    private func session(engine: any MenuEngine,
                         launch: FakeLaunch = FakeLaunch(),
                         signals: FakeSignals = FakeSignals(),
                         signalTimeout: TimeInterval = 0.2,
                         signalPoll: TimeInterval = 0.01) -> EngineSession {
        EngineSession(
            engine: engine,
            configuration: ServiceConfiguration(port: 9, logPath: self.directory.appendingPathComponent("service.log").path),
            launch: launch,
            signals: signals,
            signalTimeout: signalTimeout,
            signalPoll: signalPoll)
    }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var events: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored
    }

    func add(_ event: String) {
        self.lock.lock()
        self.stored.append(event)
        self.lock.unlock()
    }
}

private final class FakeEngine: MenuEngine, @unchecked Sendable {
    var snapshot: [String: Any] = ["v": 2]
    var agentStatus: [String: Any] = ["v": 2]
    var diagnostics: [String: Any] = ["service": "torget-tokenserver", "rev": "test"]
    var results: [MenuEngineStart] = [.started(port: 9)]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var events: OrderLog?

    func start() -> MenuEngineStart {
        self.startCount += 1
        self.events?.add("start")
        guard !self.results.isEmpty else { return .started(port: 9) }
        return self.results.removeFirst()
    }

    func stop() {
        self.stopCount += 1
        self.events?.add("stop")
    }
}

private final class LiveEngineAdapter: MenuEngine, @unchecked Sendable {
    let engine: VibePulseEngine
    init(_ engine: VibePulseEngine) { self.engine = engine }
    var snapshot: [String: Any] { self.engine.snapshot }
    var agentStatus: [String: Any] { self.engine.agentJSON }
    var diagnostics: [String: Any] { self.engine.diagnosticsJSON }
    func start() -> MenuEngineStart {
        switch self.engine.start() {
        case let .started(port): .started(port: port)
        case let .portBusy(pid, command): .portBusy(pid: pid, command: command)
        case let .failed(message): .failed(message)
        }
    }

    func stop() { self.engine.stop() }
}

private final class FakeLaunch: LaunchAgentControlling, @unchecked Sendable {
    var statusValue = LaunchAgentStatus.absent
    var events: OrderLog?
    var bootstrapStatus: Int32 = 0
    var bootstrapError = ""

    func status() async -> LaunchAgentStatus { self.statusValue }

    func disable() async -> CommandRunner.Result {
        self.events?.add("disable")
        return self.ok
    }

    func bootout() async -> CommandRunner.Result {
        self.events?.add("bootout")
        return self.ok
    }

    func enable() async -> CommandRunner.Result {
        self.events?.add("enable")
        return self.ok
    }

    func bootstrap() async -> CommandRunner.Result {
        self.events?.add("bootstrap")
        return CommandRunner.Result(status: self.bootstrapStatus, stdout: "", stderr: self.bootstrapError)
    }

    private var ok: CommandRunner.Result { CommandRunner.Result(status: 0, stdout: "", stderr: "") }
}

private struct SignalRecord: Equatable {
    var signal: Int32
    var pid: Int32
}

private final class FakeSignals: ProcessSignaling, @unchecked Sendable {
    var sent: [SignalRecord] = []
    var alive: Set<Int32> = []
    var dieOnSignal = true
    var events: OrderLog?

    func send(signal: Int32, to pid: Int32) {
        self.sent.append(SignalRecord(signal: signal, pid: pid))
        self.events?.add("signal")
        if self.dieOnSignal { self.alive.remove(pid) }
    }

    func isAlive(_ pid: Int32) -> Bool { self.alive.contains(pid) }
}
