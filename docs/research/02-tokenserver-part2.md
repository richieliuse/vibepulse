# VibePulse tokenserver — behavioral spec, part 2 (`tools/tokenserver/tokenserver.py` lines 1650–3250)

Scope: the tail of the Claude probe cycle (header fallback), the Claude probe scheduler, the entire Codex limit subsystem (OAuth usage API → `codex app-server` JSON-RPC → rollout-file tail scan), quota-cache async persistence, Max Tracker dirty-writer, OBS-39 regression evidence, weekly-quota resolution, the usage-totals recompute/placeholder machinery, `get_snapshot()` (the `/api/tokens` v2 payload), and `BoundedThreadingHTTPServer`.

Conventions used below:
- "wall" = `time.time()` (epoch seconds, float). "mono" = `time.monotonic()`.
- **Python rounding**: `round(x)` / `round(x, 1)` is round-half-to-EVEN on the binary double (e.g. `round(2.5)=2`, `round(0.25,1)=0.2`). Swift must use `.toNearestOrEven`; for 1-decimal rounding use `(x*10).rounded(.toNearestOrEven)/10` (accept rare binary-repr differences, or emulate via decimal string). `int(x)` truncates toward zero.
- "valid number" = JSON int or float, NOT bool, finite. Python `json` yields int for integer literals and float otherwise; both accepted wherever "number" is said.
- Logger name: `"tokenserver"`. Log texts are quoted because tests assert substrings.
- `STATE` = state dir: macOS `~/Library/Application Support/VibePulse`; Windows `%LOCALAPPDATA%\VibePulse` (fallback `~/AppData/Local/VibePulse`).

## 0. Constants referenced (values)

| Name | Value | Where defined |
|---|---|---|
| `LIMITS_EVERY_S` | 240 | top of file |
| `AUTH_RECOVERY_EVERY_S` | 15.0 | top |
| `PROBE_WHEN_BRIDGED_S` | 1800 | top |
| `RECOMPUTE_EVERY_S` | 30 | top |
| `HTTP_MAX_WORKERS` | 32 | top (test requires ≥ `interactions.MAX_PENDING`(8) + 16) |
| `MAX_TRACKER_CLAUDE_SESSION_MINUTES` | 300 | top |
| `MAX_TRACKER_CLAUDE_WEEK_MINUTES` | 10080 | top |
| `CODEX_SESSIONS` | `codex_usage.default_sessions_dir()` evaluated ONCE at import: `$CODEX_HOME/sessions` (expanduser) else `~/.codex/sessions` (or `codex_usage.DEFAULT_SESSIONS_DIR` override if not None) | in range |
| `CODEX_APP_SERVER_TIMEOUT_S` | 15 | in range |
| `CODEX_LIMIT_SCAN_BYTES` | 1 048 576 (1 MiB) | in range |
| `CODEX_WEEK_MINUTES` | 10080 | in range |
| `_CODEX_PROBE_LOCK_PATH` | `STATE/codex-probe.lock` | in range |
| `_CODEX_PROBE_STATE_PATH` | `STATE/codex-probe-state.json` | in range |
| `_ERROR_LOG_THROTTLE_S` | 300.0 | in range |
| `_SERVER_STARTED_MONO` | mono at module import | top |

Module imports used in range: `codex_oauth` (load_auth, auth_path, token_fingerprint, config_path, base_url_from_config, usage_url, retry_after_seconds, app_server_body), `codex_rollout` (codex_rollout_rate_limits, observation_timestamp), `codex_command.resolve_codex_executable`, `codex_usage.default_sessions_dir`, `quota_cache.CachedQuota/QuotaCache` (`latest`, `put`), `usage_history.Forecast/UsageHistory` (`record_many`, `delta_since`, `forecast`), `subscription_quota` (`kick_all`, `fields`), `value_meter.build_payload`, `MaxTrackerStore` (`observe_quota`, `save`). Functions from part 1 of this file called here: `_parse_limit_headers`, `_quota_identity`, `_hold_probe_lock`, `_publish_probe_status`, `_note_probe_schedule_locked`, `_probe_limits`, `_merge_claude_statusline`, `_merge_claude_plan_usage`, `_get_usage_history`, `_get_quota_cache`, `_compute`, `_ota_available_version`, `_state_dir`.

`_quota_identity(provider, scope, raw=None)` = lowercase hex SHA-256 of UTF-8 `f"{provider}\0{scope}\0{raw if raw is not None else 'default-v1'}"` (raw passed through `str()`). Never store/return raw ids.

---

## 1. Claude probe — tail of `_probe_cycle(outcome)` (lines 1650–1710)

Context (from part 1): `_probe_cycle` iterates OAuth token candidates `(token, expires_at_ms)`. For each: skip if in `_dead_tokens` (status `token_dead_awaiting_refresh`); skip if `expires_at and expires_at/1000 < now` (status `token_expired_HH:MM`, local time); else GET `https://api.anthropic.com/api/oauth/usage` (timeout 15). 429 → cooldown, return None (abort). 401/403 → mark dead (FIFO cap 8), continue. Other HTTPError → `token = candidate; break`. Non-HTTP exception → status `usage_request_failed: <ExcTypeName>`, `token = candidate; break`. 200 with mapped limits → status `usage_http_200 + ok`, return found. 200 without mapped limits → status `usage_http_200 + no_mapped_limits`, then (**line 1650**) `token = candidate; break`.

In range:
1. If `token is None` (every candidate dead/expired/401/403) → return None. **No header probe** with a rejected token.
2. Header probe request:
   - `POST https://api.anthropic.com/v1/messages`, timeout 15 s.
   - Body (Python `json.dumps`, default separators): `{"model": "claude-haiku-4-5", "max_tokens": 0, "messages": [{"role": "user", "content": "ping"}]}`
   - Headers: `Content-Type: application/json`, `Authorization: Bearer <token>`, `anthropic-version: 2023-06-01`, `anthropic-beta: oauth-2025-04-20`. (No explicit User-Agent → urllib default `Python-urllib/3.x`.)
3. Outcome string is only APPENDED (the usage status is never overwritten):
   - success: `headers = dict(resp.headers)`; append `"; fallback_http_200"`.
   - HTTPError: append `f"; fallback_http_{code}"`; headers = error's headers (or `{}`) — rate-limit headers on an error response are still parsed.
   - any other exception: append `f"; fallback_failed: {TypeName}"`; return None.
   - `dict(HTTPMessage)`: duplicate header names collapse to the FIRST value; name case as sent by server.
4. One-time diagnostics (process-global `_headers_logged`): on the first probe that reaches here, for each header name in `sorted(headers)` containing `"ratelimit"` (case-insensitive) log INFO `"ratelimit-header: %s"`.
5. `found = _parse_limit_headers(headers, now_ts=time.time())` (part 1: maps `anthropic-ratelimit-unified-<bucket>-(utilization|reset|resets[-_]at)` to session/week/model `*Pct`, `*ResetAt`, `*ResetMin`, `modelLabel`, `*ObservedAt`, `*Identity`, plus `unknownBuckets`).
6. `outcome.headers = sorted(n for n in headers if "ratelimit" in n.lower())`; `outcome.unknown_buckets = found.pop("unknownBuckets", [])`.
7. If `found` empty → append `" + no_mapped_headers"`, return None. Else append `" + ok"`, return found (non-empty even if it only holds `modelLabel`).

Example final status (pinned by test): `"usage_request_failed: URLError; fallback_http_500 + no_mapped_headers"`.
The caller `_probe_limits_locked` publishes outcome once (status, headers, unknown buckets, credential, cooldown, streak, `_last_probed`) under `_limits_lock`.

## 2. `_probe_interval_s()` — Claude probe cadence

Evaluated with `_limits_lock` held by callers (`get_limits`, `_probe_view`):
1. If `_probe_status` starts with any of `"no_claude_oauth_token"`, `"token_expired_"`, `"token_dead_awaiting_refresh"` → `AUTH_RECOVERY_EVERY_S` (15.0). (These states make no network call; only re-read keychain/credentials.) Prefix match — e.g. `"no_claude_oauth_token: keychain_denied"` qualifies.
2. Else if `_claude_statusline_bridged` (set by `_merge_claude_statusline`) AND `_probe_status == "usage_http_200 + ok"` exactly → `PROBE_WHEN_BRIDGED_S` (1800).
3. Else `LIMITS_EVERY_S * 2**min(_probe_failure_streak, 2)` → 240 / 480 / 960.

