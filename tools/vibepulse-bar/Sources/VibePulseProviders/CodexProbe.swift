import Foundation

/// One read of the Codex probe for `GET /`.
/// `cooldownLeft` and `age` are nil when there is no rest, and when no cycle
/// has finished. A finished cycle may report age 0. Neither field uses 0
/// to mean "missing".
public struct CodexProbeView: Equatable {
    public var status: String
    public var streak: Int
    public var interval: Int
    public var cooldownLeft: Int?
    public var age: Int?

    public init(status: String, streak: Int, interval: Int, cooldownLeft: Int?, age: Int?) {
        self.status = status
        self.streak = streak
        self.interval = interval
        self.cooldownLeft = cooldownLeft
        self.age = age
    }
}

public struct CodexProbeResult: Equatable {
    /// Quota to publish. Nil until a cycle publishes one. An empty quota is a
    /// real clear: percents stay nil, they are not written as 0.
    public var limits: CodexQuota?
    public var view: CodexProbeView

    public init(limits: CodexQuota?, view: CodexProbeView) {
        self.limits = limits
        self.view = view
    }
}

/// One Codex usage cycle. The HTTP transport, the clock, and the file lock
/// are injected. `run` is the whole cycle a tick calls. Nothing here starts
/// a thread or opens a socket of its own.
///
/// A future `cooldown_until` makes no request. HTTP 429 rests for
/// `max(Retry-After, 600)` and is written to the probe-state file. A 429
/// does not fall through to the CLI. A missing, expired, or rejected
/// credential re-reads `auth.json` on the 15 s ladder and asks the injected
/// app-server, then `CodexLimitsSource.scan`, on the 240/480/960 s ladder.
public final class CodexProbe {
    public static let deadTokenCapacity = 8
    public static let rateLimitFloor: TimeInterval = 600
    public static let limitsEvery: TimeInterval = 240
    public static let authRecoveryEvery: TimeInterval = 15
    public static let stateFileName = "codex-probe-state.json"
    public static let lockFileName = "codex-probe.lock"

    public private(set) var status = "not_run"
    public private(set) var failureStreak = 0
    public private(set) var cooldownUntil: TimeInterval = 0
    public private(set) var authState = "unknown"
    public private(set) var limits: CodexQuota?

    private let transport: any QuotaHTTPTransport
    private let lockPath: URL
    private let statePath: URL
    private let authPath: URL
    private let configPath: URL
    private let sessionsDirectory: URL
    private let limitsSource: CodexLimitsSource
    private let appServer: (TimeInterval) throws -> CodexQuota
    private let acquireLock: (URL) -> ProbeFileLock?

    private var stateLoaded = false
    private var deadOrder: [String] = []
    private var deadReason: [String: String] = [:]
    private var lastRead: TimeInterval?
    private var lastCLI: TimeInterval?
    private var cliFailureStreak = 0

    public init(
        transport: any QuotaHTTPTransport,
        lockPath: URL,
        statePath: URL,
        authPath: URL,
        sessionsDirectory: URL,
        configPath: URL? = nil,
        limitsSource: CodexLimitsSource = CodexLimitsSource(),
        appServer: @escaping (TimeInterval) throws -> CodexQuota = { _ in CodexQuota() },
        acquireLock: @escaping (URL) -> ProbeFileLock? = ProbeFileLock.acquire
    ) {
        self.transport = transport
        self.lockPath = lockPath
        self.statePath = statePath
        self.authPath = authPath
        self.configPath = configPath ?? authPath.deletingLastPathComponent().appendingPathComponent("config.toml")
        self.sessionsDirectory = sessionsDirectory
        self.limitsSource = limitsSource
        self.appServer = appServer
        self.acquireLock = acquireLock
    }

    public var deadTokenCount: Int { deadOrder.count }

    public func isDead(_ token: String) -> Bool {
        deadReason[CodexOAuth.tokenFingerprint(token)] != nil
    }

    /// 15 s while the saved token cannot be used. Otherwise 240 s, then 480 s, then 960 s.
    public var interval: TimeInterval {
        if authState == "missing" || authState == "expired" || authState == "unauthorized" {
            return Self.authRecoveryEvery
        }
        let shift = min(max(failureStreak, 0), 2)
        return Self.limitsEvery * TimeInterval(1 << shift)
    }

