import Foundation

public struct GitHubMonitorError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(message: String) { self.message = message }
}

public struct GitHubHTTPRequest: Equatable, Sendable {
    public var url: String
    public var headers: [String: String]

    public init(url: String, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

public struct GitHubHTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public struct GitHubEvent: Equatable, Sendable {
    public var eventID: String
    /// Absent login is JSON null when the event is present.
    public var actor: String?
    public var eventStars: Int

    public init(eventID: String, actor: String?, eventStars: Int) {
        self.eventID = eventID
        self.actor = actor
        self.eventStars = eventStars
    }
}

public struct GitHubSnapshot: Equatable, Sendable {
    public var version: Int
    public var enabled: Bool
    public var repo: String?
    public var project: String?
    public var stale: Bool?
    public var stars: Int?
    public var forks: Int?
    public var event: GitHubEvent?

    public init(version: Int = 1, enabled: Bool, repo: String? = nil, project: String? = nil,
                stale: Bool? = nil, stars: Int? = nil, forks: Int? = nil, event: GitHubEvent? = nil) {
        self.version = version
        self.enabled = enabled
        self.repo = repo
        self.project = project
        self.stale = stale
        self.stars = stars
        self.forks = forks
        self.event = event
    }

    public func value() -> CanonicalJSON.Value {
        var fields: [String: CanonicalJSON.Value] = [
            "v": .int(version),
            "enabled": .bool(enabled),
        ]
        if let repo { fields["repo"] = .string(repo) }
        if let project { fields["project"] = .string(project) }
        if let stale { fields["stale"] = .bool(stale) }
        if let stars { fields["stars"] = .int(stars) }
        if let forks { fields["forks"] = .int(forks) }
        if let event {
            fields["eventId"] = .string(event.eventID)
            fields["actor"] = event.actor.map(CanonicalJSON.Value.string) ?? .null
            fields["eventStars"] = .int(event.eventStars)
        }
        return .object(fields)
    }
}

/// One public repository, polled through an injected transport. `pollOnce` does not throw.
/// No background thread and no live GitHub connection in this slice.
public final class GitHubMonitor {
    public static let pollSeconds: TimeInterval = 120
    public static let eventTTL: TimeInterval = 600
    public static let failureBackoff: TimeInterval = 600
    public static let staleAfter: TimeInterval = 300
    public static let userAgent = "VibePulse-public-repo-monitor/1"
    public static let accept = "application/vnd.github+json"
    public static let apiVersion = "2022-11-28"
    public static let maxBodyBytes = 256 * 1024

    public let repo: String
    public let pollSeconds: TimeInterval

    public var nextPollAt: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return storedNextPoll
    }

    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return storedError
    }

    private let token: String?
    private let transport: (GitHubHTTPRequest) throws -> GitHubHTTPResponse
    private let clock: () -> TimeInterval
    private let wallClock: () -> TimeInterval
    private let lock = NSLock()
    private var stars: Int?
    private var forks: Int?
    private var project: String
    private var event: GitHubEvent?
    private var eventSeenAt: TimeInterval?
    private var lastSuccessAt: TimeInterval?
    private var storedError: String?
    private var storedNextPoll: TimeInterval = 0
    private var stopped = false

    public init(
        repo: String,
        token: String? = nil,
        transport: @escaping (GitHubHTTPRequest) throws -> GitHubHTTPResponse,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallClock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        pollSeconds: TimeInterval = GitHubMonitor.pollSeconds
    ) throws {
        let normalized = try Self.normalizeRepo(repo)
        self.repo = normalized
        self.project = String(normalized.split(separator: "/", maxSplits: 1)[1])
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.token = trimmed.isEmpty ? nil : trimmed
        self.transport = transport
        self.clock = clock
        self.wallClock = wallClock
        self.pollSeconds = pollSeconds
    }

    public static func normalizeRepo(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isRepoPart(parts[0]), isRepoPart(parts[1]) else {
            throw GitHubMonitorError(message: "GitHub repository must be owner/repository")
        }
        return trimmed
    }

    public static func disabledSnapshot() -> GitHubSnapshot {
        GitHubSnapshot(enabled: false)
    }