A 429 rest does NOT change the interval: resting cycles still run on the ladder, each counted as a miss (streak+1) and making no network call until `_probe_cooldown_until`.

## 3. `_refresh_limits()` — background probe body (thread `claude-limit-probe`, daemon)

```
with _limits_lock: _probe_cycle_published = False
try: refreshed = _probe_limits()
except Exception as e:
    refreshed = None
    crashed = f"probe_crashed: {type(e).__name__}"
    if _probe_status != crashed: log.exception("the claude probe crashed (status was %s)", _probe_status)
    _publish_probe_status(crashed)   # empties header evidence, counts a miss
if _probe_status != _probe_status_logged:
    log.info("claude-probe: %s -> %s", _probe_status_logged or "start", _probe_status)
    _probe_status_logged = _probe_status
with _limits_lock:
    if not _probe_cycle_published: _note_probe_schedule_locked(refreshed)   # streak/last_probed fallback
    _probe_cycle_published = False
    _last_limits = refreshed          # NOTE: a failed cycle CLEARS limits to None
    _limits_refreshing = False
```
- `_note_probe_schedule_locked(refreshed)`: streak = 0 if truthy else streak+1; `_last_probed = mono`; `_probe_cycle_published = True`. Every real `_probe_limits` path already calls it inside its own publish; the fallback only covers a replaced `_probe_limits` (tests). Never count a cycle twice.
- Transition log is one line per status change; same status repeated → silent. Crash traceback logged once per episode (identical crash string → no second traceback).
- Honesty: after a failed probe `_last_limits` is None, so live Claude week figures vanish; the quota cache supplies them flagged stale.

## 4. `get_limits()` — non-blocking accessor

```
with _limits_lock:
    if (_last_probed == 0.0 or mono - _last_probed > _probe_interval_s()) and not _limits_refreshing:
        _limits_refreshing = True
        start daemon thread "claude-limit-probe" -> _refresh_limits
    return _last_limits    # may be None; returned by reference (callers copy)
```
Returns immediately with the previous result (test: < 0.1 s while probe runs).

---

## 5. Codex limits subsystem

### 5.1 Module state (all guarded by `_codex_limits_lock` unless noted)
| Var | Init | Meaning |
|---|---|---|
| `_last_codex_limits` | None | last panel dict (see 5.6 keys) |
| `_codex_failure_streak` | 0 | upstream ladder streak |
| `_codex_cli_failure_streak` | 0 | CLI-fallback ladder streak (written without lock, probe thread only) |
| `_codex_cooldown_until` | 0.0 | wall epoch; 429 rest |
| `_codex_auth_state` | "unknown" | ready / missing / expired / unauthorized / unknown |
| `_codex_status` | "not_run" | diagnostic status string |
| `_codex_status_logged` | None | for transition log |
| `_last_codex_cli` | 0.0 | mono of last CLI fallback run (probe thread only) |
| `_codex_probe_state_loaded` | False | persisted cooldown loaded once |
| `_codex_dead_tokens` | {} | fingerprint → "http_401"/"http_403", insertion-ordered, cap 8 FIFO |
| `_last_codex_read` | 0.0 | mono of last completed refresh |
| `_codex_refreshing` | False | single-flight flag |

Source preference: (1) ChatGPT OAuth usage API; (2) local `codex app-server` over stdio JSON-RPC; (3) newest rollout files' tail. A 429 from (1) never falls through to (2)/(3) (same account). Token never logged/returned.

### 5.2 `_any_provider_dir(projects_dir) -> bool`
`projects_dir.is_dir() or CODEX_SESSIONS.is_dir()`. Used by `main()` startup gate (wait until either provider directory exists).

### 5.3 Window parsing helpers
`_codex_rollout_rate_limits` / `_observation_timestamp` are aliases of `codex_rollout.codex_rollout_rate_limits` / `observation_timestamp`:
- `codex_rollout_rate_limits(obj)`: accept ONLY `{"type":"event_msg","payload":{"type":"token_count","rate_limits":{...dict}}}`; return the `rate_limits` dict else None. Stringified/nested `rate_limits` (under `payload.message`, JSON inside `payload.content`, top-level) rejected.
- `observation_timestamp(v)`: str only; `datetime.fromisoformat(v.replace("Z","+00:00"))` → `int(ts)`; naive ISO (no offset) is interpreted as LOCAL time; parse error → None.

**`_codex_window(win, now_ts)` → `(pct, reset_min, window_minutes)` or None**
- win must be dict. `pct = used_percent`: valid number, 0 ≤ pct ≤ 100. `window_minutes`: valid number (any value, incl. 0/negative). `resets_at`: valid number and `> now_ts`. Any failure → None.
- `reset_at = int(resets_at)`; `reset_min = max(0, int(round((reset_at - now_ts)/60)))`.
- returns `(round(float(pct),1), reset_min, window_minutes)` — window_minutes as given (int or float).
- Test: used 57.0, window 10080, resets 1_900_000_000, now 1_899_996_400 → (57.0, 60, 10080). Value is USED percent (no inversion).

**`_codex_general_observation(rate_limits, observed_at, now_ts)`** — authoritative unnamed weekly:
- rate_limits dict. `limit_name` must be absent/None or exactly `""`; any non-empty string or non-string (False, 0, [], {}) → None.
- `observed_at` must be int (not bool; float rejected).
- Check `primary` then `secondary`: first window that parses AND `window_minutes == 10080` (numeric equality; 10080.0 ok; 43200 rejected; missing/"10080"/True rejected by `_codex_window`).
- Returns `{"pct", "reset_at": int(resets_at), "observed_at": int, "identity": _quota_identity("codex","general_weekly", rate_limits.get("limit_id")), "window_minutes"}`. Raw `limit_id` never returned (hashed; None → "default-v1").

**`_codex_session_observation(rate_limits, observed_at, now_ts)`**:
- rate_limits dict and `observed_at` isinstance int (bool technically passes). primary then secondary: first parsed window with `window_minutes <= 600` → `{"pct","reset_min","observed_at","window_minutes"}`. Does NOT check `limit_name`.

**`_camel_codex_window(w)`**: dict → `{"used_percent": w.usedPercent, "window_minutes": w.windowDurationMins, "resets_at": w.resetsAt}`; non-dict → None.

**`_parse_codex_rate_limits_response(body, observed_at, now_ts)`** (app-server `account/rateLimits/read` result shape; also OAuth after conversion):
1. body not dict → `{}`.
2. `rl = body.rateLimitsByLimitId.codex` if `rateLimitsByLimitId` is a dict and that entry is a dict; else `rl = body.rateLimits`; not dict → `{}`.
3. normalized = `{limit_id: rl.limitId, limit_name: rl.limitName, primary: camel(rl.primary), secondary: camel(rl.secondary)}`.
4. weekly = general observation; None → return `{}` (session alone is NOT returned on this path).
5. out = `codexWeekPct, codexWeekResetAt, codexWeekObservedAt, codexWeekIdentity, codexWeekStale=False, codexWeekWindowMinutes`.
6. session observation (if any) adds `codexSessionPct, codexSessionResetMin, codexSessionWindowMinutes`.
Named buckets (e.g. `codex_bengalfox` "GPT-5.3-Codex-Spark") are ignored.

