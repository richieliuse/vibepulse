# 05 — State files & metering: behavioral specification for the Swift port

Source of truth: `tools/tokenserver/` at this worktree. Modules covered:
`max_tracker.py`, `usage_history.py`, `value_meter.py`, `quota_cache.py`,
`subscription_quota.py`, `state_files.py`, `vibepulse_config.py`,
`prices.json`, `update_prices.py`, `verify_value.py`, `quota_http.py`, their
tests, the `codex_rollout.py` helpers they import, and the parts of
`tokenserver.py` / `codex_usage.py` / `smoke.py` that call them.

Runtime baseline: CI runs **Python 3.12** (`.github/workflows/ci.yml`). Some
edge-case behaviour below (ISO parsing, `date.fromisoformat`) is 3.12's.

The Swift port **must read and write the same state files** as the Python
service (never concurrently — see §11.1), so every byte-level format detail
is given. "MUST" = required for compatibility; "Python quirk" = observed
behaviour worth knowing, replicate only where it affects files or wire.

---------------------------------------------------------------------------

## 0. Cross-cutting conventions

### 0.1 Time zones and day boundaries

* **All calendar days are the machine's local days**, never UTC.
  * epoch → local date: `datetime.fromtimestamp(ts).astimezone().date()`
    (correct local zone rules incl. DST for that instant). Swift:
    `Calendar.current` with `TimeZone.current`, `dateComponents([.year,.month,.day], from: Date(timeIntervalSince1970: ts))`.
  * ISO timestamp from a log (`"2026-08-07T10:00:00Z"` or with offset)
    → `datetime.fromisoformat(s.replace("Z", "+00:00"))` then `.astimezone()`
    (convert to local) → local date. A **naive** timestamp (no offset) is
    interpreted as **local** time by `.astimezone()`/`.timestamp()`.
    Python 3.12 `fromisoformat` accepts full ISO 8601 (any fractional-second
    digits, `Z`, `+HH:MM`, `+HHMM`, basic format `20260807T100000`, …).
* **"Start of current month" (Python quirk, replicate for byte-exact
  ownership semantics):**
  `now = datetime.now().astimezone(); now.replace(day=1, hour=0, minute=0, second=0, microsecond=0).timestamp()`.
  `replace()` keeps the **current** UTC offset, so if a DST change happened
  between the 1st and today, the computed instant is off by the DST delta
  (e.g. Stockholm on 30 March: offset +02:00, month start computed as
  `03-01T00:00+02:00` = `02-28T23:00+01:00`). Same pattern for "start of
  today" in `get_snapshot` (`local_now.replace(hour=0,…)`). Swift: take the
  current `secondsFromGMT()`, build `YYYY-MM-01T00:00:00` in a
  **fixed-offset** zone with that offset.
* Max Tracker's pure functions reason only about `YYYY-MM-DD` strings with
  calendar-date arithmetic (no clocks), so DST/year boundaries are free.
* ISO weeks: `date.isocalendar()` → `(iso_year, iso_week, weekday)`;
  week key format `"%d-W%02d" % (iso_year, iso_week)`, e.g. `2026-W33`,
  `2026-W53`, `2026-W01` for 2025-12-29. Swift: `Calendar(identifier: .iso8601)`,
  components `.yearForWeekOfYear`, `.weekOfYear`.
  `date.fromisocalendar(y, w, 1)` = Monday of that ISO week; raises
  `ValueError` for an invalid week (e.g. W54, W53 in a 52-week year).

### 0.2 Rounding (MUST match Python)