    /// No further poll. Safe if `pollOnce` never ran. A second call is a no-op.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
    }

    public func pollOnce() -> Bool {
        lock.lock()
        let halted = stopped
        lock.unlock()
        if halted { return false }
        let now = clock()
        let owner = quote(String(repo.split(separator: "/", maxSplits: 1)[0]))
        let name = quote(String(repo.split(separator: "/", maxSplits: 1)[1]))
        let url = "https://api.github.com/repos/\(owner)/\(name)"
        do {
            let payload = try fetchJSON(url)
            guard case let .object(fields) = payload else {
                throw pollError("GitHub repository response was not an object")
            }
            guard fields["private"] == .bool(false) else {
                throw pollError("configured GitHub repository is not public")
            }
            guard let starCount = strictCount(fields["stargazers_count"]) else {
                throw pollError("invalid GitHub star count")
            }
            guard let forkCount = strictCount(fields["forks_count"]) else {
                throw pollError("invalid GitHub fork count")
            }
            guard case let .string(projectName) = fields["name"],
                  !projectName.isEmpty, projectName.count <= 100 else {
                throw pollError("invalid GitHub repository name")
            }
            let previous = lockedStars()
            var starred: GitHubEvent?
            if let previous, starCount > previous {
                let latest = latestStargazer()
                starred = GitHubEvent(
                    eventID: latest.when ?? "count:\(starCount)",
                    actor: latest.login,
                    eventStars: starCount
                )
            }
            lock.lock()
            stars = starCount
            forks = forkCount
            project = projectName
            lastSuccessAt = now
            storedError = nil
            storedNextPoll = now + pollSeconds
            if let starred {
                event = starred
                eventSeenAt = now
            }
            lock.unlock()
            return true
        } catch {
            let delay = retryDelay(error, wall: wallClock())
            lock.lock()
            storedError = "\(type(of: error)): \(error)"
            storedNextPoll = now + delay
            lock.unlock()
            return false
        }
    }

    public func snapshot() -> GitHubSnapshot {
        let now = clock()
        lock.lock()
        let stars = self.stars
        let forks = self.forks
        let project = self.project
        let lastSuccess = lastSuccessAt
        let event = self.event
        let seen = eventSeenAt
        let failed = storedError != nil
        lock.unlock()
        let stale = lastSuccess == nil || failed || now - (lastSuccess ?? 0) > Self.staleAfter
        let live = event.flatMap { item -> GitHubEvent? in
            guard let seen, now - seen <= Self.eventTTL else { return nil }
            return item
        }
        return GitHubSnapshot(
            enabled: true, repo: repo, project: project, stale: stale,
            stars: stars, forks: forks, event: live)
    }

    public func snapshotValue() -> CanonicalJSON.Value { snapshot().value() }

    private func lockedStars() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return stars
    }

    private func latestStargazer() -> (login: String?, when: String?) {
        let owner = quote(String(repo.split(separator: "/", maxSplits: 1)[0]))
        let name = quote(String(repo.split(separator: "/", maxSplits: 1)[1]))
        let url = "https://api.github.com/repos/\(owner)/\(name)/events?per_page=30"
        do {
            let payload = try fetchJSON(url)
            guard case let .array(items) = payload else {
                throw pollError("GitHub events response was not a list")
            }
            for item in items {
                guard case let .object(fields) = item, fields["type"] == .string("WatchEvent") else { continue }
                let login: String?
                if case let .object(actor) = fields["actor"], case let .string(name) = actor["login"], !name.isEmpty {
                    login = name
                } else {
                    login = nil
                }
                guard let login, case let .string(created) = fields["created_at"],
                      let parsed = parseGitHubTimestamp(created) else { continue }
                return (login, formatGitHubTimestamp(parsed))
            }
            return (nil, nil)
        } catch {
            return (nil, nil)
        }
    }

    private func fetchJSON(_ url: String) throws -> CanonicalJSON.Value {
        var headers = [
            "Accept": Self.accept,
            "User-Agent": Self.userAgent,
            "X-GitHub-Api-Version": Self.apiVersion,
        ]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        let response = try transport(GitHubHTTPRequest(url: url, headers: headers))
        guard response.status == 200 else {
            throw GitHubHTTPStatus(status: response.status, headers: response.headers)
        }
        guard response.body.count <= Self.maxBodyBytes else {
            throw pollError("GitHub response exceeded 256 KiB")
        }
        guard case let .success(value) = CanonicalJSON.parse(response.body) else {
            throw pollError("invalid GitHub JSON")
        }
        return value
    }

    private func retryDelay(_ error: Error, wall: TimeInterval) -> TimeInterval {
        guard let http = error as? GitHubHTTPStatus, http.status == 403 || http.status == 429 else {
            return Self.failureBackoff
        }
        let retryAfter = headerNumber(http.headers, "retry-after") ?? 0
        let resetAfter: Double
        if let reset = headerNumber(http.headers, "x-ratelimit-reset") {
            resetAfter = reset - wall
        } else {
            resetAfter = 0 - wall
        }
        return max(Self.failureBackoff, retryAfter, resetAfter, 0)
    }

    private func headerNumber(_ headers: [String: String], _ name: String) -> Double? {
        let match = headers.first { $0.key.lowercased() == name }?.value
        guard let match else { return nil }
        return Double(match.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func strictCount(_ value: CanonicalJSON.Value?) -> Int? {
        guard case let .int(number) = value, number >= 0, number <= 2_147_483_647 else { return nil }
        return number
    }

    private func quote(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            let unreserved = (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x7E
            if unreserved {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func isRepoPart(_ part: Substring) -> Bool {
        guard (1...100).contains(part.count) else { return false }
        return part.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2E, 0x2D: return true
            default: return false
            }
        }
    }

    private func pollError(_ message: String) -> GitHubPollError {
        GitHubPollError(message)
    }
}

private struct GitHubHTTPStatus: Error, CustomStringConvertible {
    var status: Int
    var headers: [String: String]
    var description: String { "GitHub returned HTTP \(status)" }
}

private struct GitHubPollError: Error, CustomStringConvertible {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func parseGitHubTimestamp(_ text: String) -> Date? {
    let scalars = Array(text.unicodeScalars)
    func digit(_ index: Int) -> Int? {
        guard scalars.indices.contains(index) else { return nil }
        let value = scalars[index].value
        guard (48...57).contains(value) else { return nil }
        return Int(value - 48)
    }
    func number(_ start: Int, _ count: Int) -> Int? {
        var value = 0
        for offset in 0..<count {
            guard let piece = digit(start + offset) else { return nil }
            value = value * 10 + piece
        }
        return value
    }
    guard scalars.count >= 20,
          let year = number(0, 4), scalars[4].value == 45,
          let month = number(5, 2), scalars[7].value == 45,
          let day = number(8, 2), scalars[10].value == 84,
          let hour = number(11, 2), scalars[13].value == 58,
          let minute = number(14, 2), scalars[16].value == 58,
          let second = number(17, 2) else { return nil }
    var index = 19
    var fraction = 0.0
    if index < scalars.count, scalars[index].value == 46 {
        index += 1
        var digits = 0
        var value = 0
        while index < scalars.count && digits < 9 {
            guard let piece = digit(index) else { break }
            value = value * 10 + piece
            digits += 1
            index += 1
        }
        while index < scalars.count && digit(index) != nil { index += 1 }
        guard digits > 0 else { return nil }
        fraction = Double(value) / pow(10, Double(digits))
    }
    let offset: Int
    if index < scalars.count, scalars[index].value == 90 {
        offset = 0
        index += 1
    } else if index < scalars.count, scalars[index].value == 43 || scalars[index].value == 45 {
        let sign = scalars[index].value == 43 ? 1 : -1
        index += 1
        guard let hours = number(index, 2), index + 2 < scalars.count, scalars[index + 2].value == 58,
              let minutes = number(index + 3, 2) else { return nil }
        offset = sign * (hours * 3600 + minutes * 60)
        index += 5
    } else {
        return nil
    }
    guard index == scalars.count else { return nil }
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: offset)
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    components.nanosecond = Int((fraction * 1_000_000_000).rounded())
    return components.date
}

func formatGitHubTimestamp(_ date: Date) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let zone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents(in: zone, from: date)
    let base = String(
        format: "%04d-%02d-%02dT%02d:%02d:%02d",
        parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
        parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    let nanos = parts.nanosecond ?? 0
    if nanos == 0 { return base + "Z" }
    return base + String(format: ".%06dZ", min(999_999, nanos / 1000))
}
