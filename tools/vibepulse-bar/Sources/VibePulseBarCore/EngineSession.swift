import Darwin
import Foundation
import Observation

public enum MenuEngineStart: Equatable, Sendable {
    case started(port: Int)
    case portBusy(pid: Int32?, command: String?)
    case failed(String)
}

/// The in-process server the menu reads. `start` does not launch a child.
public protocol MenuEngine: AnyObject {
    var snapshot: [String: Any] { get }
    var agentStatus: [String: Any] { get }
    var diagnostics: [String: Any] { get }
    func start() -> MenuEngineStart
    func stop()
}

/// launchctl operations the session may perform. Tests pass a stand-in.
public protocol LaunchAgentControlling: Sendable {
    func status() async -> LaunchAgentStatus
    func disable() async -> CommandRunner.Result
    func bootout() async -> CommandRunner.Result
    func enable() async -> CommandRunner.Result
    func bootstrap() async -> CommandRunner.Result
}

/// How a foreign listener is asked to exit. Tests pass a stand-in and never signal a live pid.
public protocol ProcessSignaling: Sendable {
    func send(signal: Int32, to pid: Int32)
    func isAlive(_ pid: Int32) -> Bool
}

/// Owns the in-process engine's place on the port: start, stop, take-over, and hand-back.
@MainActor
@Observable
public final class EngineSession {
    public private(set) var phase: ServicePhase = .idle
    public private(set) var launchAgent: LaunchAgentStatus = .absent
    public private(set) var foreign: ProcessDescription?
    public private(set) var lastError: String?
    public private(set) var ownsEngine = false
    public private(set) var wantsRunning = false
    public private(set) var boundPort: Int?
    public private(set) var startedAt: Date?
    public private(set) var issues: [ServiceConfiguration.Issue] = []

    public var configuration: ServiceConfiguration {
        didSet { self.issues = self.configuration.validate() }
    }

    public var isServing: Bool { self.phase == .running && self.ownsEngine }

    private let engine: any MenuEngine
    private let launch: any LaunchAgentControlling
    private let signals: any ProcessSignaling
    private let signalTimeout: TimeInterval
    private let signalPoll: TimeInterval
    private var stopping: StopBox?

    public init(engine: any MenuEngine,
                configuration: ServiceConfiguration,
                launch: any LaunchAgentControlling,
                signals: any ProcessSignaling,
                signalTimeout: TimeInterval = 10,
                signalPoll: TimeInterval = 0.05) {
        self.engine = engine
        self.configuration = configuration
        self.launch = launch
        self.signals = signals
        self.signalTimeout = signalTimeout
        self.signalPoll = signalPoll
        self.issues = configuration.validate()
    }

    public var serviceSnapshot: ServiceSnapshot {
        ServiceSnapshot(
            phase: self.phase,
            pid: self.ownsEngine ? Int32(ProcessInfo.processInfo.processIdentifier) : nil,
            processStartedAt: self.startedAt,
            diagnostics: self.isServing ? MenuReading.diagnostics(self.engine.diagnostics) : nil,
            foreign: self.foreign,
            launchAgent: self.launchAgent,
            issues: self.issues,
            lastError: self.lastError,
            port: self.boundPort ?? self.configuration.port,
            ownsProcess: self.ownsEngine,
            wantsRunning: self.wantsRunning,
            isServing: self.isServing)
    }

    public func bootstrap(startService: Bool) async {
        self.phase = .checking
        self.lastError = nil
        self.launchAgent = await self.launch.status()
        if self.launchAgent.loaded {
            self.wantsRunning = false
            self.phase = .launchAgent
            return
        }
        self.wantsRunning = startService
        guard startService else {
            self.phase = .idle
            return
        }
        self.begin()
    }

    public func start() async {
        self.launchAgent = await self.launch.status()
        if self.launchAgent.loaded {
            self.phase = .launchAgent
            return
        }
        guard !self.ownsEngine else { return }
        self.wantsRunning = true
        self.begin()
    }

    public func pause() async {
        self.wantsRunning = false
        self.phase = .stopping
        await self.stopEngine()
        self.ownsEngine = false
        self.startedAt = nil
        self.boundPort = nil
        self.phase = .idle
        self.log("paused the in-process server")
    }

    public func restart() async {
        guard self.ownsEngine else { return }
        self.phase = .stopping
        await self.stopEngine()
        self.ownsEngine = false
        self.startedAt = nil
        self.boundPort = nil
        self.begin()
    }

