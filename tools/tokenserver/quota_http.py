"""One JSON request that refuses redirects.

A bearer token is attached by the caller. Following a redirect would send
that token to whatever host the usage service named, so this opener never
does. Response bodies are not logged.
"""

from __future__ import annotations

import json
from email.utils import parsedate_to_datetime
from typing import Optional
from urllib import error, request

_MAX_BODY = 1024 * 1024


class NoRedirect(request.HTTPRedirectHandler):
    """Refuse redirects so a bearer token cannot leave the usage host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


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


def exchange(url: str, *, method: str = "GET", headers: dict,
             body: Optional[bytes] = None, timeout: float = 15,
             now_ts: float = 0.0, opener=None):
    """Return ``(status, payload, retry_after)``.

    ``status`` is 0 when the connection itself failed. ``payload`` is a
    dict only for a JSON object; anything else is ``None``.
    """
    req = request.Request(url, data=body, headers=headers, method=method)
    if opener is None:
        opener = request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=timeout) as response:
            raw = response.read(_MAX_BODY + 1)
            status = getattr(response, "status", 200) or 200
    except error.HTTPError as failure:
        retry = retry_after_seconds(
            (failure.headers or {}).get("Retry-After"), now_ts)
        return failure.code, None, retry
    except Exception:
        return 0, None, 0
    if len(raw) > _MAX_BODY:
        return 0, None, 0
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return status, None, 0
    if not isinstance(payload, dict):
        return status, None, 0
    return status, payload, 0
