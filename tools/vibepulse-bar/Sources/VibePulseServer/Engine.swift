import Darwin
import Foundation
import VibePulseAgents
import VibePulseProviders
import VibePulseRelay
import VibePulseState
import VibePulseSupport

public enum EngineStart: Sendable, Equatable {
    case started(port: Int)
    case portBusy(pid: Int32?, command: String?)
    case failed(String)
}

public enum EngineWorker: String, CaseIterable, Sendable {
    case transcript
    case claudeProbe
    case codexProbe
    case subscriptions
    case agentStatus
    case maxTrackerBackfill
    case publisher
    case interactionRelay
    case github
}

public struct EngineRelayConfig {
    public var baseURL: String
    public var mailbox: String
    public var macToken: String
    public var deviceKeyHex: String
    public var publishInteractions: Bool
    public var publishAgentStatus: Bool
    public var transport: @Sendable (RelayHTTPRequest) throws -> RelayHTTPResponse

    public init(baseURL: String, mailbox: String, macToken: String, deviceKeyHex: String,
                publishInteractions: Bool = true, publishAgentStatus: Bool = false,
                transport: @escaping @Sendable (RelayHTTPRequest) throws -> RelayHTTPResponse) {
        self.baseURL = baseURL
        self.mailbox = mailbox
        self.macToken = macToken
        self.deviceKeyHex = deviceKeyHex
        self.publishInteractions = publishInteractions
        self.publishAgentStatus = publishAgentStatus
        self.transport = transport
    }
}

/// Clocks, transports, and directories the engine calls. Defaults never open
/// the network, the keychain, or `api.github.com`.
public struct EngineEnvironment {
    public var clock: any Clock
    public var projectsDirectory: URL
    public var codexSessions: URL
    public var stateDirectory: URL
    /// Claude Desktop's plan-usage history. Nil leaves `claudeLocalUsage` at `not_checked`.
    public var claudePlanUsageURL: URL?
    public var quotaTransport: any QuotaHTTPTransport
    public var claudeCandidates: @Sendable () -> [ClaudeOAuthCandidate]
    public var keychainReason: String?
    public var grokFetch: @Sendable (TimeInterval) throws -> SubscriptionSample
    public var cursorFetch: @Sendable (TimeInterval) throws -> SubscriptionSample
    public var githubRepo: String?
    public var githubToken: String?
    public var githubTransport: (@Sendable (GitHubHTTPRequest) throws -> GitHubHTTPResponse)?
    public var publishURL: String?
    public var publishMachine: String
    public var publishPost: (@Sendable (PublishRequest) -> Bool)?
    public var relay: EngineRelayConfig?
    public var discoveryAddresses: @Sendable () -> [String]
    public var hostname: @Sendable () -> String
    public var discoveryRegistrar: DiscoveryRegistering?
    public var plans: [String: String]
    public var priceTable: PriceTable?
    public var planCosts: [String: StrictJSON.Value]
    public var claudeInteractions: Bool
    public var codexInteractions: Bool
    public var interactionDetail: Bool
    public var legacyClaudePanelV1: Bool
    public var interactionTimeout: TimeInterval
    public var interactionSecret: String
    public var deviceKeyURL: URL?
    /// Codex `auth.json`. Nil uses a file under `stateDirectory` that is not created.
    public var codexAuthPath: URL?
    /// CLI fallback for `CodexProbe`. The default returns an empty quota and does not spawn a process.
    public var codexAppServer: @Sendable (TimeInterval) throws -> CodexQuota
    public var automaticWorkers: Bool
    public var connectionCap: Int
    public var trapSignals: Bool
    public var transcriptOverride: (@Sendable () throws -> TranscriptScan)?

    public init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibepulse-engine-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        self.clock = SystemClock()
        self.projectsDirectory = projects
        self.codexSessions = codex
        self.stateDirectory = state
        self.claudePlanUsageURL = nil
        self.quotaTransport = RefusingQuotaTransport()
        self.claudeCandidates = { [] }
        self.keychainReason = nil
        self.grokFetch = { _ in SubscriptionSample(auth: "missing", status: "not_run") }
        self.cursorFetch = { _ in SubscriptionSample(auth: "missing", status: "not_run") }
        self.githubRepo = nil
        self.githubToken = nil
        self.githubTransport = nil
        self.publishURL = nil
        self.publishMachine = "host"
        self.publishPost = nil
        self.relay = nil
        self.discoveryAddresses = { [] }
        self.hostname = { ProcessInfo.processInfo.hostName }
        self.discoveryRegistrar = nil
        self.plans = [:]
        self.priceTable = nil
        self.planCosts = [:]
        self.claudeInteractions = false
        self.codexInteractions = false
        self.interactionDetail = false
        self.legacyClaudePanelV1 = false
        self.interactionTimeout = 120
        self.interactionSecret = ""
        self.deviceKeyURL = nil
        self.codexAuthPath = nil
        self.codexAppServer = { _ in CodexQuota() }
        self.automaticWorkers = true
        self.connectionCap = VibePulseEngine.defaultConnectionCap
        self.trapSignals = false
        self.transcriptOverride = nil
    }
}

