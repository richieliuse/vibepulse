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
    private let now: @Sendable () -> TimeInterval
    private let wall: @Sendable () -> TimeInterval
    private let projectsDirectory: URL?
    private let codexSessions: URL?
    private let store: AgentStatusStore
    private let tailer = JsonlTailer()
    private let pollLock = NSLock()
    private let pollGate = NSCondition()
    private var pollStopped = false
    private var pollLoopCount = 0
    private var activeClaude: [URL] = []
    private var activeCodex: [URL] = []
    private var backfills: [String: ReplayObservation] = [:]
    private var observationSequence = 0
    private var nextDiscoveryAt = -Double.infinity

    private struct ReplayObservation {
        var event: AgentEvent
        var observedAt: TimeInterval
        var orderAt: TimeInterval
        var sequence: Int
    }

    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.wall = { Date().timeIntervalSince1970 }
        self.projectsDirectory = nil
        self.codexSessions = nil
        self.store = AgentStatusStore(now: now)
    }

    public init(projectsDirectory: URL, codexSessions: URL,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                wall: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.now = now
        self.wall = wall
        self.projectsDirectory = projectsDirectory
        self.codexSessions = codexSessions
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

    /// Calls `pollOnce` until `stop()`. The server starts this on a worker it owns.
    /// The wait between passes is interrupted by `stop()`. This method does not
    /// create a thread.
    public func pollOnceLoop(interval: TimeInterval = 0.5) {
        pollGate.lock()
        if pollStopped {
            pollGate.unlock()
            return
        }
        pollLoopCount += 1
        pollGate.unlock()
        defer {
            pollGate.lock()
            pollLoopCount -= 1
            pollGate.broadcast()
            pollGate.unlock()
        }
        while !pollLoopShouldStop() {
            _ = pollOnce()
            if !pausePollLoop(interval) { return }
        }
    }

    /// Idempotent. Every `pollOnceLoop` the server started returns, including
    /// one that is waiting between passes. A second call waits for nothing.
    public func stop() {
        pollGate.lock()
        pollStopped = true
        pollGate.broadcast()
        while pollLoopCount > 0 {
            pollGate.wait()
        }
        pollGate.unlock()
    }

    /// Tail the discovered logs once. Startup history is applied from each
    /// record's own timestamp, on both the order clock and the age clock.
    public func pollOnce() -> Int {
        guard let projectsDirectory, let codexSessions else { return 0 }
        pollLock.lock()
        defer { pollLock.unlock() }
        if now() >= nextDiscoveryAt {
            activeClaude = discoverJSONL(in: projectsDirectory, rolloutOnly: false)
            activeCodex = discoverJSONL(in: codexSessions, rolloutOnly: true)
            nextDiscoveryAt = now() + 5
        }
        var changed = 0
        for url in activeClaude {
            changed += ingest(url, provider: "claude", classify: classifyClaude)
        }
        for url in activeCodex {
            changed += ingest(url, provider: "codex", classify: classifyCodex)
        }
        return changed
    }

    public func snapshot() -> WireObject {
        store.snapshot()
    }

    private func pollLoopShouldStop() -> Bool {
        pollGate.lock()
        defer { pollGate.unlock() }
        return pollStopped
    }

    /// True when the loop should poll again. False after `stop()`.
    private func pausePollLoop(_ interval: TimeInterval) -> Bool {
        pollGate.lock()
        defer { pollGate.unlock() }
        if pollStopped { return false }
        let pause = interval.isFinite && interval > 0 ? interval : 0
        let deadline = Date().addingTimeInterval(pause)
        while !pollStopped && Date() < deadline {
            if !pollGate.wait(until: deadline) { break }
        }
        return !pollStopped
    }

    private func ingest(_ url: URL, provider: String, classify: (Any?) -> AgentEvent?) -> Int {
        let key = storageKey(url)
        let hadState = tailer.contains(url)
        let read = tailer.read(url)
        let isBackfill = !hadState || backfills[key] != nil
        let fileTime = fileModificationTime(url)
        let monotonic = now()
        let wallNow = wall()
        var changed = 0
        if isBackfill {
            for record in read.records {
                guard let event = classify(record) else { continue }
                observationSequence += 1
                let orderAt = resolvedEventWallTime(of: record, fileMTime: fileTime, wallNow: wallNow)
                let observedAt = replayObservedAt(monotonicNow: monotonic, wallNow: wallNow, orderAt: orderAt)
                let observation = ReplayObservation(
                    event: event, observedAt: observedAt, orderAt: orderAt, sequence: observationSequence)
                if let current = backfills[key] {
                    if (observation.orderAt, observation.sequence) >= (current.orderAt, current.sequence) {
                        backfills[key] = observation
                    }
                } else {
                    backfills[key] = observation
                }
            }
            if read.caughtUp, let observation = backfills.removeValue(forKey: key) {
                if apply(observation, provider: provider, refreshUnchanged: false) { changed += 1 }
            }
        } else {
            for record in read.records {
                guard let event = classify(record) else { continue }
                observationSequence += 1
                let orderAt = resolvedEventWallTime(of: record, fileMTime: fileTime, wallNow: wallNow)
                let observedAt = replayObservedAt(monotonicNow: monotonic, wallNow: wallNow, orderAt: orderAt)
                let observation = ReplayObservation(
                    event: event, observedAt: observedAt, orderAt: orderAt, sequence: observationSequence)
                if apply(observation, provider: provider, refreshUnchanged: true) { changed += 1 }
            }
        }
        return changed
    }

    private func apply(_ observation: ReplayObservation, provider: String, refreshUnchanged: Bool) -> Bool {
        (try? store.apply(
            provider: provider, event: observation.event, observedAt: observation.observedAt,
            orderAt: observation.orderAt, refreshUnchanged: refreshUnchanged)) ?? false
    }
}

