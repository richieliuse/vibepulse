import Foundation

/// One read of a JSONL file. `records` are complete JSON values only.
/// A line that has not yet ended in `\n` stays buffered and is not returned.
public struct JsonlTailRead {
    public var records: [Any]
    public var caughtUp: Bool

    public init(records: [Any], caughtUp: Bool) {
        self.records = records
        self.caughtUp = caughtUp
    }
}

/// Incremental JSONL reader. The byte offset includes bytes held in the
/// unfinished line, so the next read continues after them instead of
/// replaying earlier records.
public final class JsonlTailer: @unchecked Sendable {
    static let readChunkBytes = 65_536
    static let readBytesPerPoll = 1_048_576
    static let maxLineBytes = 1_048_576
    static let maxRecordsPerPoll = 256

    private let lock = NSLock()
    private var files: [String: TailState] = [:]

    public init() {}

    public func contains(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return files[storageKey(url)] != nil
    }

    /// Nil until the file has been read at least once.
    public func byteOffset(of url: URL) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return files[storageKey(url)]?.offset
    }

    public func read(_ url: URL) -> JsonlTailRead {
        lock.lock()
        defer { lock.unlock() }
        let key = storageKey(url)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return JsonlTailRead(records: [], caughtUp: false)
        }
        defer { try? handle.close() }

        var state = files[key] ?? TailState()
        let openedSize: UInt64
        do {
            openedSize = try handle.seekToEnd()
        } catch {
            return JsonlTailRead(records: [], caughtUp: false)
        }
        if openedSize < state.offset {
            state = TailState()
        }
        do {
            try handle.seek(toOffset: state.offset)
        } catch {
            return JsonlTailRead(records: [], caughtUp: false)
        }

        var records: [Any] = []
        var offset = state.offset
        var remaining = JsonlTailer.readBytesPerPoll
        while remaining > 0 && records.count < JsonlTailer.maxRecordsPerPoll {
            let want = min(remaining, JsonlTailer.readChunkBytes)
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: want), !read.isEmpty else { break }
                chunk = read
            } catch {
                files[key] = state
                return JsonlTailRead(records: records, caughtUp: false)
            }
            let consumed = consume(chunk, state: &state, records: &records)
            offset += UInt64(consumed)
            remaining -= consumed
            if consumed < chunk.count { break }
        }

        let finalSize: UInt64
        do {
            finalSize = try handle.seekToEnd()
        } catch {
            state.offset = offset
            files[key] = state
            return JsonlTailRead(records: records, caughtUp: false)
        }
        state.offset = offset
        files[key] = state
        return JsonlTailRead(records: records, caughtUp: offset >= finalSize)
    }
}

private struct TailState {
    var offset: UInt64 = 0
    var partial = Data()
    var discarding = false
}

func storageKey(_ url: URL) -> String {
    url.standardizedFileURL.path
}

private func consume(_ chunk: Data, state: inout TailState, records: inout [Any]) -> Int {
    let bytes = [UInt8](chunk)
    var position = 0
    while position < bytes.count {
        guard let newline = findNewline(bytes, from: position) else {
            let fragment = Data(bytes[position...])
            if !state.discarding {
                if state.partial.count + fragment.count <= JsonlTailer.maxLineBytes {
                    state.partial.append(fragment)
                } else {
                    state.partial.removeAll(keepingCapacity: false)
                    state.discarding = true
                }
            }
            return bytes.count
        }
        let fragment = Data(bytes[position..<newline])
        let consumed = newline + 1
        if state.discarding {
            state.discarding = false
            state.partial.removeAll(keepingCapacity: false)
            position = consumed
            continue
        }
        if state.partial.count + fragment.count > JsonlTailer.maxLineBytes {
            state.partial.removeAll(keepingCapacity: false)
            position = consumed
            continue
        }
        var raw = state.partial
        raw.append(fragment)
        state.partial.removeAll(keepingCapacity: false)
        if !isASCIIBlank(raw), let record = decodeJSONLine(raw) {
            records.append(record)
            if records.count >= JsonlTailer.maxRecordsPerPoll {
                return consumed
            }
        }
        position = consumed
    }
    return bytes.count
}

private func findNewline(_ bytes: [UInt8], from start: Int) -> Int? {
    var index = start
    while index < bytes.count {
        if bytes[index] == 0x0A { return index }
        index += 1
    }
    return nil
}

private func isASCIIBlank(_ data: Data) -> Bool {
    data.allSatisfy { byte in
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
    }
}

private func decodeJSONLine(_ data: Data) -> Any? {
    guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
        return nil
    }
    if value is NSNull { return nil }
    return value
}
