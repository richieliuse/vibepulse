# VibePulse tokenserver — behavioral spec, part 1 (`tokenserver.py` lines 1–1649)

Scope: constants and module globals, state/log directories, Claude plan-usage and statusline reads and merges, log rotation, server revision and source fingerprint, usage-history and quota-cache singletons, transcript scan (`_parse_file`, `_compute`), Claude OAuth candidate discovery (process env, Keychain, Windows credentials file), rate-limit header and usage-body parsing, the machine-wide probe lock and persisted 429 cooldown, OTA version announcement, and the probe cycle up to (not including) the header fallback that part 2 documents from line 1650.

Conventions:
- "wall" = `time.time()`. "mono" = `time.monotonic()`.
- Python `round` is half-to-even. `int` truncates toward zero. `math.ceil` for credential minutes.
- Bool is not a number. Finite required wherever a number is accepted.
- Logger name `"tokenserver"`. Transition logs fire once per change.
- `STATE` = `_state_dir()`: macOS `~/Library/Application Support/VibePulse`; Windows `%LOCALAPPDATA%\VibePulse` (fallback `~/AppData/Local/VibePulse`).
- `_IS_WINDOWS` = `sys.platform == "win32"`. Tests patch it.

Part 2 continues at `_probe_cycle`'s header fallback (line 1650) and owns Codex limits, `get_snapshot`, and the HTTP server. Functions defined here that part 2 calls: `_parse_limit_headers`, `_quota_identity`, `_hold_probe_lock`, `_publish_probe_status`, `_note_probe_schedule_locked`, `_probe_limits`, `_merge_claude_statusline`, `_merge_claude_plan_usage`, `_get_usage_history`, `_get_quota_cache`, `_compute`, `_ota_available_version`, `_state_dir`.

## 0. Imports that this range uses

`statusline_bridge` (`FRESH_S`, `SAMPLE_NAME`, `peek_sample`, `summarize_sample`, `config_path`), `value_meter` (`price_usage`, `build_payload`), `codex_usage.month_value`, `QuotaCache.latest` (called as `quota_cache.latest(provider, scope, now=)`), `UsageHistory` constructor. `fcntl` on POSIX, `msvcrt` on Windows (import guarded; the missing one is `None`).

## 1. Constants

| Name | Value | Notes |
|---|---|---|
| `RECOMPUTE_EVERY_S` | 30 | transcript rescan cadence |
| `FIRST_SCAN_WAIT_S` | 600 | warm-up thread waits this long for a scan an early request already started |
| `LIMITS_EVERY_S` | 240 | OAuth probe cadence when not bridged |
| `AUTH_RECOVERY_EVERY_S` | 15.0 | local token recheck; no upstream while waiting |
| `CLAUDE_CREDENTIAL_WARNING_S` | 1800 | credential status becomes `expiring` inside this |
| `CLAUDE_PLAN_USAGE_FRESH_S` | 1200 | plan-usage sample older than this is stale |
| `STATUSLINE_FRESH_S` | `statusline_bridge.FRESH_S` | per-window freshness |
| `PROBE_WHEN_BRIDGED_S` | 1800 | probe cadence when both statusline windows cover the probe |
| `CLAUDE_PLAN_USAGE_MAX_BYTES` | 2 MiB | larger file is `invalid_size` |
| `HTTP_MAX_WORKERS` | 32 | used by part 3; tests require ≥ `interactions.MAX_PENDING` (8) + 16 |
| `JSON_BODY_TIMEOUT_S` | 2.0 | part 3 |
| `REQUEST_DRAIN_LIMIT` | 64 KiB | part 3 |
| `REQUEST_DRAIN_TIMEOUT_S` | 0.05 | part 3 |
| `_LOG_CAP_BYTES` | 5 MiB | rotate above this |
| `_LOG_TAIL_KEEP_BYTES` | 256 KiB | tail copied to `<name>.old` |
| `_LOG_ROTATE_CHECK_S` | 3600 | hourly recheck |
| `MAX_TRACKER_BACKFILL_TICK_S` | 0.5 | matches `agent_status.POLL_S` |
| `MAX_TRACKER_CLAUDE_SESSION_MINUTES` | 300 | 5 h; Claude never sends window minutes |
| `MAX_TRACKER_CLAUDE_WEEK_MINUTES` | 10080 | 7 d |
| `_PROBE_LOCK_PATH` | `STATE/claude-probe.lock` | flock, non-blocking |
| `_PROBE_STATE_PATH` | `STATE/claude-probe-state.json` | `{"cooldown_until": <epoch float>}` |