    /// `launchctl disable`, then `bootout`, then the in-process server. No child is spawned.
    public func takeOverLaunchAgent() async {
        guard self.phase == .launchAgent else { return }
        self.phase = .stopping
        self.lastError = nil
        _ = await self.launch.disable()
        _ = await self.launch.bootout()
        self.launchAgent = await self.launch.status()
        self.wantsRunning = true
        self.log("took over se.torget.tokenserver (launchctl disable + bootout)")
        self.begin()
    }

    /// SIGINT the foreign listener, wait until it exits or the timeout passes, then start here.
    public func takeOverExternal() async {
        guard self.phase == .external, let foreign, foreign.looksLikeTokenServer else { return }
        let pid = foreign.pid
        self.phase = .stopping
        self.lastError = nil
        self.signals.send(signal: SIGINT, to: pid)
        self.log("taking over pid \(pid): SIGINT")
        let deadline = Date().addingTimeInterval(self.signalTimeout)
        while self.signals.isAlive(pid), Date() < deadline {
            let pause = UInt64(self.signalPoll * 1_000_000_000)
            try? await Task.sleep(nanoseconds: pause)
        }
        if self.signals.isAlive(pid) {
            self.lastError = "pid \(pid) did not exit"
        }
        self.foreign = nil
        self.wantsRunning = true
        self.begin()
    }

    /// Stop this process's server, then `launchctl enable` and `bootstrap`.
    public func handBack() async {
        self.phase = .stopping
        await self.stopEngine()
        self.ownsEngine = false
        self.startedAt = nil
        self.boundPort = nil
        self.wantsRunning = false
        self.log("handing the service back to the LaunchAgent (launchctl enable + bootstrap)")
        _ = await self.launch.enable()
        let result = await self.launch.bootstrap()
        if !result.succeeded {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lastError = detail.isEmpty ? "launchctl bootstrap failed" : "launchctl bootstrap failed: \(detail)"
        }
        self.launchAgent = await self.launch.status()
        self.phase = self.launchAgent.loaded ? .launchAgent : .idle
    }

    /// Quit path. Stops the engine and does not signal anyone else.
    public func shutdown() async {
        self.wantsRunning = false
        await self.stopEngine()
        self.ownsEngine = false
        self.startedAt = nil
        self.boundPort = nil
        if self.phase != .external, self.phase != .launchAgent {
            self.phase = .idle
        }
    }

    private func begin() {
        self.issues = self.configuration.validate()
        if let issue = self.issues.first {
            self.phase = .failed
            self.lastError = issue.message
            self.ownsEngine = false
            return
        }
        self.phase = .starting
        self.apply(self.engine.start())
    }

    private func apply(_ result: MenuEngineStart) {
        switch result {
        case let .started(port):
            self.phase = .running
            self.boundPort = port
            self.foreign = nil
            self.ownsEngine = true
            self.startedAt = Date()
            self.lastError = nil
            self.wantsRunning = true
            self.log("in-process server listening on port \(port)")
        case let .portBusy(pid, command):
            self.phase = .external
            self.ownsEngine = false
            self.startedAt = nil
            self.boundPort = nil
            if let pid {
                let text = command?.isEmpty == false ? command! : "unknown process"
                self.foreign = ProcessDescription(pid: pid, command: text, startTime: nil)
            } else {
                self.foreign = nil
                self.lastError = command?.isEmpty == false ? command : "port \(self.configuration.port) is already in use"
            }
            var note = "port \(self.configuration.port) is busy"
            if let pid { note += " (pid \(pid))" }
            if let command, !command.isEmpty { note += ": \(command)" }
            self.log(note)
        case let .failed(message):
            self.phase = .failed
            self.ownsEngine = false
            self.startedAt = nil
            self.boundPort = nil
            self.foreign = nil
            self.lastError = message
            self.log(message)
        }
    }

    private func stopEngine() async {
        if let stopping {
            await stopping.task.value
            return
        }
        let handle = EngineHandle(self.engine)
        let box = StopBox(Task.detached { handle.stop() })
        self.stopping = box
        await box.task.value
        if self.stopping === box { self.stopping = nil }
    }

    private func log(_ message: String) {
        ServiceLog(path: self.configuration.logPath).append(message)
    }
}

private final class StopBox: @unchecked Sendable {
    let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
}

private final class EngineHandle: @unchecked Sendable {
    private let engine: any MenuEngine
    init(_ engine: any MenuEngine) { self.engine = engine }
    func stop() { self.engine.stop() }
}