### 5.4 `codex app-server` stdio JSON-RPC read — `_read_codex_app_server_limits(timeout_s=15)`
- Executable: `_codex_app_server_command()` = `resolve_codex_executable()`:
  - Windows: `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe` if it is a file; else `which("codex")`, but on Windows reject paths containing a `\WindowsApps\` segment (case-insensitive) → None.
  - elsewhere `which("codex")`; macOS fallback `/Applications/ChatGPT.app/Contents/Resources/codex`, then `/Applications/Codex.app/Contents/Resources/codex` (must be file and executable).
  - None → return `{}`. Accepts str/PathLike (→ `[exe]`) or list/tuple of str/PathLike (tests pass `[python, script]`); anything else/empty → `{}`.
- Spawn argv: `command + ["app-server", "--listen", "stdio://"]`; stdin PIPE, stdout PIPE, stderr DEVNULL, text mode, line-buffered.
- Wire: newline-delimited JSON (Python `json.dumps` + `"\n"`, flush after each):
  1. Immediately send `{"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "vibepulse", "version": "1"}, "capabilities": {}}}`.
  2. Start a reader thread (`codex-app-server-reader`, daemon) that pushes each stdout line into a queue and pushes `None` (EOF sentinel) when readline returns empty or raises OSError/ValueError.
  3. Loop until `deadline = mono + timeout_s`: `get(timeout=min(0.25, remaining))`. Queue empty → if process exited break, else continue. `None` → break. Non-JSON line → skip.
     - message `id == 1` (first time) → send `{"method": "initialized", "params": {}}` then `{"id": 2, "method": "account/rateLimits/read"}` (no params key).
     - message `id == 2` → return `_parse_codex_rate_limits_response(message.get("result"), observed_at=int(time.time()), now_ts=time.time())` (error response → result None → `{}`).
  4. Deadline/EOF/exit → `{}`.
  - A JSON line that is not an object makes `.get` raise AttributeError, which is NOT caught here (propagates → Codex refresh records `probe_crashed: AttributeError`). Caught: OSError, ValueError, BrokenPipeError → `{}`.
- Cleanup (always): if still running → terminate (SIGTERM), wait 1 s; on timeout kill + wait 1 s. Then close stdin, stdout, stderr in that order ignoring OSError (FD leak fix: runs every cycle forever).
- Tests: real fake server returns week 62.0 / reset 1_900_000_000; silent server with timeout 1 → `{}` in <10 s; instantly-exiting process → `{}` well before deadline.

### 5.5 Rollout tail scans
**`_read_codex_observations(path, now_ts, block_size=65536, max_bytes=1 MiB)` → `(general|None, session|None)`**
- `max_bytes = min(max_bytes, CODEX_LIMIT_SCAN_BYTES)` (hard cap 1 MiB).
- Open binary; seek end; `position = size`; `fragment = b""`; `remaining = max_bytes`.
- While `position > 0 and remaining > 0`: `n = min(block_size, position, remaining)`; `position -= n; remaining -= n`; read `n` bytes at `position`; `parts = (chunk + fragment).split(b"\n")`; `fragment = parts.pop(0)` (possibly-partial first line carried to next, earlier block); iterate `reversed(parts)` (newest line first):
  - skip lines not containing the bytes `"rate_limits"` (with quotes);
  - `json.loads(bytes)` (JSONDecodeError/UnicodeDecodeError → skip);
  - `limits = codex_rollout_rate_limits(event)`; `observed_at = observation_timestamp(event["timestamp"])` if event is dict; either None → skip;
  - if general unset → try `_codex_general_observation(limits, observed_at, now_ts)`; if session unset → try `_codex_session_observation(...)`; both set → return immediately.
- After loop: only if `position == 0` and fragment contains `"rate_limits"` → process fragment the same way (no early-return needed). If the byte budget ran out first, the straddling fragment is discarded.
- OSError anywhere → return what was found so far (initially (None, None)).
- Named newer events do not hide an older unnamed general event (general is searched independently).

**`_read_latest_rate_limits(path, block_size, max_bytes)`** — same reverse scan, returns the first accepted raw `rate_limits` dict (no timestamp/classification), else None. **No production callers** (tests only); port optional. Tests: finds event after 100 000 noise lines without full-file read; returns None when event lies beyond `max_bytes` (64 KiB with 4 KiB blocks) and beyond 1 MiB even if `max_bytes=2 MiB` requested; rejects the 5 impostor envelopes.

**`_scan_codex_limits()` → panel dict**
1. `CODEX_SESSIONS` not a dir → `{}`.
2. `CODEX_SESSIONS.glob("**/rollout-*.jsonl")` (recursive incl. top level), sorted by `st_mtime` DESC, first 20. Any OSError during glob/stat/sort → `{}`.
3. `now_ts = time.time()`; for each path collect `_read_codex_observations(path, now_ts)` results.
4. weekly = max by `observed_at` (ties → earliest in list = newest mtime) → `codexWeekPct, codexWeekResetAt, codexWeekObservedAt, codexWeekIdentity, codexWeekStale=False, codexWeekWindowMinutes`.
5. session = max by `observed_at` → `codexSessionPct, codexSessionResetMin, codexSessionWindowMinutes`. (Independent of weekly here.)
6. Return merged (possibly `{}`). Test: 21 files → exactly 20 read; picks the unnamed one.

### 5.6 Codex panel dict (value of `_last_codex_limits`, `_read_codex_limits()`)
Keys (all optional): `codexWeekPct` float(1dp), `codexWeekResetAt` int epoch, `codexWeekObservedAt` int epoch, `codexWeekIdentity` 64-hex, `codexWeekStale` False, `codexWeekWindowMinutes` number (10080), `codexSessionPct` float(1dp), `codexSessionResetMin` int (computed at probe time, NOT recomputed later), `codexSessionWindowMinutes` number (≤600).

### 5.7 Cadence
- `_codex_probe_interval_s()`: `_codex_auth_state in {missing, expired, unauthorized}` → 15.0; else `240 * 2**min(_codex_failure_streak,2)`. (No statusLine slowdown.)
- `_codex_cli_interval_s()`: `240 * 2**min(_codex_cli_failure_streak,2)` — CLI fallback cadence while the API credential is unusable (the 15 s auth re-read must not spawn app-server each time).

### 5.8 Persisted 429 rest
- `_load_codex_probe_state_locked()` (caller holds lock; runs once per process): read `STATE/codex-probe-state.json` as UTF-8 JSON, `until = float(data.get("cooldown_until", 0.0))`; OSError/ValueError/TypeError → return silently (note non-dict JSON raises AttributeError — not caught; file is only ever written by us). If finite and `> now` → `_codex_cooldown_until = until`; `_codex_status = "usage_http_429 + backoff_until_HH:MM (persisted)"` (local time of `until`).
- `_save_codex_probe_state(cooldown_until)`: mkdir parents; write `{"cooldown_until": <float>}` (json.dumps default) as UTF-8 via plain `write_text` (non-atomic, no fsync); OSError ignored. Never cleared on success (harmless: only a future value is honored at load).

### 5.9 `_note_codex_status_locked(status)`
Sets `_codex_status`; if different from `_codex_status_logged` → log INFO `"codex-probe: %s -> %s"` (old or `"start"`, new) and remember.

### 5.10 Usage URL — `_codex_usage_url()`
- `config.toml` = `auth_path().with_name("config.toml")` = `$CODEX_HOME/config.toml` (expanduser) or `~/.codex/config.toml`.
- If `stat().st_size <= 256 KiB`, read UTF-8 and extract `chatgpt_base_url` via regex (multiline) `^[ \t]*chatgpt_base_url[ \t]*=[ \t]*(['"])([^'"]+)\1[ \t]*$` (commented lines don't match); value stripped, empty → None. OSError/UnicodeError → None.
- `codex_oauth.usage_url(base)`: None/blank → `https://chatgpt.com/backend-api/wham/usage`. Else strip + rstrip "/"; must be `https`, have hostname, no userinfo, no query/fragment, else **None** (→ kind "transport"). Path (rstrip "/"): ends with `/wham/usage` or `/api/codex/usage` → keep; contains `/backend-api` → append `/wham/usage`; else append `/api/codex/usage`. Result `scheme://netloc + path`.

### 5.11 `_NoRedirect`
urllib redirect handler returning None → any 3xx surfaces as HTTPError (→ "transport"). Swift: URLSession delegate `willPerformHTTPRedirection` → completion(nil).

### 5.12 `_read_codex_oauth_limits(now_ts=None)` → `(kind, limits, retry_after)`
`current = now_ts or time.time()`.
1. `auth = codex_oauth.load_auth(auth_path(), current)`:
   - `auth.json` at `$CODEX_HOME/auth.json` or `~/.codex/auth.json`. Missing file → "missing"; stat error/size ≤0 or >256 KiB/invalid JSON/not UTF-8 → "malformed"; `tokens` not dict → "missing"; `tokens.access_token` not a non-empty str without whitespace → "missing"; `account_id` = `tokens.account_id` if non-empty str. JWT expiry: base64url-decode the 2nd dot-segment (pad `=`), JSON `exp` number (not bool); if `exp <= now` → "expired". Else "ready". Never refreshes, never writes auth.json.
2. status "expired" → `("expired", {}, 0)`. status ≠ "ready" or no token → `("missing", {}, 0)` (includes malformed).
3. `fp = sha256_hex(token)`; if in `_codex_dead_tokens` → `("unauthorized", {}, 0)` (no network).
4. `url = _codex_usage_url()`; None → `("transport", {}, 0)`.
5. `lock = _hold_probe_lock(STATE/codex-probe.lock)` (non-blocking exclusive flock; Windows msvcrt 1-byte lock after writing "1"); None → `("held", {}, 0)`.
6. `GET url`, timeout 15 s, no redirects, headers: `Authorization: Bearer <token>`, `Accept: application/json`, `User-Agent: vibepulse`, plus `ChatGPT-Account-Id: <account_id>` if present. Body parsed as JSON.
   - HTTPError: `retry = retry_after_seconds(headers["Retry-After"], time.time())` (int ≥0 seconds; else HTTP-date → `max(0, round(when-now))`; else 0). 429 → `("rate_limited", {}, retry)`. 401/403 → `_codex_dead_tokens[fp] = f"http_{code}"`, evict oldest while len > 8, → `("unauthorized", {}, 0)`. Other codes → `("transport", {}, 0)`.
   - Any other exception (URLError, timeout, JSON error) → `("transport", {}, 0)`.
   - Lock file closed (released) in all cases after the request.
7. `body = codex_oauth.app_server_body(payload)`: payload dict with `rate_limit` dict; each of `primary_window`/`secondary_window` converted iff dict with `limit_window_seconds` a positive number divisible by 60 → `{"usedPercent": used_percent, "windowDurationMins": secs//60, "resetsAt": reset_at}`; both None → body None. Returns `{"rateLimits": {"limitId": None, "limitName": None, "primary":…, "secondary":…}}`. `additional_rate_limits` ignored. None → `("unmapped", {}, 0)`.
8. `found = _parse_codex_rate_limits_response(body, observed_at=int(current), now_ts=current)`; empty → `("unmapped", {}, 0)`; else `("ok", found, 0)`.
Test: wham 18000 s/15% + 604800 s/5% → session 15.0/300 min, week 5.0/10080; "spark" absent.

### 5.13 `_codex_cli_fallback()`
`found = _read_codex_app_server_limits(timeout_s=15)`; if empty → `_scan_codex_limits()`; return found or `{}`.

### 5.14 `_refresh_codex_limits()` (thread `codex-limit-scan`, daemon)
Locals: `replace=None` (None = keep last limits), `status=_codex_status`, `auth_state=_codex_auth_state`, `streak="leave"`, `cooldown=None`.
```
try:
  with lock: _load_codex_probe_state_locked(); resting = now < _codex_cooldown_until; status = _codex_status
  if resting: streak = "increment"                      # no network, status/limits unchanged
  else:
    kind, limits, retry = _read_codex_oauth_limits()
    ok           -> replace=limits; status="usage_http_200 + ok"; auth="ready"; streak=reset; cooldown=0.0
    rate_limited -> cooldown = now + max(int(retry or 0), 600)
                    status = "usage_http_429 + backoff_until_HH:MM" (local time of cooldown)
                    _save_codex_probe_state(cooldown); replace={}; auth="ready"; streak=increment
                    (CLI NOT called)
    unmapped     -> status="usage_http_200 + no_mapped_limits"; auth="ready"; replace={}; increment
    transport    -> status="usage_request_failed"; auth="ready"; replace={}; increment
    held         -> status="probe_held_by_other_instance"; increment (auth, limits unchanged)
    missing/expired/unauthorized ->
        auth_state = kind
        idle_status = {"missing":"no_codex_oauth_token","expired":"token_expired",
                       "unauthorized":"token_dead_awaiting_refresh"}[kind]
        cli_due = _last_codex_cli == 0.0 or mono - _last_codex_cli >= _codex_cli_interval_s()
        if kind == "unauthorized" and previous global _codex_auth_state != "unauthorized": cli_due = True
        if not cli_due: status = _codex_status; streak = "leave"      # keep CLI snapshot + status
        else:
            found = _codex_cli_fallback(); replace = found; _last_codex_cli = mono
            if found: status="cli"; _codex_cli_failure_streak=0; streak=reset
            else: status = idle_status + "; cli_empty"; _codex_cli_failure_streak += 1; streak=increment
except Exception as e:
  status=f"probe_crashed: {TypeName}"; replace={}; streak=increment; log.exception("the codex probe crashed")
with lock:
  if cooldown is not None: _codex_cooldown_until = cooldown
  if replace is not None: _last_codex_limits = replace
  _codex_auth_state = auth_state
  streak: reset -> 0; increment -> +1; leave -> unchanged
  _note_codex_status_locked(status); _last_codex_read = mono; _codex_refreshing = False
```
Note: with a missing credential, refresh runs every 15 s (only re-reads auth.json) and the CLI runs on its own 240/480/960 ladder. Failure/429 clears limits to `{}` → snapshot falls back to the stale quota cache.

### 5.15 `_codex_probe_view()` — `GET /` diagnostics (no token/account)
Under lock: `{"codexProbe": status, "codexProbeStreak": int, "codexProbeIntervalS": int(interval), "codexProbeCooldownLeftS": ceil(cooldown - now) if > 0 else null, "codexProbeAgeS": int(mono - _last_codex_read) if _last_codex_read else null}`.

### 5.16 `_read_codex_limits()` — non-blocking accessor
```
with lock:
  if (_last_codex_read == 0.0 or mono - _last_codex_read > _codex_probe_interval_s()) and not _codex_refreshing:
      _codex_refreshing = True; start thread "codex-limit-scan" -> _refresh_codex_limits
  return dict(_last_codex_limits or {})     # shallow copy
```

---

## 6. Small helpers

- `_reset_at(now_ts, reset_minutes)`: reset_minutes must be number (not bool) and ≥ 0 → `now_ts + reset_minutes*60`; else None. (Unused by get_snapshot; kept.)
- `_reset_minutes(reset_at, now_ts)`: reset_at number (not bool) and `> now_ts` → `max(0, int(round((reset_at - now_ts)/60)))` (half-even); else None. Used for EVERY `*ResetMin` in the v2 payload except `codexSessionResetMin`.
- `_valid_window_minutes(v)`: number, not bool, finite, `> 0`.
- `_quota_record_key(r)` = `(provider, scope, identity)`.

## 7. Quota-cache async persistence (single writer per cache)

State: `_quota_writer_lock` (Lock), `_quota_writers` = WeakKeyDictionary cache → `{"queued": {key: rec}, "inflight": {key: rec}, "persisted": {key: rec}, "running": bool}` (insertion-ordered dicts). Swift: attach this state to the cache instance.

**`_persist_quota_records_async(cache, records)`** (called on the HTTP thread; never blocks on disk):
1. Drop None records; none left → return.
2. Under lock: create state if absent. For each record: skip if equal (all 7 fields, dataclass equality) to `persisted[key]`, `inflight[key]` or `queued[key]`; else `queued[key] = record` (replaces an older queued value for that key, keeps position).
3. If queued non-empty and not running → running = True and start ONE daemon thread `quota-cache-writer` → `_quota_cache_writer(cache)`.

**`_quota_cache_writer(cache)`** loop:
- Under lock: state missing or queued empty → `running = False` (if state) and exit. Else pop the FIRST queued key → `inflight[key] = record`.
- Outside lock: `persisted = cache.put(record)` (exception → False).
- Under lock: state gone → continue (next iteration exits). If `inflight[key] == record` delete it. If persisted → `persisted[key] = record`.
- A failed put (False) leaves nothing in `persisted`, so the next snapshot carrying the same record re-queues it (retry). An unchanged record already persisted is never rewritten (no `os.replace`).

`QuotaCache.put` (quota_cache.py): validates (provider ∈ {claude, codex}; scope ∈ {general_session, general_weekly, model_weekly}; identity printable ASCII 1..128; pct finite 0..100; reset_at/observed_at int ≥ 0; label None or printable ≤128); rejects a record OLDER (`observed_at <`) than the stored one for the same key; atomic write of `{"v":1,"records":[...sorted by (provider,scope,identity)]}` (compact separators + "\n") to tmp `.<name>.XXXX.tmp` in same dir → fsync → `os.replace` → fsync parent; on parent-fsync failure restore the prior bytes. Readers (`latest`) use an immutable snapshot and never take the writer lock. `latest(provider, scope, now)` = among records of that provider+scope with `reset_at > now`, max by `(observed_at, identity)`; else None. File: `STATE/quota-cache.json`.

## 8. Max Tracker dirty writer

State: `_max_tracker_writer_lock`, `_max_tracker_dirty=False`, `_max_tracker_writer_running=False`, `_max_tracker_save_failing_since=None` (mono), `_last_save_error_logged=None` (mono; None = never logged — must NOT be 0.0 because mono counts from boot).

**`_mark_max_tracker_dirty(store)`**: under lock set dirty; if no writer running → running = True and start daemon thread `max-tracker-writer` → `_max_tracker_writer(store)`. Bursts coalesce (≤ 1 trailing save after the in-flight one).

**`_max_tracker_writer(store)`** loop:
- Under lock: not dirty → running = False, exit. Else dirty = False.
- `store.save()` (atomic write of `STATE/max-tracker.json`, see max_tracker spec).
  - success: if `_last_save_error_logged is not None` → log INFO `"max-tracker: save succeeded again after %.0f s"` (mono − failing_since, or 0) and reset `_last_save_error_logged = None`; always `_max_tracker_save_failing_since = None`.
  - exception: `now = mono`; set failing_since if None; if `_last_save_error_logged is None or now − it >= 300` → set it and `log.exception("max-tracker: save failed — the observations stay in memory and the next attempt is coming")`. Under lock: dirty = True, running = False; exit (NO hot retry; the next mark retries).
- `GET /` exposes `maxTrackerSaveOk = failing_since is None`, `maxTrackerSaveFailingForS = int(mono − failing_since)` or null.

## 9. OBS-39 quota regression evidence

State: `_quota_regressions` dict keyed `(provider, scope, reset_at)`, `_quota_regressions_lock`.

**`_note_quota_regression(provider, scope, live_pct, cached, now_ts)`**: key = `(provider, scope, cached.reset_at)`. Under lock: already present → return (once per window). Insert `{"provider", "scope", "livePct": round(float(live_pct),1), "cachedPct": round(float(cached.pct),1), "resetAt": cached.reset_at, "at": int(now_ts)}`; then prune entries with `resetAt <= now_ts`. Outside lock log WARNING: `"%s %s: live %.1f%% is below the cached %.1f%% for the same reset (%d) -- OBS-39 evidence, the live reading still wins"`.

**`_quota_regressions_view(now_ts=None)`**: prune `resetAt <= now` under lock; return list of copies sorted by `at` ascending. Served on `GET /` as `quotaRegressions`.

## 10. `_resolve_weekly_quota(source, provider, scope, prefix, quota_cache, now_ts, label_key=None)`

Reads `source[prefix+"Pct"]`, `…ResetAt`, `…ObservedAt`, `…Identity`. `live` = pct valid number in [0,100] AND reset_at valid number `> now_ts` AND observed_at valid number AND identity non-empty str.

Returns dict `{pct, reset_at, observed_at?, label, stale, live, cache_record}`:
1. `live` and `source[prefix+"StaleFloor"] is True` (only Claude week via statusLine sets `weekStaleFloor`) → `{pct: round(pct,1), reset_at: int, observed_at: int, label: None, stale: True, live: False, cache_record: None}` (served stale; not a new measurement).
2. `live` → `cached = quota_cache.latest(provider, scope, now_ts)`; if `cached` and `cached.reset_at == int(reset_at)` and `cached.pct > float(pct)` → `_note_quota_regression(...)` (live still wins). `label = source[label_key]` if label_key and str else None. `record = CachedQuota(provider, scope, identity, float(pct), int(reset_at), int(observed_at), label)`. Return `{pct: round(pct,1), reset_at: int, observed_at: int, label, stale: False, live: True, cache_record: record}`.
3. not live → `cached = latest(...)`: present → `{pct: round(cached.pct,1), reset_at: cached.reset_at, observed_at: cached.observed_at, label: cached.label, stale: True, live: False, cache_record: None}`.
4. else → `{pct: None, reset_at: None, label: None, stale: False, live: False, cache_record: None}` (no `observed_at` key → callers `.get` → None).

## 11. `_add_forecast(result, prefix, forecast)`
Sets `{prefix}ForecastState` (str), `{prefix}ForecastPctAtReset` (int|null), `{prefix}ForecastPaceFactor` (float 1dp|null), `{prefix}ForecastAt` (= `exhausts_at`, int epoch|null), `{prefix}ForecastOffsetMin` (int|null). States: `unavailable`, `collecting`, `exhausts` (At/OffsetMin set), `at_reset` (PctAtReset 0..100, PaceFactor maybe null). Algorithm lives in usage_history.forecast (linear regression over same-cycle samples within 24 h; ≥3 samples, span ≥ 90 min, movement ≥ 1.0).

## 12. Usage totals recompute & placeholder

Globals (guarded by `_cache_lock`): `_last_result` (None until first successful scan), `_last_computed` (mono of last attempt, 0.0 initially), `_snapshot_refreshing`, `_last_result_at` (mono of last SUCCESS), `_compute_failing_since` (mono|None), `_last_compute_error_logged` (mono|None).

**`_refresh_usage_totals(projects_dir, max_tracker_store=None)`** (background thread):
- `refreshed = _compute(projects_dir, max_tracker_store)` (part 1: v1 dict `v, dayTokens, dayTokensPerHour, daySessions, monthTokens, claudeSourcePresent, value, at`).
- exception → refreshed None; failing_since = mono if None; if last_logged None or mono − last_logged ≥ 300 → set and `log.exception("usage recompute crashed — /api/tokens serves frozen figures until it succeeds again")`.
- success and failing_since not None → log INFO `"usage recompute healthy again after %.0f s"`; failing_since = None; last_logged = None (new episode logs immediately).
- Under `_cache_lock`: if refreshed → `_last_result = refreshed`, `_last_result_at = mono`; always `_last_computed = mono`, `_snapshot_refreshing = False`. (Crash keeps serving the old result.)

**`_usage_totals_state_locked(have_result)`** (caller holds `_cache_lock`, same read that chose the counters):
- `failing = _compute_failing_since is not None`.
- not have_result → `{"state": "failing" if failing else "refreshing", "sinceS": int(mono − _SERVER_STARTED_MONO), "placeholder": true}`.
- have_result → `{"state": "failing" if failing else "ready", "ageS": int(mono − _last_result_at) or null if None, "placeholder": false}`.

**`_usage_totals_state()`**: `with _cache_lock: _usage_totals_state_locked(_last_result is not None)` → `GET /` `usageTotals`.

**`usage_totals_are_placeholders(payload)`**: payload dict and `payload["usageTotals"]` dict with `placeholder is True`. Handler uses it: placeholder + request header `X-VibePulse-Accepts` not containing `usage-totals` (case-insensitive substring) → HTTP 503 `{"error": "usage totals not measured yet", "usageTotals": {...}}` (no counters); otherwise 200.

**`_startup_totals_placeholder(projects_dir)`** (firmware requires numeric counters, so zeros + marker):
```
{"v": 1, "dayTokens": 0, "dayTokensPerHour": 0, "daySessions": 0, "monthTokens": 0,
 "claudeSourcePresent": projects_dir.is_dir(),
 "value": value_meter.build_payload(0.0, 0, 0, claude_plan=_claude_plan, codex_plan=_codex_plan,
          plan_costs=_plan_costs, table=_price_table, claude_usd=0.0, codex_usd=0.0),
 "at": now local ISO-8601 with offset, seconds precision (e.g. "2026-09-24T14:28:00+08:00")}
```
The zero-volume value block = `{"value_usd": 0.0, "plan_usd": null, "cost_source": "unknown", "basis": "list API prices", "prices_as_of": <table date>, "unpriced_token_share": 0.0, "state": "no_plan_cost", "multiple": null}` (key order as listed).

**`_start_usage_refresh(projects_dir, store, name)`**: starts daemon thread `name` → `_refresh_usage_totals(projects_dir, store)`; caller already set `_snapshot_refreshing` under lock.

## 13. `_subscription_wire(now_ts)`
If `_subscription_probes_enabled` (tests set False) → `subscription_quota.kick_all()` (non-blocking; starts Grok/Cursor probe threads when due). Always returns `subscription_quota.fields(now_ts)` — keys ALWAYS present:
`grokCreditPct, grokCreditResetMin, grokCreditStale, grokQuotaLabel, cursorTotalPct, cursorTotalResetMin, cursorTotalStale, cursorModelsPct, cursorModelsResetMin, cursorModelsStale, cursorThirdPct, cursorThirdResetMin, cursorThirdStale, cursorBotPct, cursorBotResetMin, cursorBotStale`. Lane absent/pct None/reset passed → `Pct: null, ResetMin: null, Stale: false`. ResetMin there = `floor((reset_at − now)/60)` (FLOOR, unlike `_reset_minutes`), null if reset_at None or passed. `grokQuotaLabel` = label or null. (Full semantics: subscription_quota spec.)

---

## 14. `get_snapshot(projects_dir, history=None, now_ts=None, quota_cache=None, max_tracker_store=None)` — `/api/tokens` v2

Callers: `Handler._tokens_payload` (with the server's MaxTrackerStore), `Handler._max_tracker_payload` (uses `claudeWeekStale`/`codexWeekStale`), publisher paths in `main`. `max_tracker_store=None` ⇒ every Max Tracker call is a no-op.

### 14.1 Counter block (under `_cache_lock`)
- `_last_result is None` (no completed scan): if `not _snapshot_refreshing and (_last_computed == 0.0 or mono − _last_computed > 30)` → `_snapshot_refreshing = True`, `_start_usage_refresh(…, "usage-total-first-scan")`. `result = _startup_totals_placeholder(projects_dir)`; `totals = _usage_totals_state_locked(False)`. (A crashed first scan is retried only after 30 s, never per request; the request never waits for the scan.)
- else: if `mono − _last_computed > 30 and not _snapshot_refreshing` → start `"usage-total-refresh"`. `result = dict(_last_result)` (shallow copy); `totals = _usage_totals_state_locked(True)`.
- `totals` is captured in the SAME critical section as the counters (a scan landing later cannot relabel placeholder zeros as ready).

### 14.2 Inputs (outside lock)
- `current_ts = now_ts if given else time.time()`.
- `usage_history = history or _get_usage_history()` (`STATE/usage-history.json`); `cache = quota_cache or _get_quota_cache()` (`STATE/quota-cache.json`).
- `claude = _merge_claude_plan_usage(_merge_claude_statusline(get_limits() or {}, cache, current_ts), cache, current_ts)` (part 1). Claude dict keys possibly present: `sessionPct, sessionResetAt, sessionResetMin, sessionSource, sessionLive, weekPct, weekResetAt, weekResetMin, weekObservedAt, weekIdentity, weekSource, weekStaleFloor, modelPct, modelResetAt, modelResetMin, modelObservedAt, modelIdentity, modelLabel`.
- `codex = _read_codex_limits()`.

### 14.3 Claude session (no stale flag on the wire ⇒ withheld rather than stale)
```
session_pct = claude.get("sessionPct"); session_reset_at = claude.get("sessionResetAt")
session_reset_min = _reset_minutes(session_reset_at, current_ts)
if claude.get("sessionLive", True) is not True: session_pct = None      # stale statusLine floor -> dashes
if session_pct is None or session_reset_min is None: all three = None
session_record = None; session_from_cache = False
if session_pct is not None:
    cached = cache.latest("claude", "general_session", now=current_ts); reset_int = int(session_reset_at)
    if cached and cached.reset_at > reset_int:                   # cache already saw a LATER window
        session_pct = round(cached.pct, 1); session_reset_at = cached.reset_at
        session_reset_min = _reset_minutes(cached.reset_at, current_ts); session_from_cache = True
    elif cached and cached.reset_at == reset_int and cached.pct >= session_pct:   # floor stands / unchanged
        session_from_cache = cached.pct > session_pct
        session_pct = round(cached.pct, 1)
    else:
        session_record = CachedQuota("claude", "general_session", _quota_identity("claude","general_session"),
                                     float(session_pct), reset_int, int(current_ts), None)
result["claudeSessionPct"] = session_pct         # raw value in the 3rd branch (not re-rounded)
result["claudeSessionResetMin"] = session_reset_min
if store and session_pct is not None and not session_from_cache:
    store.observe_quota("claude", 300, session_pct, current_ts); _mark_max_tracker_dirty(store)
```
The cached session is only a FLOOR for a live reading; it is never served by itself (no live reading → null). An equal reading is observed by Max Tracker/history but not rewritten to the cache.

### 14.4 Weekly quotas
```
claude_week  = _resolve_weekly_quota(claude, "claude", "general_weekly", "week",      cache, current_ts)
claude_model = _resolve_weekly_quota(claude, "claude", "model_weekly",   "model",     cache, current_ts, label_key="modelLabel")
codex_week   = _resolve_weekly_quota(codex,  "codex",  "general_weekly", "codexWeek", cache, current_ts)
_persist_quota_records_async(cache, (session_record, claude_week.cache_record, claude_model.cache_record, codex_week.cache_record))
```
Then (in this order):
- `claudeWeekPct` = cw.pct; `claudeWeekResetMin` = `_reset_minutes(cw.reset_at)`; `claudeWeekObservedAt` = cw.observed_at|null; `claudeWeekStale` = `cw.pct is not None and cw.stale`.
- store and `cw.live` → `observe_quota("claude", 10080, cw.pct, cw.cache_record.observed_at)` + mark dirty.
- `claudeModelWeekPct`, `claudeModelWeekResetMin`, `claudeModelWeekObservedAt`, `claudeModelWeekLabel` (= resolved label; live label only from `modelLabel`, never inferred from the active agent model), `claudeModelWeekStale`.
- `codexSessionPct` = `codex.get("codexSessionPct")`, `codexSessionResetMin` = `codex.get("codexSessionResetMin")` — raw pass-through (no cache, no stale flag, reset minutes as of probe time).
- `codexWeekPct`, `codexWeekResetMin`, `codexWeekObservedAt`, `codexWeekStale`.
- Max Tracker for Codex: `codexSessionPct` not None and `_valid_window_minutes(codex.codexSessionWindowMinutes)` → `observe_quota("codex", window, pct, current_ts)`; `codex_week.live` and valid `codexWeekWindowMinutes` → `observe_quota("codex", window, pct, cache_record.observed_at)`; each + mark dirty. Never guess a window.

### 14.5 History recording (only live observations)
Reset times come from the resolved entries (live OR cached) so "today" deltas survive a 429 blackout; only LIVE samples are recorded:
```
samples = [(p, w, pct, reset) for (p, w, pct, reset, is_live) in (
   ("claude","session",    claudeSessionPct,     session_reset_at, not session_from_cache),
   ("claude","week",       claudeWeekPct,        cw.reset_at,  cw.live),
   ("claude","model_week", claudeModelWeekPct,   cm.reset_at,  cm.live),
   ("codex", "week",       codexWeekPct,         xw.reset_at,  xw.live))
   if is_live and pct is not None and reset is not None]
usage_history.record_many(samples, at=current_ts)     # always called; one atomic write per batch
```
UsageHistory: samples `{"at": int, "provider", "window", "pct": float, "reset": reset rounded to 5-min quantum}`; per (provider, window, reset-cycle) at most one sample per 15 min; 8-day retention.

### 14.6 Deltas
`day_start` = `datetime.fromtimestamp(current_ts).astimezone().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()` — local midnight computed with the CURRENT instant's UTC offset (fixed-offset tz). On DST-change days this differs from true local midnight by the offset change; Swift `Calendar.startOfDay` would differ — preserve if byte-parity matters.
- `claudeWeekTodayDeltaPct` = null if cw.reset_at None else `delta_since("claude","week", day_start, cw.reset_at, now=current_ts)`.
- `claudeModelWeekTodayDeltaPct` = same with `model_week`, cm.reset_at.
- `claudeSessionHourDeltaPct` = null if session_reset_at None else `delta_since("claude","session", current_ts − 3600, session_reset_at, now)`.
- `codexWeekTodayDeltaPct` = `delta_since("codex","week", day_start, xw.reset_at, now)`.
`delta_since`: samples of the same cycle with `at <= now`; none → null; if cycle start (`reset − window length`: session 5 h, weeks 7 d) ≥ since → `round(max(0, latest.pct),1)`; else needs ≥ 2 samples; baseline = last sample at/before `since` else first sample; baseline is latest → null; delta < 0 → null; else round 1 dp.

### 14.7 Forecasts
`claude_forecast = Forecast("unavailable") if cw.reset_at is None else usage_history.forecast("claude","week", cw.reset_at, now)`; same for codex with xw.reset_at. `_add_forecast(result, "claude", …)`, `_add_forecast(result, "codex", …)`.

### 14.8 Tail
- `otaAvailableVersion` = `_ota_available_version()` (newest `build*/torget.bin` with valid app descriptor, project "torget"; string or null).
- `result.update(_subscription_wire(current_ts))`.
- `usageTotals` = totals (14.1).
- `v` = 2 (overwrites the v1 value in place, so `"v"` stays the FIRST key).

### 14.9 Complete `/api/tokens` v2 JSON (key order as emitted)
| Key | Type | Notes |
|---|---|---|
| `v` | int | always 2 |
| `dayTokens` | int | 0 when placeholder |
| `dayTokensPerHour` | int | tokens in last hour |
| `daySessions` | int | |
| `monthTokens` | int | |
| `claudeSourcePresent` | bool | projects dir exists (may be absent if an injected `_compute` result lacks it) |
| `value` | object | value_meter block |
| `at` | string | local ISO-8601 w/ offset, seconds |
| `claudeSessionPct` | number\|null | |
| `claudeSessionResetMin` | int\|null | |
| `claudeWeekPct` | number(1dp)\|null | |
| `claudeWeekResetMin` | int\|null | |
| `claudeWeekObservedAt` | int\|null | epoch |
| `claudeWeekStale` | bool | false when pct null |
| `claudeModelWeekPct` | number\|null | |
| `claudeModelWeekResetMin` | int\|null | |
| `claudeModelWeekObservedAt` | int\|null | |
| `claudeModelWeekLabel` | string\|null | "FABLE · WEEK" / "OPUS · WEEK" / "SONNET · WEEK" / null |
| `claudeModelWeekStale` | bool | |
| `codexSessionPct` | number\|null | raw |
| `codexSessionResetMin` | int\|null | raw |
| `codexWeekPct` | number\|null | |
| `codexWeekResetMin` | int\|null | |
| `codexWeekObservedAt` | int\|null | |
| `codexWeekStale` | bool | |
| `claudeWeekTodayDeltaPct` | number\|null | |
| `claudeModelWeekTodayDeltaPct` | number\|null | |
| `claudeSessionHourDeltaPct` | number\|null | |
| `codexWeekTodayDeltaPct` | number\|null | |
| `claudeForecastState`, `claudeForecastPctAtReset`, `claudeForecastPaceFactor`, `claudeForecastAt`, `claudeForecastOffsetMin` | str, int\|null, number\|null, int\|null, int\|null | |
| `codexForecastState` … `codexForecastOffsetMin` | same | |
| `otaAvailableVersion` | string\|null | |
| grok/cursor subscription keys (13) | | always present |
| `usageTotals` | object | `{state, sinceS, placeholder:true}` or `{state, ageS, placeholder:false}` |

Honesty rules: null (dash) means no data — never 0; `*Stale` true only when a pct is shown from cache/stale floor; stale values never feed cache, Max Tracker or history; counters are zeros ONLY with `usageTotals.placeholder: true`.

## 15. `BoundedThreadingHTTPServer(ThreadingHTTPServer)`
- Class attrs: `daemon_threads = True`, `block_on_close = False`.
- `__init__(addr, handler, *, max_workers=32)`: `max_workers` must be exactly int (not bool) ≥ 1 else ValueError; `BoundedSemaphore(max_workers)`.
- `process_request`: non-blocking acquire; fail → `_reject_busy(sock)` then `shutdown_request(sock)` (close) and return. Else spawn the per-request thread; if spawning raises → release slot, shutdown request, re-raise.
- `process_request_thread`: run handler; `finally` release slot.
- `_reject_busy(sock)`: `settimeout(0.05)` (OSError ignored); drain up to 8 KiB, `recv(min(2048, 8192 − got))` until `\r\n\r\n` seen or EOF (OSError stops); `sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")`; `shutdown(SHUT_WR)`; all OSErrors ignored. (Draining avoids WSAECONNABORTED on Windows.)
- `main` binds `("0.0.0.0", port)`.

## 16. Threads & locks summary
| Thread | Started by | Lock(s) |
|---|---|---|
| `claude-limit-probe` | `get_limits` | `_limits_lock`; machine-wide `STATE/claude-probe.lock` |
| `codex-limit-scan` | `_read_codex_limits` | `_codex_limits_lock`; `STATE/codex-probe.lock` (only around the OAuth HTTP call) |
| `codex-app-server-reader` | app-server read | queue |
| `quota-cache-writer` | `_persist_quota_records_async` | `_quota_writer_lock`; cache's own lock |
| `max-tracker-writer` | `_mark_max_tracker_dirty` | `_max_tracker_writer_lock` |
| `usage-total-first-scan` / `usage-total-refresh` | `get_snapshot` | `_cache_lock` |
| `grok-quota` / `cursor-quota` | `subscription_quota.kick_all` | per-probe lock |
Single-flight flags: `_limits_refreshing`, `_codex_refreshing`, `_snapshot_refreshing`, writer `running` flags. HTTP threads never wait on network, disk writes or scans.

## 17. Files touched in this range
| Path | Op | Format |
|---|---|---|
| `STATE/codex-probe.lock` | open "w" + non-blocking exclusive flock (Windows: write "1", msvcrt 1-byte lock); released on close | — |
| `STATE/codex-probe-state.json` | read once; write on 429 (non-atomic) | `{"cooldown_until": float}` |
| `STATE/claude-probe.lock` | via `_probe_limits` (part 1) | — |
| `STATE/quota-cache.json` | atomic via QuotaCache.put | `{"v":1,"records":[{provider,scope,identity,pct,reset_at,observed_at,label}]}` |
| `STATE/usage-history.json` | atomic via record_many | `{"v":1,"samples":[{at,provider,window,pct,reset}]}` |
| `STATE/max-tracker.json` | atomic via MaxTrackerStore.save | see max_tracker spec |
| `$CODEX_HOME|~/.codex/auth.json` | read ≤256 KiB | `tokens.access_token`, `tokens.account_id` |
| `$CODEX_HOME|~/.codex/config.toml` | read ≤256 KiB | `chatgpt_base_url` |
| `CODEX_SESSIONS/**/rollout-*.jsonl` | tail read ≤1 MiB each, newest 20 | JSONL events |
| `<repo>/build*/torget.bin` | via `_ota_available_version` | ESP app descriptor |

External calls: `POST https://api.anthropic.com/v1/messages` (Claude header fallback); `GET <chatgpt usage url>` (Codex OAuth); subprocess `codex app-server --listen stdio://`.

---

## 18. Tests in `test_tokenserver.py` covering this range

**Claude header fallback / scheduler / refresh** (class `ClaudeLimitHeaderTests`, `ClaudeStatuslineBridgeTests`, `ProbeTransitionLogTests`):
- `test_probe_gives_up_when_every_candidate_is_rejected` — two 401s → None, status `usage_http_401`, only 2 usage calls, no header probe.
- `test_status_is_published_once_at_the_end_of_the_cycle` — URLError on usage then 500 on messages → final `"usage_request_failed: URLError; fallback_http_500 + no_mapped_headers"`; no half-built status visible mid-cycle.
- `test_a_cycle_that_skips_the_fallback_clears_old_header_names` — header evidence emptied when the fallback is not reached.
- `test_probe_backoff_interval_grows_with_failures` — 240/480/960 for streak 0/1/5.
- `test_local_auth_wait_states_retry_quickly` — the three auth-wait prefixes → 15.0 even with streak 5.
- `test_probe_slows_down_only_while_bridged_and_healthy` — 1800 only when bridged AND status exactly ok.
- `test_refresh_updates_failure_streak` — None → streak +1 each; result → 0.
- `test_stale_limits_refresh_in_background_without_blocking_response` — `get_limits` returns old value <0.1 s, later swapped.
- `test_failed_background_refresh_marks_latest_attempt_failed` — failed refresh sets `_last_limits` None.
- `test_a_crashing_cycle_publishes_the_crash_with_empty_evidence` — `probe_crashed: KeyError`, empty headers/buckets.
- `test_a_cycle_publishes_its_backoff_with_its_outcome` — streak/last_probed published with outcome; `_refresh_limits` doesn't double count; flags reset.
- `test_status_change_logs_once_then_stays_quiet`, `test_probe_crash_replaces_stale_ok_status_and_logs_once`, `test_recovery_is_a_transition_too` — transition log texts `"start -> …"`, `"-> probe_crashed: RuntimeError"`, `"usage_http_401 -> usage_http_200 + ok"`.
- (Also related, part 1: `test_probe_backs_off_on_rate_limit`, persisted cooldown tests, `test_a_429_publishes_its_cooldown_with_its_status`, `test_probe_diagnostics_expose_the_backoff_state` which uses `_probe_interval_s`.)

**Codex** (`CodexLimitLogTests`):
- `test_wham_usage_maps_onto_session_and_week`, `test_codex_upstream_interval_matches_the_claude_ladder` (240/480/960, missing → 15, CLI 240), `test_codex_window_value_preserves_used_percent`, `test_app_server_uses_shared_codex_resolver`, `test_app_server_read_talks_to_a_real_process`, `test_app_server_read_gives_up_when_the_process_says_nothing`, `test_app_server_read_returns_when_the_process_dies_at_once`, `test_app_server_rate_limit_maps_remaining_38_to_used_62` (prefers `rateLimitsByLimitId.codex`, stale False).
- `test_refresh_prefers_oauth_over_cli` (no CLI/scan; status ok; interval 240), `test_refresh_uses_cli_when_oauth_credential_is_missing` (app-server called with timeout 15; status `cli`; interval 15), `test_oauth_429_does_not_call_cli_and_rests_ten_minutes` (limits `{}`, cooldown ≥590 s, status contains `usage_http_429`), `test_missing_credential_recheck_does_not_spawn_cli_again` (CLI not due → keep limits & status `cli`).
- Tail scan: `test_latest_rate_limit_is_read_from_tail_without_read_text`, `test_reverse_scan_stops_at_configured_byte_limit`, `test_reverse_scan_never_reads_more_than_one_mebibyte`, `test_only_expected_rollout_event_envelope_is_accepted`.
- Classification: `test_missing_or_non_numeric_window_is_never_classified`, `test_30_day_window_is_never_published_as_weekly`, `test_empty_limit_name_remains_general_weekly`, `test_non_string_limit_name_is_unclassifiable`, `test_newer_named_quota_does_not_hide_older_general_quota`, `test_scan_searches_twenty_files_and_selects_newest_general`, `test_identity_is_hashed_and_raw_limit_id_is_not_returned`, `test_codex_scan_refreshes_in_background_without_blocking`.

**Snapshot / quota cache / history** (`UsageSnapshotTests`, bridge snapshot tests, `ClaudeLimitHeaderTests.test_snapshot_never_infers_label_from_active_agent_model`):
- `test_stale_usage_totals_refresh_in_background`; `test_snapshot_emits_today_hour_deltas_and_real_forecasts` (v=2; deltas 7.0/3.0/11.0/5.0; forecast `at_reset` with int pct); `test_snapshot_exposes_live_pool_observation_times_for_relay_merge`; `test_snapshot_uses_fresh_local_claude_week_when_oauth_is_stale` (week live 14.0, model stale); `test_snapshot_flattens_collecting_and_exhaustion_states`; `test_snapshot_marks_forecast_unavailable_without_weekly_reset`; `test_snapshot_batches_all_quota_samples_into_one_atomic_write` (one history `os.replace`, 4 samples, 3 cache puts); default path tests (`usage-history.json`, `quota-cache.json` under VibePulse state dir); `test_named_only_codex_uses_cache_stale_and_without_cache_is_null`; `test_stale_cache_retains_pool_observation_times_for_relay_merge`; `test_success_then_failed_attempt_resolves_only_through_stale_cache`; `test_slow_cache_put_does_not_block_snapshot_and_is_single_flight` (exactly one writer thread); `test_unchanged_live_snapshot_does_not_replace_cache_again`; `test_changed_live_observation_is_eventually_cached_for_failure`; `test_failed_async_cache_write_retries_unchanged_observation`; `test_cache_lock_held_by_writer_does_not_block_changed_snapshot`; `test_missing_snapshot_reads_stale_while_cache_lock_is_held`; `test_mixed_snapshot_reads_stale_while_cache_lock_is_held`; `test_restart_cache_expires_exactly_and_reset_minutes_decrease` (2 → 1 → null/false at reset); `test_stale_cache_is_not_recorded_or_used_for_forecast`; `test_optional_stale_flags_are_false_when_percent_is_missing`.
- Bridge: `test_live_reading_below_the_cache_is_logged_once_as_obs39_evidence` (one OBS-39 warning per window, view fields, pruned at reset, higher reading silent); `test_session_floor_survives_a_restart_through_the_cache` (all four session branches 14.3); `test_snapshot_serves_records_and_tracks_a_fresh_sample`; `test_snapshot_serves_a_stale_sample_as_a_floor` (session null, week stale, nothing recorded).
- `test_snapshot_never_infers_label_from_active_agent_model` — model label null without `modelLabel`.

**Max Tracker hooks & writer**: `MaxTrackerLiveHookTests` (claude 300/10080 windows, stale/absent never observed, codex real windows, no window → no observe, no store → no-op); `MaxTrackerDirtyWriterTests` (`test_a_failing_save_is_visible_on_the_root_payload_until_it_recovers`, `test_marking_dirty_eventually_saves_off_the_calling_thread`, `test_bursts_of_dirty_marks_coalesce_without_a_second_writer` ≤2 saves, `test_failed_save_keeps_dirty_so_the_next_mark_retries` incl. "save failed"/"succeeded again" logs and immediate log for a new episode).

**Usage totals**: `UsageComputeHealthTests` (crash logs "frozen figures" once then throttled, keeps old result, `usageComputeOk` false; recovery logs "healthy again", resets throttle); `StartupSnapshotTests` (`test_first_request_answers_at_once_with_a_marked_placeholder` <0.5 s, zeros, `claudeSourcePresent` false, state refreshing, value state `no_plan_cost`, single compute; `test_the_totals_block_describes_the_counters_it_rides_on`; `test_placeholders_go_only_to_clients_that_declared_they_understand` 503 vs 200 by `X-VibePulse-Accepts`; `test_a_crashing_first_scan_is_retried_on_the_cadence_not_per_request`; `test_root_payload_names_the_three_usage_total_states`; `test_placeholder_satisfies_the_smoke_shape_and_the_device_budget`).

**HTTP server**: `BoundedHTTPServerTests` (`test_busy_rejection_drains_request_before_graceful_close` order timeout→recv→send 503→shutdown(SHUT_WR); `test_worker_cap_rejects_promptly_then_recovers_after_completion`; `test_thread_start_failure_releases_its_worker_slot`; `test_default_capacity_leaves_headroom_above_held_hook_limit`).

## 19. Port pitfalls (must preserve)
1. Header fallback status is appended, never replaces the usage status; no fallback with a rejected token.
2. A failed Claude cycle sets limits to None; a failed/429 Codex cycle sets limits to `{}`; "held"/resting/not-due keep the previous limits.
3. Codex 429 never triggers the CLI; cooldown ≥600 s, persisted to disk, loaded once at startup.
4. Codex weekly = unnamed (`limit_name` null or "") window of exactly 10080 min; session = any ≤600-min window; raw `limit_id` only as SHA-256.
5. Rollout scan: ≤1 MiB per file from the end, newest 20 files by mtime, `"rate_limits"` byte prefilter, strict envelope, max by event timestamp.
6. app-server: send initialize before reading; on id 1 send `initialized` + id 2 `account/rateLimits/read`; 15 s total deadline; kill + close pipes always.
7. Python half-even rounding; `int()` truncation; `_reset_minutes` round vs subscription FLOOR.
8. Session: live-only, cache as floor, withheld when stale; `codexSession*` raw pass-through.
9. Only live observations reach cache, Max Tracker, history; stale values served with `*Stale: true`.
10. `usageTotals` computed in the same lock as the counters; placeholder zeros only with `placeholder: true`; 503 for clients without `X-VibePulse-Accepts: usage-totals`.
11. Error-log throttles use "None = never logged", 300 s window, reset on recovery.
12. HTTP threads never block on network/disk/scans (single-flight background threads).
