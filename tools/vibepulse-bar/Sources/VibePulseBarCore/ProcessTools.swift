import Darwin
import Foundation

public enum CommandRunner {
    public struct Result: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public var succeeded: Bool { self.status == 0 }
    }

    /// Runs a short helper command off the main thread with a hard deadline.
    public static func run(_ executable: String, _ arguments: [String],
                           timeout: TimeInterval = 10) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.runBlocking(executable, arguments, timeout: timeout))
            }
        }
    }

    static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // Drain both pipes concurrently so a chatty command cannot fill one
        // and block before it exits.
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        _ = group.wait(timeout: .now() + 2)
        return Result(
            status: process.isRunning ? -1 : process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}

public struct ProcessDescription: Sendable, Equatable {
    public var pid: Int32
    public var command: String
    public var startTime: TimeInterval?

    public init(pid: Int32, command: String, startTime: TimeInterval?) {
        self.pid = pid
        self.command = command
        self.startTime = startTime
    }

    /// A tokenserver, or a wrapper around one, judged from its command line.
    public var looksLikeTokenServer: Bool {
        self.command.contains("tokenserver")
    }
}

public enum ProcessInspector {
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Kernel start time; with the pid it identifies one process, so a
    /// recycled pid is never mistaken for the server this app started.
    public static func startTime(of pid: Int32) -> TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }

    public static func describe(_ pid: Int32) async -> ProcessDescription? {
        let result = await CommandRunner.run("/bin/ps", ["-o", "command=", "-p", String(pid)], timeout: 5)
        let command = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !command.isEmpty else { return nil }
        return ProcessDescription(pid: pid, command: command, startTime: self.startTime(of: pid))
    }

    /// Processes listening on a local TCP port.
    public static func listeners(onPort port: Int) async -> [Int32] {
        let result = await CommandRunner.run(
            "/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeout: 5)
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}
