import Darwin
import Foundation
import VibePulseSupport

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public struct VibePulseConfig: Equatable, Sendable {
    public var claudeInteractions: Bool
    public var codexInteractions: Bool
    public var interactionDetail: Bool
    public var legacyClaudePanelV1: Bool
    public var interactionRelay: Bool
    public var agentStatusRelay: Bool
    public var interactionRelayURL: String?
    public var interactionMailbox: String?

    public init(claudeInteractions: Bool = false, codexInteractions: Bool = false,
                interactionDetail: Bool = false, legacyClaudePanelV1: Bool = false,
                interactionRelay: Bool = false, agentStatusRelay: Bool = false,
                interactionRelayURL: String? = nil, interactionMailbox: String? = nil) throws {
        self.claudeInteractions = claudeInteractions
        self.codexInteractions = codexInteractions
        self.interactionDetail = interactionDetail
        self.legacyClaudePanelV1 = legacyClaudePanelV1
        self.interactionRelay = interactionRelay
        self.agentStatusRelay = agentStatusRelay
        self.interactionRelayURL = interactionRelayURL
        self.interactionMailbox = interactionMailbox
        try validate()
    }

    public static func load(from url: URL) throws -> VibePulseConfig {
        let data: Data
        do {
            data = try readExisting(url)
        } catch let error as ConfigError {
            throw error
        } catch let error as NSError where StateIO.isMissing(error) {
            return try VibePulseConfig()
        } catch {
            throw ConfigError("cannot read configuration")
        }
        if data.count > 16 * 1024 { throw ConfigError("configuration file is too large") }
        guard String(bytes: data, encoding: .utf8) != nil else {
            throw ConfigError("cannot read configuration")
        }
        let payload: StrictJSON.Value
        do {
            payload = try ConfigJSON.parse(data)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError("malformed configuration JSON")
        }
        guard let object = payload.object else { throw ConfigError("configuration must be a JSON object") }
        let unknown = Set(object.keys).subtracting(Self.fields)
        if !unknown.isEmpty { throw ConfigError("unknown configuration keys") }
        return try decode(object)
    }

    public func save(to url: URL) throws {
        try validate()
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            chmod(directory.path, 0o700)
            let payload = JSONValue.object([
                ("agent_status_relay", .bool(agentStatusRelay)),
                ("claude_interactions", .bool(claudeInteractions)),
                ("codex_interactions", .bool(codexInteractions)),
                ("interaction_detail", .bool(interactionDetail)),
                ("interaction_mailbox", interactionMailbox.map(JSONValue.string) ?? .null),
                ("interaction_relay", .bool(interactionRelay)),
                ("interaction_relay_url", interactionRelayURL.map(JSONValue.string) ?? .null),
                ("legacy_claude_panel_v1", .bool(legacyClaudePanelV1)),
            ])
            try StateFiles.atomicWrite(JSONWire.encode(payload, asciiOnly: true), to: url)
            chmod(url.path, 0o600)
            // StateFiles.fsyncParent swallows errors, so a failed directory sync is reported here.
            try syncParentOrThrow(directory)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError("cannot save configuration")
        }
    }

    private static let fields: Set<String> = [
        "claude_interactions", "codex_interactions", "interaction_detail", "legacy_claude_panel_v1",
        "interaction_relay", "agent_status_relay", "interaction_relay_url", "interaction_mailbox",
    ]

    private static func decode(_ object: [String: StrictJSON.Value]) throws -> VibePulseConfig {
        func flag(_ key: String, _ fallback: Bool) throws -> Bool {
            guard let value = object[key] else { return fallback }
            guard let flag = value.bool else { throw ConfigError("\(key) must be a boolean") }
            return flag
        }
        let url = try optionalString(object["interaction_relay_url"], key: "interaction_relay_url")
        let mailbox = try optionalString(object["interaction_mailbox"], key: "interaction_mailbox")
        return try VibePulseConfig(
            claudeInteractions: flag("claude_interactions", false),
            codexInteractions: flag("codex_interactions", false),
            interactionDetail: flag("interaction_detail", false),
            legacyClaudePanelV1: flag("legacy_claude_panel_v1", false),
            interactionRelay: flag("interaction_relay", false),
            agentStatusRelay: flag("agent_status_relay", false),
            interactionRelayURL: url,
            interactionMailbox: mailbox)
    }

    private static func optionalString(_ value: StrictJSON.Value?, key: String) throws -> String? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard let text = value.string else {
            if key == "interaction_mailbox" { throw ConfigError("interaction_mailbox is invalid") }
            throw ConfigError("interaction_relay_url must be HTTPS")
        }
        return text
    }

    private func validate() throws {
        if let interactionRelayURL {
            try Self.validateOrigin(interactionRelayURL)
        }
        if let interactionMailbox {
            let pattern = #"^vp_[A-Za-z0-9_-]{16}$"#
            if interactionMailbox.range(of: pattern, options: .regularExpression) == nil {
                throw ConfigError("interaction_mailbox is invalid")
            }
        }
    }

    private static func validateOrigin(_ raw: String) throws {
        let scalars = raw.unicodeScalars
        if scalars.isEmpty || scalars.contains(where: { $0.value < 0x21 || $0.value > 0x7E }) {
            throw ConfigError("interaction_relay_url must be HTTPS")
        }
        let split: URLSplit
        do { split = try URLSplit(raw) } catch { throw ConfigError("interaction_relay_url has an invalid port") }
        let port = split.port ?? 443
        if split.scheme != "https" || split.hostname?.isEmpty != false || split.username != nil
            || split.password != nil || (split.path != "" && split.path != "/")
            || !split.query.isEmpty || !split.fragment.isEmpty || !(1...65535).contains(port) {
            throw ConfigError("interaction_relay_url must be an origin")
        }
    }
}

