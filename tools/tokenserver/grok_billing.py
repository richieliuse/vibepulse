"""Grok subscription credits from the local CLI login.

Reads ``$GROK_HOME/auth.json`` (or ``~/.grok/auth.json``) and calls the same
CLI-proxy billing URL CodexBar uses. The access token is not refreshed,
written back, or logged. Browser cookies and the grok.com gRPC fallback are
not used: a missing or rejected CLI login stays unknown.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

try:
    from .quota_http import exchange
except ImportError:  # python3 tools/tokenserver/tokenserver.py
    from quota_http import exchange

BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
_AUTH_MAX_BYTES = 256 * 1024
_PREFERRED_PREFIX = "https://auth.x.ai::"


class AuthView:
    """Content-free view. The token stays off ``repr``."""

    def __init__(self, status: str, access_token: Optional[str] = None):
        self.status = status
        self.access_token = access_token

    def __repr__(self) -> str:
        return (f"AuthView(status={self.status!r}, "
                f"has_token={bool(self.access_token)})")


def auth_path(environ: Optional[dict] = None,
              home: Optional[Path] = None) -> Path:
    env = os.environ if environ is None else environ
    configured = env.get("GROK_HOME")
    root = Path(configured).expanduser() if configured else (
        (home if home is not None else Path.home()) / ".grok")
    return root / "auth.json"


def parse_time(value) -> Optional[float]:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        stamp = float(value)
        if stamp > 10_000_000_000:
            stamp /= 1000.0
        if stamp < 1_000_000_000:
            return None
        return stamp
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if text.isdigit():
        return parse_time(int(text))
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def as_percent(value) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if number != number or number < 0:  # NaN
        return None
    if number > 100:
        if number > 1000:
            return None
        number = 100.0
    return round(number, 1)


def _money(node) -> Optional[float]:
    if isinstance(node, dict):
        node = node.get("val")
    if isinstance(node, bool) or not isinstance(node, (int, float)):
        return None
    number = float(node)
    if number != number or number < 0:
        return None
    return number


def _usable_token(token: str) -> bool:
    if token.startswith("xai-"):
        return False
    if token.count(".") < 2:
        return False
    if "=" in token and token.count(".") < 2:
        return False
    return True


def _entry_token(entry: dict, now_ts: float) -> Optional[str]:
    token = entry.get("key")
    if not isinstance(token, str) or not _usable_token(token):
        return None
    expires = parse_time(entry.get("expires_at"))
    if expires is not None and expires <= now_ts:
        return None
    return token


def load_auth(path: Path, now_ts: float) -> AuthView:
    """Read the bearer ``key``. The refresh token is never retained."""
    try:
        size = path.stat().st_size
    except FileNotFoundError:
        return AuthView("missing")
    except OSError:
        return AuthView("unreadable")
    if size <= 0 or size > _AUTH_MAX_BYTES:
        return AuthView("malformed")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return AuthView("malformed")
    if not isinstance(payload, dict):
        return AuthView("malformed")

    preferred = []
    rest = []
    expired = False
    for name, entry in payload.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("key"), str):
            continue
        expires = parse_time(entry.get("expires_at"))
        if expires is not None and expires <= now_ts:
            expired = True
            continue
        bucket = preferred if str(name).startswith(_PREFERRED_PREFIX) else rest
        bucket.append(entry)
    for entry in preferred + rest:
        token = _entry_token(entry, now_ts)
        if token:
            return AuthView("ready", token)
    if expired:
        return AuthView("expired")
    return AuthView("missing")


def quota_label(start: Optional[float], end: Optional[float]) -> str:
    """Weekly, monthly, or the generic credits label. Never a guessed week."""
    if start is None or end is None or end <= start:
        return "CREDITS"
    days = (end - start) / 86400.0
    if 6 <= days <= 8:
        return "WEEKLY"
    if 27 <= days <= 32:
        return "MONTHLY"
    return "CREDITS"


def _period_bounds(config: dict) -> tuple[Optional[float], Optional[float]]:
    current = config.get("currentPeriod")
    start = end = None
    if isinstance(current, dict):
        start = parse_time(current.get("start"))
        end = parse_time(current.get("end"))
    if end is None:
        end = parse_time(config.get("billingPeriodEnd"))
        if start is None:
            start = parse_time(config.get("billingPeriodStart"))
    return start, end


def parse_billing(payload) -> Optional[dict]:
    """Map a credits document to percent, reset, and a window label.

    ``creditUsagePercent`` wins. The on-demand ratio is only a fallback when
    that field is absent and the cap is a positive number. A period with
    neither value is unknown, not 0%.
    """
    if not isinstance(payload, dict):
        return None
    config = payload.get("config")
    if not isinstance(config, dict):
        config = {}
    percent = None
    found_field = False
    for source in (config, payload):
        if "creditUsagePercent" not in source:
            continue
        found_field = True
        percent = as_percent(source.get("creditUsagePercent"))
        break
    if not found_field:
        used = _money(config.get("onDemandUsed"))
        if used is None:
            used = _money(payload.get("onDemandUsed"))
        cap = _money(config.get("onDemandCap"))
        if cap is None:
            cap = _money(payload.get("onDemandCap"))
        if used is not None and cap is not None and cap > 0:
            percent = as_percent(used / cap * 100.0)
    if percent is None:
        return None
    start, end = _period_bounds(config)
    return {
        "pct": percent,
        "reset_at": end,
        "label": quota_label(start, end),
    }


def fetch(now_ts: float, opener=None) -> dict:
    """One billing read. Returns a probe reading, never a token."""
    auth = load_auth(auth_path(), now_ts)
    if auth.status == "expired":
        return {"auth": "expired", "status": "token_expired"}
    if auth.status != "ready" or not auth.access_token:
        status = {
            "missing": "no_grok_oauth_token",
            "malformed": "grok_auth_malformed",
            "unreadable": "grok_auth_unreadable",
        }.get(auth.status, "no_grok_oauth_token")
        return {"auth": "missing", "status": status}
    headers = {
        "Authorization": f"Bearer {auth.access_token}",
        "x-xai-token-auth": "xai-grok-cli",
        "Accept": "application/json",
        "User-Agent": "vibepulse",
    }
    status, payload, retry = exchange(
        BILLING_URL, headers=headers, now_ts=now_ts, opener=opener)
    if status == 429:
        return {"auth": "ready", "status": "rate_limited",
                "retry_after": retry}
    if status in (401, 403):
        return {"auth": "unauthorized", "status": "token_dead_awaiting_refresh"}
    if status != 200 or payload is None:
        return {"auth": "ready", "status": "transport"}
    parsed = parse_billing(payload)
    if parsed is None:
        return {"auth": "ready", "status": "unmapped"}
    return {"auth": "ready", "status": "ok", "reading": parsed}
