import Foundation
import Observation

/// Quota and agent data, polled from the tokenserver while one is serving.
///
/// Cadence follows the panel's: quotas every 30 s, faster only while the
/// menu is open. The service's own upstream probes are cadence-gated, so a
/// read here never adds a request to Claude, Codex, Grok or Cursor. Failures
/// back off, and the last good values stay visible, marked by their age:
/// never replaced by zeros.
@MainActor
@Observable
public final class MonitorStore {
    public struct Cadence: Sendable {
        public var tokens: TimeInterval = 30
        public var tokensMenuOpen: TimeInterval = 10
        public var agents: TimeInterval = 5
        public var agentsMenuOpen: TimeInterval = 2
        public var maximumBackoff: TimeInterval = 120
        public var tick: TimeInterval = 1

        public init() {}
    }

    public private(set) var tokens: TokensSnapshot?
    public private(set) var tokensFetchedAt: Date?
    public private(set) var tokensError: String?
    public private(set) var agents: AgentStatusSnapshot?
    public private(set) var agentsFetchedAt: Date?
    public private(set) var agentsError: String?

    public var isMenuVisible = false {
        didSet {
            guard self.isMenuVisible, !oldValue else { return }
            self.nextTokensAt = .distantPast
            self.nextAgentsAt = .distantPast
        }
    }

    private let supervisor: ServiceSupervisor
    private let cadence: Cadence
    private var loop: Task<Void, Never>?
    private var nextTokensAt = Date.distantPast
    private var nextAgentsAt = Date.distantPast
    private var tokensFailures = 0
    private var agentsFailures = 0
    private var tokensInFlight = false
    private var agentsInFlight = false

    public init(supervisor: ServiceSupervisor, cadence: Cadence = Cadence()) {
        self.supervisor = supervisor
        self.cadence = cadence
    }

    public func start() {
        guard self.loop == nil else { return }
        self.loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick(now: Date())
                try? await Task.sleep(nanoseconds: UInt64(self.cadence.tick * 1_000_000_000))
            }
        }
    }

    public func stop() {
        self.loop?.cancel()
        self.loop = nil
    }

    /// Fetch everything on the next tick, e.g. right after a (re)start.
    public func refreshNow() {
        self.nextTokensAt = .distantPast
        self.nextAgentsAt = .distantPast
        self.tick(now: Date())
    }

    public func usage(for provider: Provider) -> ProviderUsage {
        ProviderUsage.build(provider, from: self.tokens)
    }

    public var allUsage: [ProviderUsage] {
        Provider.allCases.map(self.usage(for:))
    }

    /// The last quota read is too old to call current (the panel's own
    /// CACHED threshold is two minutes).
    public func tokensAreStale(now: Date = Date()) -> Bool {
        guard let fetched = self.tokensFetchedAt else { return true }
        return now.timeIntervalSince(fetched) > 120 || !self.supervisor.isServing
    }

    public func agentsAreStale(now: Date = Date()) -> Bool {
        guard let fetched = self.agentsFetchedAt else { return true }
        return now.timeIntervalSince(fetched) > 30 || !self.supervisor.isServing
    }

    /// Job state is only trustworthy while fresh; a stale "waiting" must not
    /// keep claiming the user's attention (lesson 2026-08-13).
    public func liveAgents(now: Date = Date()) -> AgentStatusSnapshot? {
        self.agentsAreStale(now: now) ? nil : self.agents
    }

    private func tick(now: Date) {
        guard self.supervisor.isServing else { return }
        let client = self.supervisor.client
        if now >= self.nextTokensAt, !self.tokensInFlight {
            self.tokensInFlight = true
            Task { [weak self] in
                let result: Result<TokensSnapshot, Error>
                do { result = .success(try await client.tokens()) } catch { result = .failure(error) }
                self?.finishTokens(result)
            }
        }
        if now >= self.nextAgentsAt, !self.agentsInFlight {
            self.agentsInFlight = true
            Task { [weak self] in
                let result: Result<AgentStatusSnapshot, Error>
                do { result = .success(try await client.agentStatus()) } catch { result = .failure(error) }
                self?.finishAgents(result)
            }
        }
    }

    private func finishTokens(_ result: Result<TokensSnapshot, Error>) {
        self.tokensInFlight = false
        let base = self.isMenuVisible ? self.cadence.tokensMenuOpen : self.cadence.tokens
        switch result {
        case let .success(snapshot):
            self.tokens = snapshot
            self.tokensFetchedAt = Date()
            self.tokensError = nil
            self.tokensFailures = 0
            self.nextTokensAt = Date().addingTimeInterval(base)
        case let .failure(error):
            self.tokensFailures += 1
            self.tokensError = error.localizedDescription
            self.nextTokensAt = Date().addingTimeInterval(self.backoff(base, failures: self.tokensFailures))
        }
    }

    private func finishAgents(_ result: Result<AgentStatusSnapshot, Error>) {
        self.agentsInFlight = false
        let base = self.isMenuVisible ? self.cadence.agentsMenuOpen : self.cadence.agents
        switch result {
        case let .success(snapshot):
            self.agents = snapshot
            self.agentsFetchedAt = Date()
            self.agentsError = nil
            self.agentsFailures = 0
            self.nextAgentsAt = Date().addingTimeInterval(base)
        case let .failure(error):
            self.agentsFailures += 1
            self.agentsError = error.localizedDescription
            self.nextAgentsAt = Date().addingTimeInterval(self.backoff(base, failures: self.agentsFailures))
        }
    }

    private func backoff(_ base: TimeInterval, failures: Int) -> TimeInterval {
        min(self.cadence.maximumBackoff, base * pow(2, Double(min(failures, 8))))
    }
}
