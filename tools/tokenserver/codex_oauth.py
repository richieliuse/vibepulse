"""Codex quota from the ChatGPT OAuth usage API.

The app reads the Codex CLI's local ``auth.json`` and calls the same usage
endpoint CodexBar prefers. It never refreshes a token and never writes
``auth.json``. A missing or rejected credential is a status the caller can
turn into the local CLI fallback. Tokens are not logged.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlsplit, urlunsplit

DEFAULT_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
_AUTH_MAX_BYTES = 256 * 1024
_BASE_RE = re.compile(
    r"""(?m)^[ \t]*chatgpt_base_url[ \t]*=[ \t]*(['"])([^'"]+)\1[ \t]*$""")


class AuthView:
    """A content-free view plus the token the caller must not log."""

    def __init__(self, status: str, access_token: Optional[str] = None,
                 account_id: Optional[str] = None,
                 expires_at: Optional[float] = None):
        self.status = status
        self.access_token = access_token
        self.account_id = account_id
        self.expires_at = expires_at

    def __repr__(self) -> str:
        return (f"AuthView(status={self.status!r}, "
                f"has_token={bool(self.access_token)}, "
                f"has_account={bool(self.account_id)})")


def auth_path(environ: Optional[dict] = None,
              home: Optional[Path] = None) -> Path:
    """``$CODEX_HOME/auth.json``, or ``~/.codex/auth.json``."""
    env = os.environ if environ is None else environ
    configured = env.get("CODEX_HOME")
    root = Path(configured).expanduser() if configured else (
        (home if home is not None else Path.home()) / ".codex")
    return root / "auth.json"


def config_path(environ: Optional[dict] = None,
                home: Optional[Path] = None) -> Path:
    return auth_path(environ, home).with_name("config.toml")


def token_fingerprint(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def usage_url(base: Optional[str]) -> Optional[str]:
    """Map ``chatgpt_base_url`` onto the usage path Codex itself uses.

    A base that already contains ``/backend-api`` gets ``/wham/usage``.
    Anything else gets ``/api/codex/usage``. Only ``https`` URLs without
    userinfo are accepted, so a crafted base cannot redirect the bearer
    token.
    """
    if base is None:
        return DEFAULT_USAGE_URL
    text = str(base).strip().rstrip("/")
    if not text:
        return DEFAULT_USAGE_URL
    parts = urlsplit(text)
    if (parts.scheme != "https" or not parts.hostname or parts.username
            or parts.password or parts.query or parts.fragment):
        return None
    path = parts.path.rstrip("/")
    if path.endswith("/wham/usage") or path.endswith("/api/codex/usage"):
        usage_path = path
    elif "/backend-api" in path:
        usage_path = path + "/wham/usage"
    else:
        usage_path = path + "/api/codex/usage"
    return urlunsplit((parts.scheme, parts.netloc, usage_path, "", ""))


def base_url_from_config(text: str) -> Optional[str]:
    """The ``chatgpt_base_url`` assignment, ignoring commented lines."""
    match = _BASE_RE.search(text)
    if match is None:
        return None
    return match.group(2).strip() or None


def _jwt_expiry(token: str) -> Optional[float]:
    parts = token.split(".")
    if len(parts) < 2:
        return None
    payload = parts[1]
    pad = "=" * (-len(payload) % 4)
    try:
        data = json.loads(base64.urlsafe_b64decode(payload + pad))
    except (ValueError, json.JSONDecodeError):
        return None
    exp = data.get("exp") if isinstance(data, dict) else None
    if isinstance(exp, bool) or not isinstance(exp, (int, float)):
        return None
    return float(exp)


def load_auth(path: Path, now_ts: float) -> AuthView:
    """Read ``tokens.access_token`` without retaining the refresh token."""
    try:
        size = path.stat().st_size
    except FileNotFoundError:
        return AuthView("missing")
    except OSError:
        return AuthView("malformed")
    if size <= 0 or size > _AUTH_MAX_BYTES:
        return AuthView("malformed")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return AuthView("malformed")
    tokens = payload.get("tokens") if isinstance(payload, dict) else None
    if not isinstance(tokens, dict):
        return AuthView("missing")
    access = tokens.get("access_token")
    if not isinstance(access, str) or not access.strip() or any(
            ch.isspace() for ch in access):
        return AuthView("missing")
    account = tokens.get("account_id")
    account_id = account if isinstance(account, str) and account else None
    expires_at = _jwt_expiry(access)
    if expires_at is not None and expires_at <= now_ts:
        return AuthView("expired", expires_at=expires_at)
    return AuthView("ready", access_token=access, account_id=account_id,
                    expires_at=expires_at)


def _minutes(seconds: Any) -> Optional[int]:
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)):
        return None
    if seconds <= 0 or seconds % 60 != 0:
        return None
    return int(seconds // 60)


def _http_window(window: Any) -> Optional[dict]:
    if not isinstance(window, dict):
        return None
    minutes = _minutes(window.get("limit_window_seconds"))
    if minutes is None:
        return None
    return {
        "usedPercent": window.get("used_percent"),
        "windowDurationMins": minutes,
        "resetsAt": window.get("reset_at"),
    }


def app_server_body(payload: Any) -> Optional[dict]:
    """Turn a ``wham/usage`` document into the app-server rate-limit shape.

    Named ``additional_rate_limits`` are left out. The weekly contract only
    accepts an unnamed 10080-minute window, and the caller already classifies
    primary/secondary by duration.
    """
    if not isinstance(payload, dict):
        return None
    rate_limit = payload.get("rate_limit")
    if not isinstance(rate_limit, dict):
        return None
    primary = _http_window(rate_limit.get("primary_window"))
    secondary = _http_window(rate_limit.get("secondary_window"))
    if primary is None and secondary is None:
        return None
    return {
        "rateLimits": {
            "limitId": None,
            "limitName": None,
            "primary": primary,
            "secondary": secondary,
        }
    }


def retry_after_seconds(value: Optional[str], now_ts: float) -> int:
    if value is None:
        return 0
    text = str(value).strip()
    try:
        seconds = int(text)
    except ValueError:
        seconds = None
    if seconds is not None and seconds >= 0:
        return seconds
    try:
        when = parsedate_to_datetime(text).timestamp()
    except (TypeError, ValueError, OverflowError):
        return 0
    return max(0, int(round(when - now_ts)))
