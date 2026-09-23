"""Cursor subscription usage from the local Cursor.app session.

On macOS the first source is the read-only state database, the same one
CodexBar prefers. The access token is not refreshed or logged. Browser
cookies and ``/api/auth/me`` are not used. A Grok Bot failure leaves the
other three bars alone.
"""

from __future__ import annotations

import base64
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from typing import Optional
from urllib.parse import quote

try:
    from .grok_billing import as_percent, parse_time
    from .quota_http import exchange
except ImportError:  # python3 tools/tokenserver/tokenserver.py
    from grok_billing import as_percent, parse_time
    from quota_http import exchange

USAGE_URL = "https://cursor.com/api/usage-summary"
SAND_URL = "https://cursor.com/api/dashboard/get-sand-usage-status"
_TOKEN_KEY = "cursorAuth/accessToken"
_SKEW_S = 60
# The dashboard accepts the app JWT only as this cookie, with the user id
# from the JWT subject joined by a literal %3A%3A. It is not a bearer token
# and it is not written anywhere.
_USER_ID = re.compile(r"^[A-Za-z0-9._-]+$")


def db_path(environ: Optional[dict] = None,
            home: Optional[Path] = None) -> Path:
    env = os.environ if environ is None else environ
    root = home if home is not None else Path.home()
    if sys.platform == "darwin":
        return (root / "Library/Application Support/Cursor/User/"
                "globalStorage/state.vscdb")
    if sys.platform == "win32":
        appdata = env.get("APPDATA")
        base = Path(appdata) if appdata else root / "AppData/Roaming"
        return base / "Cursor/User/globalStorage/state.vscdb"
    configured = env.get("XDG_CONFIG_HOME")
    if configured and Path(configured).is_absolute():
        return Path(configured) / "Cursor/User/globalStorage/state.vscdb"
    return root / ".config/Cursor/User/globalStorage/state.vscdb"


def decode_token(raw) -> Optional[str]:
    """SQLite may store the JWT as UTF-8 or BOM-less ASCII UTF-16LE."""
    if isinstance(raw, str):
        text = raw
    elif isinstance(raw, (bytes, bytearray)):
        data = bytes(raw)
        if data.startswith(b"\xff\xfe") or (
                len(data) % 2 == 0 and data and
                all(data[index] == 0 for index in range(1, len(data), 2))):
            text = data.decode("utf-16-le", errors="replace")
        else:
            text = data.decode("utf-8", errors="replace")
    else:
        return None
    text = text.strip("\x00 \t\r\n")
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        text = text[1:-1]
    text = text.strip()
    return text or None


def jwt_expiry(token: str) -> Optional[float]:
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


def _sqlite_uri(path: Path, immutable: bool) -> str:
    quoted = quote(path.as_posix(), safe="/:")
    flags = "mode=ro&immutable=1" if immutable else "mode=ro"
    return f"file:{quoted}?{flags}"


def load_token(path: Path, now_ts: float) -> tuple[str, Optional[str]]:
    """Return ``(status, token)``. Status is ready, missing, or expired."""
    if not path.is_file():
        return "missing", None
    wal = path.with_name(path.name + "-wal")
    uri = _sqlite_uri(path, immutable=not wal.exists())
    try:
        connection = sqlite3.connect(uri, uri=True)
    except sqlite3.Error:
        return "missing", None
    try:
        try:
            row = connection.execute(
                "SELECT value FROM ItemTable WHERE key = ?",
                (_TOKEN_KEY,),
            ).fetchone()
        except sqlite3.Error:
            return "missing", None
    finally:
        connection.close()
    if not row:
        return "missing", None
    token = decode_token(row[0])
    if not token or token.count(".") < 2:
        return "missing", None
    expires = jwt_expiry(token)
    if expires is None or expires <= now_ts + _SKEW_S:
        return "expired", None
    return "ready", token


def plan_block(payload: dict) -> Optional[dict]:
    individual = payload.get("individualUsage")
    if isinstance(individual, dict) and isinstance(individual.get("plan"), dict):
        return individual["plan"]
    plan = payload.get("planUsage")
    if isinstance(plan, dict):
        return plan
    return None


def _lane(block: Optional[dict], key: str, reset_at: Optional[float]) -> dict:
    if block is None or key not in block:
        return {"pct": None, "reset_at": reset_at if block else None}
    return {"pct": as_percent(block.get(key)), "reset_at": reset_at}