* `round(x, n)` for floats (used for `avgPeakPct`, `value_usd`, deltas,
  pace factors, shares, multiples): **correctly rounded on the exact binary
  value, ties-to-even.** Equivalent Swift: `Double(String(format: "%.\(n)f", x))!`
  (C `printf` uses the exact binary expansion + round-half-even for true
  ties, matching CPython's `_Py_dg_dtoa` mode 3). Do **not** use
  `(x*10^n).rounded()/10^n` — it differs on some inputs.
* `int(round(x))` / `round(x)` to integer: **ties-to-even**
  (`round(2.5) == 2`). Swift: `x.rounded(.toNearestOrEven)`.
* `int(x)` on a float: truncation toward zero. `math.floor` = floor.
* Max Tracker day pct uses its own rule `_round_day_pct` (§3.2), NOT
  Python `round`.

### 0.3 JSON encoding conventions

* **State files** (`max-tracker.json`, `usage-history.json`,
  `quota-cache.json`): `json.dump(obj, stream, ensure_ascii=False, separators=(",", ":"))`
  then a single `"\n"`, written in **text mode with `encoding="utf-8"`**
  → on Windows the trailing newline becomes `"\r\n"` (text-mode newline
  translation). No other whitespace. Non-ASCII written raw as UTF-8.
* `config.json`: `json.dumps(asdict(cfg), sort_keys=True, separators=(",", ":"))`
  (default `ensure_ascii=True`) + `b"\n"`, written in **binary** mode (so
  `\n` on every OS).
* HTTP responses: `json.dumps(payload)` → default separators `", "` and
  `": "`, `ensure_ascii=True`. (Whitespace is irrelevant to the device
  parser, cJSON.)
* Python writes Python `int` as a JSON integer (`2000`) and Python `float`
  as `repr(float)` (`46.0`, `59.1`, `1e-05`, `1e+16`). **Where Python
  validators require `int`** (see per-file tables: quota-cache
  `reset_at`/`observed_at`, max-tracker `offset`/`size`/`lvl`), the Swift
  writer MUST emit a JSON integer with no decimal point or exponent.
  Everywhere else Python accepts either `46` or `46.0`.
* Python's `json.loads` quirks the Swift reader should tolerate or mirror:
  duplicate keys → last wins (except config.json, where duplicates are an
  error); accepts `NaN`/`Infinity`/`-Infinity` literals; arbitrarily large
  integers (e.g. `10**400`); a leading UTF-8 BOM (U+FEFF) is **rejected**
  (`JSONDecodeError: Unexpected UTF-8 BOM`) because files are decoded with
  `utf-8`, not `utf-8-sig`. `JSONDecodeError.pos` is a *character* index
  (quarantine log says "invalid JSON at byte {pos}" regardless).

### 0.4 Bool is not a number

Every numeric validator in these modules excludes JSON `true`/`false`
(Python `bool` is an `int` subclass, so they check
`not isinstance(v, bool)` explicitly). The Swift port MUST treat JSON
booleans as non-numbers everywhere (beware `NSNumber` bridging from
`JSONSerialization`, which makes `true` look like `1`; prefer a typed JSON
decoder that distinguishes bool/int/double).

---------------------------------------------------------------------------

## 1. `state_files.py` — shared state-file discipline

Logger name: `tokenserver.state`.

### 1.1 `state_dir() -> Path`

* Windows (`sys.platform == "win32"`): `%LOCALAPPDATA%\VibePulse`; if
  `LOCALAPPDATA` unset/empty → `~\AppData\Local\VibePulse`.
* Everything else: `~/Library/Application Support/VibePulse`.
* `tokenserver._state_dir()` is an identical copy (uses
  `_IS_WINDOWS = sys.platform == "win32"`).

### 1.2 `quarantine_corrupt(path, reason) -> Path | None`

Moves an unreadable state file aside so the next save does not destroy the
evidence (OBS-11).

```python
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")   # e.g. 20260924T062801Z
target = path.with_name(f"{path.name}.corrupt-{stamp}")
counter = 1
while target.exists():
    counter += 1
    target = path.with_name(f"{path.name}.corrupt-{stamp}-{counter}")  # -2, -3, ...
os.replace(path, target)
```

* Naming: `<name>.corrupt-YYYYMMDDTHHMMSSZ` (UTC), collision suffixes start
  at `-2`. Same directory.
* If `os.replace` fails: log WARNING
  `"%s is unreadable (%s) and could not be quarantined (%s): starting empty; the next save overwrites it"`
  (name, reason, exception class name) → return `None`.
* Then `fsync_parent(target)`; on `OSError`: WARNING
  `"%s is unreadable (%s): quarantined as %s and starting empty, but the directory fsync failed (%s) so the copy is not yet durable."`
  → return `target`.
* Success: WARNING
  `"%s is unreadable (%s): quarantined as %s and starting empty. The bytes are kept for inspection or hand repair."`
  → return `target`.
* Log messages carry only file **names** and the reason — never contents.
* Quarantined files are never cleaned up automatically.

### 1.3 `fsync_parent(path) -> None`

* `os.name == "nt"` → no-op.
* Else `fd = os.open(path.parent, O_RDONLY | O_DIRECTORY)`; `fsync(fd)`;
  `close(fd)`. Errors propagate (`OSError`).

### 1.4 Atomic write recipe (used by max-tracker, usage-history, quota-cache)

1. `path.parent.mkdir(parents=True, exist_ok=True)` (default mode, umask).
2. `tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False)`
   → name `.<name>.<8 random [a-z0-9_]>.tmp`, created mode **0600**
   (mkstemp). Max Tracker additionally `os.chmod(temp, 0o600)`.
3. Write JSON (§0.3) + `"\n"`, `flush()`, `os.fsync()`.
4. `os.replace(temp, path)` (atomic rename; final file inherits 0600).
5. `fsync_parent(path)`.
6. On any failure before the replace: unlink the temp (ignore errors).
   After a successful replace the temp is gone; a directory-fsync failure is
   handled per store (see each).

---------------------------------------------------------------------------

## 2. State directory inventory

All under `state_dir()`:

| File | Owner | Format section |
|---|---|---|
| `max-tracker.json` | `MaxTrackerStore` | §3.6 |
| `usage-history.json` | `UsageHistory` | §4 |
| `quota-cache.json` | `QuotaCache` | §5 |
| `config.json` | `vibepulse_config` | §9 |
| `.config.json.lock` | `config_lock` | §9.4 |
| `..config.json.vibepulse-setup-transaction.lock` | `tools/vibepulse_setup.py` (outer transaction lock via `config_lock(path.with_name(".config.json.vibepulse-setup-transaction"))`) | §9.4 |
| `*.corrupt-<stamp>[-n]` | quarantine | §1.2 |
| `.<name>.<rand>.tmp` | transient atomic-write temps | §1.4 |
| `.config.json.<rand>` | transient config temp (mkstemp, **no** `.tmp` suffix) | §9.3 |
| others (out of scope here): `claude-probe.lock`, `claude-probe-state.json`, `codex-probe.lock`, `codex-probe-state.json`, statusLine bridge sample/config (`statusline_bridge.SAMPLE_NAME`/`CONFIG_NAME`), `Logs/` | | |

`smoke.py check_state_files` shape tripwires (for reference): usage-history
requires `v == 1` and list `samples`; quota-cache requires keys exactly
`{v, records}`, `v == 1`, list `records`; max-tracker requires dict
`claude` and dict `codex`. `usage-history.json` older than
`USAGE_HISTORY_FRESH_S` → WARN.

---------------------------------------------------------------------------

## 3. Max Tracker (`max_tracker.py`)

Logger `tokenserver.state`. Imports `codex_rollout_rate_limits`,
`observation_timestamp` from `codex_rollout.py` (§3.9).

### 3.1 Constants

```
PROVIDERS       = ("claude", "codex")        # order matters for output/iteration
WINDOW_WEEKS    = 20
WINDOW_DAYS     = 140
AGGREGATE_MAX   = 999
PLAN_LABELS     = {"pro": "PRO", "max5x": "MAX 5X", "max20x": "MAX 20X", "plus": "PLUS"}
MaxTrackerStore.RETENTION_DAYS         = 400
MaxTrackerStore._GENERAL_WINDOW_MINUTES = 600     # > 600 min = weekly window
MaxTrackerStore._BLOCK_BYTES           = 65536
MaxTrackerStore._MAX_RECORDS_PER_STEP  = 256
MaxTrackerStore._MAX_LINE_BYTES        = 8 * 1024 * 1024
MaxTrackerStore._SCHEMA_VERSION        = 1
```

tokenserver: `MAX_TRACKER_BACKFILL_TICK_S = 0.5`,
`MAX_TRACKER_CLAUDE_SESSION_MINUTES = 300`,
`MAX_TRACKER_CLAUDE_WEEK_MINUTES = 10080`.

### 3.2 Pure functions

**`volume_levels(day_volumes: {day: int}) -> {day: 0..2}`** — terciles over
*distinct nonzero* volumes:

```python
distinct = sorted({v for v in day_volumes.values() if v and v > 0})
count = len(distinct)
rank = {v: (i * 3 // count) for i, v in enumerate(distinct)}
return {d: (rank[v] if v and v > 0 else 0) for d, v in day_volumes.items()}
```
Every input key appears in output. 0/falsy → 0 and excluded from
thresholds. One distinct value → 0. Two distinct → 0,1. Three → 0,1,2.
Six → 0,0,1,1,2,2. Ties share a level.

**`coding_streak(active_dates: set[str], today: str) -> int`** — start at
`today` if it's active, else yesterday; count consecutive active days
backwards. Returns 0 if none.

**`week_key(date_str) -> "YYYY-Www"`** (ISO week-year).

**`_week_key_to_monday(key) -> date`**: `year_str, week_str = key.split("-W")`
(must split into exactly 2), `date.fromisocalendar(int(y), int(w), 1)`.
Raises `ValueError`/`IndexError` on garbage.

**`max_weeks_streak(week_maxed: {key: bool}, this_week: key) -> int`** —
cursor = Monday(this_week) − 7 days; while `week_maxed.get(week_key(cursor))`
truthy: count, cursor −= 7. The current week is never inspected.

**`_round_day_pct(pct: float) -> int`** (MUST replicate exactly):
```python
if pct >= 100.0: return 100
return min(int(math.floor(pct + 0.5)), 99)
```
Half away from zero for non-negatives; never rounds <100 up to 100
(99.5 → 99, 99.96 → 99, 0.5 → 1, 2.5 → 3, 15.5 → 16, 15.4 → 15).

**`dense_window(today, weeks, per_day) -> [[pct, lvl], ...]`** of length
`weeks*7`:
```python
current_monday = today - (isoweekday(today) - 1) days
window_start   = current_monday - 7*(weeks-1) days
for offset in 0 ..< weeks*7:
    day = window_start + offset
    if day > today:              -> [-1, -1]      # rest of current week = padding
    rec = per_day.get(day.iso)
    if not rec (None or {}):     -> [-1, -1]
    pct = rec.get("pct"); lvl = rec.get("lvl")
    -> [_round_day_pct(pct) if pct is not None else -1,
        lvl if lvl is not None else -1]
```
Note: when called from `build_payload`, `per_day` values already have
`pct = -1` for "no pct", and `_round_day_pct(-1)` = `min(floor(-0.5), 99)` = `-1`
— so -1 passes through unchanged. Index 0 is always a Monday; today
2026-08-12 (Wed) → window starts 2026-03-30, today at index 135, 136–139
padding.

**`_window_week_keys(today, weeks)`** — week keys for the 20 window weeks,
oldest first (Monday of each).

**`_clamp_aggregate(v) = max(0, min(999, v))`**.

**`_provider_days(days) -> {day: {"pct": int|-1, "lvl": int}}`** over the
FULL history:
```python
rankable = {d: (r.get("vol") or 0) for d, r in days.items()
            if r.get("act") and "lvl" not in r}
levels = volume_levels(rankable)
for d, r in days.items():
    pct = r.get("pct"); active = bool(r.get("act"))
    lvl = -1 if not active else (r["lvl"] if "lvl" in r else levels.get(d, -1))
    merged[d] = {"pct": pct if pct is not None else -1, "lvl": lvl}
```
Two populations never mixed: a day with explicit `lvl` (loaded from disk)
is authoritative and excluded from ranking; days with raw `vol` are ranked
only against each other. `lvl` is computed even when a real `pct` exists.

**`build_payload(state, today, plans) -> dict`** — the `/api/max-tracker`
v1 contract (§3.8). Algorithm:
```python
plans = plans or {}
payload = {"v": 1, "weeks": 20, "stale": bool(state.get("stale", False))}
active_dates = union over providers of days with truthy "act"
payload["codingStreakDays"] = None if not active_dates else clamp(coding_streak(active_dates, today))
window_keys = _window_week_keys(today, 20); this_week = week_key(today)
for provider in ("claude", "codex"):
    days  = (state.get(provider) or {}).get("days") or {}
    weeks = (state.get(provider) or {}).get("weeks") or {}
    merged = _provider_days(days)
    window_days  = dense_window(today, 20, merged)
    window_maxed = [1 if weeks.get(k) else 0 for k in window_keys]
    real = [p for p, _ in window_days if p != -1]
    avg = round(sum(real) / len(real), 1) if real else None      # Python round (§0.2)
    out = {}
    label = PLAN_LABELS.get(plans.get(provider)) if isinstance(plans.get(provider), str) else None
    if label: out["planLabel"] = label                           # omitted otherwise
    out.update({
      "avgPeakPct": avg,                                          # window only
      "maxWeeksStreak": clamp(max_weeks_streak(weeks, this_week)),# full history
      "maxWeeks": clamp(count of truthy weeks values),            # full history
      "maxDays":  clamp(count of merged days with pct == 100),    # full history, incl. inactive days
      "weekMaxed": window_maxed,                                  # 20 ints 0/1
      "days": window_days,                                        # 140 [pct,lvl] int pairs
    })
    payload[provider] = out
```
`avgPeakPct` is a Python float (e.g. `42.0`), serialized with a decimal
point; device accepts any finite number 0..100 or null.

### 3.3 `MaxTrackerStore(path, codex_root, claude_root)` — in-memory model

```
_state   = {"claude": {"days": {}, "weeks": {}}, "codex": {...}}
            day record: {"pct"?: int 0..100, "act"?: bool, "vol"?: int, "lvl"?: int 0..2}
            (a day never has both "vol" and "lvl")
            weeks: {"YYYY-Www": True}
_backfill = {"claude": {inode:int -> {"offset":int,"size":int,"done":bool,"discarding":bool}}, "codex": {...}}
_pending  = {"claude": {inode -> bytes}, "codex": {...}}   # in-memory ONLY, never persisted
_load_error: str | None
_lock     = RLock (re-entrant; every public method holds it for its whole body,
            except save() which releases it before the disk write)
```
Constructor calls `_load()`.

Threading: backfill thread (`backfill_step`, `observe_volume` via
handlers, `save` via writer thread), HTTP threads (`snapshot`, and
`observe_quota`/`observe_volume` via `get_snapshot`/`_compute`). Swift:
serialize all state access (actor or lock); the disk write of `save` must
not hold the lock.

### 3.4 Live rollup

**`observe_quota(provider, window_minutes: float|None, pct, ts)`**
* Ignore if provider unknown, or `pct` not a finite non-bool number in
  `[0,100]`, or `ts` not a finite non-bool number.
* `date = local_date(ts)`.
* `window_minutes is None` → bump day pct.
* `window_minutes` finite non-bool `> 0`:
  * `<= 600` → bump day pct;
  * `> 600` and `pct >= 100` → `weeks[week_key(date)] = True`
    (never un-marks; `pct <= 100` enforced so effectively `== 100`).
* Any other `window_minutes` (≤0, NaN, bool, string) → ignore entirely.
* **Never sets `act`.**
* bump: `day = days.setdefault(date, {})`; `r = _round_day_pct(float(pct))`;
  if `day.get("pct") is None or r > current`: `day["pct"] = r` (max only).

**`observe_volume(provider, date_str, tokens)`**
* Ignore if provider unknown; tokens not finite non-bool number or `<= 0`;
  `date.fromisoformat(date_str)` fails (Python 3.12 also accepts
  `YYYYMMDD` and ISO week dates — the Swift port may accept only
  `YYYY-MM-DD`; callers always pass that).
* `day = days.setdefault(date_str, {})`; `day["act"] = True`;
  `day["vol"] = int(day.get("vol") or 0) + int(tokens)` (int truncation; so
  0 < tokens < 1 marks active with +0); `day.pop("lvl", None)`.

### 3.5 Backfill

**`backfill_step(budget_bytes=1_048_576) -> bool`** (under lock):
```python
codex_more  = _advance_one_file("codex",  codex_root,  "**/rollout-*.jsonl", budget, _handle_codex_event)
claude_more = _advance_one_file("claude", claude_root, "**/*.jsonl",         budget, _handle_claude_event,
                                live_channel_cutoff_ts=_current_month_start_ts())
return codex_more or claude_more
```
`_current_month_start_ts()` per §0.1 quirk. Codex files are never deferred.

**`_advance_one_file(provider, root, pattern, budget, handler, cutoff=None) -> bool`**
1. `root` not a dir → `False`. `paths = sorted(root.glob(pattern))`
   (recursive, `**` = zero or more dirs; dotfiles included; sort is
   pathlib component-wise — order only affects which file drains first,
   not results); `OSError` → `False`.
2. `deferred_to_live(st)` = `cutoff is not None and st.st_mtime >= cutoff
   and (entry is None or entry.get("done", False))` where
   `entry = bucket.get(st.st_ino)`. (A started-but-unfinished file stays
   backfill-owned regardless of mtime — "Rule 2".)
3. **Single pass over every path** ("Rule 1"): `stat()` (skip on
   `OSError`); if deferred → `_advance_watermark(bucket, pending, st)` and
   continue; if a candidate already chosen → continue; if
   `_is_fully_drained(entry, st)` → continue; else choose
   `(path, st, entry)`.
4. No candidate → `False`.
5. Resume point:
   * `entry is None or entry.get("size", 0) > st.st_size` (new inode or
     shrank) → `start=0`, `discarding=False`, drop `pending[ino]`.
   * else `start=entry["offset"]`, `discarding=entry["discarding"]`.
6. `(new_off, new_pending, still_discarding, dangling_eof) = _drain_file(path, start, budget, handler, pending.get(ino, b""), discarding)`.
7. `done = dangling_eof or new_off >= st.st_size`;
   `bucket[ino] = {"offset": new_off, "size": st.st_size, "done": done, "discarding": still_discarding}`;
   store/clear `pending[ino]`.
8. Not done → `True`. Done → drop pending; return `True` if any **other**
   path (re-stat'ed; skip `OSError`; skip deferred ones) is not fully
   drained, else `False`.

`_is_fully_drained(entry, st) = entry and entry["done"] and entry["size"] == st.st_size`.

**`_advance_watermark(bucket, pending, st)`** — stat-only, never reads:
if an existing entry has `done == False` → leave it untouched; else
`bucket[ino] = {"offset": size, "size": size, "done": True, "discarding": False}`
and drop pending. This is what makes month rollover resume from where the
live channel stopped.

**`_drain_file(path, start, budget, handler, pending_buf, discarding)`** —
MUST replicate the offset semantics exactly (offset is persisted):
```python
offset = start
seek = start + (0 if discarding else len(pending_buf))
records = 0; read = 0
buf = b"" if discarding else pending_buf
hit_eof = False
open(path, "rb"); seek(seek)
while records < 256:
    if discarding:
        if read >= budget: break
        chunk = read(min(65536, budget - read))
        if not chunk: hit_eof = True; break
        read += len(chunk)
        nl = chunk.find(b"\n")
        if nl < 0: offset += len(chunk); continue          # garbage, commit progress now
        discarding = False; records += 1
        offset += nl + 1; buf = chunk[nl+1:]; continue
    nl = buf.find(b"\n")
    if nl >= 0:                                            # resolve from buffer first
        line, buf = buf[:nl], buf[nl+1:]
        offset += nl + 1; records += 1
        if line.strip():                                   # blank lines count as records
            try: event = json.loads(line)                  # bytes; decode errors -> skip
            except (JSONDecodeError, UnicodeDecodeError): event = None
            if event is not None: handler(event)
        continue
    if len(buf) > 8 MiB:                                   # oversized, start discarding
        discarding = True; offset += len(buf); buf = b""; continue
    if read >= budget: break
    chunk = read(min(65536, budget - read))
    if not chunk: hit_eof = True; break
    read += len(chunk); buf += chunk
# OSError anywhere (open/seek/read) -> return (start, pending_buf, discarding_in, False)
if hit_eof and not discarding and buf:
    return offset, b"", False, True                        # dangling unterminated tail
return offset, (b"" if discarding else buf), discarding, False
```
Properties pinned by tests: lines ≤ 8 MiB are parsed in full even across
many small-budget calls; lines > 8 MiB are skipped without buffering and
never stall; after the 256-record cap, complete lines already in the
buffer are carried forward and resolved first next call; an unterminated
final line marks the file done with `offset` at the **start** of that tail
(nothing counted), and it is parsed once the file grows; lines split on
`\n` only (a trailing `\r` is JSON whitespace). `json.loads` in Python also
accepts `NaN`/`Infinity` and UTF-16/32 byte input (auto-detected).

Python quirks: exceptions raised by a handler (e.g. a non-dict `message`,
or a string token count → `TypeError` in the `+`) propagate out of
`backfill_step` without updating the bucket, so the same line is retried
(and fails) every tick; the Swift port should instead treat such a record
as unusable and continue (this only affects in-memory progress, not file
format). An `open` failure on a new file leaves `done=False` → the step
reports more work forever (save every tick). Bookkeeping entries are never
pruned (deleted files' inodes stay; inode reuse by a larger new file would
resume mid-file).

**`_handle_codex_event(event)`**
1. `rl = codex_rollout_rate_limits(event)` (strict envelope, §3.9); `None` → return.
2. `limit_name = rl.get("limit_name")`: if not `None` and (not a string
   **or** a non-empty string) → return (named/scoped pool). `""` counts as
   the general pool.
3. `ts = observation_timestamp(event.get("timestamp"))` (int epoch,
   truncated; `None` → return). `date = local_date(ts)`.
4. For `key in ("primary", "secondary")`: window must be a dict with
   `used_percent` finite non-bool in `[0,100]` and `window_minutes` finite
   non-bool `> 0` (no `resets_at` check); `pct = _round_day_pct(used_percent)`;
   `window_minutes <= 600` → bump day pct (max); else `pct >= 100` → mark
   week. Any valid window found → `days.setdefault(date, {})["act"] = True`.

**`_handle_claude_event(event)`** ("Rule 3", the load-bearing ownership rule)
1. Must be a dict; `usage = (event.get("message") or {}).get("usage")`;
   `ts_raw = event.get("timestamp")`; falsy usage / non-dict usage / falsy
   ts → return.
2. `ts = fromisoformat(str(ts_raw).replace("Z","+00:00"))` (ValueError →
   return); `local = ts.astimezone()`.
3. **If `local.timestamp() >= _current_month_start_ts()` → return** (the
   live `/api/tokens` scanner owns current-month events; offset still
   advances).
4. `tokens = (input_tokens or 0) + (output_tokens or 0) + (cache_creation_input_tokens or 0) + (cache_read_input_tokens or 0)`;
   not a number or `<= 0` → return.
5. `observe_volume("claude", local.date().isoformat(), tokens)`.
No dedup by message/request id (only feeds a coarse tercile).

### 3.6 Persistence — `max-tracker.json`

Path: `state_dir()/max-tracker.json`.

**Exact on-disk schema (version 1)** — top level has exactly the two
provider keys, in order `claude`, `codex`:
```json
{"claude":{"v":1,
           "days":{"2026-08-07":{"pct":55,"act":true,"lvl":2},
                   "2026-08-08":{"pct":null,"act":false,"lvl":null}},
           "weeks":{"2026-W32":true},
           "backfill":{"1234567":{"offset":4096,"size":4096,"done":true,"discarding":false}}},
 "codex":{"v":1,"days":{},"weeks":{},"backfill":{}}}
```
| key | type | notes |
|---|---|---|
| `<provider>.v` | int | must equal `1` |
| `days` | object | key `YYYY-MM-DD` local date |
| `days.*.pct` | int 0..100 or null | already `_round_day_pct`-rounded |
| `days.*.act` | bool | any agent activity that day |
| `days.*.lvl` | int 0..2 or null | null iff `act` false; the tercile (raw `vol` is **never** persisted — privacy allowlist) |
| `weeks` | object | key `YYYY-Www`, value always `true` (only maxed weeks written) |
| `backfill` | object | key = decimal inode string; values `offset`/`size` non-negative ints, `done`/`discarding` bools |

Nothing else may ever be written (no paths, file names, models, prompts —
backfill is keyed by inode alone because Claude paths encode project
names).

**`save(today: str|None = None)`**
1. If `_load_error` → raise `OSError("max-tracker.json was unreadable at startup ({err}); refusing to overwrite it")`.
2. Under lock: `_prune_retention(today)` (mutates memory too), build
   payload via `_provider_payload` for each provider.
3. Outside lock: atomic write (§1.4) incl. chmod 0600 and
   `fsync_parent(path)`. Any exception propagates (after temp cleanup);
   `fsync_parent` failure raises after the file is already replaced.

`_prune_retention(today)`: `anchor = date.today()` (local) or
`fromisoformat(today)`; `cutoff = anchor − 400 days`; delete days with
`date < cutoff` or unparseable keys (kept: exactly 400 days old);
`week_cutoff = cutoff − 7 days`; delete weeks whose Monday `< week_cutoff`
or whose key doesn't parse.

`_provider_payload(provider)`:
```python
rankable = {d: (r.get("vol") or 0) for d, r in days.items() if r.get("act") and "lvl" not in r}
levels = volume_levels(rankable)
days_out[d] = {"pct": _round_day_pct(float(pct)) if pct is not None else None,
               "act": bool(r.get("act")),
               "lvl": None if not act else (r["lvl"] if "lvl" in r else levels.get(d, 0))}
weeks_out = {w: True for w, m in weeks.items() if m}
backfill_out = {str(ino): {"offset": e["offset"], "size": e["size"],
                           "done": bool(e["done"]), "discarding": bool(e.get("discarding", False))}}
return {"v": 1, "days": days_out, "weeks": weeks_out, "backfill": backfill_out}
```

**`_load()`** (constructor):
* `FileNotFoundError` → empty (normal first run).
* `UnicodeError` (not UTF-8) → quarantine `"not UTF-8"`, empty.
* other `OSError` (permission, I/O) → `_load_error = <exception class name>`,
  WARNING `"%s exists but could not be read (%s): starting empty and refusing to save over it until the service restarts with a readable file"`, empty; **all later saves raise**.
* `JSONDecodeError` → quarantine `f"invalid JSON at byte {pos}"`.
* top level not an object → quarantine `"top level is not an object"`.
* any provider section invalid → quarantine
  `"a provider section (claude/codex) is missing or not the {v, days, weeks, backfill} shape save() writes"`.
  Valid section = dict with `v == 1` (Python `==`: `1.0` and `true`
  also compare equal to 1 — Swift should accept integer 1; a writer MUST
  write `1`) and `days`, `weeks`, `backfill` all dicts. So `{}`,
  `{"claude": [], "codex": {}}`, a missing provider, `v: 2`, `days: []`,
  missing `backfill` → all quarantined (no older formats exist; the file
  has had all four keys since its first commit — **there is no
  migration**).
* Extra top-level keys are ignored.

`_load_provider(provider, section)` (lenient per record):
* days: skip keys failing `date.fromisoformat` (3.12 also accepts
  `YYYYMMDD` etc. — never written by Python); skip non-dict records.
  `out = {"act": bool(record.get("act"))}` (truthiness!);
  if `pct` finite non-bool in [0,100] → `out["pct"] = _round_day_pct(float(pct))`;
  if `act` and `lvl` is an int (not bool, not float) → `out["lvl"] = clamp(lvl, 0, 2)`.
  **Loaded days never have `vol`.** A day loaded with `act` true but no
  valid `lvl` becomes rankable with `vol` 0 → tercile 0.
* weeks: any key with a truthy value → `True` (keys not validated until
  the next save's prune).
* backfill: key must be `str.isdigit()` → `int(key)`; entry dict with
  `offset`, `size` ints ≥0 (not bool), `done` bool, `discarding` bool
  (default `False` if absent); otherwise skipped.
* Python quirk: a pct that is a huge integer (e.g. `1e400` literal as int)
  raises `OverflowError` from `math.isfinite` and crashes startup; Swift
  should just treat it as invalid.

### 3.7 `snapshot(today, plans) -> dict`

Under lock, builds a state copy where each day is
`{"pct": r.get("pct"), "act": bool(r.get("act")), **({"lvl": r["lvl"]} if "lvl" in r else {"vol": r.get("vol") or 0})}`,
weeks copied, `stale = False`; returns `build_payload(state, today, plans)`.

### 3.8 `GET /api/max-tracker` (tokenserver `Handler._max_tracker_payload`)

```python
quota_snapshot = get_snapshot(projects_dir, max_tracker_store=store)  # feeds observe_quota hooks
today = datetime.now().astimezone().date().isoformat()
payload = store.snapshot(today, Handler.plans)      # plans = {"claude": --claude-plan, "codex": --codex-plan}
payload["stale"] = bool(quota_snapshot.get("claudeWeekStale") or quota_snapshot.get("codexWeekStale"))
```
Response: 200, headers `Content-Type: application/json`,
`Content-Length`; body `json.dumps(payload)`. On any exception → log
`"500 on /api/max-tracker"` and 500 `{"error": "internal server error"}`
(never leaks the message). The same producer is used by the relay
publisher (`--publish`) for `/api/max-tracker`. Request counts as a panel
poll (`_record_panel_poll`).

**Wire shape (key order as produced):**
```json
{"v": 1, "weeks": 20, "stale": false, "codingStreakDays": 2,
 "claude": {"planLabel": "MAX 20X", "avgPeakPct": 59.1, "maxWeeksStreak": 1,
            "maxWeeks": 1, "maxDays": 1,
            "weekMaxed": [0,0,...20 ints 0|1],
            "days": [[89,1],[1,1],[100,1],[-1,-1], ... 140 pairs]},
 "codex":  {"avgPeakPct": null, "maxWeeksStreak": 0, "maxWeeks": 0, "maxDays": 0,
            "weekMaxed": [...20], "days": [...140]}}
```
| field | type / range |
|---|---|
| `v` | int 1 |
| `weeks` | int 20 |
| `stale` | bool |
| `codingStreakDays` | int 0..999 or null (null iff no active day in all history) |
| `planLabel` | optional; only `PRO`, `MAX 5X`, `MAX 20X`, `PLUS` |
| `avgPeakPct` | number 0..100 (one decimal) or null |
| `maxWeeksStreak`, `maxWeeks`, `maxDays` | int 0..999 |
| `weekMaxed` | exactly 20 ints ∈ {0,1}, oldest week first |
| `days` | exactly 140 `[pct, lvl]`; `pct` int −1..100, `lvl` int −1..2; index 0 = Monday 19 weeks before this week's Monday |

Device parser (`components/app_tokens/max_tracker_parse.c`) rejects the
**whole** document if any day pct/lvl is non-integral or out of range, if
`weekMaxed`/`days` lengths differ, if an aggregate > 999 or non-integral,
if `avgPeakPct` is missing (null is OK) or out of range, if `stale` is not
bool, `v != 1`, `weeks != 20`, an `"error"` key exists, or a known key is
duplicated. A bad `planLabel` (non `[A-Z0-9 ]`, empty, too long) is dropped
alone. Therefore: **emit ints (not floats) in `days`**.

Committed contract fixtures: `sim-fixtures/max-tracker-{empty,coldstart,full,live-shape}.json`.
`max-tracker-empty.json` equals `build_payload(empty, "2026-08-12", {})`.
`max-tracker-live-shape.json` equals the store fed (today `2026-08-12`, plans
`{"claude":"max20x","codex":"pro"}`): claude `observe_quota(300, pct, local noon)`
+ `observe_volume(day, 800)` for 08-01..08-07 with pcts
15.5, 62.3, 99.96, 47.49, 88.51, 0.5, 100.0; codex `observe_quota(300, …)`
08-08 33.34, 08-09 71.66, 08-10 100.0; weekly 100.0 for claude 08-07 and
codex 08-10; claude volume 120 on 08-11, 4000 on 08-12. Resulting claude
`avgPeakPct` 59.1, codex 68.3, `codingStreakDays` 2.

### 3.9 `codex_rollout.py` helpers used here

* `codex_rollout_rate_limits(obj)`: returns `obj.payload.rate_limits`
  only if `obj.type == "event_msg"`, `obj.payload` is a dict with
  `type == "token_count"`, and `rate_limits` is a dict; else `None`
  (nested/quoted variants rejected).
* `observation_timestamp(v)`: string → `int(fromisoformat(v.replace("Z","+00:00")).timestamp())`
  (truncation; naive → local); else/errors `None`.

### 3.10 tokenserver wiring (both channels + persistence)

* Construction: `MaxTrackerStore(state_dir()/"max-tracker.json", CODEX_SESSIONS, --dir)`
  where `CODEX_SESSIONS = ($CODEX_HOME expanded, else ~/.codex)/sessions`
  and `--dir` default `~/.claude/projects`.
* **Live Claude volume**: `_compute(projects_dir, store)` scans
  `projects_dir/**/*.jsonl` whose mtime ≥ month start (§0.1), incrementally
  (per-path cache keyed by `(mtime,size)` + `(dev,ino)`, append-resume when
  same identity, same month, larger size; otherwise re-parse from 0), and
  calls `store.observe_volume("claude", day, tokens)` for **every newly
  parsed record** (day = local `YYYY-MM-DD`, tokens = same 4-field sum,
  records with ts < month start or tokens ≤ 0 skipped; no dedup on this
  path). Marks store dirty if anything was observed. Quirk: the startup
  warm-up scan `_refresh_usage_totals(projects_dir)` passes **no** store, so
  if it wins the race, pre-restart current-month volume is not re-fed (days
  keep their loaded `lvl` until new volume arrives, which then pops it).
* **Live quota** in `get_snapshot` (only when a store is passed, i.e. HTTP
  handlers and publisher):
  * Claude session: if a live (non-cache-derived) session pct exists →
    `observe_quota("claude", 300, session_pct, now_ts)`.
  * Claude week: if `claude_week["live"]` →
    `observe_quota("claude", 10080, week_pct_rounded_1dp, record.observed_at)`.
  * Codex session: if `codexSessionPct` not None and
    `codexSessionWindowMinutes` finite > 0 → `observe_quota("codex", minutes, pct, now_ts)`.
  * Codex week: if live and `codexWeekWindowMinutes` valid →
    `observe_quota("codex", minutes, pct, observed_at)`.
  * Each call → `_mark_max_tracker_dirty(store)`.
  * Stale/cached figures never reach `observe_quota`.
* **Backfill thread** `max-tracker-backfill`: loop until stop:
  `if store.backfill_step(): mark dirty`; exceptions logged WARNING
  `"max-tracker backfill step failed: %s: %s"` at most once per 600 s
  (first immediately); `stop_event.wait(0.5)`. Never stops on its own.
* **Writer** (`_mark_max_tracker_dirty`): sets a global dirty flag and
  starts one daemon thread `max-tracker-writer` if none running; the writer
  loops `while dirty: dirty=False; store.save()`. On failure: remember
  `failing_since` (monotonic), log exception at most every 300 s
  (`_ERROR_LOG_THROTTLE_S`), set dirty again and **exit** (retry only on the
  next mark or the final flush). On success after failure: INFO
  `"max-tracker: save succeeded again after %.0f s"`.
  `GET /` exposes `maxTrackerSaveOk` (bool) and `maxTrackerSaveFailingForS`
  (int or null).
* Shutdown: stop backfill (join ≤ 2 s), `store.save()` final flush (errors
  logged).

---------------------------------------------------------------------------

## 4. Usage history (`usage_history.py`) — `usage-history.json`

Coarse quota-% samples for "today delta" and weekly pace forecasts.

### 4.1 Constants

```
SAMPLE_INTERVAL_S   = 900         # at most one sample / 15 min per (provider, window, cycle)
RETENTION_S         = 691200      # 8 days
FORECAST_WINDOW_S   = 86400       # regression uses last 24 h
MIN_FORECAST_SPAN_S = 5400        # 90 min
MIN_FORECAST_DELTA  = 1.0         # percentage points
RESET_QUANTUM_S     = 300         # reset times bucketed to 5 min
_PROVIDERS = {"claude", "codex"}
_WINDOWS   = {"session", "week", "model_week"}
_WINDOW_LENGTH_S = {"session": 18000.0, "week": 604800.0, "model_week": 604800.0}
```

`_reset_cycle(reset_at) = int(floor((reset_at + 150) / 300) * 300)` —
nearest 5-minute mark, exact half rounds up.

`Forecast` (frozen): `state: str` ∈ {`unavailable`, `collecting`,
`exhausts`, `at_reset`}, `pct_at_reset: int|None`, `pace_factor: float|None`,
`exhausts_at: int|None`, `offset_minutes: int|None`.

### 4.2 File format (v1)

Path `state_dir()/usage-history.json`.
```json
{"v":1,"samples":[{"at":1790000000,"provider":"claude","window":"week","pct":42.0,"reset":1790300000}]}
```
| key | type | constraint |
|---|---|---|
| `v` | int | `== 1` |
| `samples[]` | array of objects | each object has **exactly** keys `at, provider, window, pct, reset` |
| `at` | number (written as int epoch s) | finite |
| `provider` | string | `claude` or `codex` |
| `window` | string | `session`, `week`, `model_week` |
| `pct` | number (written as float, e.g. `42.0`) | finite, 0..100 |
| `reset` | number (written as int, the 5-min-bucketed cycle) | finite |

Samples written sorted ascending by `at`. Written with the atomic recipe
(§1.4), no explicit chmod (mkstemp gives 0600).

### 4.3 Load

* Missing → empty. `UnicodeError` → quarantine `"not UTF-8"`. Other
  `OSError` → `_load_error = classname`, WARNING (same text as §3.6),
  empty, persist refuses. `JSONDecodeError` → quarantine
  `"invalid JSON at byte {pos}"`. Not dict / `v != 1` / `samples` not a
  list → quarantine `"not a {v: 1, samples: [...]} file"`.
* Keep only valid records (`_valid_record`), copy them, sort by `at`, drop
  `at < now() − RETENTION_S`. No write happens at load.
* Python quirk: a huge-int number in `at/pct/reset` raises `OverflowError`
  (uncaught) → startup crash; Swift: treat as invalid record.

### 4.4 `record(provider, window, pct, reset_at, at=None) -> bool`

= `record_many(((provider, window, pct, reset_at),), at) > 0`.

### 4.5 `record_many(samples, at=None) -> int` (under RLock, persist inside the lock)

```python
ts = now() if at is None else at
if not finite(ts): return 0
ts = int(round(ts))                                   # ties-to-even
old = records
records = [r for r in records if r["at"] >= ts - RETENTION_S]   # prune
added = 0
for provider, window, pct, reset_at in samples:
    if provider/window unknown or pct not finite in [0,100] or reset_at not finite: continue
    cycle = _reset_cycle(reset_at)
    prev = last record (iterating newest-first in the at-sorted list, then
           including ones appended earlier in THIS batch) with same provider, window, reset==cycle
    if prev and ts - prev["at"] < 900: continue       # also skips if ts < prev.at
    records.append({"at": ts, "provider": provider, "window": window,
                    "pct": float(pct), "reset": cycle})
    added += 1
if not added: records = old; return 0                 # prune NOT persisted if nothing added
records.sort(key=at)
persist():
  - load_error set -> raises OSError -> records = old; return 0
  - write/replace failure (OSError) -> records = old; return 0
  - replace succeeded but fsync_parent failed -> KEEP new records (disk has them),
    WARNING "%s was saved but its directory fsync failed (%s): the file may not
    survive power loss until the next save", return added
return added
```
Note "newest-first": the reversed scan over the list sorted by `at`
(appends within the batch are at the end with `at == ts`).

### 4.6 `forecast(provider, window, reset_at, now=None) -> Forecast`

```python
if provider/window unknown or reset_at not finite: unavailable
now = now() if now is None else now; not finite -> unavailable
cycle = _reset_cycle(reset_at); cutoff = now - 86400
S = sorted(records with same provider, window, reset==cycle and cutoff <= at <= now) by at
if not S: unavailable
latest = S[-1]
if reset_at <= latest.at: unavailable
span = S[-1].at - S[0].at; movement = max(pct) - min(pct)
if len(S) < 3 or span < 5400 or movement < 1.0: collecting
xs = [at - S[0].at]; ys = [pct]; ordinary least squares slope
denominator = Σ(x - x̄)²; if <= 0: collecting
slope = Σ(x-x̄)(y-ȳ)/denominator; if not finite or slope <= 0: unavailable
seconds_left = reset_at - latest.at
gain = slope * seconds_left; projected = latest.pct + gain
if projected >= 100:
    exhausts_at = int(round(latest.at + (100 - latest.pct) / slope))
    return Forecast("exhausts", exhausts_at=exhausts_at,
                    offset_minutes=int(round((exhausts_at - reset_at) / 60)))
pace = (100 - latest.pct) / gain if gain > 0 else None
return Forecast("at_reset", pct_at_reset=clamp(int(round(projected)), 0, 100),
                pace_factor=None if pace is None else round(pace, 1))
```
Uses the raw `reset_at` for the `reset_at <= latest.at` and
`seconds_left` math, the bucketed cycle only for selection.

### 4.7 `delta_since(provider, window, since, reset_at, now=None) -> float|None`

```python
invalid inputs -> None; now not finite -> None
cycle = _reset_cycle(reset_at)
S = sorted(records same provider/window/cycle with at <= now)
if not S: None
latest = S[-1]
if reset_at - _WINDOW_LENGTH_S[window] >= since:        # cycle began inside the period
    return round(max(0.0, float(latest.pct)), 1)
if len(S) < 2: None
earlier = [r for r in S if r.at <= since]
baseline = earlier[-1] if earlier else S[0]
if baseline is latest: None                             # identity, not equality
delta = latest.pct - baseline.pct
return None if delta < 0 else round(delta, 1)
```

### 4.8 `records` property

Tuple of dict copies, under lock (always complete and sorted).

### 4.9 tokenserver usage

* Singleton `UsageHistory(state_dir()/"usage-history.json")`.
* Every `get_snapshot` records live samples only (`is_live and pct is not None and reset_at is not None`):
  `("claude","session", claudeSessionPct, sessionResetAt, not session_from_cache)`,
  `("claude","week", claudeWeekPct, reset, week.live)`,
  `("claude","model_week", claudeModelWeekPct, reset, model.live)`,
  `("codex","week", codexWeekPct, reset, codexWeek.live)`, `at=current_ts`.
* Output keys (`/api/tokens`):
  `claudeWeekTodayDeltaPct = delta_since("claude","week", day_start, week_reset)`,
  `claudeModelWeekTodayDeltaPct` (model_week, day_start),
  `claudeSessionHourDeltaPct` (session, `now − 3600`),
  `codexWeekTodayDeltaPct` (codex week, day_start); each `None` when its
  reset is `None`. `day_start` per §0.1 quirk.
  Forecast (`claude`/`codex` week; `unavailable` when reset None) →
  `{p}ForecastState`, `{p}ForecastPctAtReset`, `{p}ForecastPaceFactor`,
  `{p}ForecastAt` (= `exhausts_at`), `{p}ForecastOffsetMin`.

---------------------------------------------------------------------------

## 5. Quota cache (`quota_cache.py`) — `quota-cache.json`

Latest quota observation per `(provider, scope, identity)`; lets the panel
show an honest (stale-flagged) figure through probe outages and restarts.

### 5.1 Types & validation

```
_PROVIDERS = {"claude", "codex"}
_SCOPES    = {"general_session", "general_weekly", "model_weekly"}
_MAX_IDENTITY_LENGTH = 128; _MAX_LABEL_LENGTH = 128
CachedQuota(provider, scope, identity, pct, reset_at, observed_at, label=None)  # frozen, equality by value
```
Valid record:
* `provider ∈ _PROVIDERS`, `scope ∈ _SCOPES` (strings).
* `identity`: string, `1 ≤ len ≤ 128` (Python `len` = code points),
  every char in `' '..'~'` (0x20–0x7E).
* `pct`: int/float, not bool, finite (huge ints → invalid via caught
  `OverflowError`), `0 ≤ pct ≤ 100`.
* `reset_at`, `observed_at`: **Python `int`** (JSON integer; a float like
  `2000.0` is INVALID), not bool, `≥ 0`.
* `label`: `None`, or a string with `len ≤ 128` (code points),
  `str.isprintable()` true (rejects Unicode categories Cc, Cf, Cs, Co, Cn,
  Zl, Zp and Zs except U+0020 — e.g. `\n`, NBSP U+00A0, lone surrogates),
  UTF-8 encodable. `"FABLE · WEEK"` is valid.

### 5.2 File format (v1)

```json
{"v":1,"records":[{"provider":"codex","scope":"general_weekly","identity":"account-a","pct":46.0,"reset_at":2000,"observed_at":1000,"label":"Work account"}]}
```
* Top level must have **exactly** keys `{v, records}`, `v == 1`,
  `records` list — otherwise quarantine `"not a {v: 1, records: [...]} file"`.
* Each record must have **exactly** the 7 keys (label may be null).
* Written sorted by `(provider, scope, identity)`; `pct` written as
  `float(pct)`; key order as shown. Atomic recipe §1.4 (no explicit chmod).

### 5.3 Load (constructor)

* Missing → `{}`. `UnicodeError` → quarantine `"not UTF-8"`. **Other
  `OSError` → `{}` silently** (no log, no load-error flag; but every
  subsequent `put` fails because it re-reads the file first — so it never
  overwrites in practice). JSON error → quarantine
  `"invalid JSON at byte {pos}"`. Shape error → quarantine (above).
* For each record: invalid → skip; if `now()` finite and
  `record.reset_at <= now` → skip (expired). Per key keep the one with the
  greatest `observed_at` (strictly greater replaces; first wins on tie).
* `_read_records = tuple(records.values())` — the immutable reader view.

### 5.4 `put(record) -> bool` (writer lock held across the fsync)

```python
if not CachedQuota or invalid: return False
key = (provider, scope, identity); prev = records.get(key)
if prev and record.observed_at < prev.observed_at: return False      # equal replaces
updated = dict(records); updated[key] = record; snapshot = tuple(updated.values())
try: prior = path.read_bytes()    # FileNotFound -> None ; other OSError -> return False
records = updated
try persist(snapshot):
  - replace done but dir fsync failed -> records = old; restore `prior` bytes atomically
    (same temp+fsync+replace+dir-fsync; binary) or, if there was no prior file, unlink it
    and fsync the dir; errors during rollback ignored; return False
  - OSError/UnicodeError/TypeError/ValueError before replace -> records = old; return False
_read_records = snapshot; return True
```
Note: expired records are only pruned at load; a `put` persists whatever
is in memory (so the next put after a load drops the ones expired at load
time — test pinned).

### 5.5 `latest(provider, scope, now=None) -> CachedQuota|None`

Unknown provider/scope → None; `now` not finite (incl. huge int) → None.
From `_read_records` (lock-free), candidates with same provider/scope and
`reset_at > now` (**strict** — expires at the exact reset second);
return `max` by `(observed_at, identity)` (tie → lexicographically greatest
identity).

### 5.6 tokenserver usage

* Singleton `QuotaCache(state_dir()/"quota-cache.json")`.
* Scopes used: `claude/general_session`, `claude/general_weekly`,
  `claude/model_weekly`, `codex/general_weekly`.
* Session identity: `sha256(f"{provider}\0{scope}\0default-v1".encode()).hexdigest()`
  (`_quota_identity`, 64 hex chars); weekly identities come from the live
  source (`weekIdentity`, `modelIdentity`, `codexWeekIdentity`).
* `_resolve_weekly_quota`: live when pct finite 0..100, `reset_at` finite >
  now, `observed_at` finite, identity non-empty string → builds
  `CachedQuota(pct=float(pct), reset_at=int(reset_at), observed_at=int(observed_at), label=str|None)`
  to persist, returns `pct` rounded 1dp, `stale False`, `live True`.
  `…StaleFloor is True` → served stale, not persisted/observed. Not live →
  `latest()` served as `stale True`; else nulls. A live pct lower than the
  cached pct for the same reset is logged once per `(provider, scope, reset)`
  as OBS-39 evidence (`GET /` → `quotaRegressions`).
* Writes are async: `_persist_quota_records_async` → one daemon thread
  `quota-cache-writer` per cache, dedup against queued/in-flight/persisted
  maps; a failed put is retried next time the same record is offered.

---------------------------------------------------------------------------

## 6. Value meter (`value_meter.py`, `prices.json`, `update_prices.py`, `verify_value.py`)

"What would this month's usage cost at list API prices ÷ what the
subscriptions cost."

### 6.1 Constants

```
DEFAULT_PRICES_PATH = <module dir>/prices.json   # bundled resource in Swift
UNPRICED_TOLERANCE  = 0.02
_ACCOUNTING_MODES   = {"cache_excluded_input", "cache_included_input"}
```

Helpers: `_number(v)` = float(v) if int/float, not bool, finite, `≥ 0`, else
`None`. `_count(v)` = `int(_number(v))` (truncate) or 0.

### 6.2 `prices.json` schema (generated)

```json
{"_readme": [strings...],
 "source": {"catalogue": "BerriAI/litellm model_prices_and_context_window.json",
            "url": "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
            "blob_sha": "4273ec544726bf255ea920533e209e6022653bb4",
            "generated": "2026-09-08"},
 "providers": {
   "anthropic": {"accounting": "cache_excluded_input",
                 "cache_write_5m_multiplier": 1.25, "cache_write_1h_multiplier": 2.0,
                 "cache_read_multiplier": 0.1,
                 "tier_multipliers": {"standard": 1.0, "batch": 0.5},
                 "models": {"claude-opus-5": {"input": 5.0, "output": 25.0, "cache_read": 0.5,
                                              "cache_write_5m": 6.25, "cache_write_1h": 10.0}, ...}},
   "openai":    {"accounting": "cache_included_input", same multipliers/tiers,
                 "models": {"gpt-5.6-sol": {"input": 4.0, "output": 20.0, "cache_read": 0.4, "cache_write_5m": 5.0}, ...}}},
 "plans": {"_note": "...", "claude": {"pro": 20.0, "max5x": 100.0, "max20x": 200.0},
                           "codex":  {"plus": 20.0, "pro": 200.0}}}
```
Rates are USD per **million** tokens. Model rate keys: `input`, `output`
(always both), optional `cache_read`, `cache_write_5m`, `cache_write_1h`.
Shipped: 28 anthropic models, 119 openai models (bundle the file verbatim
into the Swift app; do not hand-copy rates).

### 6.3 `PriceTable(document)`

* For each `providers[name]` that is a dict: `accounting` must be in
  `_ACCOUNTING_MODES` else **`ValueError`** (hard startup failure), even
  if it has no models. Non-dict provider specs skipped.
* Index: `by_model[model] = (provider, spec, rates)` for dict `rates`,
  iterating providers in document order then models in order; **a model id
  in two providers → last one wins**.
* **Model lookup is exact string equality** — no lowercasing, no prefix
  or date-suffix stripping, no alias. `knows(model)` = `isinstance(model, str) and model in by_model`.
  (Dated ids like `claude-opus-4-5-20251101` are separate entries; an
  unlisted id like `claude-something-6` is unpriced.)
* `as_of()` = `source.generated` if `source` is a dict and it's a string,
  else `None`.

**`price(model, usage) -> (usd: float, unpriced_tokens: int)`** — exactly
one non-zero:
```python
if usage not dict: (0.0, 0)
if not knows(model): (0.0, _countable_tokens(usage))
_, spec, rates = by_model[model]
in_rate = _number(rates.input) or 0.0; out_rate = _number(rates.output) or 0.0
usd, counted = cache_excluded(...) if spec["accounting"] == "cache_excluded_input" else cache_included(...)
if counted <= 0: (0.0, 0)
return (usd * _tier_multiplier(usage, spec), 0)
```
`_countable_tokens(usage)` = `_count` of `input_tokens + output_tokens + cache_read_input_tokens + cache_creation_input_tokens + cache_write_input_tokens`
(not `reasoning_output_tokens`, not `total_tokens`, not the per-TTL breakdown).

`_cache_rate(rates, spec, rate_key, mult_key, in_rate)` = `_number(rates[rate_key])`
if present/valid (0 is valid), else `in_rate * (_number(spec[mult_key]) or 0.0)`.

**Anthropic (`cache_excluded_input`)**:
```python
fresh = _count(input_tokens); out = _count(output_tokens); read = _count(cache_read_input_tokens)
w5, w1h = cache_write_split(usage)
usd = (fresh*in + out*out_rate + w5*rate(cache_write_5m | 1.25x) + w1h*rate(cache_write_1h | 2.0x)
       + read*rate(cache_read | 0.1x)) / 1_000_000
counted = fresh + out + read + w5 + w1h
```
`cache_write_split(usage)`: if `usage.cache_creation` is a dict and
`_count(ephemeral_5m_input_tokens)` or `_count(ephemeral_1h_input_tokens)`
non-zero → `(five, hour)`; else `(_count(cache_creation_input_tokens), 0)`
(flat total → cheaper 5-min bucket). `cache_write_input_tokens` is ignored
here.

**OpenAI/Codex (`cache_included_input`)**:
```python
total_in = _count(input_tokens); cached = min(_count(cached_input_tokens), total_in)
fresh = total_in - cached; out = _count(output_tokens); write = _count(cache_write_input_tokens)
usd = (fresh*in + cached*rate(cache_read | 0.1x) + write*rate(cache_write_5m | 1.25x) + out*out_rate) / 1e6
counted = total_in + out + write
```
`reasoning_output_tokens` (subset of output) and `total_tokens` never billed.

`_tier_multiplier(usage, spec)`: `tier = usage.service_tier` (string) and
`spec.tier_multipliers` dict; result `_number(table[tier])` if that is
truthy (non-zero) else `1.0`. Unknown tier or 0 multiplier → 1.0.

**`plan_cost(provider, plan, override=None) -> (cost|None, source)`**:
`_number(override) > 0` → `(override, "configured")`; else
`plans[provider][plan]` positive → `(amount, "default")`; else
`(None, "unknown")`. (Strings like `"100"`, NaN, inf, 0, negatives, bools
fall through.)

### 6.4 Loading

* `load_prices(override_path=None)`: parse bundled `prices.json`; if
  `override_path` truthy, parse it and `_merge(base, extra)` recursively
  (dict+dict → recurse; anything else replaces, lists included); return
  `PriceTable(merged)`. Unreadable/malformed override → exception (hard
  startup failure; `JSONDecodeError` is a `ValueError`).
* `default_table()`: lazily cached `load_prices()` **without** override.
* `price_usage(model, usage, table=None)` = `(table or default_table()).price(...)`.

### 6.5 `parse_plan_costs(entries, legacy_claude=None) -> {provider: usd}`

* `legacy_claude` (from `--plan-cost-usd`, float) not None: must be
  `_number > 0` else `ValueError("--plan-cost-usd must be a positive number, got {v!r}")`;
  sets `claude`.
* Each entry: `provider, sep, raw = str(entry).partition("=")`;
  `provider = provider.strip().lower()`; no `=` or empty provider →
  `ValueError("--plan expects PROVIDER=USD, got {entry!r} (for example: --plan claude=200)")`;
  `amount = _number(float(raw))` (Python `float()` tolerates surrounding
  whitespace, `1e2`, `1_000`; `inf`/`nan` → rejected by `_number`); invalid
  or ≤0 → `ValueError("--plan {provider} needs a positive monthly cost in USD, got {raw!r}")`.
  Later entries (and `--plan claude=…` over the legacy flag) win.
* No provider allowlist (`cursor=20` accepted).

### 6.6 `build_payload(value_usd, unpriced_tokens, priced_tokens, claude_plan=None, codex_plan=None, plan_costs=None, table=None, claude_usd=None, codex_usd=None) -> dict`

```python
total = priced + unpriced; share = unpriced/total if total else 0.0
prices = table or default_table(); plan_costs = plan_costs or {}
cc, cs = prices.plan_cost("claude", claude_plan, plan_costs.get("claude"))
xc, xs = prices.plan_cost("codex",  codex_plan,  plan_costs.get("codex"))
pairs = [(claude_usd, cc, cs), (codex_usd, xc, xs)]
counted   = [(s, c) for s, c, _ in pairs if s is not None and s > 0 and c is not None]
uncounted = sum(s for s, c, _ in pairs if s is not None and s > 0 and c is None)
known_split = claude_usd is not None or codex_usd is not None
if not known_split:
    costs = [c for c in (cc, xc) if c is not None]; plan_usd = sum(costs) if costs else None
    sources = [s for s in (cs, xs) if s != "unknown"]
elif counted:
    value_usd = sum(s for s, _ in counted); plan_usd = sum(c for _, c in counted)
else:
    plan_usd = None                              # value_usd keeps the caller's total
if known_split:
    sources = [src for s, c, src in pairs if s is not None and s > 0 and c is not None]
cost_source = "configured" if sources and all(x == "configured" for x in sources) \
              else "default" if sources else "unknown"
payload = {"value_usd": round(value_usd, 2), "plan_usd": plan_usd,   # plan_usd not rounded
           "cost_source": cost_source, "basis": "list API prices",
           "prices_as_of": prices.as_of(), "unpriced_token_share": round(share, 4)}
if uncounted > 0: payload["undeclared_usd"] = round(uncounted, 2)
for name, s, c in (("claude", claude_usd, cc), ("codex", codex_usd, xc)):
    if s is None or s <= 0: continue
    payload[f"{name}_usd"] = round(s, 2)
    if c is not None: payload[f"{name}_plan_usd"] = c
if share > 0.02:        payload["state"] = "partial";      payload["multiple"] = None
elif plan_usd is None:  payload["state"] = "no_plan_cost"; payload["multiple"] = None
else:                   payload["state"] = "ok";           payload["multiple"] = round(value_usd / plan_usd, 2)
```
Key order: `value_usd, plan_usd, cost_source, basis, prices_as_of,
unpriced_token_share, [undeclared_usd], [claude_usd, claude_plan_usd],
[codex_usd, codex_plan_usd], state, multiple`.

### 6.7 tokenserver usage (`/api/tokens` → `"value"`)

* Startup: `_plan_costs = parse_plan_costs(--plan..., legacy_claude=--plan-cost-usd)`;
  `_price_table = load_prices(--prices)`; `_claude_plan = --claude-plan`
  (choices `pro|max5x|max20x`), `_codex_plan = --codex-plan` (`plus|pro`).
  The same `--claude-plan/--codex-plan` drive Max Tracker `planLabel`.
* Claude records (`_parse_file`): `usd, unpriced = price_usage(message.model, usage, table=_price_table)`,
  priced per row so the `(message.id, requestId)` dedup in `_compute`
  covers dollars. Month aggregates: `month_value_usd += usd`; if
  `unpriced` → `month_unpriced += unpriced` else `month_priced += tokens`
  (tokens = 4-field sum).
* Codex (`codex_usage.month_value(now, table)`): per rollout, model from
  the latest `turn_context` (`payload.model`), usage =
  `payload.info.last_token_usage` of `token_count` events, only events with
  local ts ≥ month start; priced tokens = `input + output + cache_write_input`
  (`_counted`) when priced; files grouped by `session_meta.payload.session_id`
  and only the **largest** (priced+unpriced tokens) file per session is
  counted (replay dedup); files without session id stand alone.
* `value = build_payload(month_value_usd + codex_usd, month_unpriced + codex_unpriced, month_priced + codex_priced, claude_plan, codex_plan, plan_costs, table, claude_usd=month_value_usd, codex_usd=codex_usd)`
  → `known_split` is always true in production. Startup placeholder uses
  `build_payload(0.0, 0, 0, …, claude_usd=0.0, codex_usd=0.0)`.

### 6.8 `update_prices.py` (developer tool; keep in Python or port byte-exact)

Constants: `CATALOGUE_URL` as in `source.url`; `OUTPUT_PATH` = bundled
`prices.json`; `ACCOUNTING = {"anthropic": "cache_excluded_input", "openai": "cache_included_input"}`;
`MODES = {"chat", "responses"}`;
`RATE_KEYS = {"input_cost_per_token": "input", "output_cost_per_token": "output", "cache_read_input_token_cost": "cache_read", "cache_creation_input_token_cost": "cache_write_5m", "cache_creation_input_token_cost_above_1hr": "cache_write_1h"}`;
`PER_MILLION = 1_000_000`.

* `fetch(url)`: `urllib.request.urlopen(url, timeout=60).read()` (no custom headers).
* `blob_sha(raw)` = `sha1(b"blob %d\0" % len(raw) + raw).hexdigest()` (= `git hash-object`).
* `_rate(v)` = `round(v * 1e6, 6)` for non-bool int/float ≥ 0 else None.
* `convert(catalogue)`: for each dict spec with `litellm_provider ∈ ACCOUNTING`
  and `mode ∈ MODES`, map `RATE_KEYS`; keep only if both `input` and
  `output` present; per provider sort models by key. Result always has
  both provider keys.
* `build(catalogue, sha, generated)`: document exactly as §6.2 (readme
  lines, source, providers with the fixed multipliers/tiers, plans with
  `_note` text and the list prices).
* `render(doc)` = `json.dumps(doc, indent=2, ensure_ascii=False) + "\n"`.
* `main(argv)`: `--from FILE` (local catalogue) else fetch; `--check`;
  `--out` (default `OUTPUT_PATH`). In `--check` with an existing out file,
  reuse its `source.generated` stamp (so a passing day is not drift); else
  stamp = `date.today().isoformat()`. `--check`: compare rendered text to
  current file (missing file = `""`) → mismatch: stderr
  `"{out} is out of date; run update_prices.py"`, exit 1; match: stdout
  `"{out} is current"`, exit 0. Otherwise write and print
  `"wrote {out} from blob {sha[:12]}: {n} anthropic, {m} openai"`, exit 0.

### 6.9 `verify_value.py` (diagnostic CLI)

`--dir` (default `~/.claude/projects`), `--codex-dir` (default None →
`default_sessions_dir()`). Uses `default_table()` (no override). Prints
`month to date: YYYY-MM (as of YYYY-MM-DD HH:MM)`, `prices generated: <as_of>`,
then a table `provider tokens usd $/Mtok verdict` for claude
(`_compute(dir)`: tokens `monthTokens`, usd `_month_value_usd` or
`value.claude_usd` or `value.value_usd`) and codex
(`month_value(codex_root, table)`: tokens priced+unpriced). Rows with no
tokens/usd print `nothing to check`. Rate = `usd / (tokens/1e6)`; verdict
`band(rate)`: `< 0.20` → `SUSPICIOUS (below any published rate -- double-counted tokens?)`,
`> 35.0` → `SUSPICIOUS (above every published rate -- double-charged?)`,
else `plausible`. If codex unpriced > 0, prints the unpriced share. Exit 0.

---------------------------------------------------------------------------

## 7. Subscription probes (`subscription_quota.py`) — Grok & Cursor cadence

No files. Constants: `LIMITS_EVERY_S = 240.0`, `AUTH_RECOVERY_EVERY_S = 15.0`,
`RATE_LIMIT_FLOOR_S = 600`, `_GROK_LANE = "credit"`.

`_Lane(pct, reset_at, stale)`.

`Probe(name, fetch)` state: `refreshing=False`, `last_mono=0.0`,
`failure_streak=0`, `cooldown_until=0.0` (wall), `auth="missing"`,
`status="idle"`, `lanes={}`, `label=None`, a lock.

* `interval_s()`: `auth ∈ {"missing","expired","unauthorized"}` → 15 s;
  else `240 * 2**min(failure_streak, 2)` → 240 / 480 / 960.
* `_due_locked(now_mono)`: not refreshing and
  (`last_mono == 0` or `now_mono − last_mono ≥ interval_s()`).
* `kick()`: under lock: not due → return; if `time.time() < cooldown_until`
  → `failure_streak += 1`, `last_mono = now_mono`, return (no fetch);
  else `refreshing = True` and start daemon thread `"{name}-quota"` running
  `fetch(time.time())` (exception → raw
  `{"auth": self.auth, "status": f"probe_crashed: {ExcName}", "summary": "transport", "sand": "failed"}`
  + `log.exception("%s quota probe crashed")`), then under lock `note(raw, time.time())`,
  `last_mono = monotonic()`, `refreshing = False`.
* `refresh_inline(now_mono, now_wall)`: same, synchronous, test seam
  (cooldown check uses `now_wall`).
* `note(raw, now_wall)`: `auth = raw.auth or "missing"`;
  `kind = raw.status or raw.summary or "transport"`; dispatch by name.
* **Grok** (`_note_grok`):
  * `kind == "ok"` and `raw.reading` dict → store lane `credit`
    `(reading.pct, reading.reset_at, stale False)`,
    `label = reading.label or "CREDITS"`, streak 0, cooldown 0,
    status `"usage_http_200 + ok"`.
  * `"unmapped"` → drop lane, `label = None`, streak += 1,
    status `"usage_http_200 + no_mapped_limits"`.
  * `"rate_limited"` → mark lane stale (only if it has a pct),
    `cooldown_until = now + max(int(retry_after or 0), 600)`, streak += 1,
    status `f"usage_http_429 + backoff_until_{local HH:MM of cooldown}"`.
  * `"transport"` → mark stale, streak += 1, status `"usage_request_failed"`.
  * any other kind → mark stale, streak 0, status = kind.
* **Cursor** (`_note_cursor`): `summary = raw.summary or "skipped"`,
  `sand = raw.sand or "skipped"`.
  * summary ∈ {ok, unmapped} → store lanes `total`, `models`, `third` from
    `raw[name] or {"pct": None, "reset_at": None}`; else mark those stale
    (+ `bot` if `sand == "skipped"`).
  * `sand ∈ {ok, none}` and `raw.bot` dict → store `bot`;
    `sand ∈ {failed, rate_limited}` → mark `bot` stale.
  * summary or sand `rate_limited` → cooldown as Grok, streak += 1, 429 status; return.
  * `transport` → streak += 1, `"usage_request_failed"`.
  * `unauthorized` → streak 0, `"token_dead_awaiting_refresh"`.
  * `skipped` → streak 0, `"token_expired"` if `auth == "expired"` else `"no_cursor_session"`.
  * `unmapped` → streak += 1, `"usage_http_200 + no_mapped_limits"`.
  * else (ok) → streak 0, cooldown 0,
    `"usage_http_200 + ok" + ("" if sand in {ok, none, skipped} else "; sand_failed")`.
* `fields(now_wall)` (wire, merged into `/api/tokens`): lane →
  `{P+"Pct", P+"ResetMin", P+"Stale"}`; lane missing, `pct None`, or
  `reset_at ≤ now` → `(None, None, False)`; else
  `(pct raw, int((reset_at − now) // 60) or None if reset None/passed, bool(stale))`.
  Grok: prefix `grokCredit` + `grokQuotaLabel = self.label`. Cursor:
  `cursorTotal` (total), `cursorModels` (models), `cursorThird` (third),
  `cursorBot` (bot).
* `diagnostics()` (merged into `GET /`): `{name}Probe` status,
  `{name}ProbeIntervalS` int, `{name}ProbeCooldownLeftS`
  `ceil(cooldown_until − time.time())` if > 0 else None,
  `{name}ProbeAgeS` `int(monotonic − last_mono)` or None.
* Module singletons `_grok = Probe("grok", grok_billing.fetch)`,
  `_cursor = Probe("cursor", cursor_usage.fetch)`; `kick_all()`,
  `fields(now)`, `diagnostics()` combine both. tokenserver calls
  `kick_all()` then `fields(now_ts)` on every `/api/tokens` build (unless
  disabled in tests).

---------------------------------------------------------------------------

## 8. `quota_http.py` — one JSON request, no redirects

Used by `grok_billing.fetch` (GET `BILLING_URL`, headers include
`Accept: application/json`, `User-Agent: vibepulse`, bearer auth) and
`cursor_usage.fetch` (GET `USAGE_URL`, then POST `SAND_URL` with body
`b"{}"`). No retries anywhere here — cadence/backoff is §7.

* `_MAX_BODY = 1_048_576`.
* `NoRedirect`: `redirect_request` returns `None` → any 3xx surfaces as an
  `HTTPError` with that code (the bearer token never follows a redirect).
  Swift: `URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` → `completionHandler(nil)` and treat the 3xx response as the final status.
* `exchange(url, *, method="GET", headers, body=None, timeout=15, now_ts=0.0, opener=None) -> (status, payload|None, retry_after:int)`:
  1. Build request (method, headers, data). urllib also adds
     `Accept-Encoding: identity`, `Connection: close`, `Host`, and
     `User-Agent: Python-urllib/3.12` unless provided; honours
     `HTTP(S)_PROXY` env (default ProxyHandler); system TLS verification.
  2. `timeout=15` s (socket-level, per blocking operation).
  3. `HTTPError` (any status ≥ 400 or unfollowed 3xx) → `(code, None, retry_after_seconds(headers["Retry-After"], now_ts))`
     (header lookup case-insensitive; body not read).
  4. Any other exception (DNS, refused, TLS, timeout) → `(0, None, 0)`.
  5. Success: read up to `_MAX_BODY + 1` bytes; `status = response.status or 200`;
     body > 1 MiB → `(0, None, 0)`.
  6. Decode UTF-8 strict + `json.loads`; failure → `(status, None, 0)`;
     non-object JSON → `(status, None, 0)`; else `(status, dict, 0)`.
* `retry_after_seconds(value, now_ts) -> int`: None → 0; `text = str(value).strip()`;
  `int(text)` (Python int: also accepts `+5`, `1_0`, Unicode digits) and
  `≥ 0` → that; else HTTP-date via `email.utils.parsedate_to_datetime`
  → `max(0, int(round(when − now_ts)))` (ties-to-even; a `-0000` zone gives a
  naive datetime interpreted as local); any parse failure → 0. Negative
  integers fall through to the date parse and yield 0.

---------------------------------------------------------------------------

## 9. Saved feature switches (`vibepulse_config.py`) — `config.json`

### 9.1 Schema

Path `state_dir()/config.json`. JSON object; every key optional; **no
other keys allowed**:

| key | type | default | validation |
|---|---|---|---|
| `claude_interactions` | bool | false | strictly JSON bool |
| `codex_interactions` | bool | false | " |
| `interaction_detail` | bool | false | " |
| `legacy_claude_panel_v1` | bool | false | " |
| `interaction_relay` | bool | false | " |
| `agent_status_relay` | bool | false | " |
| `interaction_relay_url` | string or null | null | see below |
| `interaction_mailbox` | string or null | null | regex `^vp_[A-Za-z0-9_-]{16}$` (19 chars) |

`interaction_relay_url` rules (else `ConfigError`): non-empty string, every
char 0x21–0x7E; `urlsplit`: scheme `https` (urlsplit lowercases the
scheme, so `HTTPS://` passes), non-empty hostname, no username/password,
path `""` or `"/"`, empty query and fragment (a bare `?`/`#` yields empty
strings and passes), `port = parsed.port or 443` must parse (non-numeric or
>65535 → "invalid port") and be 1..65535 (port `0` becomes 443 and
passes). Messages: `"interaction_relay_url must be HTTPS"` (char/empty
check), `"interaction_relay_url has an invalid port"`,
`"interaction_relay_url must be an origin"`, `"interaction_mailbox is invalid"`,
`"{field} must be a boolean"`.

`VibePulseConfig` is immutable; validated on construction and again in
`save_config`.

### 9.2 `load_config(path) -> VibePulseConfig`

1. `_safe_open_existing`: `lstat` (FileNotFound → **return defaults** —
   also when the parent dir is missing); symlink → `ConfigError("configuration path must not be a symbolic link")`;
   `open(O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)`; `fstat`; `lstat`
   again; if now a symlink or `(st_dev, st_ino)` differ between
   before/descriptor/after → `"configuration path changed while opening"`;
   not a regular file (dir, FIFO — opened non-blocking so it never hangs) →
   `"configuration path must be a regular file"`.
2. Read at most 16385 bytes; > 16384 → `"configuration file is too large"`
   (actual bytes, not `st_size`).
3. UTF-8 strict decode; other `OSError`/`UnicodeError` → `"cannot read configuration"`.
4. `json.loads` with a pairs hook that raises on **any duplicate key at any
   depth** → `"duplicate configuration key: {k}"`; JSON errors /
   `RecursionError` → `"malformed configuration JSON"` (a BOM is malformed).
5. Not an object → `"configuration must be a JSON object"`; unknown keys →
   `"unknown configuration keys"`; construct (type errors →
   `"configuration values have invalid types"`, validation errors as above).

### 9.3 `save_config(path, config)`

1. Must be a `VibePulseConfig` (else `ConfigError`); re-run validation.
2. `mkdir(parent, mode=0o700, parents=True)`; POSIX: `chmod(parent, 0o700)`.
3. `mkstemp(prefix=".config.json.", dir=parent)` (no suffix); `fchmod 0600`;
   write `json.dumps(asdict(cfg), sort_keys=True, separators=(",", ":")) + "\n"`
   (all 8 keys always, nulls included, ASCII-escaped), flush, fsync.
4. `os.replace(temp, path)`; POSIX `chmod(path, 0o600)`.
5. Directory fsync: `os.open(parent, O_RDONLY)` (failure to open ignored —
   Windows), `fsync` (failure → `ConfigError`, file already replaced), close.
6. Any `OSError/TypeError/ValueError` → `ConfigError("cannot save configuration")`;
   temp removed on failure.

Canonical bytes example:
`{"agent_status_relay":false,"claude_interactions":true,"codex_interactions":false,"interaction_detail":false,"interaction_mailbox":null,"interaction_relay":false,"interaction_relay_url":null,"legacy_claude_panel_v1":false}\n`

### 9.4 `config_lock(path)` — cross-process + in-process transaction lock

* Lock file: `path.with_name(f".{path.name}.lock")` → `.config.json.lock`
  (never deleted, content irrelevant; Windows writes one `\0` byte).
* In-process: one `RLock` per `normcase(realpath(abspath(lock_path)))`,
  held for the whole `with` body; thread-local depth makes it re-entrant;
  the OS lock is taken only at depth 0 and released when depth returns to 0
  (also on exceptions).
* Opening the lock file (`_open_lock_file`): `mkdir(parent, 0o700)` +
  POSIX `chmod 0o700`; refuse a symlink (`lstat` before/after, same-file
  checks, must be regular) → `ConfigError("configuration lock must not be a symbolic link")`
  / `"configuration lock path is not safe"`; `open(O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK, 0o600)`; `fchmod 0600`.
* Acquire: POSIX **`flock(fd, LOCK_EX)`** (blocking). Windows:
  `msvcrt.locking(fd, LK_LOCK, 1)` on byte 0 (after ensuring size ≥ 1;
  LK_LOCK retries ~10 × 1 s then raises → `ConfigError("cannot lock configuration")`).
  No backend → `ConfigError("no supported cross-process lock backend")`
  **before** creating anything.
* Swift MUST use BSD `flock()` (not `fcntl` record locks) on the same lock
  path so it interlocks with Python peers (`tools/vibepulse_setup.py`,
  another tokenserver).
* `tools/vibepulse_setup.py` nests an outer transaction lock:
  `config_lock(".config.json.vibepulse-setup-transaction")` (lock file
  `..config.json.vibepulse-setup-transaction.lock`) around
  `config_lock(config.json)`. It is the only writer of
  `interaction_mailbox`.

### 9.5 Precedence with CLI (`tokenserver._resolve_interaction_config`)

Under `config_lock(config_path)`:
1. `saved = load_config()`; `ConfigError` → log ERROR
   `"invalid VibePulse configuration in %s — saved interactions are turned off"`,
   `saved = defaults`, `invalid_saved = True`.
2. For each switch: **explicit CLI value wins, otherwise saved**:
   * `claude_interactions`: `--interactions` (legacy alias → True) or
     `--claude-interactions/--no-claude-interactions` (mutually exclusive);
   * `--codex-interactions/--no-…`, `--interaction-detail/--no-…`,
     `--legacy-claude-panel-v1/--no-…`, `--agent-status-relay/--no-…`;
   * `--interaction-relay HTTPS_ORIGIN` → `interaction_relay = True` and
     `interaction_relay_url = ORIGIN`; `--no-interaction-relay` →
     `interaction_relay = False`, URL kept; neither → saved.
   * `interaction_mailbox` always from saved.
   (An invalid CLI origin raises `ConfigError` at construction → startup fails.)
3. If any explicit flag was given → `save_config(resolved)` (repairs an
   invalid file). Else if `invalid_saved` → return defaults (file untouched).
   Else return resolved (no write).
No environment variables feed the config.

---------------------------------------------------------------------------

## 10. CLI flags / env relevant to this area (tokenserver)

| flag / env | effect |
|---|---|
| `--dir` (default `~/.claude/projects`) | Claude root for `_compute` and Max Tracker Claude backfill |
| `CODEX_HOME` | Codex sessions = `$CODEX_HOME/sessions` (default `~/.codex/sessions`), resolved at call time |
| `--claude-plan pro|max5x|max20x` | Max Tracker `planLabel` + default plan cost |
| `--codex-plan plus|pro` | same for Codex |
| `--plan PROVIDER=USD` (repeatable) | configured plan costs |
| `--plan-cost-usd FLOAT` | deprecated alias for `--plan claude=` |
| `--prices FILE` | override merged over bundled `prices.json`; bad file = startup failure |
| interaction flags | §9.5 |
| `LOCALAPPDATA` (Windows) | state dir base |

---------------------------------------------------------------------------

## 11. Compatibility checklist & tricky semantics

1. **No inter-process locking on the three state files.** Python relies on
   a single service instance (port 8737). Swift and Python must never run
   the service at the same time; a handover is: stop one (Python does a
   final Max Tracker save on shutdown), then start the other.
2. Integers where Python requires `int`: quota-cache `reset_at`,
   `observed_at`; max-tracker `offset`, `size`, `lvl`, and write `v` as `1`.
   Write max-tracker day `pct` as int (Python writes ints there).
3. Never write raw `vol` or any path/name into `max-tracker.json`; backfill
   keys are decimal inode strings (`st_ino`, 64-bit unsigned).
4. `max-tracker.json` has no older formats; any shape deviation is
   quarantined — so a Swift writer bug would get the file quarantined by
   Python on next start (and vice versa). Keep all four section keys even
   when empty.
5. After a restart, days carry authoritative `lvl`; the first new volume
   for a day **drops** the loaded `lvl` and restarts `vol` from 0.
6. Month ownership split for Claude volume: events dated in the current
   month (per the §0.1 month-start quirk) belong to the live scanner;
   backfill skips them per event and defers current-month-mtime files
   (watermark refreshed every pass). Codex is backfilled continuously.
7. `observe_quota` never marks activity; Codex activity comes only from
   backfilled rollout snapshots; Claude activity only from volume.
8. Rounding: `_round_day_pct` for day cells; Python `round` (ties-even on
   exact binary) for all other decimals (§0.2).
9. Unreadable (permission/I-O) files: max-tracker and usage-history start
   empty and **refuse to save**; quota-cache starts empty and every `put`
   fails (it re-reads the file first). Corrupt/wrong-shape files are
   quarantined (`<name>.corrupt-<UTC stamp>`) and the store starts empty.
10. Directory-fsync failure after replace: usage-history keeps the new
    sample and returns success (warns); quota-cache rolls back memory and
    restores the prior bytes (or deletes a newly created file) and returns
    False; max-tracker raises (writer retries later).
11. Label validation in quota-cache uses Python `str.isprintable` and code
    point length — implement via Unicode general categories and
    `unicodeScalars.count`, not `String.count`.
12. Model price lookup is exact-match only.
13. JSON booleans are never numbers (§0.4).
14. Windows: state files end with `\r\n`; `config.json` with `\n`.

---------------------------------------------------------------------------

## 12. Tests and what each pins

### 12.1 `test_max_tracker.py`

Helpers: `_local_stamp(day, hour)` builds a UTC `Z` stamp that lands on the
local `day` (issue #66: day ownership is local); `_age_into_last_month`
sets mtime 40 days back; `_BACKFILL_ANCHOR = today − 45 days`; `_drain`
calls `backfill_step()` ≤ 10 000 times (starvation guard).

*MaxTrackerStoreCodexBackfillTests*
- `test_primary_window_percent_becomes_the_days_peak` — primary 42.0 → avgPeakPct 42.0.
- `test_secondary_window_marks_the_iso_week_maxed_only_at_100` — 87 no, 100 yes → maxWeeks 1.
- `test_only_the_expected_rollout_event_envelope_is_accepted` — 5 impostor shapes ignored; no pct, no streak.
- `test_named_scoped_quota_never_feeds_day_peak_or_week_maxed` — `limit_name` "GPT-5.3-Codex-Spark" ignored.
- `test_empty_limit_name_still_counts_as_the_general_week` — `""` accepted.
- `test_missing_codex_root_is_handled_without_error` — returns False.
- `test_a_qualifying_backfilled_day_is_marked_active` — codex snapshot sets act → streak not None.

*MaxTrackerStoreBackfillBudgetTests*
- `test_a_file_longer_than_the_budget_drains_over_two_steps` — budget = first line + 2 bytes; step1 True (avg 10), step2 False (avg 49).
- `test_completed_file_is_never_reopened_on_a_later_run` — `Path.open` not called once drained.
- `test_backfill_state_is_keyed_by_inode_not_by_path` — int keys.
- `test_a_grown_claude_file_resumes_from_its_offset_without_double_counting` — 100 then +50 = 150.
- `test_a_grown_codex_file_resumes_from_its_offset_without_double_counting` — avg 65 (40, 90).
- `test_a_truncated_file_at_the_same_inode_is_rescanned_from_the_start` — shrink → replay from 0.
- `test_a_line_wider_than_the_cap_is_skipped_not_starved` — >8 MiB line skipped, neighbours counted (150), then False.
- `test_a_line_between_one_and_eight_mib_is_parsed_and_counted` — 2 MiB codex line counted (71).
- `test_a_2mib_line_still_completes_over_many_small_budget_steps` — 64 KiB budget, >1 step, vol 100.
- `test_a_second_file_still_drains_despite_the_first_having_an_oversized_line` — sibling counted (33).
- `test_lines_still_pending_after_the_record_cap_are_drained_next_call` — 257 records → vol 257, done.
- `test_unterminated_final_line_marks_done_and_does_not_starve_later_files` — done, offset at tail start, sibling drained.
- `test_unterminated_line_completes_once_the_file_grows` — 100 + 999 + 25 = 1124.

*MaxTrackerStoreLiveWatermarkTests* (mock `_current_month_start_ts`)
- `test_live_observation_and_deferred_backfill_then_rollover_does_not_double_count` — deferred file gets `{offset=size,size,done}` watermark; after rollover vol stays 100.
- `test_tokens_appended_after_rollover_are_counted_exactly_once` — 100 stays, new 50 counted once.
- `test_a_file_dormant_since_before_the_first_run_still_backfills_fully_from_zero`.

*MaxTrackerStoreEventDateOwnershipTests*
- `test_backlog_starvation_does_not_prevent_the_watermark_refresh` — Rule 1: live file watermark present while a 2000-line backlog drains.
- `test_a_file_mid_discard_when_it_becomes_live_owned_is_not_clobbered` — Rule 2: mid-discard entry not stamped done; 999-token tail counted once.
- `test_seeded_randomized_schedule_counts_every_event_exactly_once` — seed 20260813; dormant/backlog/mid-drain/live archetypes; per-day volumes equal ground truth exactly (Rule 3 included).

*MaxTrackerStoreClaudeBackfillTests*
- `test_claude_volume_backfill_sets_activity_and_volume_never_pct`.
- `test_missing_claude_root_is_handled_without_error`.

*MaxTrackerStoreLiveObserveQuotaTests*
- max-of-day (40, 65, 20 → 65); weekly only at 100; `None` minutes = session; quota alone never marks active; out-of-range pct and unknown provider ignored.

*MaxTrackerStoreObserveVolumeTests*
- accumulation + act; zero tokens creates no day; invalid date ignored.

*MaxTrackerStoreSnapshotTests*
- snapshot equals `build_payload` over the equivalent state (pct 71.0 float passes through as stored, vol 0 for non-volume days); `stale` defaults False.

*RoundDayPctTests* — half-away (0.5→1, 15.5→16, 2.5→3), nearest (15.4→15, 15.6→16, 0→0), never 100 from <100 (99.5/99.96/99.999→99), 100→100, always int.

*MaxTrackerStoreIntegerPctTests* — every emitted day pct is an `int`; 99.96 renders 99.

*MaxTrackerStoreGrayLevelStabilityTests*
- `test_reload_keeps_loaded_lvls_stable_and_ranks_only_new_session_volume` — [0,1,2] survive reload, a new 5000 day ranks 0 alone, and survive a second save/load.
- `test_fresh_volume_this_session_supersedes_a_loaded_lvl` — loaded day has `lvl` not `vol`; observe_volume removes `lvl`, sets `vol` 500.

*MaxTrackerStorePersistenceTests*
- atomic save, no leftovers, mode 0600; ENOSPC on `os.replace` → previous bytes intact, no temp, memory intact, next save works; reload yields identical snapshot; corrupt JSON quarantined (`max-tracker.json.corrupt-*`, bytes preserved, log contains "quarantined as max-tracker.json.corrupt-" and "invalid JSON", never content), next save creates a new file and leaves quarantine intact; `{}`, `{"claude": [], "codex": {}}`, `{"codex": {"days": {}}}` quarantined ("provider section (claude/codex) is missing"); wrong-shape sections (`{}`, `days: []`, `v: 2`, missing backfill) quarantined ("{v, days, weeks, backfill}"); PermissionError on read → empty + "refusing to save", save raises "refusing to overwrite", file untouched; non-UTF-8 quarantined ("not UTF-8"); `fsync_parent(path)` called once per save, failure raises and leaves only `max-tracker.json`; missing file → empty; retention: 399 days kept, 401 pruned (anchor injectable); default anchor prunes 2000-01-01.

*MaxTrackerStorePrivacySchemaTests* — top keys exactly providers; section ⊆ {v, days, weeks, backfill}; day ⊆ {pct, act, lvl}; week keys `^\d{4}-W\d{2}$` with bool values; no roots/file names in backfill; backfill keys `^\d+$`, entry ⊆ {offset, size, done, discarding}.

*MaxTrackerStoreThreadSafetyTests* — 2 × 2000 concurrent `observe_volume` + snapshots: no errors, exactly 4000.

*VolumeLevelsTests* — six values → 0,0,1,1,2,2; ties same; single distinct → 0; zeros excluded from thresholds ({0,10,20,30} → 0,0,1,2); empty → empty.

*CodingStreakTests* — includes today; grace when today inactive; 0 after a full gap; crosses month; crosses Stockholm DST date 2026-03-29; 0 when empty.

*WeekKeyTests* — 2026-08-12 → 2026-W33; 2025-12-29 → 2026-W01; 2026-12-28 and 2027-01-01 → 2026-W53; 2027-01-04 → 2027-W01.

*MaxWeeksStreakTests* — completed weeks only (W32,W31 → 2 with W33 current ignored); maxed current week doesn't extend; missing = not maxed; crosses W53 (from 2027-W01 → 2).

*DenseWindowTests* — 140 entries starting Monday 2026-03-30; absent → [-1,-1]; None fields → -1 ([-1, 2] at index 0); today index 135, 136–139 padding even with data; Sunday today (1-week window) no padding.

*BuildPayloadTests* — empty state equals `sim-fixtures/max-tracker-empty.json`; nulls without activity; plan allowlist mapping; unknown/None plan omits `planLabel`; lvl computed with real pct ([55, 2]); absent vs explicit inactive/no-pct day equivalent; avgPeakPct window-only while maxDays counts 2025-01-01; clamps of codingStreakDays, maxDays, maxWeeks, maxWeeksStreak at 999; all four fixtures satisfy the contract shape (`_assert_contract_shape`: exact keys, lengths, int types, ranges); live-shape fixture regenerated from the store equals the committed file; built payloads round-trip the shape.

### 12.2 `test_usage_history.py`

*Persistence*: one sample per 15 min (0 ✓, 899 ✗, 900 ✓); prune > 8 days on next record; atomic replace once, schema `{v, samples}` with exact record keys, no `*.tmp`; corrupt → quarantined, sibling untouched, next record recreates the file; quarantine rename fsynced (`state_files.fsync_parent(quarantined)`); quarantine survives failing dir fsync ("not yet durable"); post-replace fsync failure keeps memory+disk in sync and the next save carries both samples ("directory fsync failed"); PermissionError → never overwritten ("refusing to save", record returns False); wrong shape (`v: 7`) quarantined; `fsync_parent(path)` after rename; unknown provider/window rejected.

*Forecast*: unavailable without samples; collecting until 3 points span 90 min; collecting until movement ≥ 1 pp; low pace → `at_reset` 40, pace 7.0; fast → `exhausts` at 3 h, offset −60; falling → unavailable; only current reset cycle (55); ignores points older than 24 h (45).

*Delta*: cycle started inside period → full pct (11.0) from a single sample; last sample before `since` as baseline (7.0); needs two samples in current cycle (None); negative correction → None.

*Concurrency*: interleaved writers keep both samples in memory and on disk; 4 threads × 120 unique-cycle samples all kept (memory, disk); readers always see complete, sorted snapshots.

### 12.3 `test_quota_cache.py`

Windows skips dir fsync (`os.name == "nt"` → `os.open` not called); put/latest round trip; identities isolated, newest `observed_at` wins; no cross provider/scope; restart loads; expires at exact reset (`now == reset_at` → None); `latest` lock-free while writer lock held; readers see only committed truth during a paused persist; fresher lower pct replaces; corrupt → quarantined (`quota.json.corrupt-*`); extra top-level key → quarantined; malformed sibling record ignored; unhashable provider (list) ignored; huge-int pct rejected on put and on load; huge-int `now` → None; invalid values rejected (unknown provider/scope, identity with `\n` or 129 chars, NaN, 101, negative reset, bool observed_at, non-str label, 129-char label, label with `\n`); printable UTF-8 label accepted; expired loaded records not rewritten at load but dropped on the next put; concurrent puts for two identities both persist and reload; failed replace restores memory and disk; POSIX event order `temp-fsync, replace, directory-fsync, directory-close`; dir-fsync failure rolls back memory and disk and restores exact prior bytes (even an `indent=2` prior file); failed `json.dump` (OSError/UnicodeError/TypeError/ValueError) restores state; lone-surrogate label rejected; latest picks greatest `observed_at`; persisted keys exactly the allowlist, no `accessToken`.

### 12.4 `test_value_meter.py`

Real record on claude-opus-5 = $0.063475 (literal hand arithmetic); cache ≥ 500× naive; 1 M 5-min write $6.25 vs 1-h $10.00; flat total → 5-min bucket; explicit breakdown wins; per-model cache rate (override 3.0) beats multiplier; model w/o cache rates falls back to multipliers (0.80 read, 10.00 write); batch tier half price ($2.50); unknown/missing model → all tokens unpriced (31 907); empty/non-dict usage → (0,0); malformed counts → (0,0).
Plan cost: override → configured; default pro $20; codex pro $200; None/"team" → (None, unknown); bad overrides (0, −10, NaN, inf, True, "100", None) fall through to default.
Build payload: ok 3.12; no_plan_cost keeps dollars; partial at 50 % unpriced (share 0.5); 1000/1 001 000 tolerated; partial outranks no_plan_cost; zero usage → ok, multiple 0.0, share 0.0; basis + prices_as_of present.
Codex pricing (fixture `test/fixtures/codex-prices.json`, gpt-5.6-sol $5/$30/$0.50/$6.25): $0.47125; cached subtracted (difference = 80 000 × $5/M); reasoning not billed; total_tokens ignored; cached clamped to input.
Plan flags: parse `claude=200 codex=20`; unknown provider accepted; legacy flag → claude; explicit wins over legacy; malformed entries (`claude`, `claude=`, `claude=abc`, `claude=0`, `claude=-5`, `=200`) raise; per-provider costs in payload (plan 220, configured); value never credited to another plan (27.17, undeclared 8296); declaring both → plan 120, value 11013; total-only caller keeps ratio; zero-spend provider absent.
Generated table: source recorded (litellm, 40-hex sha, date = as_of); both providers & accounting survive (>10 models); in-use models priced (claude-opus-5, claude-sonnet-5, claude-fable-5, claude-fable-5-1, claude-haiku-4-5, gpt-6-astra, gpt-5.6-sol, gpt-5.1-codex); fable-5-1 → $0.265; astra → $0.3925; every model has input+output; per-million units (1 M output opus-5 = $25); sonnet-5 input $2.00.
Price table: override merges one model's rate, others unchanged; override can add a model; unknown accounting → ValueError; broken override → ValueError.

### 12.5 `test_update_prices.py`

Per-token → per-million; float noise rounded (2e-07 → 0.2); only rate fields kept; input-only model dropped; non-chat modes skipped; `responses` kept; unsupported providers ignored (result has both keys, empty); junk entries don't crash; models sorted; `blob_sha` equals `git hash-object`; build records source, declares accounting per provider, loads as a `PriceTable` with `as_of`; render deterministic; `--check` passes on fresh output, fails on a hand-edited rate, fails when the catalogue changed, passes when only `generated` differs.

### 12.6 `test_subscription_quota.py`

Grok ok then transport keeps 42.0 as stale, reset minutes `3*24*60 − 2`, label `WEEKLY`, interval ≥ 480; 429 with `retry_after` 30 → cooldown ≥ 600 s, lane stale, status starts `usage_http_429`; Cursor `sand: failed` keeps monthly bars (20/5/0, not stale), `cursorBotPct` None, status contains `sand_failed`; a passed reset serves null (not stale).

### 12.7 `test_vibepulse_config.py`

Missing file → all off, frozen; non-bool construction rejected (0, 1, "yes", None); save revalidates a forged instance and writes nothing; partial/complete files load strict booleans; byte cap independent of `stat`; symlink refused (with and without `O_NOFOLLOW`), target untouched; FIFO rejected without blocking (subprocess, 2 s timeout); lock file mode 0600 and released after an exception; lock re-entrant in one thread; nested exception unwinds then re-acquire; no backend → ConfigError before creating the directory; symlinked lock refused; directory path rejected; round trip writes exactly the 8 public keys; unknown/duplicate/malformed/non-object JSON rejected; every non-bool JSON value rejected (0, 1, "true", [], {}, null); URL/mailbox validation (valid `https://relay.example`, `vp_A1b2C3d4E5f6G7h8`; invalid `""`, `http://`, userinfo, path, non-strings; `vp_short`, trailing `=`); dir 0700 / file 0600; atomic replace from the same directory, no `.config.json.*` leftovers; failed replace keeps the old file, no temp left.

### 12.8 `test_tokenserver.py` (parts touching this area)

`MaxTrackerEndpointTests`: route returns 200 v1 payload, passes `plans` through, `stale` = claudeWeekStale OR codexWeekStale; producer exception → sanitized 500 `{"error": "internal server error"}`; `GET /` lists `/api/max-tracker`. `ArgumentParsingTests`: plan choices enforced, default None. Interaction-config tests (≈4990–5085): relay enable/disable keeps URL/mailbox/providers; legacy-panel toggle persists; `--interactions` enables only Claude; explicit CLI repairs an invalid saved file (logged ERROR). Value tests (≈5409–5466): `_compute` value block (1 M opus-5 cache reads = $0.50, ok, plan 100 configured); duplicate records deduped in dollars; distinct accumulate; unknown model → partial, share 1.0; no plan cost → no_plan_cost with dollars. Default history/cache paths are under `…/VibePulse`.