func eventWallTime(of record: Any?) -> TimeInterval? {
    guard let record = record as? [String: Any] else { return nil }
    var candidates: [Any?] = [record["timestamp"]]
    if let payload = record["payload"] as? [String: Any] {
        if payload["type"] as? String == "task_complete" {
            candidates.append(payload["completed_at"])
            candidates.append(payload["started_at"])
        } else {
            candidates.append(payload["started_at"])
            candidates.append(payload["completed_at"])
        }
    }
    for candidate in candidates {
        guard let text = candidate as? String, !text.isEmpty,
              let stamp = parseISO8601Timestamp(text) else { continue }
        return stamp
    }
    return nil
}

func resolvedEventWallTime(of record: Any?, fileMTime: TimeInterval?, wallNow: TimeInterval) -> TimeInterval {
    var event = eventWallTime(of: record)
    if event == nil || event! > wallNow {
        event = fileMTime
    }
    guard let event, event.isFinite, event <= wallNow else { return wallNow }
    return event
}

func replayObservedAt(monotonicNow: TimeInterval, wallNow: TimeInterval, orderAt: TimeInterval) -> TimeInterval {
    monotonicNow - max(0, wallNow - orderAt)
}

private func parseISO8601Timestamp(_ text: String, allowNaive: Bool = true) -> TimeInterval? {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let attempts: [ISO8601DateFormatter.Options] = text.contains(".")
        ? [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]]
        : [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]]
    for options in attempts {
        formatter.formatOptions = options
        if let date = formatter.date(from: text) {
            let stamp = date.timeIntervalSince1970
            if stamp.isFinite { return stamp }
        }
    }
    if allowNaive, !text.hasSuffix("Z"), text.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) == nil {
        return parseISO8601Timestamp(text + "Z", allowNaive: false)
    }
    return nil
}

private func fileModificationTime(_ url: URL) -> TimeInterval? {
    guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
        return nil
    }
    let stamp = date.timeIntervalSince1970
    return stamp.isFinite ? stamp : nil
}

private func discoverJSONL(in root: URL, rolloutOnly: Bool) -> [URL] {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        return []
    }
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else {
        return []
    }
    struct Candidate {
        var mtime: TimeInterval
        var path: String
        var url: URL
    }
    var candidates: [Candidate] = []
    for case let url as URL in enumerator {
        let name = url.lastPathComponent
        if rolloutOnly {
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
        } else {
            guard name.hasSuffix(".jsonl") else { continue }
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
              values.isRegularFile == true else { continue }
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        candidates.append(Candidate(mtime: mtime, path: url.path, url: url))
    }
    candidates.sort { lhs, rhs in
        if lhs.mtime != rhs.mtime { return lhs.mtime < rhs.mtime }
        return lhs.path < rhs.path
    }
    return candidates.suffix(12).map(\.url)
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
