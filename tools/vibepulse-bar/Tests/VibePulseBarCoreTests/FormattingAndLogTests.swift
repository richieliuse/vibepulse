import XCTest
@testable import VibePulseBarCore

final class FormattingAndLogTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(Format.duration(minutes: 0), "<1m")
        XCTAssertEqual(Format.duration(minutes: 45), "45m")
        XCTAssertEqual(Format.duration(minutes: 120), "2h")
        XCTAssertEqual(Format.duration(minutes: 233), "3h 53m")
        XCTAssertEqual(Format.duration(minutes: 5530), "3d 20h")
        XCTAssertEqual(Format.duration(minutes: 2880), "2d")
        XCTAssertEqual(Format.duration(seconds: 42), "42s")
        XCTAssertEqual(Format.duration(seconds: 3 * 3600 + 17 * 60), "3h 17m")
    }

    func testRelative() {
        XCTAssertEqual(Format.relative(seconds: 2), "just now")
        XCTAssertEqual(Format.relative(seconds: 12), "12s ago")
        XCTAssertEqual(Format.relative(seconds: 3 * 3600), "3h ago")
        XCTAssertEqual(Format.relative(seconds: 72 * 3600), "3d ago")
    }

    func testTokensAndPercent() {
        XCTAssertEqual(Format.tokens(512), "512")
        XCTAssertEqual(Format.tokens(5_120), "5.1K")
        XCTAssertEqual(Format.tokens(48_231_907), "48.2M")
        XCTAssertEqual(Format.tokens(612_480_233), "612M")
        XCTAssertEqual(Format.tokens(1_200_000_000), "1.2B")
        XCTAssertEqual(Format.percent(0), "0%")
        XCTAssertEqual(Format.percent(0.3), "1%", "a partial window never reads empty")
        XCTAssertEqual(Format.percent(99.7), "99%", "a partial window never reads full")
        XCTAssertEqual(Format.percent(100), "100%")
        XCTAssertEqual(Format.usd(1840.55), "$1,841")
        XCTAssertEqual(Format.usd(12.5), "$12.50")
    }

    func testServerTailSkipsSupervisorLinesAndOlderRuns() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpbar-log-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let log = ServiceLog(path: path)
        let handle = try log.openForChild()
        handle.write(Data("old run line\n".utf8))
        let mark = log.size
        log.append("started tokenserver pid 1")
        handle.write(Data("Traceback (most recent call last):\nOSError: boom\n".utf8))
        try handle.close()
        XCTAssertEqual(log.serverTail(since: mark), ["Traceback (most recent call last):", "OSError: boom"])
        XCTAssertEqual(log.tail(limit: 2), ["Traceback (most recent call last):", "OSError: boom"])
        XCTAssertTrue(log.tail().contains { $0.hasSuffix("INFO vibepulse-bar: started tokenserver pid 1") })

        // In-place truncation (the server's own rotation) drops the mark.
        try Data("after rotation\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(log.serverTail(since: mark + 1000), ["after rotation"])
    }

    func testOwnershipRecordRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpbar-own-\(UUID().uuidString)/service.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pid = ProcessInfo.processInfo.processIdentifier
        let started = try XCTUnwrap(ProcessInspector.startTime(of: pid))
        OwnershipRecord(pid: pid, startTime: started, port: 8737).save(to: url)
        let loaded = try XCTUnwrap(OwnershipRecord.load(from: url))
        XCTAssertTrue(loaded.isStillRunning)
        XCTAssertFalse(OwnershipRecord(pid: pid, startTime: started - 60, port: 8737).isStillRunning,
                       "a recycled pid with a different start time is not ours")
        OwnershipRecord.clear(at: url)
        XCTAssertNil(OwnershipRecord.load(from: url))
    }
}