def parse_summary(payload) -> Optional[dict]:
    """Three plan bars. Missing percent fields stay unknown, not zero."""
    if not isinstance(payload, dict):
        return None
    block = plan_block(payload)
    if block is None:
        return None
    reset_at = parse_time(payload.get("billingCycleEnd"))
    return {
        "total": _lane(block, "totalPercentUsed", reset_at),
        "models": _lane(block, "autoPercentUsed", reset_at),
        "third": _lane(block, "apiPercentUsed", reset_at),
    }


def parse_sand(payload, now_ts: float) -> dict:
    """Grok Bot. No allowance is an empty lane, not a failed request."""
    empty = {"pct": None, "reset_at": None}
    if not isinstance(payload, dict):
        return empty
    included_zero = payload.get("includedLimitZero")
    has_nonzero = payload.get("hasNonZeroIncludedLimit")
    if isinstance(included_zero, bool):
        has_limit = not included_zero
    elif isinstance(has_nonzero, bool):
        has_limit = has_nonzero
    else:
        has_limit = None
    trial = parse_time(payload.get("sandTrialExpiresAt"))
    has_trial = has_limit is not True and trial is not None and trial > now_ts
    if has_limit is not True and not has_trial:
        return empty
    percent = as_percent(payload.get("usagePercent"))
    if percent is None:
        return empty
    reset_at = None
    if has_limit is True:
        reset_at = parse_time(payload.get("nextResetTimestampUtc"))
    return {"pct": percent, "reset_at": reset_at}


def session_user_id(token: str) -> Optional[str]:
    """User id from the JWT subject. The subject itself is not returned."""
    parts = token.split(".")
    if len(parts) < 2:
        return None
    payload = parts[1]
    pad = "=" * (-len(payload) % 4)
    try:
        data = json.loads(base64.urlsafe_b64decode(payload + pad))
    except (ValueError, json.JSONDecodeError):
        return None
    subject = data.get("sub") if isinstance(data, dict) else None
    if not isinstance(subject, str):
        return None
    user_id = subject.split("|")[-1].strip()
    if not user_id or _USER_ID.fullmatch(user_id) is None:
        return None
    return user_id


def session_cookie(token: str) -> Optional[str]:
    user_id = session_user_id(token)
    if not user_id:
        return None
    return f"WorkosCursorSessionToken={user_id}%3A%3A{token}"


def _headers(token: str, origin: bool = False) -> Optional[dict]:
    cookie = session_cookie(token)
    if not cookie:
        return None
    headers = {
        "Cookie": cookie,
        "Accept": "application/json",
        "User-Agent": "vibepulse",
    }
    if origin:
        headers["Origin"] = "https://cursor.com"
        headers["Content-Type"] = "application/json"
    return headers


def fetch(now_ts: float, opener=None) -> dict:
    """Usage-summary plus best-effort Grok Bot. No token in the result."""
    status, token = load_token(db_path(), now_ts)
    if status == "expired":
        return {"auth": "expired", "summary": "skipped", "sand": "skipped"}
    headers = _headers(token) if status == "ready" and token else None
    if status != "ready" or not token or headers is None:
        return {"auth": "missing", "summary": "skipped", "sand": "skipped"}
    code, payload, retry = exchange(
        USAGE_URL, headers=headers, now_ts=now_ts, opener=opener)
    result = {"auth": "ready", "retry_after": retry, "sand": "skipped"}
    if code == 429:
        result["summary"] = "rate_limited"
        return result
    if code in (401, 403):
        result["auth"] = "unauthorized"
        result["summary"] = "unauthorized"
        return result
    if code != 200 or payload is None:
        result["summary"] = "transport"
        return result
    parsed = parse_summary(payload)
    if parsed is None:
        result["summary"] = "unmapped"
    else:
        result["summary"] = "ok"
        result.update(parsed)
    sand_headers = _headers(token, origin=True)
    if sand_headers is None:
        result["sand"] = "skipped"
        return result
    sand_code, sand_payload, sand_retry = exchange(
        SAND_URL, method="POST", headers=sand_headers,
        body=b"{}", now_ts=now_ts, opener=opener)
    if sand_code == 200 and sand_payload is not None:
        bot = parse_sand(sand_payload, now_ts)
        result["sand"] = "none" if bot["pct"] is None else "ok"
        result["bot"] = bot
    else:
        result["sand"] = "failed"
        if sand_code == 429:
            result["retry_after"] = max(retry, sand_retry)
            result["sand"] = "rate_limited"
    return result