private struct URLSplit {
    var scheme: String
    var username: String?
    var password: String?
    var hostname: String?
    var port: Int?
    var path: String
    var query: String
    var fragment: String

    init(_ raw: String) throws {
        guard let schemeEnd = raw.firstIndex(of: ":"), raw[raw.startIndex..<schemeEnd].allSatisfy({
            $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
        }) else {
            scheme = ""
            path = raw
            query = ""
            fragment = ""
            return
        }
        scheme = raw[raw.startIndex..<schemeEnd].lowercased()
        var rest = raw[raw.index(after: schemeEnd)...]
        guard rest.hasPrefix("//") else {
            path = String(rest)
            query = ""
            fragment = ""
            return
        }
        rest = rest.dropFirst(2)
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        } else { fragment = "" }
        if let question = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: question)...])
            rest = rest[..<question]
        } else { query = "" }
        if let slash = rest.firstIndex(of: "/") {
            path = String(rest[slash...])
            rest = rest[..<slash]
        } else { path = "" }
        var hostport = String(rest)
        if let at = hostport.lastIndex(of: "@") {
            let userinfo = hostport[..<at]
            hostport = String(hostport[hostport.index(after: at)...])
            if let colon = userinfo.firstIndex(of: ":") {
                username = String(userinfo[..<colon])
                password = String(userinfo[userinfo.index(after: colon)...])
            } else if !userinfo.isEmpty {
                username = String(userinfo)
            }
        }
        if hostport.hasPrefix("[") {
            guard let end = hostport.firstIndex(of: "]") else { throw ConfigError("interaction_relay_url has an invalid port") }
            hostname = String(hostport[hostport.index(after: hostport.startIndex)..<end])
            let tail = hostport[hostport.index(after: end)...]
            if tail.hasPrefix(":") { port = try Self.port(String(tail.dropFirst())) }
        } else if let colon = hostport.lastIndex(of: ":") {
            hostname = String(hostport[..<colon])
            port = try Self.port(String(hostport[hostport.index(after: colon)...]))
        } else {
            hostname = hostport.isEmpty ? nil : hostport
        }
    }

    private static func port(_ text: String) throws -> Int {
        guard let value = Int(text), (0...65535).contains(value) else {
            throw ConfigError("interaction_relay_url has an invalid port")
        }
        return value == 0 ? 443 : value
    }
}

