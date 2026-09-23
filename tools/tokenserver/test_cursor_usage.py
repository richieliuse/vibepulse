"""Cursor usage-summary and Grok Bot mapping, without a network call."""

import base64
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from tools.tokenserver.cursor_usage import (
    decode_token,
    jwt_expiry,
    load_token,
    parse_sand,
    parse_summary,
    session_cookie,
)


def _jwt(exp):
    body = base64.urlsafe_b64encode(
        json.dumps({"exp": exp}).encode()).rstrip(b"=").decode()
    return f"aaa.{body}.sig"


class CursorUsageTests(unittest.TestCase):
    def test_utf16_blob_and_quoted_text_decode_to_the_same_token(self):
        token = _jwt(1_800_000_000)
        self.assertEqual(decode_token(token.encode("utf-16-le")), token)
        self.assertEqual(decode_token(f'"{token}"'), token)
        self.assertEqual(jwt_expiry(token), 1_800_000_000)

    def test_expired_or_missing_db_does_not_return_a_token(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.vscdb"
            self.assertEqual(load_token(path, 1_700_000_000), ("missing", None))
            connection = sqlite3.connect(path)
            connection.execute(
                "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)")
            connection.execute(
                "INSERT INTO ItemTable VALUES (?, ?)",
                ("cursorAuth/accessToken", _jwt(1_700_000_000).encode()))
            connection.commit()
            connection.close()
            self.assertEqual(load_token(path, 1_700_000_000)[0], "expired")
            connection = sqlite3.connect(path)
            connection.execute(
                "UPDATE ItemTable SET value = ? WHERE key = ?",
                (_jwt(1_800_000_000).encode(), "cursorAuth/accessToken"))
            connection.commit()
            connection.close()
            status, token = load_token(path, 1_700_000_000)
            self.assertEqual(status, "ready")
            self.assertEqual(token, _jwt(1_800_000_000))

    def test_plan_percents_stay_in_percent_units(self):
        parsed = parse_summary({
            "billingCycleEnd": "1771077734000",
            "individualUsage": {
                "plan": {
                    "totalPercentUsed": 0.36,
                    "autoPercentUsed": 17.2,
                    "apiPercentUsed": 0,
                }
            },
        })
        self.assertEqual(parsed["total"]["pct"], 0.4)
        self.assertEqual(parsed["models"]["pct"], 17.2)
        self.assertEqual(parsed["third"]["pct"], 0.0)
        self.assertIsNotNone(parsed["total"]["reset_at"])

    def test_plan_usage_shape_is_accepted(self):
        parsed = parse_summary({
            "billingCycleEnd": "2026-10-01T00:00:00Z",
            "planUsage": {"totalPercentUsed": 15.48, "apiPercentUsed": 46.4},
        })
        self.assertEqual(parsed["total"]["pct"], 15.5)
        self.assertIsNone(parsed["models"]["pct"])
        self.assertEqual(parsed["third"]["pct"], 46.4)

    def test_sand_allowance_gates_the_fourth_bar(self):
        now = 1_700_000_000
        self.assertIsNone(parse_sand({
            "includedLimitZero": True,
            "usagePercent": 80,
        }, now)["pct"])
        live = parse_sand({
            "includedLimitZero": False,
            "usagePercent": 12.5,
            "nextResetTimestampUtc": "2026-09-30T00:00:00Z",
        }, now)
        self.assertEqual(live["pct"], 12.5)
        self.assertIsNotNone(live["reset_at"])
        trial = parse_sand({
            "includedLimitZero": True,
            "sandTrialExpiresAt": "2099-01-01T00:00:00Z",
            "usagePercent": 3,
            "nextResetTimestampUtc": "2099-01-08T00:00:00Z",
        }, now)
        self.assertEqual(trial["pct"], 3.0)
        self.assertIsNone(trial["reset_at"])

    def test_dashboard_cookie_uses_the_subject_suffix(self):
        body = base64.urlsafe_b64encode(json.dumps({
            "sub": "auth0|user_01ABC",
            "exp": 1_800_000_000,
        }).encode()).rstrip(b"=").decode()
        token = f"hdr.{body}.sig"
        self.assertEqual(
            session_cookie(token),
            f"WorkosCursorSessionToken=user_01ABC%3A%3A{token}")
        bad = base64.urlsafe_b64encode(json.dumps({
            "sub": "auth0|not a user",
        }).encode()).rstrip(b"=").decode()
        self.assertIsNone(session_cookie(f"hdr.{bad}.sig"))


if __name__ == "__main__":
    unittest.main()