public final class VibePulseEngine: @unchecked Sendable {
    public static let defaultConnectionCap = 32
    public static let defaultPort = 8737
    /// Firmware drops a body at or above these sizes.
    public static let tokensBodyCap = 4096
    public static let maxTrackerBodyCap = 8192
    public static let githubBodyCap = 768
    public static let agentStatusBodyCap = 4096
    public static let pendingBodyCeiling = 3584

    public private(set) var port: Int
    private(set) var stopTrace: [String] = []
    private(set) var workerRuns: [EngineWorker: Int] = [:]
    private(set) var workerErrors: [EngineWorker: String] = [:]
    private(set) var runningWorkers: Set<EngineWorker> = []
    private(set) var jsonBodyReads = 0

    let environment: EngineEnvironment
    let maxTracker: MaxTrackerStore
    let history: UsageHistory
    let cache: QuotaCache
    let claudeProbe: ClaudeProbe
    let codexProbe: CodexProbe
    let grokProbe: SubscriptionProbe
    let cursorProbe: SubscriptionProbe
    let agentStatus: AgentStatusService
    let discovery: DiscoveryAdvertiser
    private let scanner = TranscriptScanner()
    private let server: HTTPServer
    private let box: EngineBox
    let lock = NSLock()
    private let signalQueue = DispatchQueue(label: "se.torget.vibepulse.signal")
    private static let signalKey = DispatchSpecificKey<DispatchQueue>()

    private var tokens = JSONValue.object([("v", .int(2))])
    var transcript: TranscriptScan?
    var haveScan = false
    var computeFailingSince: TimeInterval?
    var lastResultAt: TimeInterval?
    var codexQuota = CodexQuota()
    var githubMonitor: GitHubMonitor?
    private var publisher: NumbersPublisher?
    private var relay: InteractionRelay?
    var bridge: StoreRelayBridge?
    var interactionStore: InteractionStore?
    var startedMono: TimeInterval
    var startedAt: Date
    private var loops: [EngineWorker: WorkerLoop] = [:]
    private var lastRun: [EngineWorker: TimeInterval] = [:]
    var panel = PanelMemory()
    var maxTrackerDirty = false
    var maxTrackerSaveFailingSince: TimeInterval?
    var relayStatus = "off"
    var relayReason: String?
    var agentRelayStatus = "off"
    var agentRelayReason: String?
    private var armed = false
    private var stopped = false
    private var listening = false
    private var signalSource: DispatchSourceSignal?
    private var previousSignal: sig_t?
    var boundPort = 0

    public init(port: Int = VibePulseEngine.defaultPort, environment: EngineEnvironment = EngineEnvironment()) {
        self.port = port
        self.environment = environment
        let clock = environment.clock
        self.startedMono = clock.monotonic()
        self.startedAt = Date(timeIntervalSince1970: clock.wall())
        let state = environment.stateDirectory
        self.maxTracker = MaxTrackerStore(path: state.appendingPathComponent("max-tracker.json"))
        self.history = UsageHistory(path: state.appendingPathComponent("usage-history.json")) {
            clock.wall()
        }
        self.cache = QuotaCache(path: state.appendingPathComponent("quota-cache.json")) {
            clock.wall()
        }
        self.claudeProbe = ClaudeProbe(
            transport: environment.quotaTransport,
            lockPath: state.appendingPathComponent("claude-probe.lock"),
            statePath: state.appendingPathComponent("claude-probe-state.json")
        )
        self.codexProbe = CodexProbe(
            transport: environment.quotaTransport,
            lockPath: state.appendingPathComponent(CodexProbe.lockFileName),
            statePath: state.appendingPathComponent(CodexProbe.stateFileName),
            authPath: environment.codexAuthPath ?? state.appendingPathComponent("codex-auth.json"),
            sessionsDirectory: environment.codexSessions,
            appServer: environment.codexAppServer
        )
        self.grokProbe = SubscriptionProbe(provider: .grok, fetch: environment.grokFetch)
        self.cursorProbe = SubscriptionProbe(provider: .cursor, fetch: environment.cursorFetch)
        self.agentStatus = AgentStatusService(
            projectsDirectory: environment.projectsDirectory,
            codexSessions: environment.codexSessions,
            now: { clock.monotonic() },
            wall: { clock.wall() }
        )
        self.discovery = DiscoveryAdvertiser(
            addresses: environment.discoveryAddresses,
            hostname: environment.hostname,
            registrar: environment.discoveryRegistrar
        )
        let box = EngineBox()
        self.box = box
        self.server = HTTPServer(connectionCap: environment.connectionCap) { request in
            box.engine?.handle(request) ?? HTTPResponse.json(500, .object([("error", .string("stopped"))]))
        }
        box.engine = self
        configureInteractions()
        rebuildSnapshot()
    }

