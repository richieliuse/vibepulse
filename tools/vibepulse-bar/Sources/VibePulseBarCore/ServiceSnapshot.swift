import Foundation

public enum ServicePhase: String, Equatable, Sendable {
    case idle
    case checking
    case starting
    case running
    case stopping
    case external
    case launchAgent
    case failed
}

/// Everything the menu shows about the service, captured as a value.
public struct ServiceSnapshot: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case healthy
        case pending
        case paused
        case warning
        case failure
    }

    public var phase: ServicePhase
    public var pid: Int32?
    public var processStartedAt: Date?
    public var diagnostics: ServerDiagnostics?
    public var foreign: ProcessDescription?
    public var launchAgent: LaunchAgentStatus
    public var issues: [ServiceConfiguration.Issue]
    public var lastError: String?
    public var port: Int
    public var ownsProcess: Bool
    public var wantsRunning: Bool
    public var isServing: Bool

    public init(phase: ServicePhase, pid: Int32? = nil, processStartedAt: Date? = nil,
                diagnostics: ServerDiagnostics? = nil, foreign: ProcessDescription? = nil,
                launchAgent: LaunchAgentStatus = .absent, issues: [ServiceConfiguration.Issue] = [],
                lastError: String? = nil, port: Int = ServiceConfiguration.defaultPort,
                ownsProcess: Bool = false, wantsRunning: Bool = false, isServing: Bool = false) {
        self.phase = phase
        self.pid = pid
        self.processStartedAt = processStartedAt
        self.diagnostics = diagnostics
        self.foreign = foreign
        self.launchAgent = launchAgent
        self.issues = issues
        self.lastError = lastError
        self.port = port
        self.ownsProcess = ownsProcess
        self.wantsRunning = wantsRunning
        self.isServing = isServing
    }

    public var tone: Tone {
        switch self.phase {
        case .running: .healthy
        case .external, .launchAgent: .warning
        case .checking, .starting, .stopping: .pending
        case .idle: .paused
        case .failed: .failure
        }
    }

    public var headline: String {
        switch self.phase {
        case .idle: "Paused"
        case .checking: "Checking…"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .external: "Port in use"
        case .launchAgent: "Managed by launchd"
        case .failed: "Didn't start"
        }
    }

    /// One line under the headline: who is listening, and on which port.
    public func detail(now: Date) -> String {
        var parts: [String] = []
        switch self.phase {
        case .running, .starting:
            if let pid { parts.append("pid \(pid)") }
            if let started = self.processStartedAt {
                parts.append("up \(Format.duration(seconds: Int(now.timeIntervalSince(started))))")
            }
            parts.append("port \(self.port)")
        case .external:
            if let foreign { parts.append("pid \(foreign.pid)") }
            parts.append("port \(self.port)")
            parts.append("not started by this app")
        case .launchAgent:
            if let pid = self.launchAgent.pid { parts.append("pid \(pid)") }
            parts.append("se.torget.tokenserver")
        case .failed:
            parts.append(self.issues.first?.message ?? self.lastError ?? "the server did not start")
        case .idle:
            parts.append(self.wantsRunning ? "not running" : "monitoring paused")
        case .checking, .stopping:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// Revision and panel reachability, from the engine's diagnostics view.
    public func footnote(now: Date) -> String? {
        guard let diagnostics else { return nil }
        var parts: [String] = []
        if let rev = diagnostics.rev { parts.append("rev \(rev)") }
        if let panel = diagnostics.panel {
            switch panel.status {
            case "ready":
                parts.append("panel polled \(Format.relative(seconds: panel.ageSeconds ?? 0))")
            case "stale":
                parts.append("panel last seen \(Format.relative(seconds: panel.ageSeconds ?? 0))")
            default:
                parts.append("panel not seen yet")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