## 2. Directories

`_state_dir()` as above. `_log_dir()` is `~/Library/Logs` on macOS and `STATE/Logs` on Windows. `DEFAULT_LOG_PATH` = `_log_dir()/torget-tokenserver.log`.

`_claude_plan_usage_path()`: macOS `~/Library/Application Support/Claude/plan-usage-history.json`; Windows `%APPDATA%\Claude\plan-usage-history.json` (fallback `~/AppData/Roaming`). Owned by Claude Desktop; read only.

`_claude_statusline_path()`: `STATE/<statusline_bridge.SAMPLE_NAME>`, unless `_claude_statusline_path_override` is set (tests).

`_credentials_file_path()`: `~/.claude/.credentials.json` (Windows source).

## 3. Claude plan-usage file

`_read_claude_plan_usage(path=None, now_ts=None) -> dict | None`. Sets global `_claude_plan_usage_status`.

Fail closed, in order:
- stat fails `FileNotFoundError` → `missing`. Other `OSError` / `UnicodeError` / `JSONDecodeError` → `invalid`.
- size ≤ 0 or > 2 MiB → `invalid_size` (file not even parsed).
- not a dict, or `version != 2`, or `samples` not a non-empty list → `unsupported`.
- last sample not a dict, or `t` not a positive int (bool rejected), or `org` not a str whose UTF-8 length is 1..128, or `u` not a dict → `invalid`.
- `u.fh` and `u.sd` must each be a finite number in [0, 100] (bool rejected). Stored as `round(float, 1)`.
- age = now − `t/1000`. age < −60 or age > 1200 → `stale`.
- else status `fresh`, return `{session_pct, week_pct, observed_at: int(t/1000)}`. The raw org id never leaves the function.

## 4. Statusline read and window arbitration

`_read_claude_statusline` holds `_claude_statusline_lock`. Calls `statusline_bridge.peek_sample`. `missing` becomes `not_installed` when `statusline_bridge.config_path(sample_dir)` does not exist. On `ok`, `summarize_sample(document, now)` replaces the status word. View `{status, ageS, claudeCodeVersion}` is published even when unusable. Logs `claude-statusline: <prev|start> -> <status>` only on change. Returns the summary only when it has windows.

`_valid_epoch_after(v, now)`: finite number (not bool) strictly greater than now. `_valid_pct`: finite number in [0, 100].

`_window_wins(candidate_reset, candidate_pct, incumbent_reset, incumbent_pct)`: no incumbent → candidate wins; different resets → the later reset wins; same reset → candidate wins only when its pct is strictly higher. Ties keep the incumbent.

`_covers(window, probe_valid, probe_reset, probe_pct)`: a fresh bridge window may stand in for the probe (and slow it) only when it is at least as new. No valid probe → yes. Different reset → window reset must be later. Same reset → window pct ≥ probe pct. A lower replay of the same window must not slow the probe.

`_merge_claude_statusline(claude, quota_cache, now, path=None)` returns a new dict (or the original when there is no summary). Per window (`five_hour` → session, `seven_day` → week); the model week is never touched.

Session: probe reading is valid when `sessionResetAt` is a future epoch and `sessionPct` is a valid pct. A fresh covering window increments `covered`. The window wins by `_window_wins`, but a stale window never wins against a valid live probe (the wire has no session-stale flag, so a stale floor would be shown as live). On a win: `sessionPct`, `sessionResetAt`, `sessionSource="statusline"`, `sessionLive=fresh`.

