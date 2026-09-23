"""Codex OAuth usage mapping. No network and no real auth.json."""

import base64
import json
import tempfile
import unittest
from pathlib import Path

from tools.tokenserver import codex_oauth


def _jwt(exp):
    payload = base64.urlsafe_b64encode(
        json.dumps({"exp": exp}).encode("utf-8")).decode("ascii").rstrip("=")
    return f"header.{payload}.sig"


class CodexOAuthTests(unittest.TestCase):
    def test_usage_url_follows_codex_path_style(self):
        self.assertEqual(
            codex_oauth.usage_url(None),
            "https://chatgpt.com/backend-api/wham/usage")
        self.assertEqual(
            codex_oauth.usage_url("https://chatgpt.com/backend-api"),
            "https://chatgpt.com/backend-api/wham/usage")
        self.assertEqual(
            codex_oauth.usage_url("https://example.com"),
            "https://example.com/api/codex/usage")
        self.assertIsNone(codex_oauth.usage_url("http://chatgpt.com/backend-api"))
        self.assertIsNone(codex_oauth.usage_url(
            "https://user:pass@chatgpt.com/backend-api"))

    def test_config_base_ignores_comments(self):
        text = '\n'.join([
            '# chatgpt_base_url = "https://evil.example"',
            'chatgpt_base_url = "https://chatgpt.com/backend-api"',
        ])
        self.assertEqual(
            codex_oauth.base_url_from_config(text),
            "https://chatgpt.com/backend-api")

    def test_expired_token_is_not_returned(self):
        token = _jwt(1_700_000_000)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "auth.json"
            path.write_text(json.dumps({
                "tokens": {
                    "access_token": token,
                    "refresh_token": "refresh-secret",
                    "account_id": "acct",
                },
            }), encoding="utf-8")
            view = codex_oauth.load_auth(path, now_ts=1_700_000_001)
        self.assertEqual(view.status, "expired")
        self.assertIsNone(view.access_token)
        self.assertNotIn(token, repr(view))
        self.assertNotIn("refresh-secret", repr(view))

    def test_ready_token_stays_out_of_repr(self):
        token = _jwt(1_900_000_000)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "auth.json"
            path.write_text(json.dumps({
                "tokens": {"access_token": token, "account_id": "acct"},
            }), encoding="utf-8")
            view = codex_oauth.load_auth(path, now_ts=1_800_000_000)
        self.assertEqual(view.status, "ready")
        self.assertEqual(view.access_token, token)
        self.assertEqual(view.account_id, "acct")
        self.assertNotIn(token, repr(view))

    def test_api_key_only_file_is_missing(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "auth.json"
            path.write_text(json.dumps({"OPENAI_API_KEY": "sk-test"}),
                            encoding="utf-8")
            view = codex_oauth.load_auth(path, now_ts=1_800_000_000)
        self.assertEqual(view.status, "missing")
        self.assertIsNone(view.access_token)

    def test_retry_after_accepts_seconds_and_http_date(self):
        self.assertEqual(codex_oauth.retry_after_seconds("42", 0), 42)
        self.assertEqual(
            codex_oauth.retry_after_seconds(
                "Thu, 01 Jan 1970 00:02:00 GMT", 0), 120)

    def test_non_minute_window_is_dropped(self):
        body = codex_oauth.app_server_body({
            "rate_limit": {
                "primary_window": {
                    "used_percent": 10,
                    "limit_window_seconds": 18001,
                    "reset_at": 1_900_000_000,
                },
            },
        })
        self.assertIsNone(body)


if __name__ == "__main__":
    unittest.main()
