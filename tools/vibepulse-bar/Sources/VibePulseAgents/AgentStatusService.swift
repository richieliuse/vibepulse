import Foundation

private struct StoredJob {
    var taskID: String
    var eventID: String
    var state: String
    var project: String?
    var activity: String?
    var model: String?
    var effort: String?
    var observedAt: TimeInterval
    var orderAt: TimeInterval
}

private struct PublicJob {
    var taskID: String
    var eventID: String
    var state: String
    var project: String?
    var activity: String?
    var model: String?
    var effort: String?
    var updatedMS: Int
}

public final class AgentStatusStore: @unchecked Sendable {
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var seq = 0
    private var agents: [String: [String: StoredJob]] = ["claude": [:], "codex": [:]]

    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    @discardableResult
    public func apply(provider: String, event: AgentEvent, observedAt: TimeInterval? = nil,
                      orderAt: TimeInterval? = nil, refreshUnchanged: Bool = true,
                      eventIDOverride: String? = nil) throws -> Bool {
        guard agents[provider] != nil else { throw AgentStatusError.unsupportedProvider(provider) }
        guard agentStates.contains(event.state) else { throw AgentStatusError.unsupportedState(event.state) }
        if let activity = event.activity, !agentActivities.contains(activity) {
            throw AgentStatusError.unsupportedActivity(activity)
        }
        let clock = finite(self.now(), fallback: 0)
        var seenAt = observedAt ?? clock
        if !seenAt.isFinite { seenAt = clock }
        var orderedAt = orderAt ?? seenAt
        if !orderedAt.isFinite { orderedAt = seenAt }
        var effectiveAt = self.now()
        if !effectiveAt.isFinite { effectiveAt = seenAt }

        let taskID = boundedTaskID(event.taskID)
        var replacement = StoredJob(
            taskID: taskID,
            eventID: eventIDOverride ?? stableEventID(provider: provider, event: event),
            state: event.state,
            project: sanitizeProject(event.project),
            activity: event.activity,
            model: normalizeModel(event.model),
            effort: normalizeEffort(event.effort),
            observedAt: seenAt,
            orderAt: orderedAt)

        lock.lock()
        defer { lock.unlock() }
        var records = agents[provider] ?? [:]
        let current = records[taskID]
        if let current, orderedAt < current.orderAt { return false }
        if let current {
            if replacement.model == nil { replacement.model = current.model }
            if replacement.effort == nil { replacement.effort = current.effort }
        }
        let changed = current.map { !samePublicFields($0, replacement) } ?? true
        if changed {
            records[taskID] = replacement
            if records.count > agentTrackedJobLimit {
                let evicted = records.values.min { lhs, rhs in
                    let left = effective(lhs, at: effectiveAt)
                    let right = effective(rhs, at: effectiveAt)
                    let lp = agentStatePriority[left.state] ?? 0
                    let rp = agentStatePriority[right.state] ?? 0
                    if lp != rp { return lp < rp }
                    if lhs.orderAt != rhs.orderAt { return lhs.orderAt < rhs.orderAt }
                    return lhs.taskID < rhs.taskID
                }
                if let evicted { records.removeValue(forKey: evicted.taskID) }
            }
            seq += 1
        } else if refreshUnchanged, var current {
            current.observedAt = max(current.observedAt, seenAt)
            current.orderAt = max(current.orderAt, orderedAt)
            records[taskID] = current
        }
        agents[provider] = records
        return changed
    }

    public func snapshot() -> WireObject {
        let moment = finite(now(), fallback: 0)
        lock.lock()
        defer { lock.unlock() }
        var providerObjects: [(String, WireValue)] = []
        for provider in ["claude", "codex"] {
            let records = agents[provider] ?? [:]
            var publicJobs = records.values.map { effective($0, at: moment) }
                .filter { $0.state != "idle" && $0.state != "unknown" }
            let active = publicJobs.filter {
                $0.state == "working" || $0.state == "waiting" || $0.state == "error"
            }.count
            publicJobs.sort { lhs, rhs in
                let lp = agentStatePriority[lhs.state] ?? 0
                let rp = agentStatePriority[rhs.state] ?? 0
                if lp != rp { return lp > rp }
                if lhs.updatedMS != rhs.updatedMS { return lhs.updatedMS < rhs.updatedMS }
                return lhs.taskID < rhs.taskID
            }
            let jobs = publicJobs.prefix(agentPublicJobLimit).map { WireValue.object(jobWire($0)) }
            providerObjects.append((provider, .object(WireObject([
                ("active_count", .int(active)),
                ("jobs", .array(Array(jobs))),
            ]))))
        }
        return WireObject([
            ("v", .int(2)),
            ("seq", .int(seq)),
            ("agents", .object(WireObject(providerObjects))),
        ])
    }

    private func effective(_ record: StoredJob, at now: TimeInterval) -> PublicJob {
        let age = max(0, now - record.observedAt)
        var state = record.state
        var activity = record.activity
        if (state == "working" && age > agentLeaseSeconds)
            || ((state == "waiting" || state == "error") && age > agentWaitingLeaseSeconds) {
            state = "unknown"
            activity = nil
        }
        let millis = min(0xFFFF_FFFF, Int(age * 1000))
        return PublicJob(taskID: record.taskID, eventID: record.eventID, state: state,
                         project: record.project, activity: activity, model: record.model,
                         effort: record.effort, updatedMS: millis)
    }
}

public final class AgentStatusService: @unchecked Sendable {
    private let store: AgentStatusStore

    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = AgentStatusStore(now: now)
    }

    /// Classify one JSONL record and fold it into the snapshot. False means the line is not a job event.
    @discardableResult
    public func applyLine(_ line: String, provider: String) throws -> Bool {
        let record = jsonObject(from: line)
        let event: AgentEvent?
        switch provider {
        case "claude": event = classifyClaude(record)
        case "codex": event = classifyCodex(record)
        default: throw AgentStatusError.unsupportedProvider(provider)
        }
        guard let event else { return false }
        return try store.apply(provider: provider, event: event)
    }

    public func snapshot() -> WireObject {
        store.snapshot()
    }
}

private func finite(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
    value.isFinite ? value : fallback
}

private func samePublicFields(_ lhs: StoredJob, _ rhs: StoredJob) -> Bool {
    lhs.taskID == rhs.taskID && lhs.eventID == rhs.eventID && lhs.state == rhs.state
        && lhs.project == rhs.project && lhs.activity == rhs.activity
        && lhs.model == rhs.model && lhs.effort == rhs.effort
}

private func jobWire(_ job: PublicJob) -> WireObject {
    WireObject([
        ("task_id", .string(job.taskID)),
        ("event_id", .string(job.eventID)),
        ("state", .string(job.state)),
        ("project", job.project.map(WireValue.string) ?? .null),
        ("activity", job.activity.map(WireValue.string) ?? .null),
        ("model", job.model.map(WireValue.string) ?? .null),
        ("effort", job.effort.map(WireValue.string) ?? .null),
        ("updated_ms", .int(job.updatedMS)),
    ])
}
