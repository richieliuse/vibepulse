import XCTest
@testable import VibePulseBarCore

final class ProviderUsageTests: XCTestCase {
    func testCodexRunsOutBeforeReset() throws {
        let tokens = try XCTUnwrap(TokensSnapshot(data: fixture("tokens-live.json")))
        let codex = ProviderUsage.build(.codex, from: tokens)
        let week = try XCTUnwrap(codex.metrics.first { $0.id == "codex.week" })
        XCTAssertEqual(week.pace, .runsOutEarly(minutesBeforeReset: 7499, minutesFromNow: 9483 - 7499))
        XCTAssertEqual(week.delta, 1)
        XCTAssertEqual(week.remainingPercent, 68)
        XCTAssertEqual(codex.primary?.id, "codex.week")
    }

    func testClaudeWithoutQuotaHasNoData() throws {
        let tokens = try XCTUnwrap(TokensSnapshot(data: fixture("tokens-live.json")))
        let claude = ProviderUsage.build(.claude, from: tokens)
        XCTAssertFalse(claude.hasData)
        XCTAssertNil(claude.mostConstrained)
        XCTAssertTrue(claude.metrics.allSatisfy { $0.pace == nil },
                      "a forecast is never shown under a percentage it does not measure")
    }

    func testClaudeFull() throws {
        let tokens = try XCTUnwrap(TokensSnapshot(data: fixture("tokens-full.json")))
        let claude = ProviderUsage.build(.claude, from: tokens)
        XCTAssertEqual(claude.metrics.map(\.title), ["Session", "Weekly", "Fable · Week"])
        XCTAssertEqual(claude.primary?.id, "claude.modelWeek")
        XCTAssertEqual(claude.mostConstrained?.id, "claude.week")
        XCTAssertEqual(claude.metrics[1].pace, .lastsToReset(projectedPercent: 88))
        XCTAssertEqual(claude.session?.delta, 9)
    }

    func testGrokAndCursorTitles() throws {
        let tokens = try XCTUnwrap(TokensSnapshot(data: fixture("tokens-live.json")))
        XCTAssertEqual(ProviderUsage.build(.grok, from: tokens).metrics.first?.title, "Weekly credits")
        let cursor = ProviderUsage.build(.cursor, from: tokens)
        XCTAssertEqual(cursor.metrics.map(\.title), ["Total", "Cursor models", "Third party", "Grok Bot"])
        XCTAssertEqual(cursor.mostConstrained?.id, "cursor.third")
    }

    func testPlaceholdersWithoutSnapshot() {
        for provider in Provider.allCases {
            let usage = ProviderUsage.build(provider, from: nil)
            XCTAssertFalse(usage.metrics.isEmpty)
            XCTAssertFalse(usage.hasData)
        }
    }

    func testPaceRules() {
        let window = QuotaWindow(usedPercent: 50, resetMinutes: 600, stale: false)
        func pace(_ state: Forecast.State?, offset: Int? = nil, atReset: Int? = nil,
                  window: QuotaWindow = window) -> PaceNote? {
            ProviderUsage.pace(Forecast(state: state, pctAtReset: atReset, offsetMinutes: offset), window: window)
        }
        XCTAssertNil(pace(.exhausts, offset: 0), "exhausting exactly at reset is not a warning")
        XCTAssertNil(pace(.exhausts, offset: 30))
        XCTAssertNil(pace(.exhausts, offset: -700), "a projection already in the past is dropped")
        XCTAssertEqual(pace(.exhausts, offset: -120), .runsOutEarly(minutesBeforeReset: 120, minutesFromNow: 480))
        XCTAssertEqual(pace(.atReset, atReset: 71), .lastsToReset(projectedPercent: 71))
        XCTAssertEqual(pace(.collecting), .collecting)
        XCTAssertNil(pace(.unavailable))
        XCTAssertNil(pace(.collecting, window: QuotaWindow(usedPercent: 50, resetMinutes: 600, stale: true)),
                     "a stale window gets no forecast")
    }

    func testClampsWirePercent() {
        let metric = QuotaMetric(id: "x", title: "X", window: QuotaWindow(usedPercent: 104, resetMinutes: nil,
                                                                         stale: false))
        XCTAssertEqual(metric.usedPercent, 100)
        XCTAssertEqual(metric.remainingPercent, 0)
    }

    func testTitleCase() {
        XCTAssertEqual(ProviderUsage.titleCase("FABLE · WEEK"), "Fable · Week")
        XCTAssertNil(ProviderUsage.titleCase("  "))
        XCTAssertNil(ProviderUsage.titleCase(nil))
    }
}
