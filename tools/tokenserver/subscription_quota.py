"""Background cadence for the Grok and Cursor subscription probes.

Success waits 240 s. Failures wait 480 s, then 960 s. HTTP 429 rests at
least 10 minutes and does not replace a saved reading with a blank. A
missing local credential is re-read every 15 s and never opens a connection.
"""

from __future__ import annotations

import logging
import math
import threading
import time
from datetime import datetime

try:
    from . import cursor_usage, grok_billing
except ImportError:  # python3 tools/tokenserver/tokenserver.py
    import cursor_usage
    import grok_billing

log = logging.getLogger("tokenserver")

LIMITS_EVERY_S = 240.0
AUTH_RECOVERY_EVERY_S = 15.0
RATE_LIMIT_FLOOR_S = 600

_GROK_LANE = "credit"


class _Lane:
    def __init__(self, pct, reset_at, stale):
        self.pct = pct
        self.reset_at = reset_at
        self.stale = stale


class Probe:
    def __init__(self, name: str, fetch):
        self.name = name
        self.fetch = fetch
        self._lock = threading.Lock()
        self.refreshing = False
        self.last_mono = 0.0
        self.failure_streak = 0
        self.cooldown_until = 0.0
        self.auth = "missing"
        self.status = "idle"
        self.lanes = {}
        self.label = None

    def interval_s(self) -> float:
        if self.auth in ("missing", "expired", "unauthorized"):
            return AUTH_RECOVERY_EVERY_S
        return LIMITS_EVERY_S * (2 ** min(self.failure_streak, 2))

    def _due_locked(self, now_mono: float) -> bool:
        if self.refreshing:
            return False
        if self.last_mono and now_mono - self.last_mono < self.interval_s():
            return False
        return True

    def note(self, raw: dict, now_wall: float) -> None:
        """Fold one fetch result into the saved lanes. No token is stored."""
        self.auth = raw.get("auth") or "missing"
        kind = raw.get("status") or raw.get("summary") or "transport"
        if self.name == "grok":
            self._note_grok(raw, kind, now_wall)
        else:
            self._note_cursor(raw, now_wall)

    def _mark_stale(self, names) -> None:
        for name in names:
            lane = self.lanes.get(name)
            if lane is not None and lane.pct is not None:
                lane.stale = True

    def _store(self, name: str, reading: dict) -> None:
        self.lanes[name] = _Lane(reading.get("pct"), reading.get("reset_at"),
                                 False)

    def _note_grok(self, raw: dict, kind: str, now_wall: float) -> None:
        if kind == "ok" and isinstance(raw.get("reading"), dict):
            self._store(_GROK_LANE, raw["reading"])
            self.label = raw["reading"].get("label") or "CREDITS"
            self.failure_streak = 0
            self.cooldown_until = 0.0
            self.status = "usage_http_200 + ok"
            return
        if kind == "unmapped":
            self.lanes.pop(_GROK_LANE, None)
            self.label = None
            self.failure_streak += 1
            self.status = "usage_http_200 + no_mapped_limits"
            return
        if kind == "rate_limited":
            self._mark_stale((_GROK_LANE,))
            retry = int(raw.get("retry_after") or 0)
            self.cooldown_until = now_wall + max(retry, RATE_LIMIT_FLOOR_S)
            self.failure_streak += 1
            when = datetime.fromtimestamp(self.cooldown_until)
            self.status = f"usage_http_429 + backoff_until_{when:%H:%M}"
            return
        if kind == "transport":
            self._mark_stale((_GROK_LANE,))
            self.failure_streak += 1
            self.status = "usage_request_failed"
            return
        self._mark_stale((_GROK_LANE,))
        self.failure_streak = 0
        self.status = kind

    def _note_cursor(self, raw: dict, now_wall: float) -> None:
        summary = raw.get("summary") or "skipped"
        sand = raw.get("sand") or "skipped"
        if summary in ("ok", "unmapped"):
            for name in ("total", "models", "third"):
                reading = raw.get(name) or {"pct": None, "reset_at": None}
                self._store(name, reading)
        else:
            stale = ["total", "models", "third"]
            if sand == "skipped":
                stale.append("bot")
            self._mark_stale(stale)
        if sand in ("ok", "none") and isinstance(raw.get("bot"), dict):
            self._store("bot", raw["bot"])
        elif sand in ("failed", "rate_limited"):
            self._mark_stale(("bot",))
        if summary == "rate_limited" or sand == "rate_limited":
            retry = int(raw.get("retry_after") or 0)
            self.cooldown_until = now_wall + max(retry, RATE_LIMIT_FLOOR_S)
            self.failure_streak += 1
            when = datetime.fromtimestamp(self.cooldown_until)
            self.status = f"usage_http_429 + backoff_until_{when:%H:%M}"
            return
        if summary == "transport":
            self.failure_streak += 1
            self.status = "usage_request_failed"
            return
        if summary == "unauthorized":
            self.failure_streak = 0
            self.status = "token_dead_awaiting_refresh"
            return
        if summary == "skipped":
            self.failure_streak = 0
            self.status = ("token_expired" if self.auth == "expired"
                           else "no_cursor_session")
            return
        if summary == "unmapped":
            self.failure_streak += 1
            self.status = "usage_http_200 + no_mapped_limits"
            return
        self.failure_streak = 0
        self.cooldown_until = 0.0
        suffix = "" if sand in ("ok", "none", "skipped") else "; sand_failed"
        self.status = "usage_http_200 + ok" + suffix

    def refresh_inline(self, now_mono: float, now_wall: float) -> None:
        """Run one fetch on the caller thread. Tests use this."""
        with self._lock:
            if now_wall < self.cooldown_until:
                self.failure_streak += 1
                self.last_mono = now_mono
                return
        try:
            raw = self.fetch(now_wall)
        except Exception as error:
            raw = {"auth": self.auth, "status": f"probe_crashed: {type(error).__name__}",
                   "summary": "transport", "sand": "failed"}
            log.exception("%s quota probe crashed", self.name)
        with self._lock:
            self.note(raw, now_wall)
            self.last_mono = now_mono
            self.refreshing = False

    def kick(self) -> None:
        with self._lock:
            now_mono = time.monotonic()
            if not self._due_locked(now_mono):
                return
            if time.time() < self.cooldown_until:
                self.failure_streak += 1
                self.last_mono = now_mono
                return
            self.refreshing = True
        threading.Thread(target=self._thread, name=f"{self.name}-quota",
                         daemon=True).start()

    def _thread(self) -> None:
        try:
            raw = self.fetch(time.time())
        except Exception as error:
            raw = {"auth": self.auth,
                   "status": f"probe_crashed: {type(error).__name__}",
                   "summary": "transport", "sand": "failed"}
            log.exception("%s quota probe crashed", self.name)
        with self._lock:
            self.note(raw, time.time())
            self.last_mono = time.monotonic()
            self.refreshing = False

    def _reset_minutes(self, reset_at, now_wall: float):
        if reset_at is None:
            return None
        if reset_at <= now_wall:
            return None
        return int((reset_at - now_wall) // 60)

    def _lane_wire(self, name: str, prefix: str, now_wall: float) -> dict:
        lane = self.lanes.get(name)
        pct_key = prefix + "Pct"
        reset_key = prefix + "ResetMin"
        stale_key = prefix + "Stale"
        if lane is None or lane.pct is None or (
                lane.reset_at is not None and lane.reset_at <= now_wall):
            return {pct_key: None, reset_key: None, stale_key: False}
        return {
            pct_key: lane.pct,
            reset_key: self._reset_minutes(lane.reset_at, now_wall),
            stale_key: bool(lane.stale),
        }

    def fields(self, now_wall: float) -> dict:
        with self._lock:
            if self.name == "grok":
                wire = self._lane_wire(_GROK_LANE, "grokCredit", now_wall)
                wire["grokQuotaLabel"] = self.label
                return wire
            wire = {}
            for name, prefix in (
                    ("total", "cursorTotal"),
                    ("models", "cursorModels"),
                    ("third", "cursorThird"),
                    ("bot", "cursorBot")):
                wire.update(self._lane_wire(name, prefix, now_wall))
            return wire

    def diagnostics(self) -> dict:
        with self._lock:
            left = self.cooldown_until - time.time()
            age = (int(time.monotonic() - self.last_mono)
                   if self.last_mono else None)
            return {
                self.name + "Probe": self.status,
                self.name + "ProbeIntervalS": int(self.interval_s()),
                self.name + "ProbeCooldownLeftS": (
                    int(math.ceil(left)) if left > 0 else None),
                self.name + "ProbeAgeS": age,
            }


_grok = Probe("grok", grok_billing.fetch)
_cursor = Probe("cursor", cursor_usage.fetch)


def kick_all() -> None:
    _grok.kick()
    _cursor.kick()


def fields(now_wall: float) -> dict:
    wire = {}
    wire.update(_grok.fields(now_wall))
    wire.update(_cursor.fields(now_wall))
    return wire


def diagnostics() -> dict:
    view = {}
    view.update(_grok.diagnostics())
    view.update(_cursor.diagnostics())
    return view
