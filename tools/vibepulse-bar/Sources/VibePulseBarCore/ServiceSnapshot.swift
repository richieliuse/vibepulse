import Foundation

/// Everything the menu shows about the service, captured as a value.
public struct ServiceSnapshot: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case healthy
        case pending
        case paused
        case warning
        case failure
    }

    public var phase: ServiceSupervisor.Phase
    public var pid: Int32?
    public var processStartedAt: Date?
    public var diagnostics: ServerDiagnostics?
    public var lastHealthyAt: Date?
    public var lastExit: ServiceSupervisor.ExitRecord?
    public var nextRestartAt: Date?
    public var restartAttempt: Int
    public var foreign: ProcessDescription?
    public var launchAgent: LaunchAgentStatus
    public var issues: [ServiceConfiguration.Issue]
    public var lastError: String?
    public var port: Int
    public var ownsProcess: Bool
    public var wantsRunning: Bool
    public var isServing: Bool

    public init(phase: ServiceSupervisor.Phase, pid: Int32? = nil, processStartedAt: Date? = nil,
                diagnostics: ServerDiagnostics? = nil, lastHealthyAt: Date? = nil,
                lastExit: ServiceSupervisor.ExitRecord? = nil, nextRestartAt: Date? = nil,
                restartAttempt: Int = 0, foreign: ProcessDescription? = nil,
                launchAgent: LaunchAgentStatus = .absent, issues: [ServiceConfiguration.Issue] = [],
                lastError: String? = nil, port: Int = ServiceConfiguration.defaultPort,
                ownsProcess: Bool = false, wantsRunning: Bool = false, isServing: Bool = false) {
        self.phase = phase
        self.pid = pid
        self.processStartedAt = processStartedAt
        self.diagnostics = diagnostics
        self.lastHealthyAt = lastHealthyAt
        self.lastExit = lastExit
        self.nextRestartAt = nextRestartAt
        self.restartAttempt = restartAttempt
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
        case .external, .launchAgent: self.isServing ? .healthy : .warning
        case .checking, .starting, .stopping: .pending
        case .idle: .paused
        case .unresponsive: .warning
        case .crashed, .misconfigured: .failure
        }
    }

    public var headline: String {
        switch self.phase {
        case .idle: "Paused"
        case .checking: "Checking…"
        case .starting: "Starting…"
        case .running: "Running"
        case .unresponsive: "Not responding"
        case .stopping: "Stopping…"
        case .crashed: "Crashed"
        case .external: "Running elsewhere"
        case .launchAgent: "Managed by launchd"
        case .misconfigured: "Needs setup"
        }
    }

    /// One line under the headline: who, how long, and what happens next.
    public func detail(now: Date) -> String {
        var parts: [String] = []
        switch self.phase {
        case .running, .unresponsive, .starting:
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
        case .crashed:
            if let exit = self.lastExit { parts.append(exit.summary) }
            if let next = self.nextRestartAt {
                let seconds = max(0, Int(next.timeIntervalSince(now).rounded(.up)))
                parts.append("restarting in \(seconds)s")
            } else {
                parts.append("auto-restart off")
            }
        case .misconfigured:
            parts.append(self.issues.first?.message ?? self.lastError ?? "Check Settings → Service")
        case .idle:
            parts.append(self.wantsRunning ? "not running" : "monitoring paused")
            if let exit = self.lastExit, exit.expected {
                parts.append("stopped \(Format.relative(since: exit.at, now: now))")
            }
        case .checking, .stopping:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// Revision and panel reachability, from the server's own diagnostics.
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

extension ServiceSupervisor {
    public var snapshot: ServiceSnapshot {
        ServiceSnapshot(
            phase: self.phase, pid: self.pid, processStartedAt: self.processStartedAt,
            diagnostics: self.diagnostics, lastHealthyAt: self.lastHealthyAt, lastExit: self.lastExit,
            nextRestartAt: self.nextRestartAt, restartAttempt: self.restartAttempt,
            foreign: self.foreign, launchAgent: self.launchAgent, issues: self.issues,
            lastError: self.lastError, port: self.configuration.effectivePort,
            ownsProcess: self.ownsProcess, wantsRunning: self.wantsRunning, isServing: self.isServing)
    }
}
