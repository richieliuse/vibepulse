import CommonCrypto
import Darwin
import Foundation

public enum StateFiles {
    public static func stateDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/VibePulse", isDirectory: true)
    }

    /// `<name>.corrupt-<UTC stamp>`, with a numeric suffix when that name is taken.
    @discardableResult
    public static func quarantine(_ url: URL, reason: String) -> URL? {
        let stamp = isoStamp()
        let base = url.lastPathComponent
        var target = url.deletingLastPathComponent().appendingPathComponent("\(base).corrupt-\(stamp)")
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            counter += 1
            target = url.deletingLastPathComponent().appendingPathComponent("\(base).corrupt-\(stamp)-\(counter)")
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            fsyncParent(target)
            return target
        } catch {
            return nil
        }
    }

    /// Write `data` via a temp file in the same directory, fsync, then rename.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        let fd = open(temp.path, O_RDONLY)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
        fsyncParent(url)
    }

    public static func fsyncParent(_ url: URL) {
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }
    }

    public static func quotaIdentity(provider: String, scope: String, raw: String? = nil) -> String {
        let stable = raw ?? "default-v1"
        let material = "\(provider)\u{0}\(scope)\u{0}\(stable)"
        return SHA256.hex(Data(material.utf8))
    }

    private static func isoStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}

public enum SHA256 {
    public static func hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