    /// Does not probe. `age` is nil until `run` finishes once, even when the monotonic clock is 0.
    public func view(now: TimeInterval, monotonic: TimeInterval) -> CodexProbeView {
        let left = cooldownUntil - now
        let age: Int?
        if let lastRead {
            age = Int((monotonic - lastRead).rounded(.towardZero))
        } else {
            age = nil
        }
        return CodexProbeView(
            status: status,
            streak: failureStreak,
            interval: Int(interval.rounded(.towardZero)),
            cooldownLeft: left > 0 ? Int(ceil(left)) : nil,
            age: age
        )
    }

    /// One cycle. `now` is wall epoch seconds. `monotonic` is the cadence clock.
    /// The probe does not read either clock itself.
    public func run(now: TimeInterval, monotonic: TimeInterval) -> CodexProbeResult {
        loadStateIfNeeded(now: now)
        if now < cooldownUntil {
            failureStreak += 1
            lastRead = monotonic
            return snapshot(now: now, monotonic: monotonic)
        }
        do {
            apply(try cycle(now: now, monotonic: monotonic))
        } catch {
            status = "probe_crashed: \(String(describing: type(of: error)))"
            limits = CodexQuota()
            failureStreak += 1
        }
        lastRead = monotonic
        return snapshot(now: now, monotonic: monotonic)
    }

    private func loadStateIfNeeded(now: TimeInterval) {
        guard !stateLoaded else { return }
        stateLoaded = true
        guard let until = ProbeCooldownFile.load(statePath), until.isFinite, until > now else { return }
        cooldownUntil = until
        status = "usage_http_429 + backoff_until_\(ProbeClock.hhmm(until)) (persisted)"
    }

    private func cycle(now: TimeInterval, monotonic: TimeInterval) throws -> Cycle {
        switch readOAuth(now: now) {
        case .ok(let quota):
            return Cycle(
                publish: .replace(quota),
                status: "usage_http_200 + ok",
                auth: "ready",
                streak: .reset,
                cooldown: 0
            )
        case .rateLimited(let retry):
            let until = now + Double(max(retry, Int(Self.rateLimitFloor)))
            ProbeCooldownFile.save(until, to: statePath)
            return Cycle(
                publish: .replace(CodexQuota()),
                status: "usage_http_429 + backoff_until_\(ProbeClock.hhmm(until))",
                auth: "ready",
                streak: .increment,
                cooldown: until
            )
        case .unmapped:
            return Cycle(
                publish: .replace(CodexQuota()),
                status: "usage_http_200 + no_mapped_limits",
                auth: "ready",
                streak: .increment,
                cooldown: nil
            )
        case .transport:
            return Cycle(
                publish: .replace(CodexQuota()),
                status: "usage_request_failed",
                auth: "ready",
                streak: .increment,
                cooldown: nil
            )
        case .held:
            return Cycle(
                publish: .keep,
                status: "probe_held_by_other_instance",
                auth: nil,
                streak: .increment,
                cooldown: nil
            )
        case .idle(let name):
            return try idleCycle(name, now: now, monotonic: monotonic)
        }
    }

    private func idleCycle(_ name: String, now: TimeInterval, monotonic: TimeInterval) throws -> Cycle {
        var due = true
        if let lastCLI, monotonic - lastCLI < cliInterval {
            due = false
        }
        if name == "unauthorized" && authState != "unauthorized" {
            due = true
        }
        if !due {
            return Cycle(publish: .keep, status: nil, auth: name, streak: .leave, cooldown: nil)
        }
        authState = name
        let found = try cliFallback(now: now)
        lastCLI = monotonic
        if Self.hasReading(found) {
            cliFailureStreak = 0
            return Cycle(publish: .replace(found), status: "cli", auth: name, streak: .reset, cooldown: nil)
        }
        cliFailureStreak += 1
        return Cycle(
            publish: .replace(CodexQuota()),
            status: "\(Self.idleWord(name)); cli_empty",
            auth: name,
            streak: .increment,
            cooldown: nil
        )
    }

    private func cliFallback(now: TimeInterval) throws -> CodexQuota {
        let quoted = try appServer(now)
        if Self.hasReading(quoted) { return quoted }
        return limitsSource.scan(sessionsDirectory: sessionsDirectory, now: now)
    }

