"""Grok CLI-proxy billing maps to one subscription window."""

import json
import tempfile
import unittest
from pathlib import Path

from tools.tokenserver.grok_billing import (
    AuthView,
    load_auth,
    parse_billing,
    quota_label,
)


def _entry(token="header.payload.sig", expires="2099-01-01T00:00:00Z"):
    return {
        "key": token,
        "refresh_token": "do-not-keep",
        "expires_at": expires,
    }


class GrokBillingTests(unittest.TestCase):
    def test_prefers_the_xai_oidc_entry_and_hides_the_token(self):
        path = self._write({
            "https://accounts.x.ai/sign-in": _entry("aaa.other.sig"),
            "https://auth.x.ai::tenant": _entry("aaa.preferred.sig"),
        })
        auth = load_auth(path, 1_700_000_000)
        self.assertEqual(auth.status, "ready")
        self.assertEqual(auth.access_token, "aaa.preferred.sig")
        self.assertNotIn("do-not-keep", repr(auth))
        self.assertNotIn("preferred", repr(auth))
        self.assertIsInstance(auth, AuthView)

    def test_expired_login_is_not_sent(self):
        path = self._write({
            "https://auth.x.ai::tenant": _entry(expires="2020-01-01T00:00:00Z"),
        })
        self.assertEqual(load_auth(path, 1_700_000_000).status, "expired")
        self.assertIsNone(load_auth(path, 1_700_000_000).access_token)

    def _write(self, payload) -> Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "auth.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def test_management_key_is_not_a_bearer(self):
        path = self._write({
            "https://auth.x.ai::tenant": _entry("xai-secret-key"),
        })
        self.assertEqual(load_auth(path, 1_700_000_000).status, "missing")

    def test_credit_percent_wins_over_the_on_demand_ratio(self):
        parsed = parse_billing({
            "config": {
                "creditUsagePercent": 0.4,
                "onDemandUsed": {"val": 50},
                "onDemandCap": {"val": 100},
                "currentPeriod": {
                    "start": "2026-09-16T00:00:00Z",
                    "end": "2026-09-23T00:00:00Z",
                },
            }
        })
        self.assertEqual(parsed["pct"], 0.4)
        self.assertEqual(parsed["label"], "WEEKLY")

    def test_ratio_is_only_the_fallback_and_a_zero_cap_stays_unknown(self):
        parsed = parse_billing({
            "config": {
                "onDemandUsed": {"val": 25},
                "onDemandCap": {"val": 100},
                "billingPeriodStart": "2026-09-01T00:00:00Z",
                "billingPeriodEnd": "2026-10-01T00:00:00Z",
            }
        })
        self.assertEqual(parsed["pct"], 25.0)
        self.assertEqual(parsed["label"], "MONTHLY")
        self.assertIsNone(parse_billing({
            "config": {
                "currentPeriod": {
                    "start": "2026-09-01T00:00:00Z",
                    "end": "2026-09-08T00:00:00Z",
                }
            }
        }))
        self.assertIsNone(parse_billing({
            "config": {
                "onDemandUsed": {"val": 10},
                "onDemandCap": {"val": 0},
            }
        }))

    def test_window_label_is_credits_when_the_span_is_not_a_known_cycle(self):
        self.assertEqual(quota_label(None, 100), "CREDITS")
        self.assertEqual(quota_label(0, 3 * 86400), "CREDITS")


if __name__ == "__main__":
    unittest.main()
