# 04 — Agent status, interactions, Codex adapters, statusLine bridge

Behavioral specification for a native Swift port of the following
`tools/tokenserver/` modules. You should be able to port from this document
without reading the Python.

| Module | Role |
|---|---|
| `interaction_types.py` | Provider enum + neutral result value type |
| `codex_command.py` | Locate the Codex CLI executable |
| `codex_rollout.py` | Strict acceptance rules for Codex rollout JSONL records (quota/usage readers) |
| `agent_status.py` | Tail Claude/Codex JSONL logs → privacy-safe job states → `/api/agent-status` |
| `interactions.py` | Parking lot for questions/approvals, signed device answers, panel view + digest |
| `codex_interactions.py` | Strict Codex MCP-question / permission-hook normalization + safe shell allowlist |
| `statusline_bridge.py` | Claude Code `statusLine` command: capture rate-limit windows into a state file, chain the user's previous status line |

It also covers the `tokenserver.py` glue (HTTP routes, config, diagnostics,
statusline merge), the `vibepulse_setup.py` installers that touch `~/.claude`
and `~/.codex`, and the out-of-process Codex plugin clients. Those are
covered only where they define a contract.

Sources: every line of the seven modules and their five test files, plus the
consuming parts of `tokenserver.py`, `state_files.py`, `vibepulse_setup.py`
(the statusline and codex sections), `.agents/plugins/plugins/vibepulse/*`
and `docs/agent-setup.md`. No repository file was modified.

---

## 0. Porting-critical Python semantics (read first)

