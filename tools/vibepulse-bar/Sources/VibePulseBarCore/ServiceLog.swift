import Darwin
import Foundation

/// The service log, shared with the LaunchAgent path.
///
/// Opened `O_APPEND` exactly like launchd's `StandardErrorPath`, so a later
/// writer that truncates the file in place is followed instead of leaving a
/// hole at the old offset.
public struct ServiceLog: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// A fresh append-mode handle.
    public func openForChild() throws -> FileHandle {
        let directory = (self.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(self.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open \(self.path)"])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// App events in the server's own line format, so a comb of the
    /// log reads one timeline: `2026-09-24 02:40:00 INFO vibepulse-bar: ...`.
    public func append(_ message: String, level: String = "INFO", now: Date = Date()) {
        let line = "\(Self.timestamp(now)) \(level) vibepulse-bar: \(message)\n"
        guard let handle = try? self.openForChild() else { return }
        handle.write(Data(line.utf8))
        try? handle.close()
    }

    public var size: UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: self.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The last `limit` lines, read from at most the final 64 KiB.
    public func tail(limit: Int = 40) -> [String] {
        Array(self.lines(since: 0).suffix(limit))
    }

    /// Lines written after `offset`, without this app's own events.
    public func serverTail(since offset: UInt64, limit: Int = 12) -> [String] {
        Array(self.lines(since: offset).filter { !$0.contains(" vibepulse-bar: ") }.suffix(limit))
    }

    private func lines(since offset: UInt64) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: self.path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // The server rotates by truncating in place; below the mark, every
        // remaining byte is newer than the mark.
        let mark = offset <= size ? offset : 0
        let window: UInt64 = 64 * 1024
        let start = max(mark, size > window ? size - window : 0)
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        if start > mark, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
