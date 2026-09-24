import AppKit
import Observation
import ServiceManagement
import VibePulseBarCore
import VibePulseServer
import VibePulseState

/// Everything one render of the menu needs, as values. The live app reads
/// the engine's snapshot; the preview renderer uses fixtures.
struct DashboardSnapshot {
    var service: ServiceSnapshot
    var tokens: TokensSnapshot?
    var tokensFetchedAt: Date?
    var tokensStale: Bool
    var agents: AgentStatusSnapshot?
    var agentsFetchedAt: Date?
    var usageDisplay: UsageDisplay

    func usage(_ provider: Provider) -> ProviderUsage {
        ProviderUsage.build(provider, from: self.tokens)
    }

    func agents(_ provider: Provider) -> ProviderAgents? {
        self.agents?.agents(for: provider)
    }
}

struct Preferences: Codable, Equatable {
    var startServiceOnLaunch = true
    var usageDisplay: UsageDisplay = .used
    /// `nil` picks the most constrained provider for the menu bar icon.
    var iconProvider: Provider?
}

enum ConfigurationSource: String {
    case saved = "Saved in VibePulse Bar"
    case standard = "Default"
}

@MainActor
@Observable
final class AppModel {
    let engineHost: LiveMenuEngine
    var engine: VibePulseEngine { self.engineHost.engine }
    let session: EngineSession
    var selectedTab: MenuTab = .overview
    private(set) var configurationSource: ConfigurationSource

    var preferences: Preferences {
        didSet {
            guard self.preferences != oldValue else { return }
            Self.save(self.preferences, key: Self.preferencesKey)
        }
    }

    var configuration: ServiceConfiguration {
        get { self.session.configuration }
        set {
            self.session.configuration = newValue
            self.engineHost.configuration = newValue
            self.configurationSource = .saved
            Self.save(newValue, key: Self.configurationKey)
        }
    }

    private static let preferencesKey = "preferences.v1"
    private static let configurationKey = "serviceConfiguration.v1"

    init() {
        let (configuration, source) = Self.initialConfiguration()
        self.configurationSource = source
        let preferences = Self.load(Preferences.self, key: Self.preferencesKey) ?? Preferences()
        let host = LiveMenuEngine(configuration: configuration)
        self.engineHost = host
        self.session = EngineSession(
            engine: host,
            configuration: configuration,
            launch: SystemLaunchControl(),
            signals: DarwinProcessSignals())
        self.preferences = preferences
    }

    func bootstrap() {
        Task { await self.session.bootstrap(startService: self.preferences.startServiceOnLaunch) }
    }

    func snapshot(now: Date = Date()) -> DashboardSnapshot {
        let service = self.session.serviceSnapshot
        let serving = service.isServing
        return DashboardSnapshot(
            service: service,
            tokens: serving ? MenuReading.tokens(self.engine.snapshot) : nil,
            tokensFetchedAt: serving ? now : nil,
            tokensStale: !serving,
            agents: serving ? MenuReading.agents(self.engine.agentJSON) : nil,
            agentsFetchedAt: serving ? now : nil,
            usageDisplay: .remaining)
    }

    func startService() {
        Task { await self.session.start() }
    }

    func pauseService() {
        Task { await self.session.pause() }
    }

    func restartService() {
        Task {
            if self.session.ownsEngine {
                await self.session.restart()
            } else {
                await self.session.start()
            }
        }
    }

    func takeOverExternal() {
        Task { await self.session.takeOverExternal() }
    }

    func takeOverLaunchAgent() {
        Task { await self.session.takeOverLaunchAgent() }
    }

    func handBackToLaunchAgent() {
        Task { await self.session.handBack() }
    }

    func openLog() {
        let url = URL(fileURLWithPath: self.configuration.logPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    func openDiagnostics() {
        guard self.session.ownsEngine, let port = self.session.boundPort,
              let url = URL(string: "http://127.0.0.1:\(port)/")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Quit stops the in-process engine. There is no child to reap.
    func shutdown() async {
        await self.session.shutdown()
    }

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    private static func initialConfiguration() -> (ServiceConfiguration, ConfigurationSource) {
        if let saved = self.load(ServiceConfiguration.self, key: self.configurationKey) {
            return (saved, .saved)
        }
        var configuration = ServiceConfiguration()
        if let repo = ProcessInfo.processInfo.environment["VIBEPULSE_GITHUB_REPO"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !repo.isEmpty {
            configuration.githubRepo = repo
        }
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibePulse/config.json")
        if let saved = try? VibePulseConfig.load(from: configURL) {
            configuration.relayURL = saved.interactionRelayURL ?? ""
            configuration.relayMailbox = saved.interactionMailbox ?? ""
            configuration.publishInteractions = saved.interactionRelay
            configuration.publishAgentStatus = saved.agentStatusRelay
        }
        return (configuration, .standard)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