private enum ConfigJSON {
    static func parse(_ data: Data) throws -> StrictJSON.Value {
        var parser = Parser(Array(data))
        let value = try parser.parseValue()
        parser.skip()
        guard parser.index == parser.bytes.count else { throw ConfigError("malformed configuration JSON") }
        return value
    }

    private struct Parser {
        var bytes: [UInt8]
        var index = 0
        var depth = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func parseValue() throws -> StrictJSON.Value {
            skip()
            guard let byte = peek() else { throw ConfigError("malformed configuration JSON") }
            switch byte {
            case UInt8(ascii: "n"): return try literal("null") ? .null : fail()
            case UInt8(ascii: "t"): return try literal("true") ? .bool(true) : fail()
            case UInt8(ascii: "f"): return try literal("false") ? .bool(false) : fail()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
            default: throw ConfigError("malformed configuration JSON")
            }
        }
        mutating func skip() {
            while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }
        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func literal(_ text: String) throws -> Bool {
            let raw = Array(text.utf8)
            guard bytes[index...].starts(with: raw) else { throw ConfigError("malformed configuration JSON") }
            index += raw.count
            return true
        }
        func fail() throws -> StrictJSON.Value { throw ConfigError("malformed configuration JSON") }
        mutating func object() throws -> StrictJSON.Value {
            depth += 1
            if depth > 64 { throw ConfigError("malformed configuration JSON") }
            index += 1
            var object: [String: StrictJSON.Value] = [:]
            skip()
            if peek() == UInt8(ascii: "}") { index += 1; depth -= 1; return .object(object) }
            while true {
                skip()
                guard peek() == UInt8(ascii: "\"") else { throw ConfigError("malformed configuration JSON") }
                let key = try string()
                if object[key] != nil { throw ConfigError("duplicate configuration key: \(key)") }
                skip()
                guard peek() == UInt8(ascii: ":") else { throw ConfigError("malformed configuration JSON") }
                index += 1
                object[key] = try parseValue()
                skip()
                if peek() == UInt8(ascii: ",") { index += 1; continue }
                if peek() == UInt8(ascii: "}") { index += 1; depth -= 1; return .object(object) }
                throw ConfigError("malformed configuration JSON")
            }
        }
        mutating func array() throws -> StrictJSON.Value {
            index += 1
            var items: [StrictJSON.Value] = []
            skip()
            if peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                items.append(try parseValue())
                skip()
                if peek() == UInt8(ascii: ",") { index += 1; continue }
                if peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw ConfigError("malformed configuration JSON")
            }
        }
        mutating func string() throws -> String {
            guard peek() == UInt8(ascii: "\"") else { throw ConfigError("malformed configuration JSON") }
            index += 1
            var out: [UInt8] = []
            while let byte = peek() {
                index += 1
                if byte == UInt8(ascii: "\"") {
                    guard let text = String(bytes: out, encoding: .utf8) else {
                        throw ConfigError("malformed configuration JSON")
                    }
                    return text
                }
                if byte == UInt8(ascii: "\\") {
                    guard let escaped = peek() else { throw ConfigError("malformed configuration JSON") }
                    index += 1
                    switch escaped {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escaped)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        let scalar = try hex4()
                        out.append(contentsOf: String(scalar).utf8)
                    default: throw ConfigError("malformed configuration JSON")
                    }
                } else if byte < 0x20 {
                    throw ConfigError("malformed configuration JSON")
                } else {
                    out.append(byte)
                }
            }
            throw ConfigError("malformed configuration JSON")
        }
        mutating func hex4() throws -> Unicode.Scalar {
            var value = 0
            for _ in 0..<4 {
                guard let byte = peek() else { throw ConfigError("malformed configuration JSON") }
                index += 1
                value *= 16
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): value += Int(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): value += Int(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): value += Int(byte - UInt8(ascii: "A")) + 10
                default: throw ConfigError("malformed configuration JSON")
                }
            }
            guard let scalar = Unicode.Scalar(value) else { throw ConfigError("malformed configuration JSON") }
            return scalar
        }
        mutating func number() throws -> StrictJSON.Value {
            let start = index
            if peek() == UInt8(ascii: "-") { index += 1 }
            guard let first = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else {
                throw ConfigError("malformed configuration JSON")
            }
            if first == UInt8(ascii: "0") { index += 1 }
            else { while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 } }
            var fractional = false
            if peek() == UInt8(ascii: ".") {
                fractional = true
                index += 1
                guard let digit = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else {
                    throw ConfigError("malformed configuration JSON")
                }
                while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
            }
            if let byte = peek(), byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                fractional = true
                index += 1
                if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { index += 1 }
                guard let digit = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else {
                    throw ConfigError("malformed configuration JSON")
                }
                while let next = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next) { index += 1 }
            }
            let text = String(bytes: bytes[start..<index], encoding: .utf8) ?? ""
            if !fractional, let int = Int(text) { return .int(int) }
            guard let double = Double(text), double.isFinite else { throw ConfigError("malformed configuration JSON") }
            return .double(double)
        }
    }
}

