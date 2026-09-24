import Foundation

public enum AgentState: String, Sendable, CaseIterable {
    case idle
    case working
    case waiting
    case done
    case error
    case unknown

    /// The same ranking the service uses: what needs a human first.
    var priority: Int {
        switch self {
        case .waiting: 0
        case .error: 1
        case .working: 2
        case .done: 3
        case .idle: 4
        case .unknown: 5
        }
    }

    public var isActive: Bool {
        self == .working || self == .waiting || self == .error
    }
}

public struct AgentJob: Sendable, Equatable, Identifiable {
    public var id: String { self.eventID ?? self.taskID }
    public var taskID: String
    public var eventID: String?
    public var state: AgentState
    public var project: String?
    public var activity: String?
    public var model: String?
    public var effort: String?
    /// Age of the job's last event when the snapshot was served.
    public var updatedMilliseconds: Int?

    public init(taskID: String, eventID: String? = nil, state: AgentState, project: String? = nil,
                activity: String? = nil, model: String? = nil, effort: String? = nil,
                updatedMilliseconds: Int? = nil) {
        self.taskID = taskID
        self.eventID = eventID
        self.state = state
        self.project = project
        self.activity = activity
        self.model = model
        self.effort = effort
        self.updatedMilliseconds = updatedMilliseconds
    }

    /// Seconds since the job's last event, projected from the fetch time.
    public func ageSeconds(fetchedAt: Date, now: Date) -> Int? {
        guard let updated = self.updatedMilliseconds else { return nil }
        let elapsed = max(0, now.timeIntervalSince(fetchedAt))
        return Int((Double(updated) / 1000 + elapsed).rounded(.down))
    }

    /// "thinking" / "waiting_input" become words a person reads.
    public var activityText: String? {
        self.activity.map { $0.replacingOccurrences(of: "_", with: " ") }
    }
}

public struct ProviderAgents: Sendable, Equatable {
    public var activeCount: Int
    public var jobs: [AgentJob]

    public init(activeCount: Int, jobs: [AgentJob]) {
        self.activeCount = activeCount
        self.jobs = jobs
    }

    public static let empty = ProviderAgents(activeCount: 0, jobs: [])

    public var waitingCount: Int { self.jobs.filter { $0.state == .waiting }.count }
    public var workingCount: Int { self.jobs.filter { $0.state == .working }.count }
    public var errorCount: Int { self.jobs.filter { $0.state == .error }.count }
}

/// The `/api/agent-status` v2 payload. Only Claude and Codex are monitored.
public struct AgentStatusSnapshot: Sendable, Equatable {
    public var seq: Int?
    public var claude: ProviderAgents
    public var codex: ProviderAgents

    public init(seq: Int? = nil, claude: ProviderAgents = .empty, codex: ProviderAgents = .empty) {
        self.seq = seq
        self.claude = claude
        self.codex = codex
    }

    public init?(data: Data) {
        guard let json = JSONReader(data: data), json.int("v") == 2 else { return nil }
        let agents = json.reader("agents")
        self.seq = json.int("seq")
        self.claude = agents?.reader("claude").map(Self.provider) ?? .empty
        self.codex = agents?.reader("codex").map(Self.provider) ?? .empty
    }

    public func agents(for provider: Provider) -> ProviderAgents? {
        switch provider {
        case .claude: self.claude
        case .codex: self.codex
        case .grok, .cursor: nil
        }
    }

    public var totalActive: Int { self.claude.activeCount + self.codex.activeCount }
    public var totalWaiting: Int { self.claude.waitingCount + self.codex.waitingCount }

    private static func provider(_ json: JSONReader) -> ProviderAgents {
        let jobs = (json.array("jobs") ?? []).compactMap { item -> AgentJob? in
            guard let object = item as? [String: Any] else { return nil }
            let job = JSONReader(object)
            guard let task = job.string("task_id"), !task.isEmpty else { return nil }
            return AgentJob(
                taskID: task,
                eventID: job.string("event_id"),
                state: job.string("state").flatMap(AgentState.init(rawValue:)) ?? .unknown,
                project: job.string("project"),
                activity: job.string("activity"),
                model: job.string("model"),
                effort: job.string("effort"),
                updatedMilliseconds: job.int("updated_ms"))
        }
        let ordered = jobs.enumerated().sorted { lhs, rhs in
            if lhs.element.state.priority != rhs.element.state.priority {
                return lhs.element.state.priority < rhs.element.state.priority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let counted = jobs.filter(\.state.isActive).count
        return ProviderAgents(activeCount: max(json.int("active_count") ?? counted, 0), jobs: ordered)
    }
}