    /// The current `/api/tokens` value. Reading it does not publish Max Tracker peaks.
    public var snapshot: [String: Any] {
        lock.lock()
        let value = tokens
        lock.unlock()
        return value.foundation() as? [String: Any] ?? [:]
    }

    public var tokensJSON: [String: Any] {
        get { snapshot }
        set {
            lock.lock()
            tokens = JSONValue.from(newValue)
            lock.unlock()
        }
    }

    public var agentJSON: [String: Any] { agentPayload().foundation() as? [String: Any] ?? [:] }
    public var trackerJSON: [String: Any] { maxTrackerPayload().foundation() as? [String: Any] ?? [:] }
    public var githubJSON: [String: Any] { githubPayload().foundation() as? [String: Any] ?? [:] }
    public var diagnosticsJSON: [String: Any] { diagnosticsPayload().foundation() as? [String: Any] ?? [:] }

    /// Binds the listener. Probes stay idle until this returns `.started`.
    public func start() -> EngineStart {
        lock.lock()
        if listening {
            let open = boundPort
            lock.unlock()
            return .started(port: open)
        }
        lock.unlock()
        if port != 0 {
            if port < 0 || port > 65535 {
                return .failed("port out of range")
            }
            if !Self.canBind(UInt16(port)) {
                let owner = PortOwner.lookup(port)
                return .portBusy(pid: owner.pid, command: owner.command)
            }
        }
        let requested = UInt16(port > 0 && port <= 65535 ? port : 0)
        let actual: UInt16
        do {
            actual = try server.start(port: requested)
        } catch {
            return .failed(String(describing: error))
        }
        lock.lock()
        boundPort = Int(actual)
        port = Int(actual)
        listening = true
        stopped = false
        armed = true
        lock.unlock()
        _ = discovery.start(port: Int(actual))
        startWorkers()
        if environment.trapSignals {
            installInterruptHandler()
        }
        return .started(port: Int(actual))
    }