private func readExisting(_ url: URL) throws -> Data {
    var before = stat()
    if lstat(url.path, &before) != 0 {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
    if (before.st_mode & S_IFMT) == S_IFLNK {
        throw ConfigError("configuration path must not be a symbolic link")
    }
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil) }
    defer { close(fd) }
    var descriptor = stat()
    var after = stat()
    guard fstat(fd, &descriptor) == 0, lstat(url.path, &after) == 0 else {
        throw ConfigError("cannot read configuration")
    }
    if (after.st_mode & S_IFMT) == S_IFLNK || before.st_dev != descriptor.st_dev
        || before.st_ino != descriptor.st_ino || descriptor.st_dev != after.st_dev
        || descriptor.st_ino != after.st_ino {
        throw ConfigError("configuration path changed while opening")
    }
    if (descriptor.st_mode & S_IFMT) != S_IFREG {
        throw ConfigError("configuration path must be a regular file")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024 + 1)
    let count = read(fd, &buffer, buffer.count)
    if count < 0 { throw ConfigError("cannot read configuration") }
    data.append(buffer, count: count)
    return data
}

private func syncParentOrThrow(_ directory: URL) throws {
    let fd = open(directory.path, O_RDONLY)
    if fd < 0 { return }
    defer { close(fd) }
    if fsync(fd) != 0 { throw ConfigError("cannot save configuration") }
}

/// Cross-process BSD `flock` plus an in-process re-entrant lock.
/// The lock file is `.{name}.lock` beside `path` (`.config.json.lock`).
/// Held for the whole `body`, including load-modify-save. Same-thread
/// re-entry does not take the OS lock again. Another thread waits. A
/// symlink or a failed acquire throws and does not run `body`.
@discardableResult
public func configLock<T>(_ path: URL, _ body: () throws -> T) throws -> T {
    let lockURL = path.deletingLastPathComponent().appendingPathComponent(".\(path.lastPathComponent).lock")
    let coordinator = ConfigLockTable.shared.coordinator(for: canonicalLockKey(lockURL.path))
    coordinator.lock.lock()
    do {
        if coordinator.depth == 0 {
            coordinator.fd = try openLockFile(lockURL)
            do {
                try acquireExclusiveLock(coordinator.fd)
            } catch {
                close(coordinator.fd)
                coordinator.fd = -1
                throw error
            }
        }
        coordinator.depth += 1
    } catch {
        coordinator.lock.unlock()
        throw error
    }
    do {
        defer {
            coordinator.depth -= 1
            if coordinator.depth == 0, coordinator.fd >= 0 {
                _ = flockRetry(coordinator.fd, LOCK_UN)
                close(coordinator.fd)
                coordinator.fd = -1
            }
            coordinator.lock.unlock()
        }
        return try body()
    }
}

