import AppKit
import Observation
import ServiceManagement
import VibePulseBarCore

/// Everything one render of the menu needs, as values. The live app builds
/// it from the supervisor and store; the preview renderer from fixtures.
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
    var autoRestart = true
    var usageDisplay: UsageDisplay = .used
    /// `nil` picks the most constrained provider for the menu bar icon.
    var iconProvider: Provider?
}

enum ConfigurationSource: String {
    case saved = "Saved in VibePulse Bar"
    case launchAgent = "Imported from the LaunchAgent"
    case repository = "This checkout"
    case none = "Not configured"
}

@MainActor
@Observable
final class AppModel {
    let supervisor: ServiceSupervisor
    let store: MonitorStore
    var selectedTab: MenuTab = .overview
    private(set) var configurationSource: ConfigurationSource

    var preferences: Preferences {
        didSet {
            guard self.preferences != oldValue else { return }
            self.supervisor.autoRestart = self.preferences.autoRestart
            Self.save(self.preferences, key: Self.preferencesKey)
        }
    }

    var configuration: ServiceConfiguration {
        get { self.supervisor.configuration }
        set {
            self.supervisor.configuration = newValue
            self.configurationSource = .saved
            Self.save(newValue, key: Self.configurationKey)
        }
    }

    var isMenuVisible = false {
        didSet {
            self.supervisor.isMenuVisible = self.isMenuVisible
            self.store.isMenuVisible = self.isMenuVisible
        }
    }

    private static let preferencesKey = "preferences.v1"
    private static let configurationKey = "serviceConfiguration.v1"

    init() {
        let (configuration, source) = Self.initialConfiguration()
        self.configurationSource = source
        let preferences = Self.load(Preferences.self, key: Self.preferencesKey) ?? Preferences()
        let supervisor = ServiceSupervisor(configuration: configuration)
        supervisor.autoRestart = preferences.autoRestart
        self.preferences = preferences
        self.supervisor = supervisor
        self.store = MonitorStore(supervisor: supervisor)
    }

    func bootstrap() {
        self.store.start()
        Task {
            await self.supervisor.bootstrap(startService: self.preferences.startServiceOnLaunch)
        }
    }

    func snapshot(now: Date = Date()) -> DashboardSnapshot {
        DashboardSnapshot(
            service: self.supervisor.snapshot,
            tokens: self.store.tokens,
            tokensFetchedAt: self.store.tokensFetchedAt,
            tokensStale: self.store.tokensAreStale(now: now),
            agents: self.store.liveAgents(now: now),
            agentsFetchedAt: self.store.agentsFetchedAt,
            usageDisplay: self.preferences.usageDisplay)
    }

    // MARK: Actions

    func startService() {
        Task {
            await self.supervisor.start()
            self.store.refreshNow()
        }
    }

    func pauseService() {
        Task { await self.supervisor.stop() }
    }

    func restartService() {
        Task {
            await self.supervisor.restart()
            self.store.refreshNow()
        }
    }

    func takeOverExternal() {
        Task { await self.supervisor.takeOverExternal() }
    }

    func takeOverLaunchAgent() {
        Task { await self.supervisor.takeOverLaunchAgent() }
    }

    func handBackToLaunchAgent() {
        Task { await self.supervisor.handBackToLaunchAgent() }
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
        NSWorkspace.shared.open(self.supervisor.client.baseURL)
    }

    /// Re-reads the LaunchAgent and makes its command the saved one.
    func importLaunchAgent() throws {
        self.configuration = try ServiceConfiguration.fromLaunchAgent()
        self.configurationSource = .launchAgent
    }

    func resetToRepositoryDefault() -> Bool {
        guard let root = Self.repositoryRoot() else { return false }
        self.configuration = ServiceConfiguration.fromRepository(root)
        self.configurationSource = .repository
        return true
    }

    /// Quit: the service this app owns ends with it.
    func shutdown() async {
        self.store.stop()
        await self.supervisor.shutdown()
    }

    // MARK: Launch at login

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

    // MARK: Persistence

    private static func initialConfiguration() -> (ServiceConfiguration, ConfigurationSource) {
        if let saved = self.load(ServiceConfiguration.self, key: self.configurationKey) {
            return (saved, .saved)
        }
        if let imported = try? ServiceConfiguration.fromLaunchAgent() {
            return (imported, .launchAgent)
        }
        if let root = self.repositoryRoot() {
            return (ServiceConfiguration.fromRepository(root), .repository)
        }
        return (ServiceConfiguration(pythonPath: "/usr/bin/python3", scriptPath: ""), .none)
    }

    /// The checkout this bundle was built from (stamped by `build-app.sh`),
    /// or the one it lives inside.
    static func repositoryRoot() -> URL? {
        let fileManager = FileManager.default
        if let stamped = Bundle.main.object(forInfoDictionaryKey: "VPRepositoryRoot") as? String,
           fileManager.fileExists(atPath: "\(stamped)/tools/tokenserver/tokenserver.py") {
            return URL(fileURLWithPath: stamped)
        }
        return ServiceConfiguration.findRepository(from: Bundle.main.bundleURL)
            ?? ServiceConfiguration.findRepository(
                from: URL(fileURLWithPath: fileManager.currentDirectoryPath))
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
