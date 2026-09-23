"""Probe cadence: keep the last reading, and rest after HTTP 429."""

import unittest

from tools.tokenserver.subscription_quota import Probe


class _Clock:
    def __init__(self):
        self.wall = 1_700_000_000.0


class SubscriptionQuotaTests(unittest.TestCase):
    def test_success_then_transport_keeps_a_stale_percent(self):
        clock = _Clock()
        answers = [{
            "auth": "ready",
            "status": "ok",
            "reading": {"pct": 42.0, "reset_at": clock.wall + 3 * 86400,
                        "label": "WEEKLY"},
        }, {
            "auth": "ready",
            "status": "transport",
        }]
        probe = Probe("grok", lambda _now: answers.pop(0))
        probe.refresh_inline(0, clock.wall)
        wire = probe.fields(clock.wall + 120)
        self.assertEqual(wire["grokCreditPct"], 42.0)
        self.assertEqual(wire["grokCreditResetMin"], 3 * 24 * 60 - 2)
        self.assertFalse(wire["grokCreditStale"])
        self.assertEqual(wire["grokQuotaLabel"], "WEEKLY")
        probe.refresh_inline(300, clock.wall + 300)
        stale = probe.fields(clock.wall + 300)
        self.assertEqual(stale["grokCreditPct"], 42.0)
        self.assertTrue(stale["grokCreditStale"])
        self.assertGreaterEqual(probe.interval_s(), 480)

    def test_rate_limit_rests_at_least_ten_minutes(self):
        clock = _Clock()
        probe = Probe("grok", lambda _now: {
            "auth": "ready",
            "status": "ok",
            "reading": {"pct": 10, "reset_at": clock.wall + 86400,
                        "label": "CREDITS"},
        })
        probe.refresh_inline(0, clock.wall)
        probe.fetch = lambda _now: {
            "auth": "ready", "status": "rate_limited", "retry_after": 30}
        probe.refresh_inline(300, clock.wall + 10)
        self.assertGreaterEqual(probe.cooldown_until - (clock.wall + 10), 600)
        self.assertTrue(probe.fields(clock.wall + 10)["grokCreditStale"])
        probe.refresh_inline(400, clock.wall + 20)
        self.assertEqual(probe.status.startswith("usage_http_429"), True)

    def test_cursor_sand_failure_does_not_clear_the_monthly_bars(self):
        clock = _Clock()
        reset = clock.wall + 10 * 86400
        probe = Probe("cursor", lambda _now: {
            "auth": "ready",
            "summary": "ok",
            "sand": "failed",
            "total": {"pct": 20, "reset_at": reset},
            "models": {"pct": 5, "reset_at": reset},
            "third": {"pct": 0, "reset_at": reset},
        })
        probe.refresh_inline(0, clock.wall)
        wire = probe.fields(clock.wall)
        self.assertEqual(wire["cursorTotalPct"], 20)
        self.assertEqual(wire["cursorModelsPct"], 5)
        self.assertEqual(wire["cursorThirdPct"], 0)
        self.assertIsNone(wire["cursorBotPct"])
        self.assertFalse(wire["cursorTotalStale"])
        self.assertIn("sand_failed", probe.status)

    def test_a_passed_reset_is_not_served_as_the_new_window(self):
        clock = _Clock()
        probe = Probe("grok", lambda _now: {
            "auth": "ready",
            "status": "ok",
            "reading": {"pct": 90, "reset_at": clock.wall + 30,
                        "label": "WEEKLY"},
        })
        probe.refresh_inline(0, clock.wall)
        later = probe.fields(clock.wall + 31)
        self.assertIsNone(later["grokCreditPct"])
        self.assertFalse(later["grokCreditStale"])


if __name__ == "__main__":
    unittest.main()
