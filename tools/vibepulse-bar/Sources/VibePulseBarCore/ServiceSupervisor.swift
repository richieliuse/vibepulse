import Darwin
import Foundation
import Observation

/// Owns the tokenserver's lifecycle: start, graceful stop, crash restart,
/// and an honest account of who is actually serving the port.
@MainActor
@Observable
public final class ServiceSupervisor {
    public enum Phase: String, Equatable, Sendable {
        /// Not running: paused by the user, or never started.
        case idle
        /// Looking for a LaunchAgent or another instance before spawning.
        case checking
        /// Spawned; `GET /` has not answered yet.
        case starting
        case running
        /// Our process is alive but has stopped answering.
        case unresponsive
        case stopping
        /// Exited without being asked to; see `lastExit` and `nextRestartAt`.
        case crashed
        /// Another process, not started by this app, serves the port.
        case external
        /// A loaded `se.torget.tokenserver` LaunchAgent owns the service.
        case launchAgent
        /// The configuration cannot start anything; see `issues`/`lastError`.
        case misconfigured
    }

    public struct ExitRecord: Equatable, Sendable {
        public var pid: Int32
        /// `nil` when the exit status is unknown.
        public var status: Int32?
        public var bySignal: Bool
        public var at: Date
        public var runtime: TimeInterval
        public var expected: Bool
        public var lastLines: [String]

        public init(pid: Int32, status: Int32?, bySignal: Bool, at: Date, runtime: TimeInterval,
                    expected: Bool, lastLines: [String]) {
            self.pid = pid
            self.status = status
            self.bySignal = bySignal
            self.at = at
            self.runtime = runtime
            self.expected = expected
            self.lastLines = lastLines
        }

        public var summary: String {
            guard let status else { return "exited" }
            if self.bySignal { return "killed by signal \(status)" }
            return status == 0 ? "exited cleanly" : "exited with code \(status)"
        }
    }

    public struct Timing: Sendable {
        public var startingPoll: TimeInterval = 1
        public var runningPoll: TimeInterval = 10
        public var idlePoll: TimeInterval = 15
        public var gracefulStop: TimeInterval = 10
        public var terminateStop: TimeInterval = 3
        /// How long a leftover server's own launcher gets to stop it.
        public var orphanWait = TimeInterval(ServiceGuard.orphanGrace) + 2
        public var unresponsiveAfterFailures = 3
        public var restart = RestartPolicy()

        public init() {}
    }

    public struct Dependencies: Sendable {
        public var launchAgentStatus: @Sendable () async -> LaunchAgentStatus
        public var listeners: @Sendable (Int) async -> [Int32]
        public var describe: @Sendable (Int32) async -> ProcessDescription?
        public var ownershipURL: URL
        public var baseEnvironment: [String: String]

        public static var live: Dependencies {
            Dependencies(
                launchAgentStatus: { await LaunchAgentControl.status() },
                listeners: { await ProcessInspector.listeners(onPort: $0) },
                describe: { await ProcessInspector.describe($0) },
                ownershipURL: OwnershipRecord.defaultURL,
                baseEnvironment: ProcessInfo.processInfo.environment)
        }