Week: probe reading is valid only with a future reset, a valid pct, AND `weekIdentity` a string. Fresh covering increments `covered`. A win is then rejected when `quota_cache.latest("claude","general_weekly", now=)` is strictly better by `_window_wins` (equal is the bridge's own earlier sample and stays live). On a win: `weekPct`, `weekResetAt`, `weekResetMin = max(0, int(round((reset-now)/60)))`, `weekObservedAt = int(window.at)`, `weekIdentity = _quota_identity("claude","general_weekly")` (no raw id), `weekSource="statusline"`, `weekStaleFloor = not fresh`.

`_claude_statusline_bridged` becomes true only when `covered == 2`.

## 5. Plan-usage merge

`_merge_claude_plan_usage(claude, quota_cache, now, path=None)`. No local sample → unchanged. If `weekObservedAt` is a finite number ≥ `local.observed_at` → status `oauth_newer`, unchanged. Needs `quota_cache.latest("claude","general_weekly")` with `reset_at > now`; else status `fresh_without_reset`. Same window (`weekResetAt == cached.reset_at`) with a valid existing pct is rejected (status `not_higher`) when the local week pct is lower, or equal and the existing reading is not a stale floor (`weekStaleFloor is not True`). An equal fresh reading over a stale floor falls through and lifts it.

Applied: drop `weekStaleFloor`; set `weekPct` from local, `weekResetAt` and identity from the cache entry, `weekResetMin` recomputed, `weekObservedAt` from local. Status `fresh_applied`. Model quota is never filled from this file.

## 6. Log rotation and provenance

`_maybe_rotate_own_log(path=None, stderr_fd=2)`: missing file → False. Holds every root-logger handler lock (RLock, so its own line can log). Size ≤ 5 MiB → False. Compares `os.fstat(stderr_fd)` device+inode with the file; mismatch (a terminal run) → False. Copies the last 256 KiB (read to the real EOF) to `<name>.old`, then `truncate(0)`. Logs `log file rotated (<size> bytes > the cap <cap>; the tail is in <name>.old)`. Any exception logs a warning with traceback and returns False; rotation must never take the service down. Locks released in reverse.

`_run_log_rotation_watch(stop_event, interval_s=None)` sleeps on the event (default 3600 s) and calls the above until the event is set.

`_read_server_rev()`: `git rev-parse --short HEAD`, cwd = this file's directory, timeout 5 s, stdout stripped, empty or any exception → `"unknown"`.

`_read_source_fingerprint()`: SHA-256 over `sorted(base.glob("*.py"))` excluding `test_*.py` and `smoke.py`. For each: update with the file name (UTF-8), then the file read as text and re-encoded UTF-8 (CRLF normalized). First 12 hex chars. Any exception → `"unknown"`. Computed once at import into `_SERVER_REV` / `_SERVER_SRC`. `_SERVER_STARTED` is local ISO with seconds at import. `_SERVER_STARTED_MONO` is monotonic at import.

## 7. Singletons

`_get_usage_history(path=None)`: an explicit path builds a fresh `UsageHistory`; otherwise one instance at `STATE/usage-history.json`, created under `_history_lock`. `_get_quota_cache` is the same for `QuotaCache` at `STATE/quota-cache.json` under `_quota_cache_lock`.

`_quota_identity(provider, scope, raw=None)` = lowercase hex SHA-256 of UTF-8 `"{provider}\0{scope}\0{raw or 'default-v1'}"`. Raw ids are never stored or returned.

## 8. Transcript scan

Record tuple: `(day "YYYY-MM-DD", epoch float, tokens, session id, dedup key or None, usd, unpriced tokens)`.

`_parse_file(path, month_start, start_offset=0)` reads bytes from the offset. A line without a trailing `\n` is unfinished: stop and resume at its start next time. Bad JSON is skipped (offset advances). A row counts only when `message.usage` and `timestamp` exist, the timestamp parses (`Z` → `+00:00`) and converts to local time ≥ `month_start`, and token sum > 0. Tokens = input + output + cache_creation_input + cache_read_input, each `or 0`. Dedup key = `"{message.id}:{requestId}"` when both present, else None. Session = `sessionId` or the path string. Dollars come from `value_meter.price_usage(message.model, usage, table=_price_table)`. `OSError` (file vanished) returns what was parsed.

`_compute(projects_dir, max_tracker_store=None)` uses local now. Month start is day 1 at 00:00:00.000000 local. Walks `projects_dir.glob("**/*.jsonl")`. A file whose mtime (local) is before month start is skipped unopened. Cache key is the Path. A hit requires the same `(mtime, size)` AND `(st_dev, st_ino)`. An append (same month, same inode, larger size) parses only the new tail and calls `store.observe_volume("claude", day, tokens)` for new rows only. Anything else reparses from offset 0. Cache entries whose path was not seen this scan are deleted. If any volume was observed, `_mark_max_tracker_dirty(store)` (defined in part 2).

Aggregation walks every cached record. A non-None dedup key is counted once across all files. Sums: month tokens, month USD, priced vs unpriced tokens, today's tokens, today's session set, tokens with `ts >= now-3600`. Codex adds `codex_usage.month_value(now, table=_price_table)`.

Return:

```
{
  "v": 1,
  "dayTokens": int, "dayTokensPerHour": int,   # last hour, not a rate
  "daySessions": int, "monthTokens": int,
  "claudeSourcePresent": projects_dir.is_dir(), # zeros are not measurements
  "value": value_meter.build_payload(
      claude_usd+codex_usd, unpriced sum, priced sum,
      claude_plan, codex_plan, plan_costs, table,
      claude_usd, codex_usd),
  "at": local ISO seconds
}
```

`dayTokens` cannot be null: `tokens_parse.c` rejects a payload without the number. `claudeSourcePresent` says what the zeros mean. `value` is an additive key older firmware skips.

Globals driving this: `_file_cache` under `_cache_lock` (the lock is taken by the caller in part 2, not inside `_compute`), `_claude_plan`, `_codex_plan`, `_plan_costs`, `_price_table`.

## 9. OAuth candidates (macOS)

Process token first. `pgrep -f "/Library/Application Support/Claude/claude-code/.*/claude.app/Contents/MacOS/claude"`, timeout 5. For each numeric pid, `ps eww -p <pid> -o command=`, timeout 5. The command must match `^/Users/<one segment>/Library/Application Support/Claude/claude-code/<one segment>/claude\.app/Contents/MacOS/claude( |$)`. Token is the `CLAUDE_CODE_OAUTH_TOKEN=<non-space>` group. Any failure skips that pid. The token is never logged. Returned as `(token, None)` — `ps` cannot see expiry.

Keychain second, only when its token differs from the process token. `security find-generic-password -s "Claude Code-credentials" -w`, timeout 10. Reasons, published by `_note_keychain_reason` and logged once per change as `claude-keychain: <prev|start|ok> -> <reason|ok>`:

| Cause | Reason word |
|---|---|
| no `security` binary | `keychain_security_missing` |
| timeout | `keychain_timeout` |
| other `OSError` | `keychain_spawn_failed: <ExcName>` |
| exit 44 | `keychain_no_entry` |
| other non-zero | `keychain_denied_or_locked (exit N)` |
| stdout not JSON / wrong shape | `keychain_malformed` |
| JSON but no access token | `keychain_entry_without_token` |
| success | `None` (logged as `ok`) |

Record shape: `claudeAiOauth.accessToken`, `claudeAiOauth.expiresAt` (ms).

Windows: only `_credentials_file_path()`, same JSON shape, any exception → `(None, None)` with no log. No pgrep, no security.

`_oauth_credential_snapshot(candidates, now_s=None)` never returns tokens. No candidates → `{status: unavailable}`. Expiries that are not a positive finite number (ms/1000) are skipped; none usable → `{status: unknown}`. Remaining = max(expiry) − now. ≤ 0 → `{status: expired, expiresInMin: 0}`. Else minutes = `max(1, ceil(remaining/60))`, status `expiring` when remaining ≤ 1800 else `ready`.

## 10. Limit parsing

`_parse_reset_minutes(text, now)` and `_parse_reset_at(text, now)` accept epoch seconds (a number > 1e9), seconds-remaining (smaller non-negative number: minutes = remaining/60, absolute = now + number), or ISO-8601 (`Z` → `+00:00`). Minutes are `max(0, round(seconds/60))` as int. `_parse_reset_at` returns int epoch or None; a non-finite or negative number is None. `_parse_reset_minutes` returns None on failure.

`_parse_limit_headers(headers, now)` matches header names `(?i)anthropic-ratelimit-unified-(.+?)[-_](utilization|reset|resets[-_]at)`. The bucket name, lowercased: `5h` → session; containing `fable`/`opus`/`sonnet` or the substring `model` → model (and sets `modelLabel` to `FABLE · WEEK` / `OPUS · WEEK` / `SONNET · WEEK` when a name matched); `7d` or `week` → week; anything else is sanitized to `[a-z0-9_-]{1,64}` and collected. Utilization: `round(pct*100 if pct<=1 else pct, 1)`. Reset kinds set `<window>ResetAt` and `<window>ResetMin`. Unknowns become sorted `unknownBuckets`. For week and model, when both pct and reset exist, set `<window>ObservedAt = int(now)` and `<window>Identity = _quota_identity("claude", "general_weekly"|"model_weekly")`.

`_parse_usage_limits(body, now)` requires `body.limits` to be a list, else `{}`. Each limit needs a finite pct in [0, 100] (bool rejected) and a reset strictly in the future. `kind == "session"` → session. `kind == "weekly_all"` → week. `kind == "weekly_scoped"` counts only when `is_active is True` OR pct > 0 (a 0 % inactive pool is omitted; real consumption with `is_active=false` is shown). Its `scope.model.display_name`, stripped and lowercased, must be exactly `fable`, `opus`, or `sonnet`; that sets `modelLabel` and the model prefix. Same pct/reset/identity fields as the header parser. Pct is `round(float, 1)` and is already on a 0–100 scale (not scaled).

## 11. The probe

`_usage_request(token)`: GET `https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-cli/2.1.227 (external, cli)`. Timeout 15 s at the call site.

`_hold_probe_lock(path=None)`: mkdir parent, open the lock file `"w"`, `flock(LOCK_EX|LOCK_NB)` or, on Windows, write one byte and `msvcrt.locking(LK_NBLCK, 1)`. Returns the open file or None. Closing releases it. Claude and Codex use different files so one probe cannot silence the other.

`_load_probe_state_locked()` (caller holds `_limits_lock`, once per process): read `cooldown_until`; when finite and in the future, set the cooldown and status `usage_http_429 + backoff_until_HH:MM (persisted)` using local time. Bad file → ignore.

`_save_probe_state(until)`: mkdir, write `{"cooldown_until": <float>}`. `OSError` is swallowed.

`_ProbeOutcome(status)`: `status`, `headers=[]`, `unknown_buckets=[]`, `credential=None`, `cooldown_until=None`. A cycle writes here; `_publish_probe_outcome` swaps status, header names, unknown buckets, credential (when not None), and cooldown (when not None) under `_limits_lock`, then records the streak. Nothing is published field by field.

`_note_probe_schedule_locked(refreshed)`: streak = 0 on success else streak+1; `_last_probed = monotonic()`; sets `_probe_cycle_published` so the caller does not record the streak twice.

`_publish_probe_status(status)`: status-only. Clears headers and unknown buckets (a miss must not keep the previous cycle's evidence) and counts as a failure. The credential block is left as it was.

`_probe_view()` copies under one lock: `claudeProbe`, `claudeProbeStreak`, `claudeProbeIntervalS` (int of `_probe_interval_s()`, defined in part 2), `claudeProbeCooldownLeftS` (`ceil` of remaining seconds, or None when ≤ 0), `claudeProbeAgeS` (int monotonic seconds since `_last_probed`, None when never), `claudeCredential` (dict copy), `ratelimitHeaders`, `unknownRateLimitBuckets`. `_probe_diagnostics()` returns only the four backoff fields.

`_probe_limits()`: under the lock, load persisted state; if still cooling down, record a miss in that same section and return None without any network. Else take the flock; if another instance holds it, publish `probe_held_by_other_instance` and return None. Else run `_probe_limits_locked` and always close the lock.

`_probe_limits_locked`: build an outcome seeded with the current status, run `_probe_cycle`, publish with `refreshed = bool(found)`. A cycle that raises publishes nothing; the caller (part 2) records the crash.

`_probe_cycle` (this part, through line 1649): snapshot credentials onto the outcome. No candidates → status `no_claude_oauth_token`, and on macOS when `_keychain_reason` is set, append `: <reason>` and add `reason` to the credential dict. Return None.

For each `(token, expires_at_ms)`: a token in `_dead_tokens` → status `token_dead_awaiting_refresh`, continue. `expires_at/1000 < now` → status `token_expired_HH:MM` (local), continue. Else GET the usage endpoint. 429 → status `usage_http_429 + backoff_until_HH:MM`, `cooldown_until = now + max(Retry-After, 600)` (Retry-After parsed as int, bad values count as 0), persist it, return None immediately (no second source, no header probe). 401/403 → record the token value with reason `http_<code>`, FIFO-evict past 8 entries (`pop` the oldest insertion), continue. Any other `HTTPError` → keep this token and break to the header fallback (part 2). Any other exception → status `usage_request_failed: <ExcName>`, keep the token, break. HTTP 200 → `_parse_usage_limits`. A non-empty result is success (`usage_http_200 + ok`) even without `sessionPct`: a passed session reset is skipped by the parser and the week figures are still valid. An empty result sets `usage_http_200 + no_mapped_limits` and breaks to the header fallback. Part 2 owns everything after that break.