    /// Spec 03 §8.1. Safe to call more than once. SIGINT uses this path.
    public func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        armed = false
        listening = false
        lock.unlock()
        var trace: [String] = []
        trace.append("discovery")
        discovery.stop()
        trace.append("interaction-relay")
        relay?.stop()
        join(.interactionRelay, timeout: 2)
        trace.append("numbers-publisher")
        publisher?.stop()
        join(.publisher, timeout: 5)
        trace.append("github")
        githubMonitor?.stop()
        join(.github, timeout: 2)
        trace.append("backfill")
        join(.maxTrackerBackfill, timeout: 2)
        trace.append("max-tracker-save")
        do {
            try maxTracker.save(today: localDay(environment.clock.wall()))
            lock.lock()
            maxTrackerSaveFailingSince = nil
            lock.unlock()
        } catch {
            let now = environment.clock.monotonic()
            lock.lock()
            if maxTrackerSaveFailingSince == nil { maxTrackerSaveFailingSince = now }
            lock.unlock()
        }
        trace.append("agent-status")
        agentStatus.stop()
        join(.agentStatus, timeout: 2)
        trace.append("listener")
        server.stop()
        for worker in [EngineWorker.transcript, .claudeProbe, .codexProbe, .subscriptions] {
            join(worker, timeout: 2)
        }
        lock.lock()
        stopTrace = trace
        lock.unlock()
        removeInterruptHandler()
    }

    public func handleSignal(_ signo: Int32) {
        if signo == SIGINT || signo == SIGTERM {
            stop()
        }
    }

    public func installInterruptHandler() {
        signalQueue.setSpecific(key: Self.signalKey, value: signalQueue)
        signalQueue.sync {
            guard signalSource == nil else { return }
            previousSignal = signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
            source.setEventHandler { [weak self] in
                self?.handleSignal(SIGINT)
            }
            source.resume()
            signalSource = source
        }
    }

    public func removeInterruptHandler() {
        let work = {
            self.signalSource?.cancel()
            self.signalSource = nil
            if let previousSignal = self.previousSignal {
                _ = signal(SIGINT, previousSignal)
                self.previousSignal = nil
            }
        }
        if DispatchQueue.getSpecific(key: Self.signalKey) === signalQueue {
            work()
        } else {
            signalQueue.sync(execute: work)
        }
    }

    /// One worker cycle. Does nothing until `start()` has bound the port.
    func noteJSONRead() {
        lock.lock()
        jsonBodyReads += 1
        lock.unlock()
    }

    public func tick(_ worker: EngineWorker) {
        lock.lock()
        let allowed = armed
        lock.unlock()
        guard allowed else { return }
        runWorker(worker)
    }

    func response(method: String, path: String, headers: [String: String], body: Data = Data(), peer: String = "127.0.0.1") -> HTTPResponse {
        var lists: [String: [String]] = [:]
        var first: [String: String] = [:]
        for (key, value) in headers {
            let name = key.lowercased()
            lists[name, default: []].append(value)
            if first[name] == nil { first[name] = value }
        }
        let advertised = Int(first["content-length"] ?? "") ?? 0
        let request = HTTPRequest(
            method: method,
            path: path,
            headers: first,
            headerLists: lists,
            body: body,
            bodyComplete: advertised == body.count,
            advertisedLength: max(0, advertised),
            peer: peer
        )
        return handle(request)
    }

    private func configureInteractions() {
        var secret = environment.interactionSecret
        if secret.isEmpty, let url = environment.deviceKeyURL {
            secret = readDeviceKey(at: url) ?? ""
        }
        let wantsStore = environment.claudeInteractions || environment.codexInteractions
            || environment.relay?.publishInteractions == true
        if wantsStore {
            let clock = environment.clock
            let store = InteractionStore(
                revealDetail: environment.interactionDetail,
                secret: secret,
                now: { clock.monotonic() },
                wall: { clock.wall() }
            )
            interactionStore = store
            let bridge = StoreRelayBridge(store: store, secret: secret, wall: { clock.wall() })
            self.bridge = bridge
            store.setOnPark { [weak bridge] job in
                bridge?.handoffParked(job)
            }
        }
        guard let relayConfig = environment.relay else {
            configurePublisherAndGitHub()
            return
        }
        let clock = environment.clock
        do {
            let relay = try InteractionRelay(
                store: relayConfig.publishInteractions ? bridge : nil,
                baseURL: relayConfig.baseURL,
                mailbox: relayConfig.mailbox,
                macToken: relayConfig.macToken,
                deviceKeyHex: relayConfig.deviceKeyHex,
                transport: relayConfig.transport,
                publishInteractions: relayConfig.publishInteractions,
                publishAgentStatus: relayConfig.publishAgentStatus,
                statusSource: relayConfig.publishAgentStatus ? { [weak self] in
                    guard let self else { throw RelayAdapterError(message: "stopped") }
                    return self.agentPayload(includePending: false).canonical()
                } : nil,
                now: { clock.monotonic() },
                wall: { clock.wall() }
            )
            self.relay = relay
            if relayConfig.publishInteractions {
                relayStatus = "ready"
                relayReason = nil
            }
            if relayConfig.publishAgentStatus {
                agentRelayStatus = "ready"
                agentRelayReason = nil
            }
        } catch {
            if relayConfig.publishInteractions {
                relayStatus = "disabled"
                relayReason = String(describing: error)
            }
            if relayConfig.publishAgentStatus {
                agentRelayStatus = "disabled"
                agentRelayReason = String(describing: error)
            }
        }
        configurePublisherAndGitHub()
    }

    private func configurePublisherAndGitHub() {
        let clock = environment.clock
        if let url = environment.publishURL, let post = environment.publishPost {
            publisher = NumbersPublisher(
                relayURL: url,
                machine: environment.publishMachine,
                producers: [
                    ("/api/tokens", { [weak self] in
                        guard let self else { throw JSONEncodeError.tooDeep }
                        self.publishPeaks(from: self.currentTokens())
                        return self.currentTokens().canonical()
                    }),
                    ("/api/max-tracker", { [weak self] in
                        guard let self else { throw JSONEncodeError.tooDeep }
                        return self.maxTrackerPayload().canonical()
                    }),
                    ("/api/github", { [weak self] in
                        guard let self else { throw JSONEncodeError.tooDeep }
                        return self.githubPayload().canonical()
                    }),
                ],
                post: post,
                clock: { clock.wall() }
            )
        }
        if let repo = environment.githubRepo, let transport = environment.githubTransport {
            githubMonitor = try? GitHubMonitor(
                repo: repo,
                token: environment.githubToken,
                transport: transport,
                clock: { clock.monotonic() },
                wallClock: { clock.wall() }
            )
        }
    }

    private func startWorkers() {
        for worker in EngineWorker.allCases {
            let loop = WorkerLoop()
            loops[worker] = loop
            let task = Task { [weak self] in
                defer { loop.finish() }
                await self?.runLoop(worker)
            }
            loop.task = task
        }
    }

    private func runLoop(_ worker: EngineWorker) async {
        setRunning(worker, true)
        defer { setRunning(worker, false) }
        if worker == .agentStatus, environment.automaticWorkers {
            let interval = cadence(.agentStatus)
            let service = agentStatus
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    service.pollOnceLoop(interval: interval)
                    continuation.resume()
                }
            }
            return
        }
        while !Task.isCancelled {
            if shouldRun(worker) {
                runWorker(worker)
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                break
            }
        }
    }

    private func setRunning(_ worker: EngineWorker, _ running: Bool) {
        lock.lock()
        if running {
            runningWorkers.insert(worker)
        } else {
            runningWorkers.remove(worker)
        }
        lock.unlock()
    }

    func runningWorkersNow() -> Set<EngineWorker> {
        lock.lock()
        defer { lock.unlock() }
        return runningWorkers
    }

    func workerRunCount(_ worker: EngineWorker) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return workerRuns[worker] ?? 0
    }

    private func shouldRun(_ worker: EngineWorker) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed && environment.automaticWorkers && isDueLocked(worker)
    }

    private func isDueLocked(_ worker: EngineWorker) -> Bool {
        let now = environment.clock.monotonic()
        guard let previous = lastRun[worker] else { return true }
        return now - previous >= cadence(worker)
    }

    private func cadence(_ worker: EngineWorker) -> TimeInterval {
        switch worker {
        case .transcript: return 30
        case .claudeProbe: return claudeProbe.interval
        case .codexProbe: return codexProbe.interval
        case .subscriptions: return 1
        case .agentStatus: return 0.5
        case .maxTrackerBackfill: return 0.5
        case .publisher: return NumbersPublish.checkEvery
        case .interactionRelay: return InteractionRelayLimits.pollInterval
        case .github: return githubMonitor?.pollSeconds ?? GitHubMonitor.pollSeconds
        }
    }

    private func join(_ worker: EngineWorker, timeout: TimeInterval) {
        guard let loop = loops.removeValue(forKey: worker) else { return }
        loop.task?.cancel()
        loop.wait(timeout)
    }

    func runWorker(_ worker: EngineWorker) {
        do {
            try runWorkerBody(worker)
            lock.lock()
            workerRuns[worker, default: 0] += 1
            lastRun[worker] = environment.clock.monotonic()
            lock.unlock()
        } catch {
            lock.lock()
            workerErrors[worker] = "\(type(of: error)): \(error)"
            workerRuns[worker, default: 0] += 1
            lastRun[worker] = environment.clock.monotonic()
            if worker == .transcript, computeFailingSince == nil {
                computeFailingSince = environment.clock.monotonic()
            }
            lock.unlock()
            if worker == .transcript {
                rebuildSnapshot()
            }
        }
    }

    private func runWorkerBody(_ worker: EngineWorker) throws {
        switch worker {
        case .transcript:
            try scanTranscript()
            rebuildSnapshot()
        case .claudeProbe:
            _ = claudeProbe.run(
                candidates: environment.claudeCandidates(),
                keychainReason: environment.keychainReason,
                now: environment.clock.wall(),
                monotonic: environment.clock.monotonic()
            )
            rebuildSnapshot()
        case .codexProbe:
            let wall = environment.clock.wall()
            let mono = environment.clock.monotonic()
            let reading = codexProbe.run(now: wall, monotonic: mono)
            if let limits = reading.limits {
                codexQuota = limits
            }
            rebuildSnapshot()
        case .subscriptions:
            let mono = environment.clock.monotonic()
            let wall = environment.clock.wall()
            grokProbe.kick(monotonic: mono, wall: wall)
            cursorProbe.kick(monotonic: mono, wall: wall)
            rebuildSnapshot()
        case .agentStatus:
            _ = agentStatus.pollOnce()
        case .maxTrackerBackfill:
            if maxTracker.backfillStep() {
                maxTrackerDirty = true
                try maxTracker.save(today: localDay(environment.clock.wall()))
                maxTrackerDirty = false
                maxTrackerSaveFailingSince = nil
            }
        case .publisher:
            _ = publisher?.publishOnce()
        case .interactionRelay:
            relay?.runOnce()
        case .github:
            guard let githubMonitor else { return }
            if environment.clock.monotonic() >= githubMonitor.nextPollAt {
                _ = githubMonitor.pollOnce()
            }
        }
    }

    private func scanTranscript() throws {
        if let transcriptOverride = environment.transcriptOverride {
            transcript = try transcriptOverride()
            haveScan = true
            lastResultAt = environment.clock.monotonic()
            computeFailingSince = nil
            return
        }
        transcript = scanner.compute(
            projectsDirectory: environment.projectsDirectory,
            now: Date(timeIntervalSince1970: environment.clock.wall())
        )
        haveScan = true
        lastResultAt = environment.clock.monotonic()
        computeFailingSince = nil
    }

    func currentTokens() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    /// Menu reads skip this. `GET /api/tokens` and the numbers publisher do not.
    func publishPeaks(from snapshot: JSONValue) {
        guard let fields = snapshot.object else { return }
        let now = environment.clock.wall()
        if let pct = fields["claudeSessionPct"]?.number {
            maxTracker.observeQuota(provider: "claude", windowMinutes: 300, pct: pct, timestamp: now)
            maxTrackerDirty = true
        }
        if let pct = fields["claudeWeekPct"]?.number, fields["claudeWeekStale"] == .bool(false) {
            maxTracker.observeQuota(provider: "claude", windowMinutes: 10_080, pct: pct, timestamp: now)
            maxTrackerDirty = true
        }
        if let pct = fields["codexSessionPct"]?.number, let window = codexQuota.codexSessionWindowMinutes, window > 0 {
            maxTracker.observeQuota(provider: "codex", windowMinutes: window, pct: pct, timestamp: now)
            maxTrackerDirty = true
        }
        if let pct = fields["codexWeekPct"]?.number, fields["codexWeekStale"] == .bool(false),
           let window = codexQuota.codexWeekWindowMinutes, window > 0 {
            maxTracker.observeQuota(provider: "codex", windowMinutes: window, pct: pct, timestamp: now)
            maxTrackerDirty = true
        }
    }

    func rebuildSnapshot() {
        let now = environment.clock.wall()
        let mono = environment.clock.monotonic()
        var pairs: [(String, JSONValue)] = [("v", .int(2))]
        let scan = transcript
        let measured = haveScan && scan != nil
        if let scan, measured {
            pairs.append(("dayTokens", .int(scan.dayTokens)))
            pairs.append(("dayTokensPerHour", .int(scan.dayTokensPerHour)))
            pairs.append(("daySessions", .int(scan.daySessions)))
            pairs.append(("monthTokens", .int(scan.monthTokens)))
            pairs.append(("claudeSourcePresent", .bool(scan.claudeSourcePresent)))
        } else {
            let present = directoryExists(environment.projectsDirectory)
            pairs.append(("dayTokens", .int(0)))
            pairs.append(("dayTokensPerHour", .int(0)))
            pairs.append(("daySessions", .int(0)))
            pairs.append(("monthTokens", .int(0)))
            pairs.append(("claudeSourcePresent", .bool(present)))
        }
        if let table = environment.priceTable {
            let payload = buildPayload(
                valueUSD: scan?.monthUSD ?? 0,
                unpricedTokens: scan?.unpricedTokens ?? 0,
                pricedTokens: scan?.pricedTokens ?? 0,
                claudePlan: environment.plans["claude"],
                codexPlan: environment.plans["codex"],
                planCosts: environment.planCosts,
                table: table,
                claudeUSD: scan?.monthUSD ?? 0,
                codexUSD: 0
            )
            let valuePairs = payload.keys.map { key in
                (key, JSONValue.from(strict: payload.fields[key] ?? .null))
            }
            pairs.append(("value", .object(valuePairs)))
        }
        pairs.append(("at", .string(localTimestamp(now))))

        let limits = claudeProbe.limits
        let session = sessionWire(limits: limits, now: now)
        pairs.append(("claudeSessionPct", session.pct))
        pairs.append(("claudeSessionResetMin", session.resetMin))
        if session.live, let pct = session.pct.number, let resetAt = session.resetAt {
            recordQuota(provider: "claude", scope: "general_session", window: "session", pct: pct, resetAt: Double(resetAt), label: nil, now: now)
        }

        let week = weeklyWire(pct: limits?.weekPct, resetAt: limits?.weekResetAt, provider: "claude", scope: "general_weekly", window: "week", label: nil, now: now)
        pairs.append(("claudeWeekPct", week.pct))
        pairs.append(("claudeWeekResetMin", week.resetMin))
        pairs.append(("claudeWeekObservedAt", week.observedAt))
        pairs.append(("claudeWeekStale", .bool(week.stale)))
        let model = weeklyWire(pct: limits?.modelPct, resetAt: limits?.modelResetAt, provider: "claude", scope: "model_weekly", window: "model_week", label: limits?.modelLabel, now: now)
        pairs.append(("claudeModelWeekPct", model.pct))
        pairs.append(("claudeModelWeekResetMin", model.resetMin))
        pairs.append(("claudeModelWeekObservedAt", model.observedAt))
        pairs.append(("claudeModelWeekLabel", model.label))
        pairs.append(("claudeModelWeekStale", .bool(model.stale)))

        let codex = codexQuota
        if let pct = codex.codexSessionPct, let reset = codex.codexSessionResetMin, reset > 0 {
            pairs.append(("codexSessionPct", .double(pct)))
            pairs.append(("codexSessionResetMin", .int(reset)))
        } else {
            pairs.append(("codexSessionPct", .null))
            pairs.append(("codexSessionResetMin", .null))
        }
        let codexWeek = weeklyWire(
            pct: codex.codexWeekPct, resetAt: codex.codexWeekResetAt,
            provider: "codex", scope: "general_weekly", window: "week",
            label: nil, now: now, observedOverride: codex.codexWeekObservedAt
        )
        pairs.append(("codexWeekPct", codexWeek.pct))
        pairs.append(("codexWeekResetMin", codexWeek.resetMin))
        pairs.append(("codexWeekObservedAt", codexWeek.observedAt))
        pairs.append(("codexWeekStale", .bool(codexWeek.stale)))

        pairs.append(("claudeWeekTodayDeltaPct", delta("claude", "week", resetAt: week.resetAt, now: now)))
        pairs.append(("claudeModelWeekTodayDeltaPct", delta("claude", "model_week", resetAt: model.resetAt, now: now)))
        pairs.append(("claudeSessionHourDeltaPct", hourDelta(resetAt: session.resetAt, now: now)))
        pairs.append(("codexWeekTodayDeltaPct", delta("codex", "week", resetAt: codexWeek.resetAt, now: now)))
        appendForecast(&pairs, prefix: "claude", resetAt: week.resetAt, now: now)
        appendForecast(&pairs, prefix: "codex", resetAt: codexWeek.resetAt, now: now)
        pairs.append(("otaAvailableVersion", .null))
        appendSubscription(&pairs, now: now)
        pairs.append(("usageTotals", usageTotals(measured: measured, mono: mono)))
        lock.lock()
        tokens = .object(pairs)
        lock.unlock()
    }

    private func usageTotals(measured: Bool, mono: TimeInterval) -> JSONValue {
        let failing = computeFailingSince != nil
        if !measured {
            let since = Int((mono - startedMono).rounded(.towardZero))
            return .object([
                ("state", .string(failing ? "failing" : "refreshing")),
                ("sinceS", .int(max(0, since))),
                ("placeholder", .bool(true)),
            ])
        }
        let age: JSONValue
        if let lastResultAt {
            age = .int(Int((mono - lastResultAt).rounded(.towardZero)))
        } else {
            age = .null
        }
        return .object([
            ("state", .string(failing ? "failing" : "ready")),
            ("ageS", age),
            ("placeholder", .bool(false)),
        ])
    }

    private struct SessionWire {
        var pct: JSONValue
        var resetMin: JSONValue
        var resetAt: Int?
        var live: Bool
    }

    private func sessionWire(limits: ClaudeUsageLimits?, now: TimeInterval) -> SessionWire {
        guard let limits, let pct = limits.sessionPct, let resetAt = limits.sessionResetAt else {
            return SessionWire(pct: .null, resetMin: .null, resetAt: nil, live: false)
        }
        guard let minutes = resetMinutes(resetAt, now: now) else {
            return SessionWire(pct: .null, resetMin: .null, resetAt: nil, live: false)
        }
        return SessionWire(pct: .double(pct), resetMin: .int(minutes), resetAt: resetAt, live: true)
    }

    private struct WeekWire {
        var pct: JSONValue
        var resetMin: JSONValue
        var observedAt: JSONValue
        var label: JSONValue
        var stale: Bool
        var resetAt: Int?
        var live: Bool
    }

    private func weeklyWire(pct: Double?, resetAt: Int?, provider: String, scope: String, window: String,
                            label: String?, now: TimeInterval, observedOverride: Int? = nil) -> WeekWire {
        if let pct, let resetAt, let minutes = resetMinutes(resetAt, now: now) {
            let observed = observedOverride ?? Int(now.rounded(.towardZero))
            recordQuota(provider: provider, scope: scope, window: window, pct: pct, resetAt: Double(resetAt), label: label, now: now)
            return WeekWire(
                pct: .double(pct),
                resetMin: .int(minutes),
                observedAt: .int(observed),
                label: label.map(JSONValue.string) ?? .null,
                stale: false,
                resetAt: resetAt,
                live: true
            )
        }
        if let cached = cache.latest(provider: provider, scope: scope, now: now) {
            let minutes = resetMinutes(cached.resetAt, now: now)
            return WeekWire(
                pct: .double(cached.pct),
                resetMin: minutes.map(JSONValue.int) ?? .null,
                observedAt: .int(cached.observedAt),
                label: cached.label.map(JSONValue.string) ?? .null,
                stale: true,
                resetAt: cached.resetAt,
                live: false
            )
        }
        return WeekWire(pct: .null, resetMin: .null, observedAt: .null, label: label.map(JSONValue.string) ?? .null, stale: false, resetAt: nil, live: false)
    }

    private func recordQuota(provider: String, scope: String, window: String, pct: Double, resetAt: Double, label: String?, now: TimeInterval) {
        let identity = StateFiles.quotaIdentity(provider: provider, scope: scope)
        _ = cache.put(CachedQuota(
            provider: provider, scope: scope, identity: identity, pct: pct,
            resetAt: Int(resetAt.rounded(.towardZero)), observedAt: Int(now.rounded(.towardZero)), label: label
        ))
        _ = history.record(provider: provider, window: window, pct: pct, resetAt: resetAt, at: now)
    }

    private func resetMinutes(_ resetAt: Int, now: TimeInterval) -> Int? {
        let delta = Double(resetAt) - now
        guard delta > 0 else { return nil }
        return Int(delta / 60)
    }

    private func dayStart(_ now: TimeInterval) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = Date(timeIntervalSince1970: now)
        let start = calendar.startOfDay(for: date)
        return start.timeIntervalSince1970
    }

    private func delta(_ provider: String, _ window: String, resetAt: Int?, now: TimeInterval) -> JSONValue {
        guard let resetAt else { return .null }
        guard let value = history.deltaSince(provider: provider, window: window, since: dayStart(now), resetAt: Double(resetAt), now: now) else {
            return .null
        }
        return .double(value)
    }

    private func hourDelta(resetAt: Int?, now: TimeInterval) -> JSONValue {
        guard let resetAt else { return .null }
        guard let value = history.deltaSince(provider: "claude", window: "session", since: now - 3600, resetAt: Double(resetAt), now: now) else {
            return .null
        }
        return .double(value)
    }

    private func appendForecast(_ pairs: inout [(String, JSONValue)], prefix: String, resetAt: Int?, now: TimeInterval) {
        let forecast: Forecast
        if let resetAt {
            forecast = history.forecast(provider: prefix, window: "week", resetAt: Double(resetAt), now: now)
        } else {
            forecast = Forecast(state: "unavailable")
        }
        pairs.append(("\(prefix)ForecastState", .string(forecast.state)))
        pairs.append(("\(prefix)ForecastPctAtReset", forecast.pctAtReset.map(JSONValue.int) ?? .null))
        pairs.append(("\(prefix)ForecastPaceFactor", forecast.paceFactor.map(JSONValue.double) ?? .null))
        pairs.append(("\(prefix)ForecastAt", forecast.exhaustsAt.map(JSONValue.int) ?? .null))
        pairs.append(("\(prefix)ForecastOffsetMin", forecast.offsetMinutes.map(JSONValue.int) ?? .null))
    }

    private func appendSubscription(_ pairs: inout [(String, JSONValue)], now: TimeInterval) {
        let grok = grokProbe.grokFields(at: now)
        pairs.append(("grokCreditPct", grok.grokCreditPct.map(JSONValue.double) ?? .null))
        pairs.append(("grokCreditResetMin", grok.grokCreditResetMin.map(JSONValue.int) ?? .null))
        pairs.append(("grokCreditStale", .bool(grok.grokCreditStale)))
        pairs.append(("grokQuotaLabel", grok.grokQuotaLabel.map(JSONValue.string) ?? .null))
        let cursor = cursorProbe.cursorFields(at: now)
        pairs.append(("cursorTotalPct", cursor.cursorTotalPct.map(JSONValue.double) ?? .null))
        pairs.append(("cursorTotalResetMin", cursor.cursorTotalResetMin.map(JSONValue.int) ?? .null))
        pairs.append(("cursorTotalStale", .bool(cursor.cursorTotalStale)))
        pairs.append(("cursorModelsPct", cursor.cursorModelsPct.map(JSONValue.double) ?? .null))
        pairs.append(("cursorModelsResetMin", cursor.cursorModelsResetMin.map(JSONValue.int) ?? .null))
        pairs.append(("cursorModelsStale", .bool(cursor.cursorModelsStale)))
        pairs.append(("cursorThirdPct", cursor.cursorThirdPct.map(JSONValue.double) ?? .null))
        pairs.append(("cursorThirdResetMin", cursor.cursorThirdResetMin.map(JSONValue.int) ?? .null))
        pairs.append(("cursorThirdStale", .bool(cursor.cursorThirdStale)))
        pairs.append(("cursorBotPct", cursor.cursorBotPct.map(JSONValue.double) ?? .null))
        pairs.append(("cursorBotResetMin", cursor.cursorBotResetMin.map(JSONValue.int) ?? .null))
        pairs.append(("cursorBotStale", .bool(cursor.cursorBotStale)))
    }

    func localDay(_ epoch: TimeInterval) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: epoch))
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    private func localTimestamp(_ epoch: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func canBind(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

private final class EngineBox: @unchecked Sendable {
    weak var engine: VibePulseEngine?
}

private final class WorkerLoop: @unchecked Sendable {
    var task: Task<Void, Never>?
    private let gate = DispatchSemaphore(value: 0)
    func finish() { gate.signal() }
    func wait(_ timeout: TimeInterval) {
        _ = gate.wait(timeout: .now() + timeout)
    }
}

struct PanelMemory {
    var candidateHost: String?
    var candidateAt: TimeInterval?
    var candidateCount = 0
    var lastSeenAt: TimeInterval?
    var lastSeenRoute: String?
    var recoveryBoot = false
}

private struct RefusingQuotaTransport: QuotaHTTPTransport {
    func send(_ request: QuotaHTTPRequest) throws -> QuotaHTTPResponse {
        throw RefusingQuotaError(url: request.url)
    }
}

private struct RefusingQuotaError: Error, CustomStringConvertible {
    var url: String
    var description: String { "refusing network fetch \(url)" }
}

enum PortOwner {
    static func lookup(_ port: Int) -> (pid: Int32?, command: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp", "-Fc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (nil, nil)
        }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return (nil, nil)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
        var pid: Int32?
        var command: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil, let value = Int32(line.dropFirst()) {
                pid = value
            } else if line.hasPrefix("c"), command == nil {
                command = String(line.dropFirst())
            }
        }
        return (pid, command)
    }
}