        public init(launchAgentStatus: @escaping @Sendable () async -> LaunchAgentStatus,
                    listeners: @escaping @Sendable (Int) async -> [Int32],
                    describe: @escaping @Sendable (Int32) async -> ProcessDescription?,
                    ownershipURL: URL, baseEnvironment: [String: String]) {
            self.launchAgentStatus = launchAgentStatus
            self.listeners = listeners
            self.describe = describe
            self.ownershipURL = ownershipURL
            self.baseEnvironment = baseEnvironment
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var pid: Int32?
    public private(set) var processStartedAt: Date?
    public private(set) var lastExit: ExitRecord?
    public private(set) var nextRestartAt: Date?
    public private(set) var restartAttempt = 0
    public private(set) var diagnostics: ServerDiagnostics?
    public private(set) var lastHealthyAt: Date?
    public private(set) var issues: [ServiceConfiguration.Issue] = []
    public private(set) var lastError: String?
    public private(set) var foreign: ProcessDescription?
    public private(set) var launchAgent: LaunchAgentStatus = .absent
    /// The user's intent: should a server be running? Pause clears it.
    public private(set) var wantsRunning = false
    public var autoRestart = true
    /// Faster health polling while the menu is visible.
    public var isMenuVisible = false {
        didSet { if self.isMenuVisible, !oldValue { self.pokeHealth() } }
    }

    public var configuration: ServiceConfiguration {
        didSet {
            guard self.configuration != oldValue else { return }
            self.client = TokenServerClient(port: self.configuration.effectivePort)
            self.issues = self.configuration.validate()
        }
    }

    public private(set) var client: TokenServerClient
    public var log: ServiceLog { ServiceLog(path: self.configuration.logPath) }

    /// This app answers for the process, and stops it on quit.
    public var ownsProcess: Bool { self.handle != nil }

    /// A server answered recently enough that data reads are worth trying.
    public var isServing: Bool {
        guard let lastHealthyAt else { return false }
        switch self.phase {
        case .running, .external, .launchAgent, .unresponsive:
            return Date().timeIntervalSince(lastHealthyAt) < max(30, self.timing.runningPoll * 3)
        default:
            return false
        }
    }

    public var isBusy: Bool { self.phase == .checking || self.phase == .stopping }

    private let timing: Timing
    private let dependencies: Dependencies
    private var handle: ManagedProcess?
    private var healthTask: Task<Void, Never>?
    private var healthWake: CheckedContinuation<Void, Never>?
    private var healthSleepID = 0
    private var restartTask: Task<Void, Never>?
    private var healthFailures = 0

    public init(configuration: ServiceConfiguration, timing: Timing = Timing(),
                dependencies: Dependencies = .live) {
        self.configuration = configuration
        self.timing = timing
        self.dependencies = dependencies
        self.client = TokenServerClient(port: configuration.effectivePort)
        self.issues = configuration.validate()
    }

    // MARK: - Public lifecycle

    /// Called once at launch: clear out a server a crashed run of the app
    /// left behind, then start (or only observe) according to the user's
    /// saved intent. A leftover means the service was running, so it is
    /// started again.
    public func bootstrap(startService: Bool) async {
        self.startHealthLoop()
        var wanted = startService
        if let record = OwnershipRecord.load(from: self.dependencies.ownershipURL) {
            if record.isStillRunning {
                wanted = true
                await self.reclaim(record)
            }
            OwnershipRecord.clear(at: self.dependencies.ownershipURL)
        }
        self.wantsRunning = wanted
        await self.startOrObserve()
    }

    /// Start monitoring: spawn the server unless something already serves.
    public func start() async {
        guard self.handle == nil else { return }
        self.cancelRestart()
        self.wantsRunning = true
        self.restartAttempt = 0
        await self.startOrObserve()
    }

    /// Pause monitoring: stop our server gracefully and keep it stopped.
    public func stop() async {
        self.wantsRunning = false
        self.cancelRestart()
        guard let handle else {
            if self.phase == .crashed || self.phase == .starting || self.phase == .unresponsive {
                self.phase = .idle
            }
            return
        }
        await self.terminate(handle, reason: "paused")
    }

    public func restart() async {
        if self.phase == .launchAgent {
            self.log.append("restarting the LaunchAgent service (kickstart -k)")
            _ = await LaunchAgentControl.kickstart()
            self.pokeHealth()
            return
        }
        if let handle {
            await self.terminate(handle, reason: "restart")
        }
        await self.start()
    }

    /// Quit path: stop what this app owns; never touch a foreign instance.
    public func shutdown() async {
        self.wantsRunning = false
        self.cancelRestart()
        if let handle {
            await self.terminate(handle, reason: "app quit")
        }
        self.healthTask?.cancel()
    }

    /// Stops a foreign tokenserver gracefully, then runs our own.
    public func takeOverExternal() async {
        guard self.phase == .external, let foreign, foreign.looksLikeTokenServer else { return }
        self.phase = .stopping
        self.log.append("taking over external tokenserver pid \(foreign.pid): \(foreign.command)")
        let stopped = await self.terminateForeign(foreign.pid)
        if !stopped {
            self.lastError = "pid \(foreign.pid) did not exit; it may belong to another user or supervisor"
        }
        self.foreign = nil
        await self.start()
    }

    /// Disables the LaunchAgent (reversibly) and runs the server here.
    public func takeOverLaunchAgent() async {
        guard self.phase == .launchAgent else { return }
        self.phase = .stopping
        self.log.append("taking over from the LaunchAgent (launchctl disable + bootout)")
        let before = await self.dependencies.launchAgentStatus()
        _ = await LaunchAgentControl.disable()
        if let pid = before.pid {
            _ = await self.terminateForeign(pid)
        }
        let result = await LaunchAgentControl.bootout()
        if !result.succeeded, !result.stderr.isEmpty {
            self.log.append("launchctl bootout: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                            level: "WARNING")
        }
        self.launchAgent = await self.dependencies.launchAgentStatus()
        await self.start()
    }

    /// Stops our server and lets launchd own it again.
    public func handBackToLaunchAgent() async {
        await self.stop()
        self.log.append("handing the service back to the LaunchAgent (launchctl enable + bootstrap)")
        let result = await LaunchAgentControl.handBack()
        if !result.succeeded {
            self.lastError = "launchctl bootstrap failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        await self.detectEnvironment()
    }

    // MARK: - Detection and spawning

    private func startOrObserve() async {
        self.phase = .checking
        self.lastError = nil
        await self.detectEnvironment()
        guard self.phase == .checking else { return }
        if self.wantsRunning {
            self.spawn()
        } else {
            self.phase = .idle
        }
    }

    /// Sets `.launchAgent` / `.external` when someone else owns the port,
    /// leaving the phase untouched otherwise.
    private func detectEnvironment() async {
        guard self.handle == nil else { return }
        let agent = await self.dependencies.launchAgentStatus()
        self.launchAgent = agent
        if agent.loaded {
            self.foreign = nil
            self.phase = .launchAgent
            self.pokeHealth()
            return
        }
        let listeners = await self.dependencies.listeners(self.configuration.effectivePort)
        if let listener = listeners.first {
            self.foreign = await self.dependencies.describe(listener)
                ?? ProcessDescription(pid: listener, command: "unknown process", startTime: nil)
            self.phase = .external
            self.pokeHealth()
            return
        }
        self.foreign = nil
        if self.phase == .external || self.phase == .launchAgent {
            self.phase = .idle
        }
    }

    private func spawn() {
        self.issues = self.configuration.validate()
        guard self.issues.isEmpty else {
            self.phase = .misconfigured
            return
        }
        let configuration = self.configuration
        let guardURL: URL
        do {
            guardURL = try ServiceGuard.install(in: self.dependencies.ownershipURL.deletingLastPathComponent())
        } catch {
            self.lastError = "Could not write the launcher: \(error.localizedDescription)"
            self.log.append(self.lastError!, level: "ERROR")
            self.phase = .misconfigured
            return
        }
        let process = Process()
        let command = configuration.commandLine
        let launched = configuration.supervisedCommandLine(guardPath: guardURL.path)
        let logOffset = self.log.size
        process.executableURL = URL(fileURLWithPath: launched[0])
        process.arguments = Array(launched.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.resolvedWorkingDirectory)
        var environment = configuration.processEnvironment(base: self.dependencies.baseEnvironment)
        environment["VPBAR_PARENT_PID"] = String(getpid())
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        do {
            let output = try self.log.openForChild()
            process.standardOutput = output
            process.standardError = output
        } catch {
            self.lastError = error.localizedDescription
            self.phase = .misconfigured
            return
        }
        process.terminationHandler = { [weak self] finished in
            let pid = finished.processIdentifier
            let status = finished.terminationStatus
            let bySignal = finished.terminationReason == .uncaughtSignal
            Task { @MainActor in
                self?.processExited(pid: pid, status: status, bySignal: bySignal)
            }
        }
        do {
            try process.run()
        } catch {
            self.lastError = "Could not launch \(command[0]): \(error.localizedDescription)"
            self.log.append(self.lastError!, level: "ERROR")
            self.phase = .misconfigured
            return
        }
        let pid = process.processIdentifier
        let startTime = ProcessInspector.startTime(of: pid) ?? Date().timeIntervalSince1970
        let handle = ManagedProcess(pid: pid, startTime: startTime, launchedAt: Date(), child: process)
        handle.logOffset = logOffset
        handle.noteGroupLeadership()
        self.handle = handle
        OwnershipRecord(pid: pid, startTime: startTime, port: configuration.effectivePort)
            .save(to: self.dependencies.ownershipURL)
        self.pid = pid
        self.processStartedAt = Date()
        self.diagnostics = nil
        self.healthFailures = 0
        self.phase = .starting
        self.log.append("started tokenserver pid \(pid) via \(ServiceGuard.fileName): \(command.joined(separator: " "))")
        self.pokeHealth()
    }

    /// A server a crashed run of the app left behind. Its launcher notices
    /// the app is gone and stops it; this only waits for that, and forces
    /// the rest (a server from a build without the launcher, or one stuck
    /// in cleanup). Never a second SIGINT: it would cut that cleanup short.
    private func reclaim(_ record: OwnershipRecord) async {
        self.phase = .stopping
        let guarded = await self.dependencies.describe(record.pid)?.command.contains(ServiceGuard.fileName) ?? false
        self.log.append("tokenserver pid \(record.pid) outlived the previous run of the app; "
                        + (guarded ? "waiting for its launcher to stop it" : "stopping it: SIGINT"),
                        level: "WARNING")
        let leadsGroup = getpgid(record.pid) == record.pid
        if !guarded { kill(record.pid, SIGINT) }
        let firstWait = guarded ? self.timing.orphanWait : self.timing.gracefulStop
        let steps: [(Int32, TimeInterval)] = [(0, firstWait), (SIGTERM, self.timing.terminateStop), (SIGKILL, 2)]
        for (signal, wait) in steps {
            guard record.isStillRunning else { break }
            if signal != 0 {
                self.log.append("pid \(record.pid) still running: \(signal == SIGTERM ? "SIGTERM" : "SIGKILL")",
                                level: "WARNING")
                if leadsGroup, signal == SIGKILL { killpg(record.pid, signal) } else { kill(record.pid, signal) }
            }
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline, record.isStillRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if leadsGroup, await ManagedProcess.clearGroup(record.pid) {
            self.log.append("cleared helpers left in pid \(record.pid)'s process group", level: "WARNING")
        }
        if record.isStillRunning {
            self.lastError = "pid \(record.pid) from the previous run did not exit"
        }
        self.phase = .idle
    }

    // MARK: - Stopping

    /// One stop per process: a quit during a pause joins the pause instead
    /// of sending a second SIGINT into the server's cleanup.
    private func terminate(_ handle: ManagedProcess, reason: String) async {
        if let stopping = handle.stopTask {
            await stopping.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTerminate(handle, reason: reason)
        }
        handle.stopTask = task
        await task.value
    }

    private func performTerminate(_ handle: ManagedProcess, reason: String) async {
        self.phase = .stopping
        handle.expectedExit = true
        handle.noteGroupLeadership()
        self.log.append("stopping tokenserver pid \(handle.pid) (\(reason)): SIGINT")
        handle.signal(SIGINT)
        if await !self.waitForExit(handle, timeout: self.timing.gracefulStop) {
            self.log.append("pid \(handle.pid) ignored SIGINT for \(Int(self.timing.gracefulStop)) s: SIGTERM",
                            level: "WARNING")
            handle.signal(SIGTERM)
            if await !self.waitForExit(handle, timeout: self.timing.terminateStop) {
                self.log.append("pid \(handle.pid) ignored SIGTERM: SIGKILL", level: "WARNING")
                handle.signal(SIGKILL, group: true)
                _ = await self.waitForExit(handle, timeout: 2)
            }
        }
        await self.sweep(handle)
    }

    /// Helpers the server spawned die with it, even when it could not
    /// clean up after itself (SIGKILL, a crash).
    private func sweep(_ handle: ManagedProcess) async {
        guard handle.hasExited, handle.leadsGroup else { return }
        if await ManagedProcess.clearGroup(handle.pid) {
            self.log.append("cleared helpers left in pid \(handle.pid)'s process group", level: "WARNING")
        }
    }

    private func waitForExit(_ handle: ManagedProcess, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if handle.hasExited { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return handle.hasExited
    }

    /// SIGINT is the server's graceful path (its `finally` flushes Max
    /// Tracker and stops the relays); a plain SIGTERM skips that flush.
    private func terminateForeign(_ pid: Int32) async -> Bool {
        for (signal, wait) in [(SIGINT, self.timing.gracefulStop), (SIGTERM, self.timing.terminateStop)] {
            guard ProcessInspector.isAlive(pid) else { return true }
            kill(pid, signal)
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline, ProcessInspector.isAlive(pid) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return !ProcessInspector.isAlive(pid)
    }

    private func processExited(pid: Int32, status: Int32?, bySignal: Bool) {
        guard let handle, handle.pid == pid, !handle.hasExited else { return }
        handle.hasExited = true
        self.handle = nil
        self.pid = nil
        OwnershipRecord.clear(at: self.dependencies.ownershipURL)
        let runtime = Date().timeIntervalSince(handle.launchedAt)
        let expected = handle.expectedExit || !self.wantsRunning
        let record = ExitRecord(
            pid: pid, status: status, bySignal: bySignal, at: Date(), runtime: runtime,
            expected: expected, lastLines: self.log.serverTail(since: handle.logOffset))
        self.lastExit = record
        self.log.append("tokenserver pid \(pid) \(record.summary) after \(Format.duration(seconds: Int(runtime)))",
                        level: expected ? "INFO" : "WARNING")
        self.processStartedAt = nil
        if expected {
            self.phase = .idle
            return
        }
        Task { [weak self] in await self?.sweep(handle) }
        self.phase = .crashed
        guard self.autoRestart else {
            self.nextRestartAt = nil
            return
        }
        self.restartAttempt = self.timing.restart.nextAttempt(previous: self.restartAttempt, runtime: runtime)
        let delay = self.timing.restart.delay(forAttempt: self.restartAttempt)
        self.nextRestartAt = Date().addingTimeInterval(delay)
        self.log.append("restarting in \(Int(delay)) s (attempt \(self.restartAttempt))")
        self.restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase == .crashed, self.wantsRunning else { return }
            self.nextRestartAt = nil
            await self.startOrObserve()
        }
    }

    private func cancelRestart() {
        self.restartTask?.cancel()
        self.restartTask = nil
        self.nextRestartAt = nil
    }

    // MARK: - Health

    private func startHealthLoop() {
        guard self.healthTask == nil else { return }
        self.healthTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.healthTick()
                await self.sleepUntilNextTick(self.healthInterval)
            }
        }
    }

    private var healthInterval: TimeInterval {
        switch self.phase {
        case .starting, .checking, .stopping:
            return self.timing.startingPoll
        case .running, .unresponsive, .external, .launchAgent:
            return self.isMenuVisible ? min(3, self.timing.runningPoll) : self.timing.runningPoll
        case .idle, .crashed, .misconfigured:
            return self.timing.idlePoll
        }
    }

    private func sleepUntilNextTick(_ interval: TimeInterval) async {
        self.healthSleepID &+= 1
        let sleepID = self.healthSleepID
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.healthWake = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                // A poke already ended this sleep; never cut a later one short.
                guard let self, self.healthSleepID == sleepID else { return }
                self.wakeHealth()
            }
        }
    }

    private func wakeHealth() {
        let wake = self.healthWake
        self.healthWake = nil
        wake?.resume()
    }

    /// Runs the next health check now instead of at the end of the interval.
    public func pokeHealth() {
        self.wakeHealth()
    }

    private func healthTick() async {
        let phase = self.phase
        guard phase != .checking, phase != .stopping else { return }
        do {
            let diagnostics = try await self.client.diagnostics()
            guard diagnostics.isTokenServer else {
                throw TokenServerClient.FetchError.undecodable
            }
            self.healthSucceeded(diagnostics)
        } catch {
            await self.healthFailed()
        }
    }

    private func healthSucceeded(_ diagnostics: ServerDiagnostics) {
        self.diagnostics = diagnostics
        self.lastHealthyAt = Date()
        self.healthFailures = 0
        self.handle?.noteGroupLeadership()
        switch self.phase {
        case .starting:
            self.phase = .running
            if let started = self.processStartedAt {
                let seconds = Date().timeIntervalSince(started)
                self.log.append(String(format: "tokenserver answering on port %d after %.1f s",
                                       self.configuration.effectivePort, seconds))
            }
            if let handle = self.handle {
                Task { [weak self] in await self?.verifyLauncher(handle) }
            }
        case .unresponsive:
            self.phase = .running
            self.log.append("tokenserver answering again")
        case .idle, .crashed, .misconfigured:
            // Something we did not start is serving: say who.
            if self.handle == nil {
                Task { [weak self] in
                    guard let self else { return }
                    self.cancelRestart()
                    await self.detectEnvironment()
                }
            }
        default:
            break
        }
    }

    /// A wrapper that `exec`s replaces the launcher, and with it the only
    /// thing that stops the server once the app is gone. Say so.
    private func verifyLauncher(_ handle: ManagedProcess) async {
        guard let command = await self.dependencies.describe(handle.pid)?.command,
              self.handle === handle, !handle.hasExited,
              !command.contains(ServiceGuard.fileName)
        else { return }
        self.lastError = "The launch command replaced \(ServiceGuard.fileName) (exec), so pid \(handle.pid) "
            + "would outlive an app crash. Run the server in-process (runpy) instead."
        self.log.append(self.lastError!, level: "WARNING")
    }

    private func healthFailed() async {
        self.healthFailures += 1
        switch self.phase {
        case .running where self.healthFailures >= self.timing.unresponsiveAfterFailures:
            self.phase = .unresponsive
            self.log.append("tokenserver pid \(self.pid.map(String.init) ?? "?") stopped answering GET /",
                            level: "WARNING")
        case .external, .launchAgent:
            guard self.healthFailures >= 2 else { return }
            self.diagnostics = nil
            await self.detectEnvironment()
            if self.phase == .idle, self.wantsRunning {
                await self.startOrObserve()
            }
        default:
            break
        }
    }
}

/// The server process this app spawned and answers for.
@MainActor
final class ManagedProcess {
    let pid: Int32
    let startTime: TimeInterval
    let launchedAt: Date
    var hasExited = false
    var expectedExit = false
    /// Log size when this process started; its own output follows it.
    var logOffset: UInt64 = 0
    var stopTask: Task<Void, Never>?
    /// Seen leading its own process group (the launcher's `setpgid`), so the
    /// group holds only the server and the helpers it spawned.
    private(set) var leadsGroup = false
    private let child: Process

    init(pid: Int32, startTime: TimeInterval, launchedAt: Date, child: Process) {
        self.pid = pid
        self.startTime = startTime
        self.launchedAt = launchedAt
        self.child = child
    }

    func noteGroupLeadership() {
        guard !self.hasExited, !self.leadsGroup else { return }
        self.leadsGroup = getpgid(self.pid) == self.pid
    }

    func signal(_ signal: Int32, group: Bool = false) {
        guard !self.hasExited else { return }
        if group, self.leadsGroup {
            killpg(self.pid, signal)
        } else {
            kill(self.pid, signal)
        }
    }

    /// SIGTERM, then SIGKILL, whatever is left in a group whose leader has
    /// exited. A group id stays reserved while any member lives, so this
    /// can only reach the server's own helpers. Returns whether any were left.
    static func clearGroup(_ group: Int32) async -> Bool {
        guard killpg(group, SIGTERM) == 0 else { return false }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if killpg(group, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        killpg(group, SIGKILL)
        return true
    }
}