private final class ConfigLockCoordinator: @unchecked Sendable {
    let lock = NSRecursiveLock()
    var depth = 0
    var fd: Int32 = -1
}

private final class ConfigLockTable: @unchecked Sendable {
    static let shared = ConfigLockTable()
    private let gate = NSLock()
    private var coordinators: [String: ConfigLockCoordinator] = [:]

    func coordinator(for key: String) -> ConfigLockCoordinator {
        gate.lock()
        defer { gate.unlock() }
        if let existing = coordinators[key] { return existing }
        let created = ConfigLockCoordinator()
        coordinators[key] = created
        return created
    }
}

private func canonicalLockKey(_ path: String) -> String {
    var current = path.hasPrefix("/") ? path : URL(fileURLWithPath: path).path
    var suffix: [String] = []
    while realpathString(current) == nil {
        if current == "/" || current.isEmpty { return path }
        let parent = (current as NSString).deletingLastPathComponent
        if parent == current { return path }
        suffix.append((current as NSString).lastPathComponent)
        current = parent
    }
    var resolved = realpathString(current) ?? current
    for part in suffix.reversed() {
        resolved = (resolved as NSString).appendingPathComponent(part)
    }
    return resolved
}

private func realpathString(_ path: String) -> String? {
    path.withCString { pointer in
        guard let resolved = realpath(pointer, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private func openLockFile(_ url: URL) throws -> Int32 {
    let directory = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        throw ConfigError("cannot lock configuration")
    }
    if chmod(directory.path, 0o700) != 0 {
        throw ConfigError("cannot lock configuration")
    }
    var before = stat()
    let existed = lstat(url.path, &before) == 0
    if !existed && errno != ENOENT {
        throw ConfigError("cannot lock configuration")
    }
    if existed && (before.st_mode & S_IFMT) == S_IFLNK {
        throw ConfigError("configuration lock must not be a symbolic link")
    }
    let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
    if fd < 0 { throw ConfigError("cannot lock configuration") }
    var descriptor = stat()
    var after = stat()
    if fstat(fd, &descriptor) != 0 || lstat(url.path, &after) != 0 {
        close(fd)
        throw ConfigError("configuration lock path is not safe")
    }
    let regular = (descriptor.st_mode & S_IFMT) == S_IFREG
    let afterLink = (after.st_mode & S_IFMT) == S_IFLNK
    let sameBefore = !existed || (before.st_dev == descriptor.st_dev && before.st_ino == descriptor.st_ino)
    let sameAfter = descriptor.st_dev == after.st_dev && descriptor.st_ino == after.st_ino
    if !regular || afterLink || !sameBefore || !sameAfter {
        close(fd)
        throw ConfigError("configuration lock path is not safe")
    }
    if fchmod(fd, S_IRUSR | S_IWUSR) != 0 {
        close(fd)
        throw ConfigError("cannot lock configuration")
    }
    return fd
}

/// Non-blocking exclusive flock first, then a blocking flock if another process holds it.
private func acquireExclusiveLock(_ fd: Int32) throws {
    if flockRetry(fd, LOCK_EX | LOCK_NB) == 0 { return }
    if errno != EWOULDBLOCK && errno != EAGAIN {
        throw ConfigError("cannot lock configuration")
    }
    if flockRetry(fd, LOCK_EX) != 0 {
        throw ConfigError("cannot lock configuration")
    }
}

private func flockRetry(_ fd: Int32, _ operation: Int32) -> Int32 {
    while true {
        let result = flock(fd, operation)
        if result == 0 || errno != EINTR { return result }
    }
}
