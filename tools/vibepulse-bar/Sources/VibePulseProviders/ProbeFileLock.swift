import Darwin
import Foundation

/// Non-blocking exclusive `flock`. Claude and Codex pass different paths so one
/// probe cannot silence the other. The same file is what the Python server locks.
public final class ProbeFileLock {
    private var fd: Int32

    public static func acquire(_ path: URL) -> ProbeFileLock? {
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let fd = path.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_TRUNC, mode_t(0o644)) }
        if fd < 0 { return nil }
        var interrupts = 0
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return ProbeFileLock(fd: fd)
            }
            if errno == EINTR, interrupts < 8 {
                interrupts += 1
                continue
            }
            _ = Darwin.close(fd)
            return nil
        }
    }

    public func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        _ = Darwin.close(fd)
        fd = -1
    }

    deinit { release() }

    private init(fd: Int32) { self.fd = fd }
}

enum ProbeCooldownFile {
    /// `{"cooldown_until": <epoch>}`. A missing, corrupt, or non-object file is ignored.
    static func load(_ url: URL) -> TimeInterval? {
        guard let data = try? Data(contentsOf: url), let object = JSON.object(from: data) else { return nil }
        if object["cooldown_until"] == nil { return 0 }
        guard let until = JSON.finite(object["cooldown_until"]), until.isFinite else { return nil }
        return until
    }

    static func save(_ until: TimeInterval, to url: URL) {
        guard until.isFinite else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["cooldown_until": until]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}

enum ProbeClock {
    static func hhmm(_ epoch: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}