Byte-exact parity depends on these. Each one is referenced later as **[P#]**.

- **[P1] "C-category" characters.** The code often filters or rejects
  characters where `unicodedata.category(ch).startswith("C")`. That covers
  Cc (controls, including `\t \n \r` and U+007F…U+009F), Cf (format:
  U+200B–U+200F, bidi overrides U+202A–U+202E and U+2066–U+2069, U+FEFF,
  soft hyphen U+00AD, …), Cs (lone surrogates), Co (private use) and Cn
  (unassigned in Python's Unicode DB).
  - Swift: iterate `unicodeScalars` and check
    `properties.generalCategory ∈ {.control, .format, .surrogate, .privateUse, .unassigned}`.
  - Note: U+2028 and U+2029 are Zl/Zp, **not** C, so they pass this filter.
- **[P2] Length means code points.** Python `len(str)` counts code points.
  Swift `String.count` counts grapheme clusters, so always use
  `unicodeScalars.count`. "UTF-8 bytes" means `utf8.count`.
- **[P3] Lone surrogates.** Python `json.loads` accepts `"\ud800"`, which
  gives a str containing a lone surrogate. The code then either rejects it
  (`.encode("utf-8")` raises, so "unsafe text") or hashes it with
  `errors="surrogatepass"` (CESU-style 3-byte encoding).
  - Swift `String` cannot hold lone surrogates, and Foundation JSON
    decoding rejects or replaces them.
  - Acceptable port behavior: a record or body containing one is either
    rejected as a whole or never matches.
  - Observable effects in Python: task/source ids with surrogates are
    sha256-hashed (tests `test_surrogate_ids_are_hashed_without_crashing_or_leaking`),
    and interaction text with surrogates is rejected.
  - If your JSON parser can surface raw UTF-16 escapes, reproduce the
    surrogatepass bytes (`0xED 0xA0–0xBF xx`) for hashing. Otherwise document
    the divergence.
- **[P4] `str.split()` with no argument** splits on runs of Unicode
  whitespace (`str.isspace`): `\t\n\v\f\r`, `\x1c`–`\x1f`, space, `\x85`,
  `\xa0`, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000.
  - `" ".join(s.split())` therefore collapses internal whitespace and trims.
  - `str.strip()` with no argument trims the same set.
- **[P5] Python `re` with str patterns.** `\s` is Unicode whitespace and
  `\d` is any Unicode decimal digit. `$` matches at end-of-string **or before
  a final `\n`**. `re.match` anchors at the start only; `re.search` scans;
  `re.fullmatch` must consume the whole string. `re.IGNORECASE` is Unicode
  case-insensitive.
- **[P6] JSON output formats. There are three, and they must not be mixed.**
  - (a) **Wire format** for every HTTP response body is `json.dumps(obj)`
    with defaults:
    - `ensure_ascii=True`: every non-ASCII code point becomes `\uXXXX`
      (lowercase hex); astral characters become surrogate pairs
      `\ud83d\ude00`.
    - Separators are `", "` and `": "` (spaces).
    - Keys keep insertion order; `/` is NOT escaped.
    - `True/False/None` become `true/false/null`.
    - Floats use `repr` (e.g. `42.0`).
    - Control chars become `\n \r \t \b \f` or `\u00XX`.
    - The byte-size gates `response_fits` and `pending_public` measure
      exactly this form.
  - (b) **Canonical digest form**, `view_bytes`: `sort_keys=True`,
    separators `(",", ":")`, `ensure_ascii=False`. Non-ASCII is emitted raw
    as UTF-8; `"` and `\` are escaped; control chars are escaped as above
    (they are rejected earlier anyway); `/` is not escaped.
  - (c) **Compact sorted ASCII**, used for the statusline sample file and
    the Codex fallback-task-id hash input: `separators=(",",":")` plus
    `sort_keys=True` (sample) and `ensure_ascii=True`.
  - Swift's `JSONEncoder` and `JSONSerialization` escape `/` as `\/` unless
    told otherwise, and format numbers differently. **Write small
    hand-rolled encoders** for (a), (b) and (c).
- **[P7] JSON input.** Python `json.loads`:
  - accepts `NaN`, `Infinity` and `-Infinity` literals;
  - accepts arbitrarily large ints, except that more than 4300 digits
    raises ValueError, which the code treats as invalid;
  - keeps the last value for duplicate keys;
  - raises RecursionError on very deep nesting (treated as invalid);
  - rejects a leading UTF-8 BOM when given a str.
  - `json.loads(bytes)` (used by the HTTP body reader) auto-detects
    UTF-8/16/32 from the leading bytes.
  - Numbers: `1` is an int and `1.0` is a float. **Several checks depend on
    that distinction** (`type(x) is int`). Your parser must keep integer vs
    float tokens distinct and treat `true/false` as non-numbers.
- **[P8] `int(x)` on a float truncates toward zero.** `int("12")`, `int(" 12 ")`
  and `int("1_000")` succeed; `int("1.5")` fails; `int(True)` is 1;
  `int(float("inf"))` raises OverflowError.
- **[P9] `Path(p).name`** (POSIX) is the last non-empty component after
  dropping `.` components:
  - `"/a/b/"` → `"b"`, `"/"` → `""`, `"."` → `""`, `"a/."` → `"a"`,
    `"a/.."` → `".."`.
  - On Windows `\` is also a separator and drive anchors are not names.
- **[P10] `round(x, 1)`** is correctly-rounded half-even on the exact
  binary value: `round(0.25, 1)` → `0.2` and `round(2.675, 2)` → `2.67`.
  - Swift `(x*10).rounded()/10` can differ at boundaries. To be exact, use
    `Decimal`/string rounding of the shortest repr, or accept the (tiny)
    divergence.
- **[P11] `datetime.fromisoformat(s.replace("Z","+00:00"))`** (Python ≥ 3.11)
  accepts:
  - `YYYY-MM-DD`;
  - `YYYY-MM-DDTHH:MM[:SS[.ffffff]]` with the `T` or a space;
  - offsets `±HH:MM[:SS]`.
  - Behavior differs by module. `agent_status` treats naive values as UTC.
    **`codex_rollout.observation_timestamp` treats naive values as LOCAL
    time** (`naive.timestamp()` uses the local zone).
  - Out-of-range values raise and are skipped.

---

## 1. Dependency graph

```
interaction_types  (leaf)            codex_command (leaf)      codex_rollout (leaf)
        ▲                                   ▲                         ▲
        │                                   │ tokenserver, setup      │ tokenserver, max_tracker, codex_usage
agent_status ◄──────────── interactions ◄───┴── codex_interactions
 (sanitize_project)          ▲    │  (lazy import normalize_codex_permission
        ▲                    │    │   inside _codex_approval_is_normalized)
        │                    │    └─────────────► codex_interactions (approval_view, approvable_tool)
        │                    │
tokenserver.py ─────────────┘ + statusline_bridge ─► state_files (state_dir, quarantine_corrupt, fsync_parent)
```

- `interactions` imports `InteractionProvider` and `InteractionResult` from
  `interaction_types`, and `sanitize_project` from `agent_status`.
- `codex_interactions` imports `sanitize_project` (from agent_status) and
  `approval_view` / `approvable_tool` (from interactions).
  - `interactions` in turn lazily imports `normalize_codex_permission` back,
    which is a cycle broken by a function-local import. In Swift, put both
    in one module.
- `statusline_bridge` depends only on `state_files`. It runs as a
  **separate short-lived process** that Claude Code spawns, not inside the
  server.
- `tokenserver.py` uses:
  - `AgentStatusService` (created at start; `poll_once()` synchronously,
    then `start()`; `stop()` at shutdown);
  - `InteractionStore`, `read_device_key` and `response_fits`;
  - `normalize_codex_question`, `normalize_codex_permission`,
    `codex_permission_response` and `codex_question_result`;
  - `statusline_bridge.peek_sample`, `summarize_sample`, `config_path`,
    `SAMPLE_NAME` and `FRESH_S`;
  - `resolve_codex_executable` (for `codex app-server`);
  - the `codex_rollout` helpers.

---

## 2. `interaction_types`

```python
class InteractionProvider(str, Enum):
    CLAUDE = "claude"
    CODEX = "codex"

@dataclass(frozen=True)
class InteractionResult:
    verdict: str                  # "approve" | "deny" | "leave_it"
    option_index: int | None = None
    def __post_init__(self):
        if self.verdict not in ("approve","deny","leave_it"): raise ValueError("unsupported verdict")
        if self.option_index is not None and self.option_index < 0: raise ValueError("negative option index")
```

- Wire values are exactly `"claude"` and `"codex"`. Parsing is exact and
  case-sensitive, so `"CODEX"` is invalid.
- Swift: `enum InteractionProvider: String { case claude, codex }` and a
  struct with a failable/throwing init.

Tests (`test_codex_interactions.InteractionTypeTests`):
- the result is immutable and provider-neutral;
- the wire values are stable;
- an unsupported verdict raises;
- a negative index raises.

---

## 3. `codex_command.resolve_codex_executable(*, platform, environ, which, is_file) -> str | None`

The parameters are injectable, defaulting to `sys.platform`, `os.environ`,
`shutil.which` and `os.path.isfile`.

1. **win32:** if `LOCALAPPDATA` is non-empty, try
   `LOCALAPPDATA\Programs\OpenAI\Codex\bin\codex.exe`. If `is_file`, return
   it. This standalone install is preferred over `PATH`.
2. `exe = which("codex")`. If it is truthy:
   - on win32, if `_is_windows_app_path(exe)` is true, return **None**. Do
     not fall back, because a Store alias fails with Access Denied from
     background jobs.
   - Otherwise return `exe`.
3. **darwin:** try `/Applications/ChatGPT.app/Contents/Resources/codex`,
   then `/Applications/Codex.app/Contents/Resources/codex`. Each must pass
   `is_file` and `os.access(X_OK)`.
4. Otherwise return None.

```python
def _is_windows_app_path(path):
    normalized = str(path).replace("/", "\\").casefold()
    bounded = "\\" + normalized.strip("\\") + "\\"
    return "\\windowsapps\\" in bounded
```

Consumers:
- `tokenserver._read_codex_app_server_limits` (see §9.6);
- `vibepulse_setup._resolve_executables` (the Codex install plan).

Tests (`test_codex_command.py`):
- Windows prefers the standalone install over an app alias;
- a `…\WindowsApps\…` alias gives None;
- a packaged-app binary under WindowsApps gives None;
- a normal PATH hit is returned.

---

## 4. `codex_rollout` (leaf; strict envelope acceptance)

Every function takes one decoded JSONL record (`Any`) and returns
`None` unless the exact shape matches. **Never accept nested, quoted or
stringified variants.**

| Function | Accepts | Returns |
|---|---|---|
| `codex_rollout_rate_limits(obj)` | `obj` dict, `obj.type=="event_msg"`, `payload` dict, `payload.type=="token_count"`, `payload.rate_limits` dict | that `rate_limits` dict |
| `codex_rollout_last_token_usage(obj)` | same envelope; `payload.info` dict; `info.last_token_usage` dict | `last_token_usage` (**never** `total_token_usage`) |
| `codex_rollout_session_id(obj)` | `type=="session_meta"`, `payload` dict, `payload.session_id` non-empty str | the session id (resumed/forked rollouts keep the original, so group sums by it) |
| `codex_rollout_turn_model(obj)` | `type=="turn_context"`, `payload.model` non-empty str | the model |
| `observation_timestamp(value)` | str | `int(datetime.fromisoformat(value.replace("Z","+00:00")).timestamp())`; ValueError/OverflowError gives None; non-str gives None. **Naive = local time** [P11]; truncation [P8] |

Consumers (outside this spec's modules):
- `tokenserver._read_latest_rate_limits` and `_read_codex_observations`.
  These scan the newest rollout backwards in 64 KiB blocks up to 1 MiB,
  pre-filtering lines that contain `"rate_limits"`.
- `max_tracker.py`.
- `codex_usage.py`. Its `default_sessions_dir()` is `$CODEX_HOME/sessions`
  (user-expanded) or `~/.codex/sessions`, and it also gives the Codex
  sessions root for agent status.

---

## 5. `agent_status` — log tailing → job states

### 5.1 Constants

| Name | Value | Meaning |
|---|---|---|
| `LEASE_S` | `120.0` | a `working` record older than this reads as `unknown` |
| `WAITING_LEASE_S` | `7200` | `waiting`/`error` older than this reads as `unknown` |
| `POLL_S` | `0.5` | poller sleep between `poll_once` calls |
| `PUBLIC_JOB_LIMIT` | `4` | jobs per provider in the snapshot |
| `TRACKED_JOB_LIMIT` | `16` | records kept per provider |
| `STATES` | `idle, working, waiting, done, error, unknown` | |
| `STATE_PRIORITY` | waiting 5, error 4, working 3, done 2, idle 1, unknown 0 | |
| `ACTIVITIES` | `thinking, reading, editing, searching, running, testing, building, waiting_input, waiting_approval` | |
| `MODEL_LABELS` | `claude-fable-5`→`FABLE 5`, `claude-opus-5`→`OPUS 5`, `claude-sonnet-5`→`SONNET 5`, `gpt-5.6-luna`→`GPT-5.6 LUNA`, `gpt-5.6-sol`→`GPT-5.6 SOL`, `gpt-5.6-terra`→`GPT-5.6 TERRA` | exceptions to derivation (key = lowercased bounded raw id) |
| `_DATED_SUFFIX` | `-(?:20\d{6}\|20\d\d-\d\d-\d\d\|\d{4})(?=-\|$)` | removed everywhere (`re.sub`, all matches) |
| `_VERSION_TOKEN` | `^\d+(?:\.\d+)*$` | |

Firmware caps these must fit (`components/app_tokens/agent_status.h`):

| Cap | Value | Content limit |
|---|---|---|
| `TK_AGENT_ID_CAP` | 65 | ids ≤ 64 bytes |
| `TK_AGENT_PROJECT_CAP` | 17 | project ≤ 16 bytes |
| `TK_AGENT_MODEL_CAP` | 25 | model ≤ 24 bytes |
| `TK_AGENT_EFFORT_CAP` | 13 | effort ≤ 12 bytes |

The body cap is 4096 bytes.

### 5.2 Text normalization helpers

**`_bounded_display(value, max_bytes) -> str|None`**
1. The value must be a non-empty str, else None.
2. Remove every C-category character [P1], then `.strip()` [P4].
3. Take the longest code-point prefix whose UTF-8 length is ≤ `max_bytes`.
   It never splits a code point.
4. Return None if the result is empty.

**`normalize_model(value)`**
```python
raw = _bounded_display(value, 64)          # None -> None
label = MODEL_LABELS.get(raw.lower()) or derive_model_label(raw)
return _bounded_display(label, 24)
```

**`normalize_effort(value)`**: `_bounded_display(value, 12)`, then
`.upper()`, or None.

**`derive_model_label(model_id)`** (pure, never raises):
```python
base = model_id.strip().lower()
if base.startswith("ft:"): base = base[3:].split(":", 1)[0]
base = _DATED_SUFFIX.sub("", base)
tokens = [t for t in base.split("-") if t]
if not tokens: return model_id.upper()
if tokens[0] == "claude" and len(tokens) > 1:
    names   = [t for t in tokens[1:] if not VERSION.match(t)]
    version = ".".join(t for t in tokens[1:] if VERSION.match(t))
    label   = " ".join(t.upper() for t in names)
    return f"{label} {version}".strip() if version else label
if tokens[0] == "gpt" and len(tokens) > 1:
    return " ".join([f"GPT-{tokens[1].upper()}", *(t.upper() for t in tokens[2:])])
return " ".join(t.upper() for t in tokens)
```

Vectors (docstring and tests):

| Model id | Label |
|---|---|
| `claude-opus-4-8` | `OPUS 4.8` |
| `claude-haiku-4-5-20251001` | `HAIKU 4.5` |
| `claude-3-7-sonnet-20250219` | `SONNET 3.7` |
| `gpt-4-0125-preview` | `GPT-4 PREVIEW` |
| `claude-mythos-preview` | `MYTHOS PREVIEW` |
| `gpt-5.4-mini` | `GPT-5.4 MINI` |
| `gpt-4o` | `GPT-4O` |
| `o4-mini` | `O4 MINI` |
| `codex-mini-latest` | `CODEX MINI LATEST` |
| `ft:gpt-4.1-mini-2025-04-14:acme::xyz` | `GPT-4.1 MINI` |
| `"Claude-Opus-4-8 "` | `OPUS 4.8` |

Tests also require that every model in `prices.json` derives a label that
is ≤ 24 UTF-8 bytes, uppercase and free of "CLAUDE".

Normalization is applied **repeatedly**: in the classifier, in
`_observation`, and again in `store.apply`. The function is idempotent on
its own labels (`"GPT-5.6 SOL"` → `"GPT-5.6 SOL"`), but port it
identically and call it at the same points.

**`sanitize_project(value)`**:
1. The value must be a non-empty str, else None.
2. `name = Path(value).name` [P9].
3. Remove C-category characters, `.strip()`.
4. Take a UTF-8 prefix of ≤ 16 bytes; return None if empty.

Vectors: `"Tor\x00get-med-ett-långt-namn"` → `"Torget-med-ett-l"`;
`"å"*16` → `"å"*8`.

**`_bounded_task_id(value: str)`**:
```python
raw = value.encode("utf-8", errors="surrogatepass")
if len(raw) <= 64 and no C-category char in value: return value
return sha256(raw).hexdigest()      # 64 lowercase hex
```
Vector: `"å"*40` (80 bytes) → `sha256("å"*40 UTF-8)` hex.

### 5.3 `Event` and ids

```python
@dataclass(frozen=True)
class Event: state; activity: str|None; task_id: str; source_id: str; project: str|None; model=None; effort=None

def stable_event_id(provider, event) -> str:
    raw = f"{provider}|{event.task_id}|{event.state}|{event.source_id}"
    return sha256(raw.encode("utf-8", "surrogatepass")).hexdigest()[:32]
```

- The event id is sensitive to provider, task_id, state and source_id, and
  to nothing else (test `test_stable_event_id_is_deterministic_and_sensitive_to_contract_fields`).
- Every new source record (a new uuid or item id) therefore produces a new
  `event_id`, which counts as a public change. That is how the panel
  notices each new event, e.g. for the completion pulse.

### 5.4 `classify_claude(record) -> Event|None`

The record must be a dict.

**Identity** (`_claude_identity`):
- `sessionId` and `uuid` must both be non-empty strs, else None.
- `task_id = sha256(sessionId UTF-8/surrogatepass).hexdigest()` (64 hex).
  All records of one session share it.
- `source_id = uuid`.
- `project = sanitize_project(record.cwd)`.

**Metadata** (`_claude_event`):
- If `record.message` is a dict: `model = normalize_model(message.model)`
  and `effort = normalize_effort(message.effort)`.
- If effort is still None, use `normalize_effort(record.effort)`. The
  top-level value is a fallback; nested wins.
- Never read either from `tool_input`.
- Non-str effort is ignored.

**Dispatch on `record.type`:**

| type | Result |
|---|---|
| `"user"` | `working / thinking` (every user record, including tool results) |
| `"result"` | `_has_explicit_error(record)` → `error/None`; else `subtype=="success"` → `done/None`; else `subtype in {error,failure,failed}` → `error/None`; else None |
| `"system"` | if `subtype` or `status` is a str that contains `"permission"` (case-insensitive) → `waiting/waiting_approval`; else None |
| `"assistant"` | see below |
| other | None |

`_has_explicit_error(d)` is
`d.get("is_error") is True or ("error" in d and d["error"] is not None)`.
So `"error": false` or `"error": {}` **counts as an error**.

**Assistant records:**
1. `message` must be a dict, else None.
2. If `message.content` is a list, collect a classification for each item
   that is a dict with `type == "tool_use"`, using `_claude_tool_activity`.
   Non-None results go into a list.
3. If `("waiting","waiting_input")` is in the list, return it. Else if
   `("waiting","waiting_approval")` is in the list, return it. Else if the
   list is non-empty, return its **last** element.
4. Else, if `message.stop_reason == "end_turn"` → `waiting / None`. This
   means "your turn", **not** done.
5. Else, if content is a list with any dict item whose type is `thinking`
   or `text` → `working / thinking`.
6. Else None.

**`_claude_tool_activity(item)`:**
- `name` must be a non-empty str, else None.
- Lowercase it, then:

| Tool name | Result |
|---|---|
| `askuserquestion` | `waiting/waiting_input` |
| contains `permission` | `waiting/waiting_approval` |
| `edit`, `write`, `apply_patch` | `working/editing` |
| `read` | `working/reading` |
| `glob`, `grep`, `websearch`, `web_search` | `working/searching` |
| `bash`, `shell`, `exec`, `exec_command` | depends on `input.command` (below) |
| anything else (`MultiEdit`, `TodoWrite`, `Task`, `NotebookEdit`, …) | None |

- For the shell-family tools:
  - if `input.command` is not a str → `running`;
  - else if `_TEST_COMMAND.search(cmd)` → `testing`;
  - else if `_BUILD_COMMAND.search(cmd)` → `building`;
  - else `running`.

```
_TEST_COMMAND  = (?:^|[\s;&|])(?:\./test/run\.sh|pytest|python3?\s+-m\s+unittest|npm\s+(?:run\s+)?test|cargo\s+test|go\s+test|ctest)(?:\s|$)      re.I
_BUILD_COMMAND = (?:^|[\s;&|])(?:cmake\s+--build|ninja|make|cargo\s+build|npm\s+run\s+build|idf\.py\s+build)(?:\s|$)                              re.I
```

The command text is only inspected; it is never stored (test
`test_claude_event_never_retains_a_command`).

### 5.5 `classify_codex(record) -> Event|None`

The record must be a dict and `payload` must be a dict.

| `record.type` | Rule |
|---|---|
| `turn_context` | `payload.turn_id` non-empty str → `Event(working, thinking, _bounded_task_id(turn_id), source_id=turn_id, sanitize_project(payload.cwd), normalize_model(payload.model), normalize_effort(payload.effort))` |
| `response_item` | `payload.id` must be a non-empty str (the source_id), else None. `activity = _codex_response_activity(payload)`; None gives None. `turn = payload.internal_chat_message_metadata_passthrough.turn_id` if that is a dict with a non-empty str, else `source_id`. Result: `Event(working, activity, _bounded_task_id(turn), source_id, project=None)` |
| `event_msg` | `payload.turn_id` must be a non-empty str. `payload.type=="task_started"` → `working/thinking`; `=="task_complete"` → `error` if `_has_explicit_error(payload)` else `done` (activity None). Other types give None. project=None, source_id=turn_id |

`_codex_response_activity(payload)`:
- `type ∈ {reasoning, function_call_output, custom_tool_call_output}` →
  `thinking`.
- `type ∈ {function_call, custom_tool_call}`:
  - `name` missing or empty → `running`;
  - lowercased name in `{apply_patch, edit, write}` → `editing`;
  - `{read, view_image}` → `reading`;
  - contains `search`, or is in `{web, web__run, find}` → `searching`;
  - else `running`.
- Otherwise None. For example `message` items are ignored.

> **Observed behavior to preserve:** project is *not* carried forward by
> the store; only model and effort are. A Codex job's `project` comes from
> `turn_context`. The next `response_item` or `event_msg` for the same task
> carries `project=None`, and because project is a public field the record
> is replaced with `project=null`. Port as-is unless product decides
> otherwise.

### 5.6 `AgentStatusStore(now=monotonic)`

**State.** One `threading.Lock`, `_seq=0`, and
`_agents = {"claude": {}, "codex": {}}`. Each provider map goes from
`task_id` to a record:

```
{task_id, event_id, state, project, activity, model, effort, observed_at (monotonic s), order_at (wall s)}
```

**`apply(provider, event, observed_at=None, order_at=None, refresh_unchanged=True, event_id_override=None) -> bool`**

1. Validate the inputs:
   - provider not in the map → `ValueError("unsupported provider: …")`;
   - state not in STATES → `ValueError("unsupported state: …")`;
   - activity not None and not in ACTIVITIES →
     `ValueError("unsupported activity: …")`.
2. Resolve the times:
   - `seen_at` = observed_at, or `now()`; non-finite → `now()`.
   - `ordered_at` = order_at, or seen_at; non-finite → seen_at.
   - `effective_at` = `now()`; non-finite → seen_at.
3. Build the replacement record:
   ```
   task_id   = _bounded_task_id(event.task_id)
   event_id  = event_id_override or stable_event_id(provider, event)
   project   = sanitize_project(event.project)
   model     = normalize_model(event.model)
   effort    = normalize_effort(event.effort)
   ```
   plus state, activity, `observed_at=seen_at` and `order_at=ordered_at`.
4. Under the lock:
   - `current = records.get(task_id)`.
   - If current exists and `ordered_at < current.order_at` (strictly), the
     event is older; **return False** with no mutation.
   - If current exists, carry forward model and effort when the
     replacement's value is None (same task only).
   - `changed = current is None or any(current[k] != replacement[k] for k in (task_id,event_id,state,project,activity,model,effort))`.
5. If changed:
   - `records[task_id] = replacement` (the whole record is replaced).
   - If `len(records) > 16`, evict
     `min(records, key=(STATE_PRIORITY[_effective(r, effective_at).state], r.order_at, r.task_id))`.
     This can evict the record just inserted.
   - `_seq += 1`, even if the new record itself was evicted.
6. Else, if `refresh_unchanged`: `current.observed_at = max(...)` and
   `current.order_at = max(...)`. Otherwise nothing changes.
7. Return `changed`.

**`_effective(record, now)`:**
```python
age = max(0.0, now - record.observed_at)
if (state == "working" and age > 120) or (state in ("waiting","error") and age > 7200):
    state, activity = "unknown", None
updated_ms = min(0xFFFFFFFF, int(age * 1000))
```
- `done` and `idle` never age out.
- The boundaries are exclusive: waiting is still visible at exactly 7200.0
  and hidden at 7200.001.

**`snapshot()`** (with `now` read before taking the lock):
```python
for provider in ("claude", "codex"):
    public = [effective(r, now) for r in records]           # full dict incl. updated_ms
    public = [j for j in public if j.state not in ("idle","unknown")]
    active_count = count(j.state in ("working","waiting","error"))  # over ALL public, not just top 4
    public.sort(key=(-PRIORITY[state], updated_ms, task_id))
    jobs = public[:4]
return {"v": 2, "seq": seq, "agents": {"claude": {...}, "codex": {...}}}
```

Returned objects are fresh copies (test `test_snapshot_is_a_deep_copy`).
Each job has **exactly** these 8 keys, in this order: `task_id, event_id,
state, project, activity, model, effort, updated_ms`. Values may be `null`
(project, activity, model, effort).

### 5.7 `JsonlTailer(now=monotonic)` — incremental, rewrite-aware JSONL reader

**Constants:**

| Name | Value |
|---|---|
| `_MISSING_POLLS` | 3 |
| `_READ_CHUNK_BYTES` | 65536 |
| `_READ_BYTES_PER_POLL` | 1048576 |
| `_MAX_LINE_BYTES` | 1048576 |
| `_MAX_RECORDS_PER_POLL` | 256 |
| `_VERIFY_INTERVAL_S` | 5.0 |
| `_VERIFY_BYTES_PER_POLL` | 1048576 |
| `_SAMPLE_BYTES` | 4096 |
| `_MAX_TRACKED_IDENTITIES` | 48 |
| `_MAX_ACTIVE_IDENTITIES` | 24 (declared, used only by tests as a reference) |

**Per-identity state.** `identity = (st_dev, st_ino)`. The state dict holds:

| Field | Initial value / meaning |
|---|---|
| identity | |
| offset | 0 |
| partial | b"" |
| discarding_line | False |
| prefix_hasher | sha256 running over **every accepted byte in [0, offset)** |
| sample_digest | None |
| stat_signature | None (a tuple (size, mtime_ns, ctime_ns) when set) |
| missing_polls | 0 |
| last_used | use counter |
| next_verify_at | now + 5 |
| verify_offset, verify_length, verify_expected, verify_hasher | None |
| backfilling | bool |
| last_read_backfill | False |
| last_read_caught_up | False |

There are two maps: `_files` (path → state, and several paths may alias one
state) and `_identities` (identity → state). There is also
`_discovery_needed` (a bool) and `_use_counter` (an int). A fresh state is
created with `backfilling=False`, except that replacement and reset create
it with `True`.

**`_touch(state)`**: `use_counter += 1; state.last_used = use_counter`.

**`_prune_state(state)`**: delete it from `_identities` if mapped, and
delete every alias in `_files` that points at it.

**`_enforce_identity_limit(protected=None)`**: while
`len(_identities) > 48`:
1. Candidates are identities that are not protected and not referenced by
   any `_files` alias.
2. If there are none, candidates are all identities except the protected
   one.
3. If there are still none, return.
4. Prune the candidate with the minimal `last_used`.

**`_state_for_identity(path, identity)`:**
1. If `_files[path]` exists with a different identity: delete the alias and
   remember `replaced=True`.
2. `state = _files.get(path)`. If it is missing, use
   `_identities.get(identity)`. That transfers the state on a rename
   (same inode, new path) without replay. Otherwise create a
   `_fresh_state(identity, backfilling=replaced)` and register it.
   Then set `_files[path] = state`.
3. `missing_polls = 0`; `_touch`; `_enforce_identity_limit(protected=state)`.
4. For every other alias of this state, re-`stat` it. If its identity
   differs or stat fails, drop that alias.

**`_reset_state(state, identity)`**: clear the state in place, then fill it
with `_fresh_state(identity, backfilling=True)`. Remap `_identities` from
the old identity to the new one (the same object).

**`_finish_read(state, caught_up)`**:
`last_read_backfill = backfilling; last_read_caught_up = caught_up`.
If both are true, set `backfilling = False`.

**`_sample_prefix(stream, length) -> bytes|None`**: a cheap boundary
fingerprint.
```python
d = sha256(); d.update(str(length).encode("ascii"))
ranges = [(0, min(length, 4096))]
if length > 4096: s = max(4096, length - 4096); ranges.append((s, length - s))
for start, size in ranges:
    seek(start); chunk = read(size)
    if len(chunk) != size: return None
    d.update(start.to_bytes(8, "big")); d.update(chunk)
return d.digest()
```

**Full-prefix verification** (`_advance_verification`) is budgeted across
polls:
1. If not started: `verify_offset=0`, `verify_length=offset`,
   `verify_expected = prefix_hasher.digest()` (a snapshot; Python's
   `digest()` does not finalize), and a new hasher.
2. If `verify_offset == 0` and `length ≤ 1 MiB`: hash `[0, length)` in one
   go (64 KiB reads). A short read → **False**.
3. Otherwise seek to `verify_offset` and hash up to
   `min(remaining, 1 MiB)` in 64 KiB chunks. An empty read → **False**.
4. If `verify_offset < length` → return **None** (still in progress).
5. Otherwise compare the digest with `verify_expected` and clear the
   verification fields.
6. On a match: `next_verify_at = now + 5` and return True. On a mismatch
   return False.

Swift: CryptoKit `SHA256` is a value type; `finalize()` on a *copy* gives a
non-finalizing digest.

**`_consume_chunk(state, chunk, records) -> consumed_bytes`** (line
framing):
```python
position = 0
while position < len(chunk):
    nl = chunk.find(b"\n", position)
    if nl < 0:
        frag = chunk[position:]
        if not state.discarding_line:
            if len(state.partial) + len(frag) <= 1 MiB: state.partial += frag
            else: state.partial = b""; state.discarding_line = True
        return len(chunk)
    frag = chunk[position:nl]; consumed = nl + 1
    if state.discarding_line:            # tail of an oversized line
        state.discarding_line = False; state.partial = b""; position = consumed; continue
    if len(state.partial) + len(frag) > 1 MiB:
        state.partial = b""; position = consumed; continue
    raw = state.partial + frag; state.partial = b""
    if raw.strip():                      # ASCII-whitespace-only lines skipped
        try: record = json.loads(raw.decode("utf-8"))   # strict UTF-8; any JSON value
        except (JSONDecodeError, UnicodeError): record = None
        if record is not None:
            records.append(record)
            if len(records) >= 256: return consumed      # exact stop mid-chunk
    position = consumed
return len(chunk)
```
- Records can be any JSON value; the classifiers drop non-dicts.
- A JSON line whose value is `null` is dropped, because `record is None`.

**`read(path, backfill=False) -> list`:**
1. `stat(path)`.
   - FileNotFoundError → `_note_missing_path(path)`, return `[]`.
   - Other OSError → if a state exists, set
     `last_read_backfill=backfilling` and `caught_up=False`; return `[]`.
2. `state = _state_for_identity(path, (dev, ino))`.
3. If `backfill`: `state.backfilling = True`. Then
   `last_read_backfill = backfilling` and `last_read_caught_up = False`.
4. If `st_size < offset` → `_reset_state`, i.e. the file was truncated.
5. `sig = (size, mtime_ns, ctime_ns)`.
   `due = verify_hasher is not None or now >= next_verify_at or (size == offset and sig != stat_signature)`.
6. **Fast path:** if `size == offset and sig == stat_signature and not due`
   → `_finish_read(caught_up=True)` and return `[]`, without opening the
   file.
7. Open the file `rb`. `opened = fstat`. If the opened identity differs,
   `state = _state_for_identity(path, opened_identity)`. If
   `opened.size < offset` → reset.
8. If `offset > 0 and opened.size > offset` and
   `_sample_prefix(stream, offset) != sample_digest` → reset. That catches
   a rewrite followed by growth.
9. Recompute `due` using `opened`. If due: `v = _advance_verification`.
   If `v is False` → reset. (None, meaning in progress, continues
   normally.)
10. Seek to `offset`; `remaining = 1 MiB`. While `remaining` is positive
    and fewer than 256 records have been read:
    - `chunk = read(min(remaining, 64 KiB))`; stop if it is empty.
    - `consumed = _consume_chunk(...)`.
    - `prefix_hasher.update(chunk[:consumed])`; `offset += consumed`;
      `remaining -= consumed`.
    - If `consumed < len(chunk)`: seek to `offset` and break.
11. `state.offset = offset`; `sample_digest = _sample_prefix(stream, offset)`;
    `final = fstat`.
    - FileNotFoundError inside this block → note missing, return `[]`.
    - Other OSError → set the flags, return `[]`.
12. `stat_signature = final_sig if final_sig == opened_sig else None`. A
    file modified while it was being read is not trusted for the fast path.
13. `_files[path] = state`; `_finish_read(caught_up = offset >= final.size)`.
    Return the records.

Note: `partial` counts toward nothing in `offset`. Bytes appended to
`partial` **are** counted as consumed (offset advances past them); the
unfinished line lives in memory.

**`_note_missing_path(path)`**: if the path has a state:
- set `last_read_backfill = backfilling` and `caught_up = False`;
- set `_discovery_needed = True`;
- `missing_polls += 1`, and prune the state if `missing_polls ≥ 3`.

**`retain_paths(paths, active_paths=None)`**, called after discovery:
1. `paths` is either a dict (path → identity) or an iterable, in which case
   each path is stat-ed and failures are skipped.
2. `active = set(path_identities)` if `active_paths is None`, else
   `set(active_paths)`.
3. Compute three sets:
   - `existing` = all identities in `path_identities`;
   - `active_ids` = identities of active paths that were found;
   - `recovering` = identities of states aliased by an **active** path that
     is absent from `path_identities` (temporarily missing).
4. Drop an alias if any of these holds:
   - it maps to a different identity now;
   - it vanished while its identity still exists elsewhere (moved);
   - it is not in `active`.
5. For each identity state:
   - If it is in `existing`: `missing_polls = 0`, and if it is not in
     `active_ids`, clear `partial` and `discarding_line`. Cold files drop
     their in-memory line fragment.
   - Otherwise, unless it is recovering: `missing_polls += 1`, and prune it
     at 3.
6. `_enforce_identity_limit()`.

**Small accessors:**
- `take_discovery_request()` returns the flag and clears it.
- `read_status(path)` returns `(last_read_backfill, last_read_caught_up)`,
  or `(False, False)`.
- `read_identity(path)` returns the identity or None.
- `continue_backfill(path)` sets `backfilling = last_read_backfill = True`.

### 5.8 `AgentStatusService(projects_dir, codex_sessions, now=monotonic, *, _wall_time=time.time, _diagnostic=None)`

**Constants:** `_RECENT_FILE_LIMIT=12`, `_DISCOVERY_INTERVAL_S=5.0`,
`_DIAGNOSTIC_INTERVAL_S=30.0`, `_SEEN_PATH_LIMIT=96`.

**Sources:**

| provider | root | glob | classifier |
|---|---|---|---|
| `claude` | `projects_dir` (tokenserver `--dir`, default `~/.claude/projects`) | `**/*.jsonl` | `classify_claude` |
| `codex` | `codex_sessions` (`$CODEX_HOME/sessions` or `~/.codex/sessions`) | `**/rollout-*.jsonl` | `classify_codex` |

**Fields:**

| Field | Initial value |
|---|---|
| `_store` | an `AgentStatusStore` |
| `_tailer` | a `JsonlTailer` |
| `_poll_lock` | a lock |
| `_thread_lock` | a lock |
| `_stop` | an Event |
| `_thread` | None |
| `_stopping` | False |
| `_active_paths` | `{claude:[], codex:[]}` |
| `_next_discovery_at` | −∞ |
| `_last_diagnostic` | {} |
| `_seen_paths` | OrderedDict (LRU) |
| `_seen_overflow` | False |
| `_backfills` | {} (key → pending latest observation) |
| `_stream_tasks` | {} (key → task_id) |
| `_observation_sequence` | 0 |

Here `key = (provider, path, identity)`.

**Discovery** (`_discover_paths(root, pattern)`):
1. If `root` is not a directory, return `({}, [])`.
2. Glob recursively. pathlib `**` matches zero or more directories and `*`
   matches dotfiles too.
3. For each match, `stat()`, which follows symlinks; skip it on OSError.
   Keep only regular files: `identities[path] = (dev, ino)` and
   `candidates.append((mtime_ns, str(path), path))`.
4. Any OSError from iteration → `({}, [])`.
5. `recent = sorted(heapq.nlargest(12, candidates))`. That is the 12 newest
   by (mtime_ns, path string), ordered oldest → newest.
6. Return `(identities of ALL matches, recent)`.

**`_refresh_discovery(sources)`:**
1. For each provider, discover. An exception →
   `_report_error("discovery")`, and that provider gets `[]`. Otherwise
   merge its identities into `retained` and its recent paths into `active`,
   and set `next_active[provider] = recent`.
2. `missing_previous` = previously active paths that are absent from
   `retained`.
3. `tailer.retain_paths(retained, active_paths = active + missing_previous)`.
4. **Grace:** for each provider, previously active paths that are not in
   `retained` but still in `tailer._files` are appended to
   `next_active[provider]`, up to `12 - len(...)` of them.
5. `_active_paths = next_active`.
6. Drop the `_backfills` keys whose path is in neither `tailer._files` nor
   any active list.
7. Drop the `_stream_tasks` keys that are not
   `(provider, path, tailer.read_identity(path))` for an active path.
8. `tailer.take_discovery_request()` (clears the flag);
   `_next_discovery_at = now + 5`.

**Time model:**
- `_event_wall_time(record)`: the candidates are `record.timestamp` plus,
  if `payload` is a dict:
  - `payload.completed_at, payload.started_at` when
    `payload.type == "task_complete"`;
  - otherwise `started_at, completed_at`.

  The first candidate that is a non-empty str and parses with
  `fromisoformat(value.replace("Z","+00:00"))` (naive → **UTC**) to a
  finite timestamp wins. There is no fall-through to the next candidate if
  that time is in the future.
- `_resolved_wall_time(record, file_wall_time, wall_now)`:
  1. `t = event_wall_time`; if it is None or `> wall_now`, use
     `file_wall_time` (the file's `st_mtime` as a float at poll time).
  2. If that is None, non-finite or `> wall_now`, return `wall_now`.
  3. Otherwise return `t`.
- `_observation(...)`:
  - `order_at = resolved wall time` (epoch seconds);
  - `observed_at = monotonic_now - max(0, wall_now - order_at)`;
  - `sequence += 1`.
  - The compact event is
    `Event(state, activity, _bounded_task_id(task_id), source_id="", sanitize_project(project), normalize_model(model), normalize_effort(effort))`.
  - `event_id = stable_event_id(provider, bound_event_with_original_source_id)`.
  - The result is `_Observation(event, event_id, observed_at, order_at, sequence)`.
- The store compares **`order_at` (wall clock)** for staleness, and ages
  with **`observed_at` (monotonic)**. An old log line replayed at startup
  therefore reads as old, e.g. as a `working` job already past its lease,
  which is hidden (test `test_startup_replay_uses_old_claude_and_codex_iso_timestamps`).

**Codex stream binding** (`_bind_stream_task(provider, key, record, event)`),
for codex dict records with a dict payload only:
- If `record.type != "response_item"`: remember
  `_stream_tasks[key] = event.task_id` and return the event unchanged.
- For a response_item:
  - If the metadata turn id is present, set
    `task = _bounded_task_id(turn)` and remember it.
  - Else use `_stream_tasks.get(key)`. If that is missing too, use
    `_fallback_stream_task(key)` and remember it.
  - Return a copy of the event with that task_id, keeping the source_id.
- The fallback is
  `sha256(json.dumps([provider, str(path), [dev, ino]], ensure_ascii=True, separators=(",",":")).encode()).hexdigest()`,
  in format [P6c], e.g. `["codex","/Users/x/.codex/sessions/…/rollout-….jsonl",[16777233,1234567]]`.

**`_poll_active(sources, skip_paths=None) -> changed_count`.** For each
provider in order (claude, then codex), for each path in
`_active_paths[provider]` (oldest → newest), skipping `skip_paths`:
```python
was_seen  = seen_overflow or path in seen_paths
had_state = path in tailer._files
records   = tailer.read(path, backfill = not had_state)      # cold or first-seen => backfill
(read_backfill, caught_up) = tailer.read_status(path)
if not was_seen and not had_state and not caught_up:
    tailer.continue_backfill(path); read_backfill = True
if path in tailer._files: remember_path(path)                 # LRU 96; overflow => seen_overflow = True forever
identity = tailer.read_identity(path);  if None: continue
key = (provider, path, identity)
drop _backfills entries with same (provider, path) but another identity
is_backfill = read_backfill or key in _backfills
file_wall_time = path.stat().st_mtime or None; mono = now(); wall = wall_time()
for record in records:
    event = classifier(record)            # exception -> report "classify", skip
    if event is None: continue
    event = bind_stream_task(...); obs = observation(...)
    if is_backfill:
        cur = _backfills.get(key)
        if cur is None or (obs.order_at, obs.sequence) >= (cur.order_at, cur.sequence): _backfills[key] = obs
    elif store.apply(provider, obs.event, observed_at=obs.observed_at, order_at=obs.order_at,
                     refresh_unchanged=True, event_id_override=obs.event_id): changed += 1
    # exceptions in bind/observe/apply -> report "apply", skip record
if is_backfill and caught_up:
    obs = _backfills.pop(key, None)
    if obs: apply(..., refresh_unchanged=False) -> changed += 1 if True  (exception -> "apply")
```
- Rule: history (a first sighting, a replacement, a cold re-read or a
  rewrite) is **never published step by step**. Only the single latest
  observation by `(order_at, sequence)` is applied, and only once the file
  is caught up.
- A `tail-read` exception is reported and the path is skipped.

**`poll_once() -> int`**, under `_poll_lock`:
1. If `now >= _next_discovery_at`, run discovery.
2. `polled = all active paths`; `changed = _poll_active()`.
3. If `tailer.take_discovery_request()` (a file vanished during reads):
   rediscover, then `changed += _poll_active(skip_paths=polled)`.
4. Return `changed`.

**`snapshot()`** returns `store.snapshot()`. It is lock-light, does no disk
I/O and is safe on HTTP threads.

**Diagnostics** (`_report_error(context, error)`):
- The message is `f"agent-status {context}: {type(error).__name__}"`.
  Never include the message text or path (privacy).
- Throttle per `(context, name)` to one per 30 s of monotonic time. The
  first occurrence always prints.
- The default sink is `print(..., file=stderr)`. Exceptions from the sink
  are swallowed.
- The contexts are `discovery`, `tail-read`, `classify`, `apply` and
  `poll`.

**Threading:**
- `start()` (under `_thread_lock`):
  - no-op if `_stopping`, or if a live thread exists;
  - otherwise clear `_stop` and start a daemon thread named
    `agent-status-poller`.
- The thread's `_run` loops until `_stop` is set: `poll_once()` (an
  exception is reported as `poll`), then `if _stop.wait(0.5): break`.
- `stop()`:
  1. Under the lock: if already stopping, return. Otherwise set
     `_stopping=True`, set `_stop`, and grab the thread.
  2. Join with `timeout = max(1.0, 0.5*4) = 2.0` s, unless the caller is
     that thread.
  3. `finally`, under the lock: clear `_thread` if it is the same thread
     and not alive; `_stopping = False`.
- Tests pin three cases:
  - a concurrent `start()` during `stop()` cannot clear the stop signal or
    launch a replacement;
  - start and stop are idempotent;
  - missing roots are fine.

**tokenserver wiring:**
1. `AgentStatusService(projects_dir=Handler.projects_dir, codex_sessions=CODEX_SESSIONS)`.
2. `poll_once()` once synchronously at startup, then `start()`.
3. `stop()` in shutdown.
4. The handler holds `agent_status`, and GET only calls `snapshot()`.

### 5.9 `GET /api/agent-status`

1. `_record_panel_poll()` runs first (for non-loopback clients only; it
   tracks panel liveness for `GET /`).
2. Then `_reply(_agent_status_payload)`: the producer's exception → 500
   `{"error": "internal server error"}` (logged). A write-time
   ConnectionError is ignored.
3. `_agent_status_payload`:
   ```python
   payload = agent_status.snapshot()
   if interaction_store is None: return payload
   pending = interaction_store.pending_public()
   if pending is None: return payload
   candidate = dict(payload); candidate["pending"] = pending
   if not interactions.response_fits(candidate):         # json.dumps default (P6a) <= 3584 bytes
       log.warning("the pending entry did not fit ... (%d jobs) ...", len(pending)); return payload
   return candidate
   ```
4. The path must match exactly; a query string gives 404
   `{"error":"not found"}`.
5. Response: 200, `Content-Type: application/json`, `Content-Length`, and
   the body in wire format [P6a]. The HTTP version is 1.0 (the Python
   default), so the connection closes after the response.

Complete shape:
```json
{"v": 2, "seq": 42,
 "agents": {
   "claude": {"active_count": 2, "jobs": [
     {"task_id": "<≤64 chars or 64-hex>", "event_id": "<32 hex>", "state": "waiting|error|working|done",
      "project": "<≤16 B basename>|null", "activity": "<ACTIVITY>|null", "model": "<≤24 B>|null",
      "effort": "<≤12 B upper>|null", "updated_ms": 0}]},
   "codex":  {"active_count": 0, "jobs": []}},
 "pending": { ...optional, see §6.9... }}
```
- `pending` is an optional **root** key and `v` stays 2. The shipped
  firmware ignores unknown root keys.
- The firmware drops the whole body past 4096 bytes. The server ceiling is
  3584, and a test requires a worst-case snapshot plus pending to fit.

---

## 6. `interactions` — parking lot + signed answers

### 6.1 Constants

| Name | Value | Notes |
|---|---|---|
| `KINDS` | `("question","approval")` | |
| `VERDICTS` | `("approve","deny","leave_it")` | |
| `MAX_PENDING` | 8 | concurrent parked entries |
| `ISSUED_ID_HISTORY_LIMIT` | 256 | remembered ids (anti-revival) |
| `MAX_HOLD_MS` | `0xFFFFFFFF` | hold must be ≤ 4294967.295 s |
| `FRESHNESS_S` | 90.0 | \|now − ts\| window for answers |
| `ALIVE_POLL_S` | 2.0 | liveness check cadence while parked |
| `PENDING_BUDGET_BYTES` | 640 | pending item size budget |
| `RESPONSE_CEILING_BYTES` | 3584 | full `/api/agent-status` body budget (firmware 4096) |
| `PROMPT_MAX` | 96 | bytes |
| `TITLE_MAX` | 64 | bytes |
| `SUBTITLE_MAX` | 64 | bytes |
| tool limit | 24 | bytes |
| `RECOMMENDED_SUFFIX` | `"(recommended)"` | case-insensitive, after `strip()` |
| `_APPROVABLE_TOOLS` | `{read, glob, grep, notebookread}` | |
| `_COMMAND_CHAINING` | `[;&|><`$\n]` | |
| `_SHA256_HEX` | `^[0-9a-f]{64}$` | lowercase only (used with fullmatch) |
| question view fields | `kind, options_total, marked, prompt, title, subtitle, can_approve` | |
| approval view fields | `kind, tool, title, subtitle, can_approve` | |

```
_APPROVABLE_COMMAND = ^(?:\s*)(?:\./test/run\.sh|pytest|python3?\s+-m\s+unittest|npm\s+(?:run\s+)?test|cargo\s+test|go\s+test|ctest|cmake\s+--build|ninja|make|cargo\s+build|npm\s+run\s+build|idf\.py\s+build|git\s+(?:status|diff|log|show|branch)|ls|cat|head|tail|wc|grep|rg)(?:\s|$)   re.I, used with re.match
```

### 6.2 Text helpers

- `_is_safe_text(v)`: a str that encodes to UTF-8 (so no lone surrogates)
  and contains **no** C-category character [P1]. Tabs and newlines are
  therefore unsafe.
- `_optional_text_is_safe(v)`: a non-str is fine (True); a str must be
  `_is_safe_text`.
- `_clean_text(value, limit)` produces display text:
  ```python
  if not str: None
  collapsed = " ".join(value.split())          # P4
  if not collapsed: None
  if len(collapsed) > limit:                   # CODE POINTS (P2)
      budget = limit - 3                       # "…" is 3 UTF-8 bytes
      prefix = longest code-point prefix with utf8 bytes <= budget
      collapsed = prefix.rstrip() + "…"
  if utf8_len(collapsed) > limit (or encode error): None
  return collapsed
  ```
  A value that is within the character limit but over the byte limit
  returns **None**; it is not truncated.
- `_is_truncated(v, limit)`: for a str, collapse it, then
  `len > limit or bytes > limit`; an encode error counts as True. A
  non-str gives False.
- `_byte_overflow_inside_character_limit(v, limit)`: for a str, collapse
  it, then `len <= limit and bytes > limit`; an encode error counts as
  True. A non-str gives False.

### 6.3 Question helpers

- `recommended_index(options)`:
  - not a list, or empty → 0;
  - otherwise the first index whose dict option has a str label with
    `label.strip().lower().endswith("(recommended)")`;
  - else 0.
- `has_recommendation(options)`: any option carries that marker.
- `strip_recommended(label)`: `s = label.strip()`. If it ends with the
  marker (case-insensitive), drop the last 13 characters and `strip()`
  again.
- `first_question(tool_input)`: the one renderable question, or None.
  - `tool_input` must be a dict.
  - `questions` must be a list of exactly 1 element, which is a dict.
  - `options` must be a list with 1 ≤ len ≤ 255.
  - `question` must be a str.
  - A truthy `multiSelect` → None.
  - Every option must be a dict with a str `label`.
- `command_of(tool_input)`: `tool_input.command` if it is a str.
- `approvable_tool(tool_name, tool_input)`, the device-approval tier:
  1. The name must be a str; `n = name.strip().lower()`.
  2. `n in _APPROVABLE_TOOLS` → True.
  3. `n not in ("bash","shell")` → False.
  4. The command must be a non-empty str with no match of
     `_COMMAND_CHAINING`, and `_APPROVABLE_COMMAND.match(command)` must
     succeed.

### 6.4 Views

**`question_view(question, reveal) -> (view, index)`**:
```python
options = question["options"]; marked = has_recommendation(options); index = recommended_index(options)
label = strip_recommended(options[index]["label"]); description = options[index].get("description")
view = {"kind": "question", "options_total": len(options), "marked": marked}
if reveal:
    view["prompt"]   = _clean_text(question.get("question"), 96)
    view["title"]    = _clean_text(label, 64)
    view["subtitle"] = _clean_text(description, 64)     # non-str -> None
    view["can_approve"] = marked and bool(prompt) and bool(title) and \
        not _is_truncated(question["question"], 96) and not _is_truncated(label, 64) and \
        not _is_truncated(description, 64)
else:
    view["can_approve"] = False
return view, index            # index is 0 for an unmarked question
```
- Unmarked questions are alert-only: the panel must never invent a
  recommendation.
- `marked` is published even with detail off.

**`approval_view(tool_name, tool_input, reveal)`**:
```python
command = command_of(tool_input); subject = command or ""
view = {"kind": "approval", "tool": _clean_text(tool_name, 24)}      # may be None
if reveal:
    view["title"]    = _clean_text(subject, 64) or view["tool"]
    view["subtitle"] = _clean_text(tool_input.get("description") if dict else None, 64)
    readable = bool(command) and not _is_truncated(command, 64)
    view["can_approve"] = readable and not _is_truncated(description, 64) and approvable_tool(tool_name, tool_input)
else:
    view["can_approve"] = False
```
- A truncated title carries `…` and therefore can_approve is false.
- `Read`, `Glob` and similar tools without a command have
  `readable == False`. So from the Claude hook they are *not*
  device-approvable in practice. The tier function says "approvable" (the
  tests pin only `approvable_tool("Read", {}) is True`), but the view
  requires a readable command. That is emergent behavior, not a pinned
  test; port it as-is.

**`_claude_display_fits(kind, event, reveal)`** rejects text that the
character count accepts but the byte count cannot fit:
- question: if not `reveal`, return True. Otherwise the question must be
  renderable, and none of these may be a byte overflow inside the
  character limit: prompt (96), `strip_recommended(selected.label)` (64),
  `selected.description` (64), where `selected` is the recommended option.
- approval:
  1. Reject a tool_name byte overflow (24) even when not revealing.
  2. If not revealing, return True.
  3. Otherwise check command (64) and description (64).

### 6.5 Claude hook responses: `hook_response(kind, verdict, event, option_index=0)`

| Case | Body |
|---|---|
| verdict `leave_it` | `None` (no decision) |
| question + deny | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied from VibePulse"}}` |
| question + approve | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions": <event.tool_input.questions verbatim>, "answers": {<question text verbatim>: <options[i].label verbatim, INCLUDING any "(Recommended)" marker>}}}}`; None if the question is no longer renderable or `i` is out of range |
| approval + approve | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` |
| approval + deny | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from VibePulse"}}}` |
| other kind | None |

"No decision" on the wire is **HTTP 200 with `Content-Length: 0` and no
body**. Claude Code then shows its own terminal prompt.

### 6.6 Canonical view digest and signatures

```python
def view_bytes(view):     # TypeError unless a Mapping
    stable = {k: v for k, v in view.items() if k not in ("expires_in_ms", "view_sha256")}
    return json.dumps(stable, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")   # P6b
def view_digest(view): return sha256(view_bytes(view)).hexdigest()
```
- Test vector: `{"provider":"claude","title":"Fråga"}` → bytes
  `{"provider":"claude","title":"Fråga"}` (raw UTF-8 `å`) → sha256
  `c7767b91a147d7b07a6b174b4b26544905c1419678e8c6a8f05dc3e83d06e2b2`.
- Because the digest excludes the countdown and the digest field itself,
  `view_digest(pending_public())` reproduces the stored digest.

**v1** (legacy Claude panel, and **panic**):
- `sign_answer(secret, rid, verdict, ts)` = hex
  `HMAC-SHA256(key = secret.encode("utf-8"), msg = f"{rid}|{verdict}|{int(ts)}".encode("utf-8"))`.
  The key is the device-key **string's bytes**, not the hex-decoded key.
- `verify_answer(secret, rid, verdict, ts, mac, now_wall)`:
  1. False if the secret is empty or the mac is not a str.
  2. `stamp = int(ts)` [P8]; TypeError/ValueError → False.
  3. False if `abs(now_wall - stamp) > 90`.
  4. `hmac.compare_digest(expected, mac)`.
- Port notes:
  - Python raises (it does not return False) for
    `ts = Infinity/NaN` (OverflowError/ValueError), and a non-ASCII `mac`
    str makes `compare_digest` raise TypeError. That surfaces as an
    unhandled handler exception.
  - The Swift port should return False in those cases.
  - v1 also accepts int-like strings and floats (truncated) as `ts`.

**v2** (the default):
- `sign_answer_v2(secret, provider, rid, digest, verdict, ts)`:
  - HMAC over `f"v2|{provider}|{rid}|{digest}|{verdict}|{ts}"` (UTF-8),
    with the same key.
  - Raises `ValueError("invalid v2 answer")` if the fields are invalid or
    the secret is empty.
- `_v2_fields` requires:
  - the provider to be exactly `"claude"` or `"codex"` (or the enum);
  - `request_id` to be a non-empty str;
  - the digest to fullmatch `^[0-9a-f]{64}$`;
  - the verdict to be in VERDICTS;
  - `ts` to have **`type(ts) is int`** (bool and float are rejected) and
    to satisfy `0 ≤ ts ≤ 2^63−1`.
- `verify_answer_v2(..., mac, now_wall)`:
  1. The fields must be valid and the secret a non-empty str.
  2. `mac` must be a str that fullmatches `^[0-9a-f]{64}$`.
  3. `now_wall` must be a finite int or float, and not a bool.
  4. `abs(now_wall - ts) ≤ 90`.
  5. `compare_digest`.
- Strictness tests reject: a float ts, a bool ts, `10**1000`, an uppercase
  provider, an uppercase digest, and an uppercase mac.

**`response_fits(payload)`**: `len(json.dumps(payload).encode()) ≤ 3584`,
in wire format [P6a]. A TypeError/ValueError gives False.

### 6.7 The normalized boundary (provider-neutral)

**`_normalized_view(kind, raw) -> immutable Mapping|None`**:
1. `raw` must be a dict. Its keys must be a subset of the kind's allowed
   fields, `raw.kind == kind`, and `type(raw.can_approve) is bool`.
2. Drop the `None` values.
3. Each text field present (prompt 96, title 64, subtitle 64, tool 24) must
   be `_is_safe_text`, non-empty, and within its **byte** limit.
4. Question: `options_total` must be an int (not bool) in 1..255 and
   `marked` must be a bool. `can_approve` requires `marked`, a truthy
   `prompt` and a truthy `title`.
5. Approval: `can_approve` requires `title`.
6. Return a read-only mapping.

**`_codex_question_is_normalized(normalized, view, recommended)`**:
1. The keys of `normalized` must be exactly
   `{provider, kind, project, session_id, turn_id, options, recommended_index, view}`.
2. `options` must be a list of 2 or 3 items with
   `view.options_total == len`.
3. Each option:
   - is a dict whose keys ⊆ `{label, description, recommended}`;
   - has a `label` that is safe and non-empty;
   - if it has a `description`, it is safe and non-empty;
   - if it has `recommended`, it is a bool.
   - The indices with `recommended is True` are collected as `marked`.
4. Constraints:
   - `len(marked) ≤ 1`;
   - `recommended == (marked[0] if len==1 else None)`;
   - `view.marked == (recommended is not None)`;
   - `view.can_approve == (recommended is not None)`.
5. If recommended: `view.title == options[r].label` and
   `view.subtitle == options[r].get("description")`. With None dropped
   from the frozen view, a missing subtitle equals a missing description.

**`_codex_approval_is_normalized(normalized, recommended, reveal)`**:
1. The keys must be exactly
   `{provider, kind, project, session_id, turn_id, event, recommended_index, view}`.
2. `recommended is None`.
3. `event` is a dict with:
   - `hook_event_name == "PermissionRequest"`;
   - `session_id` and `turn_id` equal to the outer values;
   - `cwd` and `tool_name` strs;
   - `tool_input` a dict.
4. `_is_safe_text(cwd)` and `sanitize_project(cwd) == project`.
5. Finally, **re-run `normalize_codex_permission(event, reveal=reveal)`
   and require deep equality with `normalized`**. An exception gives False.
   This check means a forged, more-permissive view can never be parked.

**Relay boundary** (the relay transport lives elsewhere; these are the
store's contracts):
```python
@dataclass(frozen=True) class RelayPublishJob:  request_id: str; challenge: bytes(32); view_bytes: bytes;
                                                view_sha256: bytes(32 raw); expires_at: int (ceil wall s);
                                                provider: str; can_approve: bool
@dataclass(frozen=True) class RelayResolution:  request_id: str; challenge: bytes(32); view_sha256: bytes(32);
                                                verdict: "approve"|"deny"|"terminal"|"panic"; mac: bytes(32)
class InteractionRelayListener(Protocol): on_park(job) -> None; on_remove(request_id, reason) -> None
```
The removal reasons are `resolved`, `timeout`, `abandoned`, `panic`,
`terminal` and `provider-mismatch`.

### 6.8 `InteractionStore(secret="", reveal_detail=False, now=monotonic, wall=time.time, audit=None, random_bytes=token_bytes, relay_listener=None, relay_random_bytes=token_bytes)`

**State.** One `threading.Lock` and no I/O. The store holds:
- `_pending: {request_id: _Pending}`;
- `_next_arrival_index`;
- `_issued_ids` (a set) and `_issued_order` (a deque);
- `_protected_ids` (a set of currently-parked ids);
- `_relay_notifications` (a deque of `(rid, reason)`);
- `_relay_listener`, which can be swapped via `set_relay_listener(l)`
  under the lock.

**`_Pending` fields:**
- `request_id` and `provider` (the enum);
- `kind`;
- `event` (a deep copy of the raw Claude event, or None for Codex);
- `view` (the frozen mapping);
- `recommended_index`;
- `view_sha256` (hex);
- `requires_v2`;
- `project`;
- `session_key`: the first 16 hex characters of
  sha256(session_id surrogatepass), or None;
- `hold_ms`, `created_at` (monotonic) and `arrival_index`;
- `expires_at`: monotonic `created_at + duration`;
- `relay_job`;
- `done`: a `threading.Event`;
- `verdict`: None or a str.

**Id minting** (`_mint_id_locked`):
1. While `len(issued) ≥ 256`, rotate through `issued_order` to find the
   first id that is not protected, and discard it. If every id is
   protected, return **None**.
2. Up to 32 attempts:
   - `raw = random_bytes(16)`. An exception, or a result that is not
     16 bytes → None.
   - `rid = base64.urlsafe_b64encode(raw).rstrip("=")`, which is always
     22 characters of `[A-Za-z0-9_-]`.
   - If it is unused, record it and return it.
3. After 32 collisions → None.

Vector: `bytes(range(16))` → `"AAECAwQFBgcICQoLDA0ODw"`. Ids are never
reused within the history. A second tap can therefore never land on a
later prompt.

**Parking entry points:**
- `park(kind, event, hold_s)` → `_park_claude(..., requires_v2=True)`. This
  is the default Claude path.
- `park_legacy(kind, event, hold_s)` → `_park_claude(..., requires_v2=False)`.
  It is used only when `legacy_claude_panel_v1` is on.
- `park_normalized(normalized, hold_s)` → `_park_normalized(..., requires_v2=True)`.
  This is the Codex path. **Codex is never downgraded by legacy mode.**

**`_park_claude(kind, event, hold_s, requires_v2)`**. Each failure returns
None, which the handler turns into "no decision":
1. `kind` must be in KINDS and `event` a dict.
2. **The duplicate AskUserQuestion filter:** a kind of `approval` with
   `event.tool_name.strip().casefold() == "askuserquestion"` → None. The
   dedicated question hook owns it; the pending set is not touched.
3. `_claude_event_text_is_safe(kind, event)`:
   - `cwd` must pass `_optional_text_is_safe`.
   - Question: the question must be renderable, and every one of question
     text, header, and each option's label and description must pass
     `_optional_text_is_safe`.
   - Approval: tool_name, `tool_input.command` and
     `tool_input.description` must pass `_optional_text_is_safe`.
   - So a multi-line or tabbed command is never parked.
4. `_claude_display_fits(kind, event, self._reveal)`.
5. Build the view:
   - question: `question_view(first_question(tool_input), reveal)` gives
     `(view, idx)`;
   - approval: `approval_view(tool_name, tool_input, reveal)` with
     `idx=None`.
6. Call `_park_normalized({"provider":"claude","kind":kind,"project":sanitize_project(cwd),"event":event,"recommended_index":idx,"view":view}, hold_s, requires_v2)`.

**`_park_normalized(normalized, hold_s, requires_v2)`:**
1. `normalized` must be a dict. The provider must parse and `kind` must be
   in KINDS.
2. `view = _normalized_view(kind, normalized.view)` must not be None.
3. `project` must be None, or safe text that equals
   `sanitize_project(project)`, i.e. it is already a basename.
4. `recommended_index` must be None or an int (not bool) ≥ 0. A question
   also requires it to be `< options_total`. An approval requires None.
5. **Claude:**
   - The keys must be exactly
     `{provider, kind, project, event, recommended_index, view}`.
   - The raw event must be a dict that passes the text-safe check, with
     `sanitize_project(raw.cwd) == project`.
   - Recompute the expected view and index from the raw event with
     `self._reveal`. The frozen expected view must equal `view`, and the
     index must match.
   - `event = deepcopy(raw)`; `session_id = raw.session_id`.
6. **Codex:**
   - `session_id` and `turn_id` must be non-empty strs.
   - Question → `_codex_question_is_normalized(...)`; approval →
     `_codex_approval_is_normalized(...)`.
   - `event = None` (raw data stays private in the handler);
     `session_id = normalized.session_id`.
7. **Hold:**
   - Reject a bool.
   - `float(hold_s)`; an error → None.
   - It must be finite, `> 0` and `≤ 4294967.295`.
   - `duration = max(1.0, hold)`, so 0.5 becomes 1.0 s (1000 ms).
8. Take `now = now()` and `wall = wall()`.
   `challenge = relay_random_bytes(32)`; an exception or wrong length →
   None. `wall` must be a finite int or float, not a bool.
9. `relay_expiry = ceil(wall + duration)`, which must be in
   `(0, 0xFFFFFFFF]`. `hold_ms = int(duration * 1000)`, e.g.
   90.001 → 90001.
10. **Budget:** build a template
    `{"provider", "request_id": "A"*22, "project", "hold_ms"} ∪ view`,
    dropping None values. It must satisfy
    `0 < len(view_bytes(template)) ≤ 640` (canonical form [P6b]).
11. Under the lock: sweep. Then flush the relay notifications.
12. Under the lock:
    - if `len(_pending) ≥ 8` → None;
    - mint an id; if None → None;
    - `stable = {"provider", "request_id", "project", "hold_ms"} ∪ view`,
      None dropped;
    - `sb = view_bytes(stable)`; `digest = sha256(sb)`;
    - build the `RelayPublishJob(rid, challenge, sb, digest(raw), relay_expiry, provider, bool(view.can_approve))`;
    - `arrival_index++`;
    - create the `_Pending(..., view_sha256=digest.hex(), created_at=now, expires_at=now+duration)`;
    - insert it and protect its id.
13. Outside the lock: if `requires_v2`, call `listener.on_park(job)`
    (exceptions swallowed). Audit `"parked"`. Return the entry.

**`await_result(entry, is_alive=None) -> InteractionResult|None`**
(blocks the calling HTTP thread):
- If `is_alive` is None: `done.wait(max(0, expires_at - now()))`.
- Otherwise loop:
  1. `rem = expires_at - now()`; if `rem ≤ 0`, break.
  2. If `done.wait(min(2.0, rem))` returns true, break.
  3. If `not is_alive()`, then under the lock: pop the entry, unprotect
     it, and if it was present queue a remove with `"abandoned"`. Flush,
     audit `"abandoned"`, and return None.
- Then, under the lock: pop the entry if it is still present and unprotect
  it. If it was present and the verdict is None, queue `"timeout"`.
- Flush.
- If the verdict is None: audit `"timeout"` and return None.
- Otherwise return
  `InteractionResult(verdict, recommended_index if verdict == "approve" else None)`.

**`await_verdict(entry, is_alive=None) -> dict|None`** (Claude hook
adapter):
- If the entry's provider is not CLAUDE:
  1. Under the lock: pop it, unprotect it, and queue
     `"provider-mismatch"` if it was present.
  2. `done.set()`, flush, audit `"provider-mismatch"`, and return None.
- Otherwise `r = await_result(...)`. If `r` is None or `entry.event` is
  None → None. Else return
  `hook_response(kind, r.verdict, entry.event, r.option_index or 0)`.

**`resolve(request_id, verdict, ts, mac, provider=None, view_sha256=None) -> (ok, reason)`**
(the device answer):
1. If `request_id` is not a str or `verdict` is not in VERDICTS →
   `(False, "bad request")`.
2. If there is no secret → `(False, "device answers are not configured")`.
3. Under the lock: sweep, then `entry = pending.get(rid)`. Flush.
4. `uses_v2 = provider is not None or view_sha256 is not None`.
5. If the entry exists, `entry.requires_v2` is set, and provider or
   view_sha256 is None → `(False, "v2 verdict required")`.
6. If `uses_v2`:
   - if `verify_answer_v2(...)` fails → `(False, "signature rejected")`;
   - if the entry exists and either the provider does not match the entry
     or `not compare_digest(view_sha256, entry.view_sha256)` →
     `(False, "interaction binding rejected")`.

   Otherwise (v1):
   - if the entry requires v2 → `"v2 verdict required"`;
   - if `verify_answer` fails → `"signature rejected"`.
7. Under the lock: sweep, then take the entry again.
   - Missing → failure `"no such pending interaction"`. This covers
     already-answered, expired and unknown ids; the response is identical
     on purpose.
   - `verdict == "approve"` and not `view.can_approve` → failure
     `"this one has to be approved at the terminal"`.
   - Otherwise delete the entry, set its verdict, and queue `"resolved"`.
8. Outside the lock: `done.set()` for the accepted entry, then flush.
9. A failure returns `(False, failure)`. Otherwise audit
   `"resolved"(verdict)` and return `(True, "ok")`.

A rejected answer (bad signature or wrong binding) **never consumes** the
entry.

**`resolve_relay(result, verify) -> (accepted, reason)`**:
1. `result` must be a `RelayResolution` whose challenge, view_sha256 and
   mac are each exactly 32 bytes, whose verdict is in
   `{approve, deny, terminal, panic}`, and `verify` must be callable.
   Otherwise `(False, "bad request")`.
2. Under the lock: sweep, then look up the entry.
   - Missing → `"no such pending interaction"`.
   - A mismatch of `compare_digest(challenge, job.challenge)` or of
     `compare_digest(view_sha256, job.view_sha256)` →
     `"interaction binding rejected"`.
   - `verify(job, result)` is called **under the lock**. An exception
     counts as False → `"signature rejected"`.
   - `approve` with `not job.can_approve` →
     `"this one has to be approved at the terminal"`.
   - `panic`: the anchor must be a live, correctly bound entry. Every
     pending entry gets verdict `deny` and is queued with `"panic"`;
     return `(True, "panic")`.
   - Otherwise delete the entry and set its verdict (`terminal` becomes
     `leave_it`). Queue `"terminal"` or `"resolved"`; return
     `(True, "ok")`.
3. Outside the lock: `done.set()` for each completed entry, then flush.
   When accepted, audit `"relay-panic"` or `"relay-resolved"` for each
   entry with its verdict.

Concurrent direct and relay answers consume **exactly once** (test).

**`panic(ts, mac) -> (accepted, count)`**:
1. No secret → `(False, 0)`.
2. `verify_answer(secret, "panic", "deny", ts, mac, wall())` (v1) must
   hold, else `(False, 0)`.
3. `(True, deny_all())`.

A captured panic cannot be replayed as an approval.

**`deny_all() -> int`**:
1. Under the lock: take all entries, clear `_pending`, and queue `"panic"`
   for each (v2 entries only).
2. Outside the lock: for each entry set `verdict = "deny"`, call
   `done.set()`, and audit `"panic-denied"("deny")`.
3. Flush and return the count.

**`pending_public() -> dict|None`**, the one item the panel shows (oldest
first):
```python
with lock:
    sweep(now)
    if pending:
        e = min(pending.values(), key=(created_at, arrival_index))   # equal clocks -> arrival order
        payload = {"request_id": e.request_id, "project": e.project,
                   "expires_in_ms": max(0, int((e.expires_at - now) * 1000)),
                   "hold_ms": e.hold_ms}
        if e.requires_v2: payload["provider"] = e.provider.value
        payload.update(e.view)
        if e.requires_v2: payload["view_sha256"] = e.view_sha256
flush()
drop None values
if len(json.dumps(payload).encode()) > 640: return None      # WIRE format P6a (ASCII-escaped, spaced)
return payload
```

> Port note: the park-time budget uses the canonical compact UTF-8 form,
> but this gate uses the ASCII-escaped spaced form, which is larger for
> non-ASCII text (`é` becomes 6 bytes instead of 2). A near-limit
> international view can pass `park` and then be hidden here; it still
> times out normally. Keep both measurements exactly.

**Sweep** (`_sweep_locked(now)`): every entry with `expires_at ≤ now` is
popped, queued with `"timeout"` (v2 only), and gets `done.set()`. Its
verdict stays None.

**Relay notifications:**
- `_queue_relay_remove_locked` appends only for `requires_v2` entries.
- `_flush_relay_notifications`, under the lock, snapshots the listener and
  drains the queue. Outside the lock it calls `on_remove` for each item,
  swallowing exceptions. With no listener the items are discarded.
- `on_park` is likewise called outside the lock.

**Audit** (`_log(action, entry, verdict)`): calls
`audit(action, {"request_id", "provider", "kind", "tool", "project", "session", "verdict"})`,
swallowing exceptions.
- `tool` is `entry.event.get("tool_name")` for Claude, else
  `view.get("tool")`.
- `session` is the 16-hex session key.
- It never contains prompt or command text.
- In tokenserver: `log.info("interaction %s: %s", action, json.dumps(row, sort_keys=True))`.
- The actions are `parked`, `abandoned`, `timeout`, `provider-mismatch`,
  `resolved`, `relay-resolved`, `relay-panic` and `panic-denied`.

### 6.9 Pending item shapes

These are published as `pending` on `/api/agent-status`, in wire key
order.

v2 Claude question (detail on):
```json
{"request_id": "AAECAwQFBgcICQoLDA0ODw", "project": "bright-octopus", "expires_in_ms": 118000, "hold_ms": 120000,
 "provider": "claude", "kind": "question", "options_total": 3, "marked": true,
 "prompt": "Which one?", "title": "Option A", "subtitle": "desc", "can_approve": true,
 "view_sha256": "<64 hex>"}
```
- Approval views instead carry `"kind": "approval", "tool": "Bash", "title": "<command or tool>", "subtitle": ..., "can_approve": ...`.
- Codex question view key order is
  `kind, options_total, marked, prompt, can_approve[, title[, subtitle]]`.
- With detail off:
  - a Claude question is `{kind, options_total, marked, can_approve:false}`;
  - a Claude or Codex approval is `{kind, tool, can_approve:false}`;
  - a Codex question is `{kind, options_total, marked:false, can_approve:false}`.
- Legacy v1 entries omit `provider` and `view_sha256`.
- `project` is omitted when it is null.
- The digest invariant is `view_digest(pending) == pending["view_sha256"]`.

### 6.10 `read_device_key(repo_root=None) -> str|None`

The first hit wins:
1. Env `VIBEPULSE_DEVICE_KEY`, then `TK_VIBEPULSE_DEVICE_KEY`, if non-empty
   after strip (the stripped value is returned).
2. `~/.vibepulse-device-key`, read as UTF-8 and stripped, if non-empty. An
   OSError is ignored. A UnicodeDecodeError would propagate in Python; the
   port should ignore it.
3. `<repo_root>/secrets.h` (the default root is the repository root, i.e.
   `interactions.py`'s `parents[2]`), read as UTF-8 with errors ignored.
   Take the first match of `#\s*define\s+TK_VIBEPULSE_DEVICE_KEY\s+"([^"]+)"`,
   group 1 stripped.
4. None.

There is no format validation here. The relay requires 64 hex, but
answers only need a non-empty value. **Never log or copy the key.**

---

## 7. `codex_interactions`

### 7.1 Text validity (no cleanup, no truncation)

- `_is_control_free(v)`: UTF-8 encodable, with no C-category characters.
- `_text_is_valid(v, max_bytes=None)`: a str, `v.strip()` non-empty,
  control-free, and UTF-8 length ≤ max if given. **The value is kept
  verbatim**: not collapsed and not stripped.

### 7.2 `normalize_codex_question(payload, *, cwd, session_id, turn_id) -> dict|None`

1. `identity = _identity(cwd, session_id, turn_id)`. All three must pass
   `_text_is_valid`, giving
   `{"project": sanitize_project(cwd), "session_id", "turn_id"}`.
   `payload` must be a dict.
2. The keys must be a subset of `{question, header, options}`, and
   `question` and `options` are required.
3. `question` is valid with ≤ 96 bytes. `header`, if present, is valid with
   ≤ 64 bytes. The header is validated but never displayed or stored.
4. `options` is a list of **2 or 3** items. Each item is a dict whose keys
   are a subset of `{label, description, recommended}` and include
   `label`:
   - `label` is valid with ≤ 64 bytes;
   - `description`, if present, is valid with ≤ 64 bytes;
   - `recommended`, if present, must be a bool; a second `true` → None.
   - Only the present keys are copied.
5. Build the view:
   ```json
   {"kind": "question", "options_total": n, "marked": r is not None, "prompt": question, "can_approve": r is not None}
   ```
   If `r` is set, add `"title": options[r].label` and
   `"subtitle": options[r].get("description")` (which may be None).
6. Return
   `{"provider":"codex","kind":"question", **identity, "options": [...], "recommended_index": r, "view": view}`.

There is no guessing: an unmarked question gets `recommended_index=None`
and is alert-only.

### 7.3 `normalize_codex_permission(event, *, reveal) -> dict|None`

1. `event` must be a dict with `hook_event_name == "PermissionRequest"`.
2. `session_id`, `turn_id`, `cwd` and `tool_name` must each pass
   `_text_is_valid`, and `tool_input` must be a dict. Extra top-level keys
   are ignored and dropped.
3. Take `identity`. `tool_input = dict(event.tool_input)`, a shallow copy
   that keeps every key privately.
4. If `command` or `description` is a str, it must be control-free, else
   None.
5. `view = approval_view(tool_name, tool_input, reveal)`.
6. Gate approval:
   ```python
   can = approvable_tool(tool_name, tool_input)
   if tool_name.strip().casefold() in {"bash","shell"}: can = can and _codex_shell_command_is_safe(tool_input.get("command"))
   view["can_approve"] = bool(view.get("can_approve")) and can
   ```
7. Return
   `{"provider":"codex","kind":"approval", **identity, "event": {"hook_event_name":"PermissionRequest","session_id","turn_id","cwd","tool_name","tool_input"}, "recommended_index": None, "view": view}`.

### 7.4 `_codex_shell_command_is_safe(command)`

`tokens = shlex.split(command)` (POSIX rules; a ValueError such as an
unbalanced quote → False). An empty token list → False.

| First token | Rule |
|---|---|
| `./test/run.sh` (exact, case-sensitive) | safe only if it is the only token |
| `make`, `ninja` (casefold) | every argument, casefolded, is in `{all, build, test, check}` |
| `cmake` | `args[0].casefold()=="--build"` and `args[1]` does not start with `-`. Then only: `--verbose`; `--parallel`/`-j` optionally followed by a non-flag that must be `isdigit()`; `--config X` (X required, not a flag); `--target T…` (≥ 1, each in the targets set); `--target=T` (T in the set, compared after casefold of the whole argument). Anything else is unsafe |
| `npm` | `test` followed by flags, or `run test` / `run build` followed by flags; every flag (casefold) is in `{--silent, --if-present, --ignore-scripts}` |
| `git` | `status` + flags ⊆ `{--short, -s, --branch, -b, --porcelain}`; `branch` with no args or exactly `--show-current`; `log`/`show` where each arg is a non-flag or in `{--oneline, --decorate, --graph, --stat, --patch, --no-color}`; `diff` where each flag before `--` is in `{--stat, --name-only, --name-status, --check, --no-color, --cached, --staged}` and anything goes after `--`; anything else is unsafe |
| `ls`, `cat`, `head`, `tail`, `wc`, `grep`, `rg`, `pytest`, `ctest` | no argument starts with `-` |
| `python`, `python3` | `args[:2] == ["-m","unittest"]` and the rest are plain |
| `cargo` | `args[0]` (casefold) is `test` or `build`, and the rest are plain |
| `go` | `args[0]` is `test`, and the rest are plain |
| `idf.py` | exactly `["build"]` (casefold) |
| anything else | unsafe |

The families are compared with casefold, except `./test/run.sh`.

The tests pin these:
- **Unsafe:** `make -j4`, `ninja -C build`, `./TEST/RUN.SH`,
  `make CC='touch /tmp/pwn' all`, and every chaining metacharacter.
  Chaining is also blocked earlier by `approvable_tool`.
- **Safe:** `git show install`, `npm run build --silent`.

### 7.5 Results

- `codex_permission_response(verdict)`:
  - `leave_it` → None;
  - `approve` → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`;
  - `deny` → the same with `{"behavior":"deny","message":"Denied from VibePulse"}`;
  - anything else raises `ValueError("unsupported permission verdict")`.
- `codex_question_result(verdict, normalized)`:
  - If `verdict == "approve"` and `normalized.recommended_index` is not
    None → `{"status":"answered","option_index":i,"answer":options[i].label}`.
  - Otherwise → `{"status":"computer","reason":verdict}`, where the reason
    is `deny` or `leave_it`.

---

## 8. HTTP interaction surface (in `tokenserver.py`)

### 8.1 Server model

- `BoundedThreadingHTTPServer` (ThreadingHTTPServer, daemon threads) is
  bound to `0.0.0.0:8737` (the default).
- It runs thread-per-request with `HTTP_MAX_WORKERS = 32`, enforced by a
  BoundedSemaphore. Past that, the server sets a 0.05 s timeout, drains at
  most 8 KiB of headers, and replies with the raw bytes
  `HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`.
- **Each parked hook occupies a worker for up to its hold time.** At most
  8 can be parked, since further parks are refused as "no decision".
- The responses are HTTP/1.0 (Python default), one request per connection.
- Access logging is suppressed.

### 8.2 `do_POST` routing (exact order)

- `claude_route` means the path is exactly `/api/hook/question` or
  `/api/hook/permission`.
- `codex_route` means the path is exactly `/api/codex/question` or
  `/api/codex/permission`.
- `answer_route` means the path starts with `/api/interaction/`.
- `panic_route` means the path is exactly `/api/panic`.

1. `claude_route` and (no store or `claude_interactions` off) → **404**
   `{"error": "interactions are not enabled"}`.
2. `codex_route` and (no store or `codex_interactions` off) → **404**,
   same body.
3. For a claude or codex route:
   - The client IP must be loopback (IPv4-mapped IPv6 is unwrapped; the
     test is `is_loopback`, i.e. 127/8 or ::1). Otherwise **403**
     `{"error": "hooks must be local"}` and a log warning.
   - Then there must be exactly one `Host` header that is a valid loopback
     authority, and **no** `Origin` header at all. Otherwise **403**
     `{"error": "hook ingress rejected"}`.
4. `answer_route` or `panic_route` with no store → **404** "not enabled".
   Answer and panic routes are **not** loopback-restricted, because the
   device posts them over the LAN.
5. Any of the four route kinds without an acceptable Content-Type → **415**
   `{"error": "application/json required"}`. The Content-Type must be
   exactly one header that fullmatches (case-insensitive, after strip)
   `application/json(?:\s*;\s*charset\s*=\s*(?:utf-8|"utf-8"))?`.
6. Dispatch:
   - `/api/hook/question` → `_handle_hook("question")`;
   - `/api/hook/permission` → `_handle_hook("approval")`;
   - `/api/codex/question` and `/api/codex/permission` → their handlers;
   - else, no store → 404 "not enabled";
   - answer route → `_handle_answer(path[len("/api/interaction/"):])`.
     The id is the **raw** remainder: not percent-decoded, and any query
     string is included.
   - panic route → `_handle_panic()`;
   - else **404** `{"error": "not found"}`.

**Valid loopback Host** (`_has_valid_loopback_host`):
- If it starts with `[`: it must fullmatch `\[([^\]]+)\](?::([0-9]{1,5}))?`,
  and the inner address must parse as IPv6 equal to `::1`.
- Otherwise:
  - more than one `:` → invalid;
  - if it contains `:`, split with `rpartition(":")`; an empty port →
    invalid;
  - the host, lowercased, must be `localhost` or `localhost.`, or must
    parse as an **IPv4** loopback address (a strict dotted quad, e.g.
    `127.0.0.1` or `127.8.9.10`; not `127.1`).
- If a port is present, `int(port)` must equal the bound server port, so
  `08737` is accepted.

### 8.3 Body handling

- `_read_json_body(limit=64 KiB)`:
  1. `Content-Length` must parse as an int (else None) and be in
     `(0, limit]`.
  2. Set the socket timeout to `JSON_BODY_TIMEOUT_S = 2.0` and read
     exactly that many bytes. Restore the previous timeout. A short read
     or socket error → None.
  3. Mark the body as consumed.
  4. `json.loads(raw)` [P7]. JSONDecodeError, UnicodeDecodeError,
     ValueError (including huge ints) and RecursionError → None.
- **Drain before any response** (`_drain_request_body`, once per request):
  - If the body was not consumed, read and discard up to
    `min(Content-Length, REQUEST_DRAIN_LIMIT = 64 KiB)` bytes in reads of
    ≤ 4096 bytes.
  - This is bounded by a total deadline of
    `REQUEST_DRAIN_TIMEOUT_S = 0.05 s` and the same socket timeout.
  - It prevents Windows WSAECONNABORTED on early 403/404/415 responses.
    The drained bytes are never parsed or logged.
- `_send(code, obj)`: drain, then the status line, then
  `Content-Type: application/json` and `Content-Length`, then the body in
  wire format [P6a].
- `_send_no_decision()`: drain, then 200 with `Content-Length: 0` only
  (no content type, no body).

### 8.4 Handlers

**`_handle_hook(kind)`** (Claude HTTP hooks):
1. `event = _read_json_body()`. If it is not a dict → no decision.
2. Park with `store.park_legacy` if `legacy_claude_panel_v1`, else
   `store.park`, passing `interaction_timeout_s`. None → no decision.
3. `body = store.await_verdict(entry, is_alive=lambda: not _hook_client_gone())`.
   An exception is logged and gives `body=None`.
4. None → no decision. Otherwise 200 with the JSON body. Write errors are
   ignored.

**`_hook_client_gone()`**: `select([conn], [], [], 0)`.
- Not readable → False (alive).
- Readable → `conn.recv(1, MSG_PEEK) == b""`, which means gone.
- An OSError or ValueError → True.
- The body has been fully read before this, so readable means EOF.

**`_handle_codex_question()`** (from the Codex MCP adapter):
1. The body must be a dict whose keys include `{cwd, session_id, turn_id}`
   and `{question, options}`, and are a subset of those plus `header`.
   Otherwise 200 `{"status":"computer","reason":"invalid"}`.
2. Normalize (§7.2). None → `invalid`.
3. If `interaction_detail` is off, replace:
   - `options` with the options minus their `recommended` keys;
   - `recommended_index` with None;
   - `view` with `{"kind":"question","options_total":n,"marked":false,"can_approve":false}`.
4. `store.park_normalized(normalized, timeout)`. None → reason
   `unavailable`.
5. `result = store.await_result(entry, is_alive=...)`; an exception is
   logged and gives None.
6. If `result` is None: reason `disconnected` if the client is gone, else
   `timeout`. Otherwise 200 with `codex_question_result(result.verdict, normalized)`.

**`_handle_codex_permission()`** (from the Codex PermissionRequest hook):
1. `normalized = normalize_codex_permission(body, reveal=interaction_detail)`.
   None → no decision.
2. `park_normalized`; None → no decision.
3. `await_result`; an exception gives None.
4. `body = codex_permission_response(verdict) if result else None`. None →
   no decision, otherwise 200 with the JSON.

**`_handle_answer(request_id)`** (device, LAN):
1. The body limit is **4096**. If the body is not a dict → **400**
   `{"ok": false, "reason": "bad request"}`.
2. `ok, reason = store.resolve(rid, body.get("verdict"), body.get("ts"), body.get("hmac"), provider=body.get("provider"), view_sha256=body.get("view_sha256"))`.
3. Respond **200** if ok, else **409**, with `{"ok": ok, "reason": reason}`.

The request bodies:
- v2: `{"provider": "claude|codex", "view_sha256": "<hex64>", "verdict": "approve|deny|leave_it", "ts": <int epoch s>, "hmac": "<hex64>"}`.
- v1 legacy: `{"verdict", "ts", "hmac"}`.

**`_handle_panic()`**:
1. The body limit is 4096. Not a dict → 400 `bad request`.
2. `panic(body.ts, body.hmac)`. If it is not accepted → **409**
   `{"ok": false, "reason": "signature rejected"}`. This also covers the
   no-secret case.
3. Otherwise log a warning and respond **200**
   `{"ok": true, "denied": n}`.

The panic HMAC is v1: `HMAC(key, "panic|deny|<ts>")`.

### 8.5 Configuration

**`_configure_interactions(args)`:**
- Sets the Handler flags `claude_interactions`, `codex_interactions`,
  `interaction_detail` and `legacy_claude_panel_v1`.
- `interaction_timeout_s = max(5.0, --interaction-timeout)`, where the CLI
  default is 120.
- A store is created **only if** Claude or Codex interactions are on:
  `InteractionStore(secret=read_device_key() or "", reveal_detail=detail, audit=<log.info>)`.
  With no key, parks still work but every answer gets
  `"device answers are not configured"`.
- The saved config is `state_dir()/config.json`, owned by
  `vibepulse_config` (outside this spec). Its fields include
  `claude_interactions`, `codex_interactions`, `interaction_detail`,
  `interaction_relay`, `agent_status_relay`, `interaction_relay_url` and
  `interaction_mailbox`.
- The matching CLI flags are `--claude-interactions` (with `--interactions`
  as a deprecated Claude-only alias), `--codex-interactions`,
  `--interaction-detail`, `--legacy-claude-panel-v1`,
  `--interaction-relay` and `--agent-status-relay`. Everything is off by
  default.

**Relay** (`_configure_interaction_relay`, details belong to the relay
spec). It needs:
- a 64-hex device key;
- the relay URL;
- the mailbox (`vp_[A-Za-z0-9_-]{16}`);
- a Mac token, from env `VIBEPULSE_INTERACTION_MAC_TOKEN` or
  `~/.vibepulse-interaction-relay-token`. The file must be mode 0600 and
  not a symlink, and the value is a 43-character base64url encoding of
  32 bytes.

The relay attaches through `store.set_relay_listener`. Its status is
`off`, `disabled` (with a reason) or `ready`.

**`GET /` diagnostics** (never parsed by the panel):
```json
"interactions": {"claude": bool, "codex": bool, "detail": bool, "legacyClaudePanelV1": bool,
                 "relay": {"status": "off|disabled|ready"[, "reason": str]},
                 "agentStatusRelay": {"status": ...[, "reason": str]},
                 "panel": {"status":"waiting"} | {"status":"ready|stale","ageS":int,"route":str,"httpStallRecoveryBoot":bool},
                 "transport": "lan+encrypted-relay" | "lan"},
"claudeStatusline": {"status": "...", "ageS": int|null, "claudeCodeVersion": str|null, "bridged": bool, "account": "assumed-single"}
```

### 8.6 Client-side counterparts (contract only)

**Claude Code hooks** are configured manually in `settings.json`, per
`docs/agent-setup.md`. **No installer writes them.**
```json
{"hooks": {
  "PreToolUse":        [{"matcher": "AskUserQuestion", "hooks": [{"type": "http", "url": "http://127.0.0.1:8737/api/hook/question",   "timeout": 120, "statusMessage": "Waiting for VibePulse…"}]}],
  "PermissionRequest": [{"matcher": ".*",              "hooks": [{"type": "http", "url": "http://127.0.0.1:8737/api/hook/permission", "timeout": 120, "statusMessage": "Waiting for VibePulse…"}]}]}}
```
- Claude Code refuses HTTP hooks to LAN addresses, hence the
  loopback-in/LAN-out split.
- The broad permission hook may resend `AskUserQuestion`. The server
  filter in §6.8 step 2 drops it.

**Codex plugin** (`.agents/plugins/plugins/vibepulse/`), installed through
the Codex CLI (§10.3):
- `hooks/hooks.json`:
  - `SessionStart` (matcher `startup|resume|clear|compact`) runs
    `python3 "$PLUGIN_ROOT/scripts/session_start.py"` (Windows:
    `py -3 …`) with a 3 s timeout and `additionalContextLimit` 1800.
  - `PermissionRequest` (matcher `*`) runs `scripts/permission_hook.py`
    with a timeout of 125 and the status message
    `Waiting for VibePulse or this computer`.
- `permission_hook.py`:
  1. Reads ≤ 64 KiB of stdin as strict JSON; it must be a dict.
  2. Port = `VIBEPULSE_PORT` (decimal, 1–65535) or 8737.
  3. POSTs the event verbatim to `http://127.0.0.1:<port>/api/codex/permission`
     with a connect timeout of 0.75 s and a read timeout of 125 s.
  4. Writes the result to stdout only if its shape is exactly
     `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
     or `…{"behavior":"deny","message":<clean ≤ 1024 B>}`.
  5. Always exits 0 and stays silent on error.
- `mcp_server.py` is a stdio MCP server whose tool POSTs to
  `/api/codex/question` with the same timeouts. It maps
  `status: answered|computer`. The Codex MCP `tool_timeout_sec = 130` is
  set by `tools/codex_mcp_timeout.py` in `[mcp_servers.vibepulse]` of
  `config.toml`.
- **Timeout ladder:** server hold 120 s < client read 125 s < Codex hook
  125 s < MCP tool 130 s. The server always answers first, with "no
  decision" or `timeout`.

---

## 9. `statusline_bridge` — Claude Code statusLine → quota sample

### 9.1 Constants

| Name | Value |
|---|---|
| `SAMPLE_NAME` | `claude-statusline-quota.json` |
| `CONFIG_NAME` | `claude-statusline-bridge.json` |
| `LOCK_NAME` | `claude-statusline-quota.lock` |
| `SAMPLE_VERSION` | 1 |
| `CONFIG_VERSION` | 1 |
| `ACCOUNT_KEY` | `"single"` |
| `WINDOWS` | `("five_hour", "seven_day")` |
| `RESET_SLACK_S` | 900 |
| `WINDOW_HORIZON_S` | five_hour 18900 (5 h + 15 min), seven_day 691200 (8 d) |
| `STDIN_MAX_BYTES` | 262144 (parse cap) |
| `STDIN_FORWARD_MAX_BYTES` | 8388608 (read and forward cap) |
| `SAMPLE_MAX_BYTES` | 65536 |
| `CONFIG_MAX_BYTES` | 65536 |
| `VERSION_MAX_CHARS` | 64 |
| `LOCK_WAIT_S` | 0.5 |
| `LOCK_RETRY_S` | 0.05 |
| `FRESH_S` | 900 (shared with tokenserver and the doctor) |
| `CHAINED_TIMEOUT_S` | 10.0 |

**Paths:**
- `state_dir()` is `~/Library/Application Support/VibePulse` on macOS, and
  `%LOCALAPPDATA%\VibePulse` on Windows (falling back to
  `~/AppData/Local/VibePulse`).
- `sample_path(dir)` is `(dir or state_dir())/SAMPLE_NAME`, and
  `config_path(dir)` likewise with `CONFIG_NAME`.
- The lock file is `sample_path.with_name(LOCK_NAME)`.
- `config_dir_key(dir)` is `sha256(str(Path(dir).expanduser().resolve()).encode()).hexdigest()[:16]`.
  `resolve()` follows symlinks, which makes the key path-independent
  (tests).
- `claude_config_dir(env)` is `Path(env["CLAUDE_CONFIG_DIR"]).expanduser()`
  if that is non-empty, else `~/.claude`.

### 9.2 Parsing stdin (`parse_payload(raw, now:int)`)

Failures raise `RejectedPayload`, which is caught by the caller:
1. `len(raw) > 256 KiB` → rejected.
2. Strict UTF-8 plus `json.loads`; an error → rejected. The value must be
   an object.
3. `limits = payload.get("rate_limits")`:
   - None or absent → no windows. That is **not** a rejection; it covers
     session start, the free tier and API-key sessions.
   - A non-dict → rejected.
   - Otherwise, for each name in WINDOWS that is **present**,
     `_validate_window(name, value, now)`.
4. `_validate_window`:
   - The value must be a dict.
   - `used_percentage` must be a finite number (int or float, not bool;
     an int too large for a float counts as non-finite) with
     `0 ≤ pct ≤ 100`.
   - `resets_at` must be a finite number with an integral value
     (`int(x) == x`), `> now` and `≤ now + horizon[name]`.
   - Any failure rejects the **whole payload**.
   - The result is `{"pct": round(float(pct), 1) [P10], "resets_at": int(resets_at)}`.
5. `version = payload.version` if it is a str of 1–64 code points and
   `isprintable()` (no C* or Z* characters except space); else None.
6. Return `{"windows": {...present, valid...}, "version": v|None}`.

### 9.3 Stored document and validity

The sample file `claude-statusline-quota.json` is written compact, sorted
and ASCII [P6c]:
```json
{"accounts":{"single":{"claude_code_version":"2.1.267","five_hour":{"at":1790000000,"pct":42.0,"resets_at":1790010000,"seen":1790000500},"seven_day":{...}}},"v":1}
```
- `_well_formed_window(w)`:
  - a dict with `pct` a finite number in 0..100;
  - `resets_at` a finite number with an integral value;
  - `at` and `seen` finite numbers.
- `_valid_stored_window(w, now, name)` is well-formed and also has
  `now < resets_at ≤ now + horizon`.
- `_well_formed_document(d)`:
  - a dict with `v == 1` and `accounts` a dict;
  - every entry is a dict;
  - every present window is well-formed;
  - `claude_code_version` is a str when present.

An **expired** window is not corruption.

### 9.4 Merge (`merge_entry(stored, observed, now)`, pure)

For each window name:
- `old` = the stored window if it is valid (still running), else None.
- `new` = the observed window, or None.

| Condition | Result |
|---|---|
| `new is None` | keep `old` if present (an absent window is **no observation**; it holds until its reset) |
| `old is None`, or `new.resets_at > old.resets_at`, or (same reset and `new.pct > old.pct`) | `{pct, resets_at, at: now, seen: now}` |
| same reset and `new.pct ≤ old.pct` (a replay) | `old` with `seen = now` (value and `at` stand) |
| `new.resets_at < old.resets_at` (a superseded cached window) | `old` unchanged (it does not vouch for freshness) |

Then the version is `observed.version`, else
`stored.claude_code_version`. If it is a non-empty str, store the first
64 characters as `claude_code_version`.

### 9.5 Files, lock, record

- **`_read_bounded_json(path, limit)`**: `stat` first; a size over the
  limit raises `ValueError`. Read the bytes, strict UTF-8, `json.loads`.
  A decode error raises `ValueError(<ErrorName>)`; FileNotFoundError and
  OSError propagate.
- **`load_sample(path)`** (the writer side):
  - missing → `{}`;
  - ValueError → `quarantine_corrupt(path, reason)` and `{}`;
  - OSError → **None**, meaning unreadable, so do not write;
  - not well-formed → quarantine with `"not the v1 sample shape"` and `{}`.
- **`peek_sample(path)`** (the reader side; never quarantines) returns
  `("missing", None)`, `("invalid", None)` (a ValueError or wrong shape),
  `("unreadable", None)` or `("ok", doc)`.
- **`quarantine_corrupt(path, reason)`** (`state_files`):
  1. `stamp = UTC now "%Y%m%dT%H%M%SZ"`; the target is
     `<name>.corrupt-<stamp>`, then `-2`, `-3`, … while it exists.
  2. `os.replace`. On failure, log a WARNING and return None; the caller
     starts empty.
  3. `fsync_parent`: POSIX `open(dir, O_RDONLY|O_DIRECTORY)` + `fsync`;
     a no-op on Windows.
  4. Log a WARNING on logger `tokenserver.state` with the **file name and
     reason only, never the contents**.
- **`atomic_write_private(path, payload)`**:
  1. `mkdir -p` the parent.
  2. `mkstemp(prefix=f".{name}.", dir=parent)`, then `fchmod 0600`.
  3. Write, flush, `fsync`, then `os.replace(tmp, path)`, then
     `fsync_parent`.
  4. On any failure, unlink the temp file (errors ignored) and re-raise.
     An `fsync_parent` failure after the replace also raises.
- **`_Lock(path, wait_s)`**:
  1. `mkdir -p` the parent and open the lock file in `"a+"` mode. An
     OSError → not held.
  2. Loop: try a non-blocking exclusive lock — `fcntl.flock(LOCK_EX|LOCK_NB)`
     on POSIX, or `msvcrt.locking(LK_NBLCK, 1 byte)` on Windows. With no
     primitive the lock counts as held.
  3. Past the deadline, close the file and report not held. Otherwise
     sleep 0.05 s and retry.
  4. Release with `LOCK_UN` / `LK_UNLCK` and close.
  5. The lock file is never deleted (except by uninstall).
- **`record_sample(raw, *, now=None, directory=None, lock_wait_s=0.5) -> str`**,
  which never raises:
  ```
  now = int(time.time()) or int(now)
  parse -> RejectedPayload => "rejected"          (file untouched)
  with lock:  not held => "locked"                 (skip; never write back a stale copy)
    doc = load_sample(target); None => "unreadable"
    accounts = doc.get("accounts") or {}
    before = accounts.get("single"); after = merge_entry(before, observed, now)
    if no window in after: after = None             (drops version-only / expired entries)
    if after == before: "unchanged"                 (dict equality; 42 == 42.0)
    accounts' = copy; pop "single" if after is None else set it
    write json.dumps({"v":1,"accounts":accounts'}, separators=(",",":"), sort_keys=True) atomically
    OSError on write => "unreadable"
  => "written"
  ```
  Consequences:
  - The session-start payload (no rate_limits, no file) → unchanged; no
    file is created.
  - When only expired windows are stored, the result is
    `{"v":1,"accounts":{}}`.
  - A replay in the same second is unchanged. A replay later advances
    `seen` only.
- **`chained_command(config_dir, path=None)`**:
  1. Read the config (`CONFIG_MAX_BYTES`); an error → None.
  2. It must be a dict with `v == 1` and `dirs` a dict.
  3. `record = dirs[config_dir_key(config_dir)]` must be a dict.
  4. `chained_command` must be a non-empty str with no `\n`.
  5. Otherwise return None.

### 9.6 Running (`main`, `run_chained`, `parse_argv`)

- `parse_argv(argv)` walks in **pairs** (index += 2, which is not
  robust to stray tokens):
  - `--state-dir X` (non-empty) → directory;
  - `--chained CMD` (non-empty, no `\n`) → fallback command;
  - everything else is ignored.
- `read_stdin` reads up to 8 MiB; an OSError gives `b""`.
- `main(argv)`:
  1. Parse the options; `raw = read_stdin`.
  2. `record_sample(raw, directory=dir)` inside a catch-all.
  3. `command = chained_command(claude_config_dir(env), config_path(dir) if dir else None)`,
     or the `--chained` fallback.
  4. Return `run_chained(command, raw)`.
- `run_chained(cmd, stdin, stdout=None, run=subprocess.run)`:
  - no command → return 0 and print nothing;
  - argv is `["/bin/sh","-c",cmd]`, or on win32
    `["cmd.exe","/d","/c",cmd]`;
  - `run(argv, input=stdin_bytes, stdout=PIPE, stderr=DEVNULL, timeout=10, check=False)`.
    An OSError or SubprocessError (including a timeout) → return 0.
  - Otherwise write the child's stdout through (write errors ignored) and
    return `int(returncode or 0)`.
- **Invariants:**
  - the bridge itself prints nothing;
  - the user's status line always runs with the **full** stdin, even
    beyond the 256 KiB parse cap;
  - any bridge bug → exit 0.

### 9.7 Consumption in tokenserver

**`_read_claude_statusline(path=None, now_ts=None)`**, under
`_claude_statusline_lock`:
1. `status, doc = peek_sample(state_dir()/SAMPLE_NAME)`. If it is
   `missing` and `config_path(sample.parent)` does not exist → status
   `not_installed`.
2. If ok: `summary = summarize_sample(doc, now_ts)` and
   `status = summary.status`.
3. Set the view
   `{"status","ageS","claudeCodeVersion"}` (nulls if there is no summary).
4. Log `"claude-statusline: %s -> %s"` (from `start` on the first call)
   only on a **transition**.
5. Return the summary if it has windows, else None.

**`summarize_sample(doc, now)`:**
1. The entry is `doc.accounts.single` (or `{}`).
2. Collect each **valid** window as a copy with
   `age_s = max(0, int(now) - int(seen))` and `fresh = age_s ≤ 900`.
3. The version must be a printable non-empty str, truncated to 64; else
   None.
4. With no windows:
   `{"status":"empty","ageS":null,"claudeCodeVersion":v,"windows":{}}`.
5. Otherwise `age = min(age_s)`, and the result is
   `{"status":"fresh" if age ≤ 900 else "stale","ageS":age,…,"windows":{…}}`.

**`_merge_claude_statusline(claude, quota_cache, now_ts)`**. The session
and week are arbitrated separately:
```python
def _window_wins(c_reset, c_pct, i_reset, i_pct):
    if i_reset is None: return True
    if c_reset != i_reset: return c_reset > i_reset
    return c_pct > i_pct                     # ties keep incumbent
def _covers(w, probe_valid, p_reset, p_pct):
    if not probe_valid: return True
    if w.resets_at != p_reset: return w.resets_at > p_reset
    return w.pct >= p_pct
```
- **five_hour vs probe** `(sessionResetAt, sessionPct)`:
  - The probe is valid if its reset is a finite number `> now` and its
    pct is in 0..100.
  - `covered += 1` if the window is fresh and `_covers`.
  - `wins = not probe_valid or _window_wins(...)`. A stale window never
    beats a valid probe.
  - If it wins, set `sessionPct`, `sessionResetAt`,
    `sessionSource="statusline"` and `sessionLive=fresh`.
- **seven_day vs probe** `(weekResetAt, weekPct)`:
  - The probe is additionally required to have a str `weekIdentity`.
  - The same `covered` and `wins` rules apply. In addition, a strictly
    better `quota_cache.latest("claude","general_weekly")` reading vetoes
    the win.
  - If it wins, set `weekPct`, `weekResetAt`,
    `weekResetMin = max(0, round((reset - now)/60))`,
    `weekObservedAt = int(at)`,
    `weekIdentity = _quota_identity("claude","general_weekly")`,
    `weekSource = "statusline"` and `weekStaleFloor = not fresh`.
- `_claude_statusline_bridged = (covered == 2)`. With no summary it is
  False.
- While bridged and the OAuth probe status is `"usage_http_200 + ok"`, the
  probe interval becomes `PROBE_WHEN_BRIDGED_S = 1800` s instead of the
  normal ladder (`LIMITS_EVERY_S`, 240 s, with backoff).

### 9.8 Other external process: `codex app-server` (uses `resolve_codex_executable`)

Lives in tokenserver `_read_codex_app_server_limits`:
1. Spawn
   `Popen([codex, "app-server", "--listen", "stdio://"], stdin=PIPE, stdout=PIPE, stderr=DEVNULL, text=True, line-buffered)`.
2. Send JSON lines:
   `{"id":1,"method":"initialize","params":{"clientInfo":{"name":"vibepulse","version":"1"},"capabilities":{}}}`.
3. A daemon reader thread, `codex-app-server-reader`, queues lines, with
   None as EOF.
4. Loop until a 15 s deadline, doing `get(timeout=min(0.25, rem))`. On an
   empty queue, stop if the process has exited. Non-JSON lines are
   skipped.
5. On the first `id==1` reply, send `{"method":"initialized","params":{}}`
   and `{"id":2,"method":"account/rateLimits/read"}`.
6. On the `id==2` reply, parse `result` (outside this spec).
7. `finally`: terminate, wait 1 s, kill if needed, close the pipes.

---

## 10. Installers that modify `~/.claude` / `~/.codex` (`tools/vibepulse_setup.py`)

### 10.1 statusLine install (`statusline install --yes-single-account`)

**Preconditions.** Each failure prints a `FIX …` line and returns False:
- the platform is **darwin only** (win32 and Linux are refused);
- consent: `--yes-single-account` (Claude Code and the tokenserver must
  use the same account);
- the Python interpreter must be executable;
- `<repo>/tools/tokenserver/statusline_bridge.py` must exist.

**Inputs:**
- `config_dir` = `CLAUDE_CONFIG_DIR` or `~/.claude`;
- `settings = <config_dir>/settings.json`;
- `state_dir` as above;
- `key = config_dir_key(config_dir)`;
- `launcher = <state_dir>/statusline-bridge-<key>.sh`;
- `record = <state_dir>/claude-statusline-bridge.json`.

**Reading `settings.json`** (`_statusline_read_settings`):
- The file must be ≤ 256 KiB and a regular file. Missing → `{}`.
- Strict JSON: NaN and Infinity constants are rejected, duplicate keys are
  rejected, and the top level must be an object. Otherwise
  `ConfigError`.

**Steps:**
1. `block = settings.statusLine`, or `{}`; a non-object →
   `ConfigError`. `block.type` (default `"command"`) must be `"command"`,
   otherwise nothing is touched.
2. Determine the previous command (`chained`):
   - no command → None;
   - the command already points at our launcher (the exact string, the
     shell-split single word, or a file whose first 4 KiB contain the
     marker `# vibepulse-statusline-bridge`) → **reinstall**:
     - `chained = record.dirs[key].chained_command`, if it is valid
       (printable, 1–4096 chars);
     - else, if there is no record, recover it from the launcher's
       `CHAINED=` line.
   - Otherwise the command must be a valid single printable line (≤ 4096
     characters) → `chained = command`; else `ConfigError`.
3. Write the **launcher**: atomic 0600, then `chmod 0700`.
   ```sh
   #!/bin/sh
   # vibepulse-statusline-bridge v1
   # Generated by tools/vibepulse_setup.py statusline install.
   # ... (comment lines)
   PY=<shlex.quote(python)>
   BRIDGE=<shlex.quote(bridge)>
   STATE=<shlex.quote(state_dir)>
   CHAINED=<shlex.quote(chained or '')>
   if [ -x "$PY" ] && [ -f "$BRIDGE" ]; then
     exec "$PY" "$BRIDGE" --state-dir "$STATE" --chained "$CHAINED"
   fi
   # The checkout or interpreter moved: keep the previous status line.
   exec /bin/sh -c <quoted chained>      # or: exit 0
   ```
4. Update the **record**: pretty JSON (`indent=2`, `sort_keys`), written
   atomically with mode 0600.
   ```json
   {"v":1,"dirs":{"<key>":{"config_dir":"…","settings_path":"…","chained_command":"…"|null,"launcher":"…","python":"…","bridge":"…","installed_at":<int>}}}
   ```
5. Update **settings.json**:
   - Keep every other key, and every other key in the block (e.g.
     `padding`).
   - Set `statusLine.type = "command"` and
     `statusLine.command = shlex.quote(launcher)`. The quoting matters
     because of the space in `Application Support`.
   - Write it with `json.dumps(indent=2, ensure_ascii=False) + "\n"`
     through `atomic_write_private`, then `chmod` back to the **original
     mode** (0600 for a new file).
   - Refuse a symlinked settings file.
6. If a different, older launcher path was recorded and no record still
   references it, delete it. This migrates away from the earlier shared
   launcher.
7. Print `PASS …`. Claude Code sessions must be restarted, since they bind
   the statusLine when they start.

**Idempotency and backup.** There is **no copy of settings.json**. The
"backup" is the prior `statusLine.command`, kept in two places: the
record's `chained_command` and the launcher's `CHAINED=` line.
Reinstalling never loses it.

**Uninstall** (`statusline uninstall`):
1. If there is no record and settings do not point at our launcher, print
   `OFF`; there is nothing to do.
2. If the settings point at our launcher:
   - restore `statusLine.command = chained` if it is valid (recovering it
     from the launcher's `CHAINED=` line if the record is gone);
   - otherwise remove only the `command` and `type` keys, keeping
     siblings, and drop an empty `statusLine`.
   - Write the file atomically, preserving its mode.
3. If the settings no longer point at the launcher, leave settings.json
   alone.
4. Remove `dirs[key]`.
   - If other directories remain, rewrite the record and delete this
     launcher if it is unreferenced.
   - Otherwise delete the record, the launcher, the sample file and the
     lock file.

**Doctor** (`_statusline_state` + `_statusline_report`) prints
`PASS/VARN/WAIT/FIX/OFF` lines. It checks:
- whether the record exists;
- whether settings points at the launcher, correctly quoted;
- whether the launcher exists and carries the marker;
- whether the recorded python and bridge still exist, and whether the
  bridge is this checkout;
- the sample status.

### 10.2 Claude hooks

There is no installer; the user edits `settings.json` (§8.6).

### 10.3 Codex (`~/.codex`, via the Codex CLI only — setup never edits `config.toml` directly except the timeout helper)

**`plan_codex_install(repo_root, python, codex, marketplace="torget")`**
builds shell-free argv lists. Each is run with a 15 s command timeout:
```
[codex, "plugin", "marketplace", "add", <repo_root>]
[codex, "plugin", "add", "vibepulse@torget"]
[codex, "mcp", "remove", "vibepulse"]
[codex, "mcp", "add", "vibepulse", "--", <python>, <repo>/.agents/plugins/plugins/vibepulse/scripts/mcp_server.py]
[<python>, <repo>/tools/codex_mcp_timeout.py]     # sets tool_timeout_sec = 130 under [mcp_servers.vibepulse]
```
- Removing before adding makes the MCP registration idempotent.
- The timeout helper refuses when there are several `tool_timeout_sec`
  lines, and verifies the value after writing.

**`plan_codex_uninstall`**:
`mcp remove vibepulse`, `plugin remove vibepulse@torget`,
`plugin marketplace remove torget`.

**`_codex_permission_config_status(path = $CODEX_HOME/config.toml or ~/.codex/config.toml)`**
is **read-only**. It reads ≤ 64 KiB of strict UTF-8 and considers only the
top-level lines before the first `[table]` that match
`^[ \t]*(approval_policy|approvals_reviewer|sandbox_mode)[ \t]*=[ \t]*(["'])([^"']*)\2[ \t]*(?:#.*)?$`.

| Condition | Verdict |
|---|---|
| `approval_policy=never` | FIX |
| `approvals_reviewer=auto_review` | FIX |
| `sandbox_mode=danger-full-access` | FIX |
| policy ∈ {on-request, untrusted}, reviewer ∈ {None, user}, sandbox ∈ {workspace-write, read-only} | PASS |
| missing file or anything else | CHECK |

After installing, the user must review and trust the hooks in Codex
`/hooks`; doctor never bypasses that.

---

## 11. State files

| File | Writer | Reader | Format / discipline |
|---|---|---|---|
| `<state_dir>/claude-statusline-quota.json` | bridge (`record_sample`) | tokenserver (`peek_sample`), doctor | compact sorted ASCII JSON v1; atomic 0600 + parent fsync; under the `flock` of the `.lock` file; corrupt → quarantined by the bridge only |
| `<state_dir>/claude-statusline-quota.lock` | bridge | — | empty lock file, `a+` |
| `<state_dir>/claude-statusline-bridge.json` | setup | bridge (`chained_command`), tokenserver (presence decides `not_installed`), doctor | pretty sorted JSON v1, 0600 |
| `<state_dir>/statusline-bridge-<key16>.sh` | setup | Claude Code runs it | 0700 POSIX sh |
| `<state_dir>/<name>.corrupt-YYYYmmddTHHMMSSZ[-n]` | `quarantine_corrupt` | humans | the original bytes |
| `<CLAUDE_CONFIG_DIR or ~/.claude>/settings.json` | setup (statusLine only) | Claude Code | pretty JSON; mode preserved |
| `~/.claude/projects/**/*.jsonl` | Claude Code | agent_status (read-only tail) | JSONL |
| `$CODEX_HOME or ~/.codex/sessions/**/rollout-*.jsonl` | Codex | agent_status, codex_rollout readers | JSONL |
| `$CODEX_HOME or ~/.codex/config.toml` | Codex CLI (+ timeout helper) | doctor (read-only) | TOML |
| `~/.vibepulse-device-key`, `<repo>/secrets.h` | user | `read_device_key` | secret; never log |
| `~/.vibepulse-interaction-relay-token` | user | relay setup | 0600, not a symlink |
| `<state_dir>/config.json` | vibepulse_config | tokenserver | interaction switches |

Agent status and interactions **keep no state on disk**. Everything is in
memory, and a restart forgets pending interactions; parked hooks die with
their connections.

---

## 12. Threads and locks

| Thread / lock | Owner | Notes |
|---|---|---|
| `agent-status-poller` (daemon) | `AgentStatusService` | 0.5 s cadence; `_poll_lock` serializes `poll_once`; `_thread_lock` guards start/stop |
| `AgentStatusStore._lock` | store | `apply` and `snapshot`; no I/O under it |
| HTTP worker threads (≤ 32) | server | a parked hook blocks in `Event.wait` with 2 s liveness slices |
| `InteractionStore._lock` | store | never held during listener callbacks, audit or waits, **except** `resolve_relay`'s `verify` callback |
| `_claude_statusline_lock` | tokenserver | peek + summarize + status transition logging |
| `flock` on the `.lock` file | bridge processes | interprocess; 0.5 s bounded wait, otherwise skip |
| `codex-app-server-reader` (daemon) | tokenserver | per app-server read |

The request path for `/api/agent-status` does no disk I/O (test
`test_real_service_endpoint_is_exact_private_bounded_and_memory_only`).

---

## 13. Honesty and privacy invariants

1. **No content leaves the Mac in agent status.** Prompt, message, command
   and file text are inspected only to choose an activity. Only the
   8 job fields are published. Tests plant marker strings and assert they
   are absent.
2. **Nothing is invented.**
   - Missing metadata is `null`.
   - Stale `working` becomes `unknown` and is hidden, not reported as
     still working.
   - Attention states age out after 2 h.
   - History is never replayed as live transitions.
   - Future timestamps are clamped.
   - An older event never overwrites a newer one (`order_at` check).
3. **`seq` only moves on a public change.** Aging does not increment it,
   nor does a refresh of an unchanged record.
4. **Interactions fail toward the terminal.** An unrenderable input, a
   full queue, a timeout, `leave_it`, a crash or a disconnect all give
   **no decision** (Claude / Codex permission) or
   `{"status":"computer",…}` (Codex question).
5. **Approve only what was fully shown and explicitly recommended.**
   - Truncated text gives `can_approve=false`.
   - An unmarked question is alert-only.
   - A command is device-approvable only through the narrow allowlist
     (Codex: plus the strict argument grammar).
   - A v2 answer is bound to provider + request id + the exact view
     digest + verdict + time.
6. **Panic only denies.**
7. **Detail is off by default.** The view then carries no prompt, title or
   subtitle, and `can_approve` is false. The Codex question also forces
   `marked=false`. The project is always a basename, and the session id
   is never published (only a 16-hex hash appears in the audit log).
8. **Size is the hazard.**
   - `pending` is dropped before the agent list is ever endangered
     (640 B item and 3584 B body budgets, against a firmware cap of
     4096).
   - Text byte limits match the firmware buffers exactly (é×48 prompt, é×32
     title, é×12 tool accepted; one more is rejected).
9. **The statusline is never zero and never regresses.**
   - An absent window is not an observation.
   - A replay only advances `seen`.
   - A malformed window rejects the whole payload and leaves the file
     untouched.
   - Lock contention skips the write.
   - A corrupt file is quarantined, not overwritten.
   - The user's status line always runs, and exit code 0 is returned on
     any bridge bug.

---

## 14. Test catalogue (behavior each pins)

### `test_agent_status.py`

**ClassificationTests**
- `claude_reads_model_and_effort_only_from_top_level_message`: model and
  effort come from `message`, not from tool input.
- `claude_reads_effort_from_the_record_top_level`: the top-level `effort`
  fallback.
- `claude_nested_effort_still_wins_over_the_top_level`.
- `claude_top_level_effort_is_bounded_and_never_from_tool_input`: 12
  bytes, uppercase.
- `claude_non_string_top_level_effort_is_ignored`.
- `claude_does_not_take_model_from_nested_tool_input`.
- `claude_user_starts_work`: `user` gives working/thinking.
- `claude_events_in_one_session_share_task_identity`: the task id is
  sha256(sessionId).
- `claude_task_identity_ignores_event_uuid`.
- `claude_end_turn_waits_but_does_not_finish`: waiting, activity None.
- `claude_success_result_finishes`: done.
- `claude_success_with_explicit_error_does_not_false_finish`: error.
- `claude_ask_user_question_waits_for_input`.
- `claude_permission_tool_waits_for_approval`.
- `claude_permission_status_waits_for_approval`: a system record's
  subtype/status.
- `claude_editing_tools`, `claude_read_tool`, `claude_search_tools`: the
  activity map.
- `claude_test_command`, `claude_build_command`,
  `claude_ordinary_command`: testing/building/running regexes.
- `claude_event_never_retains_a_command`.
- `codex_task_started_uses_turn_as_task_identity`.
- `codex_turn_context_reads_top_level_model_effort_and_project`.
- `every_gpt_5_6_variant_gets_a_screen_label`: MODEL_LABELS.
- `unmapped_model_ids_are_typeset_on_arrival`: the derive table (§5.2).
- `every_priced_model_derives_a_label_that_fits_the_panel`: `prices.json`
  labels are ≤ 24 B, uppercase and without CLAUDE.
- `screen_labels_fit_the_firmware_model_buffer`: `TK_AGENT_MODEL_CAP` is
  25.
- `metadata_is_control_free_and_bounded_by_utf8_bytes`.
- `codex_overlong_turn_identity_is_hashed_without_collision_truncation`:
  `"å"*40` gives the sha256.
- `codex_task_complete_finishes_same_task`.
- `codex_task_complete_with_explicit_error_does_not_false_finish`.
- `codex_reasoning_refreshes_live_work_between_lifecycle_events`.
- `codex_tool_calls_refresh_live_work_without_retaining_arguments`.
- `codex_tool_output_returns_to_thinking`.
- `codex_response_item_without_stable_identity_is_ignored`: no
  `payload.id`.
- `malformed_and_unrelated_events_are_ignored`.
- `project_sanitization_removes_controls_and_caps_characters`:
  `"Tor\x00get-med-ett-långt-namn"` → `"Torget-med-ett-l"`.
- `project_sanitization_caps_utf8_bytes_without_splitting`: `"å"*16` →
  `"å"*8`.

**StableEventIdTests**
- `stable_event_id_is_deterministic_and_sensitive_to_contract_fields`.

**StoreTests**
- `initial_snapshot_has_two_idle_agents_and_exact_shape`:
  `{"v":2,"seq":0,"agents":{"claude":{"active_count":0,"jobs":[]},"codex":{…}}}`.
- `snapshot_bounds_jobs_and_reports_all_active`: 6 working jobs give
  active_count 6 with 4 jobs shown.
- `capacity_evicts_expired_attention_before_fresh_work`: 16 expired
  waiting jobs plus 1 fresh one; the oldest expired is evicted; seq is 17.
- `two_done_jobs_survive_as_distinct_events`.
- `apply_increments_only_for_changed_public_content`: a refresh moves
  `updated_ms` without changing seq.
- `activity_task_event_and_project_changes_increment_sequence`.
- `metadata_carries_forward_only_for_the_same_task`.
- `invalid_provider_state_and_activity_are_rejected`: ValueError.
- `old_working_entry_reads_as_unknown_without_mutation_or_seq_change`: at
  age 121 s it is hidden.
- `waiting_and_error_attention_age_out_after_two_hours`: visible at 7200,
  hidden at +0.001.
- `fresh_attention_observation_revives_aged_waiting_without_seq_change`.
- `snapshot_is_a_deep_copy`.
- `updated_ms_is_nonnegative_integer_and_clamped`: 0 and 0xFFFFFFFF.
- `snapshot_exposes_only_allowed_sanitized_fields`: exactly the 8 job
  keys.
- `store_hashes_any_overlong_task_id_before_output`.
- `surrogate_ids_are_hashed_without_crashing_or_leaking`.

**JsonlTailerTests**
- `reads_only_complete_lines_then_finishes_partial_append`.
- `invalid_complete_line_is_skipped_before_later_valid_line`.
- `malformed_utf8_lines_are_skipped_before_valid_record`.
- `oversized_unterminated_line_is_bounded_and_later_record_resumes`: the
  1 MiB discard mode.
- `record_budget_drains_large_backlog_across_polls`: 256 records per poll.
- `reconciliation_bounds_cold_states_and_drops_cold_partial`:
  `retain_paths` clears the partial of inactive files.
- `inode_churn_enforces_identity_cap_before_next_discovery`: exactly 48.
- `truncation_resets_only_that_files_offset_and_buffer`.
- `same_inode_truncate_and_regrow_resets_offset`: the sample digest.
- `same_inode_rewrite_is_detected_when_final_boundary_is_unchanged`: full
  verification.
- `rewrite_during_prefix_verification_does_not_poison_fast_path`: the
  stat signature is set only when unchanged during the read.
- `complete_line_content_is_not_retained_for_rewrite_detection`: only
  hashes are kept, not bytes.
- `full_prefix_verification_uses_bounded_cadence`: 5 s.
- `large_prefix_verification_is_budgeted_and_replays_mismatch_once`:
  1 MiB per poll.
- `file_disappearance_is_tolerated`.
- `temporarily_missing_file_resumes_without_replay`: fewer than 3 missing
  polls.
- `replacement_path_read_before_rotated_inode_does_not_lose_state`.

**AgentStatusServiceTests**
- `poll_discovers_claude_and_codex_and_counts_changes`.
- `stateless_codex_tool_events_stay_on_current_turn`: stream binding and
  the fallback task.
- `live_codex_activity_recovers_after_a_newer_task_completed`.
- `appended_unchanged_classified_event_counts_as_no_change`: returns 0.
- `timestamp_less_private_rewrite_does_not_replay_public_transitions`.
- `small_first_seen_history_flushes_final_once_then_append_is_live`.
- `small_same_path_replacement_backfills_without_public_replay`.
- `large_rewrite_backfill_never_publishes_intermediate_status`.
- `cold_eviction_replays_only_genuinely_appended_final_event`.
- `fast_active_poll_does_not_repeat_recursive_discovery`: discovery at
  most once per 5 s.
- `newest_file_rotation_starts_new_file_without_replaying_old`.
- `renamed_active_file_transfers_offset_without_replaying_history`.
- `missing_roots_and_start_stop_are_idempotent`.
- `stop_signal_cannot_be_cleared_by_concurrent_start`.
- `start_during_stop_join_cannot_launch_replacement_worker`.
- `background_thread_survives_transient_poll_failure`: logs
  `agent-status poll: OSError`.
- `record_failures_are_isolated_and_diagnostics_are_sanitized`: only the
  error name, throttled.
- `snapshot_does_not_require_roots_to_exist`.
- `startup_replay_uses_old_claude_and_codex_iso_timestamps`: old working
  jobs are hidden.
- `old_file_mtime_is_fallback_when_timestamp_is_missing`.
- `future_timestamp_falls_back_to_old_file_time`.
- `task_complete_age_uses_completion_before_start_time`.
- `permanently_missing_partial_file_is_pruned_after_bounded_polls`.
- `one_missing_service_poll_retains_identity_for_short_recovery`.
- `existing_file_outside_recent_limit_is_not_pruned_or_replayed`: the
  recent 12 plus the retained identities.
- `older_event_in_newer_mtime_file_cannot_overwrite_newer_status`: the
  `order_at` check.

**HandlerTests**
- `agent_status_endpoint_uses_service_snapshot`.
- `root_lists_existing_and_agent_status_endpoints`.
- `real_service_endpoint_is_exact_private_bounded_and_memory_only`: no
  disk I/O on the request thread, privacy markers absent, within the size
  bound.
- `70k_codex_record_classifies_without_exposing_irrelevant_secret`.

### `test_interactions.py`

**RecommendationTests**
- The suffix wins even when it is not on the first option.
- Unmarked falls back to the first option.
- The marker is chrome, not part of the answer (`strip_recommended`).
- It survives junk options.

**RenderabilityTests**
- A single question is renderable.
- Multi-question calls and `multiSelect` are not answerable.
- The option count matches the uint8 boundary: 255 is OK, 256 gives None.
- Malformed payloads are not answerable.

**TierTests**
- Recognized test/build commands are approvable.
- Read-only tools are approvable.
- Dangerous and unknown commands are not.
- Chaining disqualifies a recognized prefix.
- Write tools are not device-approvable.

**HookResponseTests**
- Question approve gives the updatedInput answers with the verbatim
  label.
- `leave_it` gives None.
- Approval verdicts use the decision object.
- Question deny gives the PreToolUse deny.
- An out-of-range option gives None.

**SignatureTests**
- v1 round trip; every field is covered by the MAC; stale and future
  stamps (> 90 s) are rejected; junk never verifies.
- v2 round trip binds provider, request, view, verdict and time.
- v2 strictness: float ts, bool ts, `10**1000`, an uppercase provider and
  an uppercase digest are all rejected.

**ProviderStoreTests**
- `park_publish_resolve_round_trip`.
- `internal_question_permission_never_replaces_real_question`: an
  `"  ASKUSERQUESTION  "` approval gives None, and pending is unchanged.
- `claude_utf8_limits_are_bytes_and_preserve_codepoints`: é×48 prompt,
  é×32 title and subtitle, é×12 tool are accepted; one more is rejected.
- `claude_approval_and_normalized_views_use_utf8_byte_limits`.
- `truncated_question_prompt_is_alert_only`,
  `truncated_question_subtitle_is_alert_only`,
  `truncated_approval_subtitle_is_alert_only`: text ends in `…` and
  `can_approve` is false.
- `options_total_is_limited_to_firmware_uint8_range`.
- `view_digest_ignores_only_countdown_and_self_digest`.
- `fractional_hold_uses_one_stored_value_in_view_and_digest`: 90.001 gives
  90001.
- `view_bytes_use_the_specified_canonical_json_encoding`: the Fråga
  vector.
- `new_ids_are_unique_canonical_128_bit_base64url`: `bytes(range(16))`
  gives `AAECAwQFBgcICQoLDA0ODw`.
- `issued_id_history_is_bounded_without_evicting_active_ids`: 256
  remembered ids; protected ids stay.
- `v1_claude_compatibility_returns_the_exact_hook_shape`: `park_legacy`
  plus a v1 answer.
- `new_claude_entry_cannot_be_resolved_by_stripping_v2_binding`:
  `v2 verdict required`.
- `hold_ms_is_the_original_duration_for_the_ring`.
- `hold_duration_rejects_invalid_and_uint32_overflow_values`: 0.5 becomes
  1000 ms; the MAX boundary is honored; bool, NaN, 0 and negatives are
  rejected.
- `a_second_tap_cannot_land_on_a_later_prompt`.
- `timeout_yields_no_decision`.
- `unsigned_and_missigned_answers_are_refused`: the entry is not
  consumed.
- `replay_outside_the_freshness_window_is_refused`.
- `approve_is_refused_when_the_panel_could_not_offer_it`.
- `unmarked_questions_are_alert_only`.
- `marked_questions_stay_approvable_wherever_the_mark_sits`.
- `unreadable_command_cannot_be_approved`.
- `unrenderable_payloads_are_never_parked`.
- `legacy_park_rejects_lone_surrogates_without_raising`.
- `legacy_park_rejects_control_and_bidi_display_text`.
- `legacy_park_rejects_controls_in_project_without_sanitizing`.
- `valid_international_display_text_still_parks`.
- `queue_is_bounded`: 8.
- `oldest_interaction_is_the_one_on_screen`.
- `panic_stop_denies_everything_parked`.
- `a_held_hook_really_blocks_until_answered`.
- `answers_are_refused_when_no_secret_is_configured`.

**RelayStoreListenerTests**
- `park_emits_only_an_immutable_bounded_public_job`: the job fields,
  32-byte challenge, raw digest and ceiled expiry.
- `listener_failure_never_breaks_parking_or_resolution`.
- `direct_timeout_dead_hook_and_panic_emit_remote_removal`: the reasons
  resolved/timeout/abandoned/panic.
- `relay_resolution_checks_binding_deadline_consumption_and_policy`.
- `terminal_and_authenticated_panic_are_anchored`: terminal becomes
  leave_it; panic needs a live, bound anchor.
- `concurrent_direct_and_relay_answers_consume_exactly_once`.

**PrivacyTests** (detail off)
- Content stays on the Mac by default.
- Question text stays on the Mac by default.
- The project is a basename, never a path.
- The session id is never published.

**DeviceBudgetTests**
- The pending payload is ≤ 640.
- The ceiling is ≤ the firmware cap.
- A full snapshot plus pending still fits in 3584.

**AbandonedHookTests**
- A dead client frees its slot immediately.
- A ghost does not shadow a live prompt.
- Equal clock ticks still preserve arrival order.
- Zombies no longer fill the queue.
- An alive client still gets its answer.
- A client dying mid-wait is noticed within the 2 s poll bound.

**RealClockTests**
- The default clocks expire a short hold.

**HttpEndToEndTests** (a real server with a stub agent status)
- A question travels Claude → device → Claude.
- The internal question permission is not parked: the permission hook
  answers promptly with no decision and the pending id is unchanged.
- An approval allow travels end to end.
- Explicit legacy mode uses v1 only for Claude.
- A timeout gives an empty 200.
- An unrenderable payload gives an immediate empty 200.
- Garbage bodies never hang or crash.
- Panic denies what is parked; an unsigned panic gets 409.
- A forged answer gets 409 and the entry stays pending.
- An abandoned connection is reaped well before the timeout.
- `/api/agent-status` has no `pending` key when idle.
- POST gives 404 when interactions are off.
- Non-loopback hooks get 403.

### `test_codex_interactions.py`

**InteractionTypeTests**: see §2.

**CodexNormalizationTests**
- An explicit recommendation gives a safe approvable view.
- An unmarked question is alert-only, with no guess.
- A missing description means no subtitle.
- Three options allow one explicit recommendation.
- `question` and `options` are each required.
- The header is bounded, clean text when present.
- Malformed option objects, labels and descriptions are rejected.
- UTF-8 byte boundaries apply without truncation: `é*48` is OK, `é*48+"a"`
  is rejected.
- Non-dict, structural and option-shape errors are rejected.
- Empty text, controls and overlong display text are rejected.
- Unicode controls never reach an approvable permission view.
- The permission uses the documented response shapes.
- The readability and tool-safety gates apply.
- A wrong event or malformed required fields are rejected.
- Dangerous shell commands are never approvable.
- The shell families are strictly positive (the §7.4 table).
- The question result answers only the explicit recommendation.

**CodexInteractionStoreTests**
- The public view is provider-bound, free of private data, and immutable.
- v1 cannot resolve Codex and does not consume it.
- An exact v2 binding returns the recommended option.
- A permission keeps the raw event private and has no option.
- A dangerous event cannot borrow an approvable read view (the
  re-normalization equality check).
- Wrong v2 bindings and bad signatures never consume.
- Approve still requires `can_approve`.
- `await_verdict` refuses Codex (the provider-mismatch reap).
- The normalized boundary rejects unvalidated or private view fields,
  lone surrogates (without raising), and control/format text.

**CodexRouteTests** (HTTP)
- An answered question gives the exact JSON; legacy mode never
  downgrades Codex.
- Deny gives `computer/deny`.
- Detail off publishes no question or option text.
- An unmarked question cannot approve.
- Permission allow and deny return the hook JSON; `leave_it` gives an
  empty body.
- Permission with detail off hides the command and cannot approve.
- An invalid flat envelope gives `invalid` without parking.
- An invalid permission gives an empty body.
- Timeouts fail closed (`timeout` / empty body).
- The provider switches are independent, and disabled routes do not
  parse.
- An injected store does not enable Claude when its flag is off.
- Non-loopback clients are rejected before parsing, as are an attacker
  Host and any Origin.
- `text/plain` gets 415.
- The recognized loopback Host forms pass.
- JSON content type: only an optional `charset=utf-8` or `"utf-8"` is
  allowed.
- A partial advertised body hits the short deadline (under 1 s) and never
  parks.
- Deep or huge-integer JSON fails closed without a traceback.
- Early rejections answer even while the body is still being written.
- A disabled route answers 404 with the body written.
- An early rejection leaves nothing unread.
- A parsed body is never drained twice.

**RequestDrainBoundsTests**
- The drain stops at the byte cap.
- It uses the short socket timeout and restores it.
- It stops at EOF and runs once.
- Nothing is drained without an advertised body.

### `test_codex_command.py`

See §3.

### `test_statusline_bridge.py`

**ParsePayloadTests**
- Only the two windows and the version are kept.
- Missing `rate_limits` is no observation.
- One absent window keeps the other.
- A malformed window rejects everything: a bool or NaN pct, an out-of-range
  pct, a non-integral or past reset, a reset beyond the horizon.
- The weekly horizon is 8 days.
- Non-JSON and non-object input is rejected.
- Oversized stdin is rejected.
- `read_stdin` forwards past the parse cap.
- The version is bounded and printable.

**MergeEntryTests**
- The first observation stamps `at` and `seen`.
- A replay keeps the value and advances `seen`.
- A higher pct in the same window replaces.
- A newer reset replaces even with a lower pct.
- An older reset never vouches for the newer window.
- An absent window keeps the stored one until it expires.
- A malformed stored window counts as absent.
- The version carries over.

**RecordSampleTests**
- The first write creates a 0600 v1 file with no temp leftovers.
- A replay in the same second is `unchanged`; later, only `seen` moves.
- A rejected payload leaves the file byte-identical.
- A session-start payload writes nothing.
- Expired windows give `{"v":1,"accounts":{}}`.
- Corrupt, wrong-shape and malformed nested records are quarantined, not
  overwritten.
- An unreadable file skips the write (`unreadable`).
- A held lock skips the write within the bound (`locked`).
- An unwritable directory gives `unreadable` without raising.

**SummarizeSampleTests**
- fresh, stale and empty.
- A bad version is dropped.
- `peek_sample` never quarantines.

**ChainedCommandTests**
- The recorded command for this config dir is returned.
- Missing or malformed config gives None.
- The key is stable and path-independent (resolved).
- `CLAUDE_CONFIG_DIR` is honored.

**RunChainedTests**
- No command prints nothing and exits 0.
- stdin, stdout and the exit status pass through.
- A failed or timed-out command gives 0.
- A real shell `cat; exit 4` round trip.

**MainTests**
- It records, then runs the chained command.
- `--state-dir` selects the directory.
- The baked `--chained` stands in for an unreadable record.
- Oversized stdin still reaches the chained command whole.
- It prints nothing without a chained command.
- A bridge bug never takes the status line down.
- A stdin read error means an empty payload.

---

## 15. Swift porting checklist

1. Write hand-rolled JSON writers for the wire format [P6a], the
   canonical form [P6b] and the compact ASCII form [P6c]. Match Python
   byte-for-byte:
   - key order is insertion order (wire) or sorted (canonical/compact);
   - `/` is not escaped;
   - wire uses `\uXXXX` lowercase with surrogate pairs;
   - floats use Python repr (`42.0`).
2. Use a JSON reader that distinguishes int from float and bool from
   number, and accepts NaN/Infinity (they then fail the finite checks).
   Reject more than 4300-digit ints and deep nesting as "invalid".
3. Count code points, not graphemes, and implement the C-category filter,
   the Python whitespace set and `isprintable`.
4. Implement `Path.name`, `expanduser`/`resolve` and `shlex.split` (POSIX
   mode) exactly.
5. Keep both clocks: monotonic for leases, holds and throttles; wall for
   `order_at`, HMAC freshness and relay expiry.
6. The Python tailer is single-threaded under `_poll_lock`. Keep the Swift
   version on one serial queue.
7. The HTTP layer must support long-held requests (thread-per-request or
   async with a 32-slot cap), peeking for client EOF every 2 s, the
   bounded drain before early responses, and "no decision" as 200 with
   `Content-Length: 0`.
8. Never log device keys, tokens, prompts or commands. Diagnostics carry
   error type names only.