    private func readOAuth(now: TimeInterval) -> Read {
        let auth = CodexOAuth.loadAuth(path: authPath, now: now)
        if auth.status == "expired" { return .idle("expired") }
        guard auth.status == "ready", let token = auth.accessToken else { return .idle("missing") }
        let fingerprint = CodexOAuth.tokenFingerprint(token)
        if deadReason[fingerprint] != nil { return .idle("unauthorized") }
        guard let url = usageURL() else { return .transport }
        guard let lock = acquireLock(lockPath) else { return .held }
        defer { lock.release() }
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": "vibepulse",
        ]
        if let account = auth.accountID {
            headers["ChatGPT-Account-Id"] = account
        }
        let response: QuotaHTTPResponse
        do {
            response = try transport.send(QuotaHTTPRequest(url: url, method: "GET", headers: headers, timeout: 15))
        } catch {
            return .transport
        }
        if response.status == 429 {
            return .rateLimited(RetryAfter.seconds(response.header("Retry-After"), now: now))
        }
        if response.status == 401 || response.status == 403 {
            rememberDead(fingerprint, code: response.status)
            return .idle("unauthorized")
        }
        guard (200..<300).contains(response.status) else { return .transport }
        switch Self.classify(response.body) {
        case .invalid:
            return .transport
        case .notObject:
            return .unmapped
        case .object:
            break
        }
        guard let mapped = CodexOAuth.appServerBody(response.body) else { return .unmapped }
        let observed = Int(exactly: now.rounded(.towardZero)) ?? 0
        let found = CodexOAuth.parse(appServer: mapped, observedAt: observed, now: now)
        guard Self.hasReading(found) else { return .unmapped }
        return .ok(found)
    }

    private func usageURL() -> String? {
        CodexOAuth.usageURL(base: configuredBase())
    }

    /// Missing, unreadable, or oversized config keeps the default usage URL.
    /// A parsed base that `usageURL` rejects becomes nil, which is transport.
    private func configuredBase() -> String? {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        guard let size = (try? configPath.resourceValues(forKeys: keys))?.fileSize,
              size <= CodexOAuth.maxAuthBytes else { return nil }
        guard let text = try? String(contentsOf: configPath, encoding: .utf8) else { return nil }
        return CodexOAuth.baseURL(fromConfig: text)
    }

    private func rememberDead(_ fingerprint: String, code: Int) {
        if deadReason[fingerprint] == nil {
            deadOrder.append(fingerprint)
        }
        deadReason[fingerprint] = "http_\(code)"
        while deadOrder.count > Self.deadTokenCapacity {
            let oldest = deadOrder.removeFirst()
            deadReason.removeValue(forKey: oldest)
        }
    }

    private func apply(_ cycle: Cycle) {
        if let cooldown = cycle.cooldown { cooldownUntil = cooldown }
        if case .replace(let quota) = cycle.publish { limits = quota }
        if let auth = cycle.auth { authState = auth }
        switch cycle.streak {
        case .leave: break
        case .increment: failureStreak += 1
        case .reset: failureStreak = 0
        }
        if let status = cycle.status { self.status = status }
    }

    private func snapshot(now: TimeInterval, monotonic: TimeInterval) -> CodexProbeResult {
        CodexProbeResult(limits: limits, view: view(now: now, monotonic: monotonic))
    }

    private var cliInterval: TimeInterval {
        let shift = min(max(cliFailureStreak, 0), 2)
        return Self.limitsEvery * TimeInterval(1 << shift)
    }

    private static func hasReading(_ quota: CodexQuota) -> Bool {
        quota.codexWeekPct != nil || quota.codexSessionPct != nil
    }

    private static func idleWord(_ auth: String) -> String {
        switch auth {
        case "expired": return "token_expired"
        case "unauthorized": return "token_dead_awaiting_refresh"
        default: return "no_codex_oauth_token"
        }
    }

    private static func classify(_ data: Data) -> BodyDecode {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .invalid
        }
        return value is [String: Any] ? .object : .notObject
    }

    private struct Cycle {
        var publish: Publish
        var status: String?
        var auth: String?
        var streak: StreakMove
        var cooldown: TimeInterval?
    }

    private enum Publish {
        case keep
        case replace(CodexQuota)
    }

    private enum StreakMove {
        case leave
        case increment
        case reset
    }

    private enum Read {
        case ok(CodexQuota)
        case rateLimited(Int)
        case unmapped
        case transport
        case held
        case idle(String)
    }

    private enum BodyDecode {
        case invalid
        case notObject
        case object
    }
}
