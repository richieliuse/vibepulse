# tokenserver.py — Part 3 (lines 3182–4669): HTTP server, Handler, diagnostics, CLI, startup/shutdown, wiring

Scope: `tools/tokenserver/tokenserver.py` from `BoundedThreadingHTTPServer`
(3182) through `main()` (4669), plus the handful of out-of-range helpers the
range calls directly and whose output lands on the wire (`_probe_view`,
`_codex_probe_view`, `_usage_totals_state`, `_quota_regressions_view`,
`_maybe_rotate_own_log`, `_run_log_rotation_watch`, `_read_server_rev`,
`_read_source_fingerprint`, `_state_dir`, `_log_dir`, `_any_provider_dir`,
`_refresh_usage_totals`, `_mark_max_tracker_dirty`). Anything else
(`get_snapshot`, `_compute`, interactions store internals, max-tracker
payload, agent-status snapshot, publisher internals) is specified in the
other parts; here it is referenced by contract only.

Conventions in this document:

- "monotonic" = a monotonic clock in seconds (Python `time.monotonic()`,
  counts from boot on macOS). "wall" = Unix epoch seconds (`time.time()`).
- JSON encoding = Python `json.dumps(obj)` with defaults, see §2.4 — this
  matters for byte-size budgets.
- "Handler class state" = class-level (process-global) mutable fields,
  shared by all request threads. In Swift: one shared, lock-protected
  `ServerState` object.

---------------------------------------------------------------------------

## 0. Quick reference

| Method | Path | Gate | Success | Other responses |
|---|---|---|---|---|
| GET | `/` | none | 200 diagnostics JSON (§4) | 500 `{"error":"internal server error"}` |
| GET | `/api/tokens` | none; records panel poll | 200 tokens v2 | 503 `{"error":"usage totals not measured yet","usageTotals":{…}}` (placeholder + client lacks Accepts header); 500 error form |
| GET | `/api/agent-status` | none; records panel poll | 200 agent-status v2 (+ optional `pending`) | 500 error form |
| GET | `/api/max-tracker` | none; records panel poll | 200 max-tracker v1 with top-level `stale` overridden | 500 error form |
| GET | `/api/github` | none; records panel poll | 200 github v1 (or `{"v":1,"enabled":false}`) | 500 error form |
| GET | anything else (incl. query strings, trailing slash) | — | — | 404 `{"error":"not found"}` |
| POST | `/api/hook/question` | claude on + store; loopback peer; loopback Host; no Origin; JSON CT | 200 hook JSON body, or 200 empty body (no decision) | 404 / 403 / 415 |
| POST | `/api/hook/permission` | same | same | same |
| POST | `/api/codex/question` | codex on + store; loopback; Host; no Origin; JSON CT | 200 `{"status":"answered",…}` or `{"status":"computer","reason":…}` | 404 / 403 / 415 |
| POST | `/api/codex/permission` | same | 200 hook JSON or empty body | 404 / 403 / 415 |
| POST | `/api/interaction/<id>` (prefix match) | store exists; JSON CT (NO loopback/Host/Origin check) | 200 `{"ok":true,"reason":…}` | 409 `{"ok":false,"reason":…}`, 400 `{"ok":false,"reason":"bad request"}`, 404, 415 |
| POST | `/api/panic` | store exists; JSON CT | 200 `{"ok":true,"denied":N}` | 409 `{"ok":false,"reason":"signature rejected"}`, 400, 404, 415 |
| POST | anything else | — | — | 404 `{"error":"interactions are not enabled"}` if store is None, else 404 `{"error":"not found"}` |
| HEAD/PUT/DELETE/OPTIONS/… | any | — | — | 501 from the stdlib (HTML body), see §1.6 |

---------------------------------------------------------------------------

## 1. Transport layer

### 1.1 `BoundedThreadingHTTPServer` (lines 3182–3246)

Subclass of `http.server.ThreadingHTTPServer` (= `socketserver.ThreadingMixIn`
+ `HTTPServer` + `TCPServer`). One OS thread per accepted connection with a
hard ceiling.

Inherited facts a port must reproduce or consciously replace:

- Bind address `("0.0.0.0", port)` — IPv4 only, all interfaces (main, 4638).
  No IPv6 listener exists; `::1` hook peers are therefore unreachable in
  production even though `_is_loopback` accepts them.
- `allow_reuse_address = 1` (from `HTTPServer`) → `SO_REUSEADDR` set before
  bind.
- Listen backlog `request_queue_size = 5` (from `TCPServer`).
- `daemon_threads = True`, `block_on_close = False` (explicit, pinned by
  test): request threads never block process exit; `server_close()` does not
  join them. A parked hook at shutdown is simply dropped with the process.
- `serve_forever()` default poll interval 0.5 s (only relevant to
  `shutdown()` latency; main never calls `shutdown()`).

Constructor:

```python
def __init__(self, server_address, handler, *, max_workers=HTTP_MAX_WORKERS):  # 32
    if type(max_workers) is not int or max_workers < 1:
        raise ValueError("max_workers must be a positive integer")
    self.max_workers = max_workers
    self._worker_slots = threading.BoundedSemaphore(max_workers)
    super().__init__(server_address, handler)   # binds + listens here
```

`HTTP_MAX_WORKERS = 32`. Test pins `max_workers >= interactions.MAX_PENDING
(8) + 16`, i.e. held hooks (at most 8 parked) can never starve the panel's
polls.

Admission (`process_request`, called on the accept thread per connection):

1. `acquire(blocking=False)` on the semaphore.
2. If no slot: `_reject_busy(request)`, then `shutdown_request(request)`
   (= `shutdown(SHUT_WR)` + close), return. No thread is created.
3. Else start the per-request thread (`super().process_request`). If thread
   creation raises anything, release the slot, close the socket, re-raise.
4. The thread body (`process_request_thread`) always releases the slot in a
   `finally`, after the handler finished and the socket was shut down.

`_reject_busy(request)` — exact bytes, order pinned by test
(`timeout, recv…, send, shutdown(SHUT_WR)`):

```python
response = (b"HTTP/1.1 503 Service Unavailable\r\n"
            b"Content-Length: 0\r\n"
            b"Connection: close\r\n\r\n")
request.settimeout(0.05)                 # OSError ignored
received = b""
while len(received) < 8*1024 and b"\r\n\r\n" not in received:
    chunk = request.recv(min(2048, 8*1024 - len(received)))
    if not chunk: break
    received += chunk                    # OSError (incl. timeout) ends loop
request.sendall(response)                # OSError ignored
request.shutdown(socket.SHUT_WR)         # OSError ignored
```

Rationale (keep it): closing a Windows socket with unread bytes turns the 503
into WSAECONNABORTED at the client. The drain is bounded to 8 KiB of headers
and 50 ms per recv. Note the busy 503 uses `HTTP/1.1` in its status line,
unlike normal responses (§1.5).

Firmware semantics of 503: for `/api/interaction` and `/api/panic` POSTs,
`tk_ir_direct_result_from_http` treats `status >= 500`, 408, 429, and
transport errors as *uncertain* (may try the relay); 200 is success; every
other status is a hard reject. For GETs any non-200 is "keep last good
values".

### 1.2 Per-request handler lifecycle

Handler = `BaseHTTPRequestHandler` subclass named `Handler`.

- `protocol_version` is NOT overridden → `"HTTP/1.0"`. Consequences:
  - Status line of every normal response: `HTTP/1.0 <code> <reason>`.
  - `close_connection` stays True → exactly ONE request per TCP
    connection; the server closes after the response even if the client
    asked for keep-alive. The firmware's agent-status client configures
    `keep_alive_enable = true` but works because esp_http_client reconnects
    when the server closes. A Swift port should close after each response
    (or, if it keeps connections alive, it must be HTTP/1.1-correct and
    always send `Content-Length`); closing is the zero-risk choice.
- No socket timeout on the handler (`StreamRequestHandler.timeout = None`):
  reading the request line/headers blocks until the peer sends or closes. A
  slow-loris peer holds one of the 32 slots indefinitely. (Porting note:
  adding a header-read timeout of a few seconds is compatible with every
  client; there must be NO timeout while a hook is parked — that wait is
  bounded by the interaction store instead.)
- `handle_one_request` override: sets `self._request_body_consumed = False`
  before delegating to the stdlib (fresh bookkeeping per request).
- `log_message(...)`: no-op (access log muted: "30 s polling must not fill
  the log").
- `log_error(fmt, *args)`: `log.warning("http %s: %s", self.address_string(),
  fmt % args)` — `address_string()` is the peer IP (`client_address[0]`).
  The stdlib calls `log_error` for its own errors, e.g.
  `http 192.168.1.5: code 400, message Bad request syntax ('…')`,
  `http 127.0.0.1: code 501, message Unsupported method ('HEAD')`.
  Tests pin: `log_error` reaches the logger at WARNING, `log_message` emits
  nothing.
- Uncaught exceptions escaping `do_GET`/`do_POST` (possible in the hook /
  answer paths, e.g. a store method raising) are caught by `socketserver`'s
  `handle_error`, which prints `Exception occurred during processing of
  request from ('ip', port)` plus a Python traceback directly to stderr (not
  via `logging`), then closes the connection without an HTTP response. A
  Claude/Codex hook seeing a closed connection falls back to the terminal.

### 1.3 Response writers

`_send(code, payload)` — every JSON response:

```python
self._drain_request_body()                 # §1.4
body = json.dumps(payload).encode()        # §2.4 encoding
self.send_response(code)                   # status line + Server + Date
self.send_header("Content-Type", "application/json")
self.send_header("Content-Length", str(len(body)))
self.end_headers()
self.wfile.write(body)
```

Exact header block produced by the stdlib for a JSON response:

```
HTTP/1.0 200 OK\r\n
Server: BaseHTTP/0.6 Python/3.x.y\r\n
Date: Thu, 24 Sep 2026 06:28:00 GMT\r\n
Content-Type: application/json\r\n
Content-Length: 1234\r\n
\r\n
<body>
```

No `Connection` header, no charset parameter. Nobody depends on `Server` or
`Date`; `Content-Length` is load-bearing (firmware `esp_http_client_fetch_headers`
returns it and the agent-status client rejects `content_length >= 4096`
before reading; `< 0` is an IO error). Reason phrases are the stdlib's:
200 OK, 400 Bad Request, 403 Forbidden, 404 Not Found, 409 Conflict,
415 Unsupported Media Type, 500 Internal Server Error, 503 Service Unavailable.

`_send_no_decision()` — "the hook made no decision" (Claude/Codex show their
own prompt):

```python
self._drain_request_body()
self.send_response(200)
self.send_header("Content-Length", "0")
self.end_headers()
```

No Content-Type, empty body. Tests compare the raw body to `b""`.

### 1.4 Request-body handling

Constants (module top, lines 148–155; class attrs 3280–3282, overridable
per test):

| Name | Value |
|---|---|
| `JSON_BODY_TIMEOUT_S` → `Handler.json_body_timeout_s` | 2.0 s |
| `REQUEST_DRAIN_LIMIT` → `Handler.request_drain_limit` | 65536 bytes |
| `REQUEST_DRAIN_TIMEOUT_S` → `Handler.request_drain_timeout_s` | 0.05 s (test asserts ≤ 0.05) |

`_advertised_body_length()`: `int(headers.get("Content-Length") or 0)`;
any parse failure (non-numeric, missing headers object) → 0; negative → 0.
(Duplicate `Content-Length` headers: `get` returns the first.)

`_read_json_body(limit=64*1024)` → parsed JSON value or `None`:

1. `length = int(Content-Length or 0)`; ValueError/TypeError → None.
2. `length <= 0 or length > limit` → None (body NOT read; it will be
   drained by the next `_send*`).
3. Save socket timeout, set it to `json_body_timeout_s` (2.0 s). Failure to
   get/set → None.
4. `raw = rfile.read(length)` — blocking buffered read of exactly `length`
   bytes; returns short only at EOF. Connection/Timeout/OSError → None.
   Restore the previous socket timeout in `finally` (errors ignored). Test
   pins the setter sequence `[0.25, 7.0]` (set short, restore original).
5. `len(raw) != length` → None (incomplete framing is never parsed; e.g.
   `{}` with `Content-Length: 100` → None).
6. Mark `_request_body_consumed = True` (only when the full body arrived).
7. `json.loads(raw)`; JSONDecodeError/UnicodeDecodeError/ValueError/
   RecursionError → None. Test pins: 10000-deep `[[[…]]]` and a 5000-digit
   integer both return None without an exception escaping (Python ≥3.11
   raises ValueError for >4300-digit ints). Swift: JSONSerialization depth
   limits / big-number handling must also map to "None", never crash.

Note: the 2 s timeout is per blocking `recv`, not a total deadline — a
peer dripping one byte per <2 s could extend a read up to ~length × 2 s;
the limit (64 KiB or 4 KiB) bounds it. Test pins: a request advertising 100
bytes but sending `{` returns in < 1 s with `json_body_timeout_s = 0.1`.

`_drain_request_body()` → drained byte count (tests only):

```python
if getattr(self, "_request_body_consumed", False): return 0
self._request_body_consumed = True           # one attempt per request, always
remaining = min(self._advertised_body_length(), self.request_drain_limit)
if remaining <= 0: return 0
prev = connection.gettimeout(); connection.settimeout(self.request_drain_timeout_s)
#   (AttributeError/OSError here → return 0)
drained = 0; deadline = monotonic() + self.request_drain_timeout_s
try:
    while remaining > 0 and monotonic() < deadline:
        chunk = rfile.read1(min(4096, remaining))
        if not chunk: break
        remaining -= len(chunk); drained += len(chunk)
except (AttributeError, OSError, ValueError): pass
finally: connection.settimeout(prev)          # OSError ignored
return drained
```

- Called at the start of EVERY `_send` / `_send_no_decision`, so an early
  rejection (403/415/404) or any response to a request whose body was not
  read first drains up to 64 KiB within a 50 ms total deadline. Bytes are
  discarded unparsed and never logged.
- Pinned: drains exactly `len(json body)` for early rejections; drains 0
  after a successful `_read_json_body` (never drains twice); stops at the
  byte cap (`4*limit` advertised → returns `limit`, `rfile.tell() == limit`);
  stops at EOF (advertised 4096, 10 available → 10, second call → 0);
  non-numeric or zero Content-Length → 0 and nothing read; sets timeout to
  `request_drain_timeout_s` then restores the previous value (`None`).
- Rationale: Windows turns a close-with-unread-bytes into WSAECONNABORTED
  and the hook client loses the 403/415/404.

### 1.5 Peer / header validation helpers

`_is_loopback()`:

```python
host = self.client_address[0] if self.client_address else ""
address = ipaddress.ip_address(host)          # ValueError → False
mapped = address.ipv4_mapped (IPv6 only, else None)
return mapped.is_loopback if mapped is not None else address.is_loopback
```

Loopback = any `127.0.0.0/8`, `::1`, or `::ffff:127.x.y.z`. Pinned:
`192.168.1.20`, `10.0.0.5`, `""` → False; `127.0.0.1`, `127.42.7.9`, `::1`,
`::ffff:127.42.7.9` → True.

`_header_values(name)`: all values of a header (`headers.get_all(name) or
[]`; fall back to `[get(name)]` when the headers object has no `get_all`;
`[]` when headers are missing). Header-name matching is case-insensitive.

`_has_valid_loopback_host()` — DNS-rebinding guard for hook ingress:

1. Exactly one `Host` header, a string; else False.
2. `authority = value.strip()`.
3. If it starts with `[`: must fullmatch `\[([^\]]+)\](?::([0-9]{1,5}))?`;
   the bracketed text must parse as an IP equal to `::1` (so `[::1]`,
   `[0:0:0:0:0:0:0:1]` ok); else False. `port` = group 2 (may be None).
4. Else: more than one `:` → False. If it contains `:`, split at the last
   `:` into host/port; empty port (`localhost:`) → False. Host (case-
   insensitive) `localhost` or `localhost.` is accepted; otherwise it must
   parse as an IPv4 address that is loopback (any 127/8). Anything else
   (names, `0.0.0.0`, LAN IPs) → False.
5. No port → True. Port present → `int(port) == server.server_address[1]`
   (the bound port); parse errors → False.

Pinned accept: `localhost`, `localhost.:<port>`, `127.0.0.1:<port>`,
`127.42.7.9:<port>`, `[::1]:<port>`. Pinned reject: `attacker.example`,
`127.0.0.1:<port+1>`.

`_has_json_content_type()`: exactly one `Content-Type` header; its stripped
value must fullmatch, case-insensitively:

```
application/json(?:\s*;\s*charset\s*=\s*(?:utf-8|"utf-8"))?
```

Pinned accept: `application/json`, `Application/JSON; charset=utf-8`,
`application/json; charset="UTF-8"`. Pinned reject (415):
`application/json; charset=latin-1`, `application/json; profile=hook`,
`application/json, text/plain`, `text/plain`.

### 1.6 Stdlib-level behaviour a port should mirror

- Methods other than GET/POST (HEAD, PUT, DELETE, OPTIONS, PATCH) → stdlib
  `send_error(501, "Unsupported method ('X')")`: HTML body,
  `Content-Type: text/html;charset=utf-8`, `Connection: close`, logged via
  `log_error` → `http <ip>: code 501, message Unsupported method ('HEAD')`.
- Malformed request line → 400; HTTP/2+ request version → 505; request
  line > 65536 bytes → 414; header line > 65536 or > 100 headers → 431.
  None of these are relied on by clients; porting them as "4xx/5xx + close
  + one WARNING log line" is sufficient.
- `self.path` is the raw request-target, including any query string. All
  routing is exact string comparison, so `/api/tokens?x=1` → 404 and
  `/api/tokens/` → 404. Only `/api/interaction/` is a prefix match.

---------------------------------------------------------------------------

## 2. Handler class state and shared helpers

### 2.1 Class-level fields (lines 3249–3282), defaults, who sets them

| Field | Default | Set by |
|---|---|---|
| `projects_dir` | None | main: `Path(args.dir)` |
| `agent_status` | None | main: `AgentStatusService` |
| `max_tracker_store` | None | main: `MaxTrackerStore` |
| `github_monitor` | None | main (None unless `--github-repo`) |
| `plans` | `{"claude": None, "codex": None}` | main: `{"claude": args.claude_plan, "codex": args.codex_plan}` |
| `interaction_store` | None | `_configure_interactions` |
| `interaction_timeout_s` | 120.0 | `_configure_interactions`: `max(5.0, --interaction-timeout)` |
| `claude_interactions` | False | `_configure_interactions` |
| `codex_interactions` | False | `_configure_interactions` |
| `interaction_detail` | False | `_configure_interactions` |
| `legacy_claude_panel_v1` | False | `_configure_interactions` |
| `interaction_relay_status` | "off" | `_configure_interaction_relay` ("off"/"disabled"/"ready") |
| `interaction_relay_reason` | None | same (reason string or None) |
| `agent_status_relay_status` | "off" | same |
| `agent_status_relay_reason` | None | same |
| `discovery_status` | "off" | main after bind: `discovery.status` |
| `discovery_reason` | None | main after bind: `discovery.reason` |
| `panel_poll_lock` | Lock | — |
| `panel_poll_candidate_host` | None | `_record_panel_poll` (in-memory only, never served/logged) |
| `panel_poll_candidate_at` | None | same (monotonic) |
| `panel_poll_candidate_count` | 0 | same |
| `panel_last_seen_at` | None | same (monotonic) |
| `panel_last_seen_route` | None | same |
| `panel_last_http_stall_recovery_boot` | False | same |
| `panel_confirm_window_s` | 10.0 | constant |
| `panel_fresh_s` | 15.0 | constant |
| `json_body_timeout_s` | 2.0 | constant |
| `request_drain_limit` | 65536 | constant |
| `request_drain_timeout_s` | 0.05 | constant |

Test pins "provider defaults are strictly off": `claude_interactions is
False`, `codex_interactions is False`, `legacy_claude_panel_v1 is False`,
`interaction_relay_status == "off"`.

### 2.2 Panel presence evidence (`_record_panel_poll`, `_panel_health_snapshot`)

Called at the top of `do_GET` for exactly these paths (before routing,
regardless of the eventual status code): `/api/tokens`,
`/api/agent-status`, `/api/max-tracker`, `/api/github`.

```python
if not client_address: return
if self._is_loopback(): return               # curl on the Mac never counts
host = client_address[0]; if not non-empty str: return
now = monotonic()
recovery_boot = self._header_values("X-VibePulse-Recovery-Boot") == ["http-stall-v1"]
with panel_poll_lock:
    if candidate_host == host and candidate_at is not None \
            and now - candidate_at <= panel_confirm_window_s:   # 10 s
        candidate_count += 1
    else:
        candidate_host = host; candidate_count = 1
    candidate_at = now
    if candidate_count >= 2:
        was_fresh = last_seen_at is not None and now - last_seen_at <= panel_fresh_s  # 15 s
        last_seen_at = now
        last_seen_route = self.path
        last_http_stall_recovery_boot = recovery_boot
        became_ready = not was_fresh
if became_ready:
    log.info("startup-health: panel contact READY via %s", self.path)
```

- Two polls from the same non-loopback IP, each within 10 s of the previous
  one, confirm a panel. Every further poll within the window refreshes
  `last_seen_*`. A different IP resets the candidate.
- `recovery_boot` is True only for exactly one header with exactly the value
  `http-stall-v1` (case-sensitive value). `["http-stall-v1","forged"]` →
  False. The firmware sends it on LAN fetches after an HTTP-stall recovery
  reboot (never to the relay).
- The READY log line fires on the transition into fresh (first confirmation,
  or after a > 15 s gap).
- Class-level, i.e. process-wide.

Snapshot (served under `interactions.panel` on `GET /`):

```python
if last_seen_at is None: return {"status": "waiting"}
age_s = max(0, int(now - last_seen_at))          # truncation
return {"status": "ready" if age_s <= 15.0 else "stale",
        "ageS": age_s, "route": last_seen_route,
        "httpStallRecoveryBoot": bool(recovery_boot)}
```

Pinned: two polls at t=100,101 → after second poll snapshot at t=102
is `{"status":"ready","ageS":1,"route":"/api/agent-status","httpStallRecoveryBoot":false}`
and the READY line was logged; the IP never appears in the snapshot. One
loopback + one LAN poll → `waiting`. `last_seen_at=100`, now=116 →
`{"status":"stale","ageS":16,"route":"/api/tokens","httpStallRecoveryBoot":false}`.
Note `ageS` 15 is still `ready` (`<=`).

### 2.3 The `_reply(produce)` contract (GET routes)

```python
try:
    payload = produce()
except _NotMeasuredYet as pending:
    try: self._send(503, {"error": "usage totals not measured yet",
                          "usageTotals": pending.totals})
    except OSError: pass
    return
except Exception:
    log.exception("500 on %s", self.path)          # ERROR + traceback
    try: self._send(500, {"error": "internal server error"})
    except OSError: pass
    return
try:
    self._send(200, payload)
except (ConnectionError, TimeoutError):
    pass                                           # client went away: silent
except Exception:
    log.exception("500 on %s (response write)", self.path)
    try: self._send(500, {"error": "internal server error"})
    except OSError: pass
```

- Producer errors — INCLUDING `ConnectionError`/`TimeoutError` raised by the
  producer — are server errors: logged with the full cause and answered with
  the sanitized 500. The cause (which may contain paths) must never reach
  the wire; tests assert the body is exactly `{"error":"internal server error"}`
  and that the message text is in the log.
- Write-time `ConnectionError`/`TimeoutError` (BrokenPipe, reset) → silent,
  no second send, no log (pinned: `assertNoLogs`).
- Write-time other exceptions (e.g. unserializable payload → TypeError from
  `json.dumps`, raised before any byte is written) → log
  `500 on <path> (response write)` + traceback, then a 500. Pinned: `_send`
  called twice, second with 500.
- The firmware parsers reject any body containing a top-level `"error"` key
  and any non-200 status, keeping last good values.

### 2.4 JSON encoding (wire-visible detail)

Python `json.dumps(payload)` defaults:

- separators `", "` and `": "` (a space after every comma and colon);
- `ensure_ascii=True`: every non-ASCII character is emitted as `\uXXXX`
  (surrogate pairs for astral); output bytes are pure ASCII;
- `allow_nan=True`: float NaN/±inf would be emitted as `NaN`/`Infinity`
  (invalid JSON; the firmware lexer rejects it). Upstream producers avoid
  non-finite floats; a Swift port must also never emit them (Swift
  `JSONSerialization` throws — map that to the "response write" 500 path);
- `/` is NOT escaped; key order is insertion order (dicts), no sorting;
- Python `True/False/None` → `true/false/null`; ints are arbitrary precision
  (all values here are small); floats use `repr` (shortest round-trip).

Byte-size budgets are computed with this exact encoding:
`interactions.response_fits(payload)` = `len(json.dumps(payload).encode()) <=
RESPONSE_CEILING_BYTES (3584)`. A Swift port that emits compact JSON will be
smaller (safe), but `response_fits` MUST measure the exact bytes the port
will send; do not mix encoders. The canonical view-digest encoding used by
the interaction store is a separate, explicitly specified format (see the
interactions part), not this one.

Publisher and config files use `sort_keys=True` (publisher) and
`sort_keys=True, separators=(",",":")` (config) — not the HTTP encoding.

---------------------------------------------------------------------------

## 3. Routes in detail

### 3.1 `do_GET`

```python
if self.path in ("/api/tokens", "/api/agent-status", "/api/max-tracker", "/api/github"):
    self._record_panel_poll()
if   path == "/api/tokens":        self._reply(self._tokens_payload)
elif path == "/api/agent-status":  self._reply(self._agent_status_payload)
elif path == "/api/max-tracker":   self._reply(self._max_tracker_payload)
elif path == "/api/github":        self._reply(lambda: github_monitor.snapshot()
                                               if github_monitor is not None
                                               else {"v": 1, "enabled": False})
elif path == "/":                  self._reply(self._root_payload)
else:                              self._send(404, {"error": "not found"})
```

GET routes do no Host, Origin, loopback or Content-Type checks. The LAN is
the trust boundary ("do not expose it outward").

#### `/api/tokens` — `_tokens_payload`

```python
payload = get_snapshot(self.projects_dir, max_tracker_store=self.max_tracker_store)
if usage_totals_are_placeholders(payload) and not self._accepts_usage_totals():
    raise self._NotMeasuredYet(payload["usageTotals"])
return payload
```

- `get_snapshot` (other part) returns the v2 tokens payload, always with
  `"v": 2` and an additive `"usageTotals"` block. During the first history
  scan it returns immediately with zero counters and
  `usageTotals = {"state": "refreshing"|"failing", "sinceS": int, "placeholder": true}`.
- `usage_totals_are_placeholders(p)` = `p` is a dict AND `p["usageTotals"]`
  is a dict AND `p["usageTotals"]["placeholder"] is True` (strict boolean).
- `_accepts_usage_totals()`:
  `"usage-totals" in (headers.get("X-VibePulse-Accepts") or "").lower()` —
  first header value only, case-insensitive SUBSTRING test (so
  `"agent-rows, USAGE-TOTALS"` → True; `"something-else"` → False).
- Placeholder + no Accepts → HTTP **503**, body
  `{"error": "usage totals not measured yet", "usageTotals": <the block>}`
  (no counters). Placeholder + Accepts → 200 with the zeros. Measured →
  200 regardless of the header. All pinned by
  `test_placeholders_go_only_to_clients_that_declared_they_understand`.
- Who sends the header: firmware since 2026-09-10 (every fetch, LAN and
  relay), `smoke.py`, the hook scripts. Older flashed firmware does not →
  gets 503 → keeps last values and eventually shows STALE honestly.
- Note: `get_snapshot` is called with `max_tracker_store` → this request
  also feeds Max Tracker's live peak hooks (side effect).

#### `/api/agent-status` — `_agent_status_payload`

```python
payload = self.agent_status.snapshot()         # {"v":2,"seq":N,"agents":{...}}
if self.interaction_store is None: return payload
pending = self.interaction_store.pending_public()   # oldest parked item, or None
if pending is None: return payload
candidate = dict(payload); candidate["pending"] = pending    # appended LAST
if not interactions.response_fits(candidate):              # <= 3584 bytes
    log.warning("the pending entry did not fit in /api/agent-status "
                "(%d jobs) — the agent list takes precedence and "
                "the entry is left out", len(pending))
    return payload
return candidate
```

- `pending` is an optional root key; `v` stays 2. Firmware requires root
  keys `v`, `seq`, `agents` exactly once, `v == 2`, rejects any top-level
  `"error"`, and (in builds where pending is not allowed) rejects `pending`.
- Size: firmware `TK_AGENT_HTTP_BODY_CAP = 4096`; body length ≥ 4096 (by
  `Content-Length` or bytes read) is an overflow and the WHOLE body is
  dropped. The server enforces 3584 only for the with-pending candidate;
  the plain snapshot is not size-checked here (the agent-status part bounds
  it).
- Quirk: the warning's `%d` is `len(pending)` — the number of KEYS in the
  pending dict, not jobs. Port the text; the number is cosmetic.
- Tests pin: without anything parked, `pending` is absent and `v == 2`.

#### `/api/max-tracker` — `_max_tracker_payload`

```python
quota_snapshot = get_snapshot(self.projects_dir, max_tracker_store=self.max_tracker_store)
today = datetime.now().astimezone().date().isoformat()     # local date "YYYY-MM-DD"
payload = self.max_tracker_store.snapshot(today, self.plans)
payload["stale"] = bool(quota_snapshot.get("claudeWeekStale") or
                        quota_snapshot.get("codexWeekStale"))
return payload
```

- `get_snapshot` is called first on purpose: it publishes the fresh quota
  percentages into the tracker (side effect) and supplies the stale signal.
- Top-level `stale` is overwritten (true if either week is stale). Pinned:
  claude stale/codex fresh → true; both fresh → false; codex stale only →
  true. `store.snapshot` receives `plans` as its second positional argument
  (`{"claude": "max20x", "codex": "plus"}` in the test).
- Firmware: v must be 1, `weeks` must equal `TK_MT_WEEKS`, `stale` must be a
  bool, `claude`/`codex` objects; body cap `MT_BODY_MAX = 8192` (≥ 8192
  bytes → rejected).

#### `/api/github`

`github_monitor.snapshot()` if configured, else `{"v": 1, "enabled": false}`.
Enabled shape: `{"v":1,"enabled":true,"repo":"owner/name","project":str|null,
"stale":bool[,"stars":int][,"forks":int][,"eventId":str,"actor":str|null,
"eventStars":int]}` (event keys only within 10 min of detection). Firmware
body cap `GITHUB_BODY_MAX = 768`.

#### `/` — diagnostics, see §4.

### 3.2 `do_POST` — gate order (exact)

```python
claude_route = path in ("/api/hook/question", "/api/hook/permission")
codex_route  = path in ("/api/codex/question", "/api/codex/permission")
answer_route = path.startswith("/api/interaction/")
panic_route  = path == "/api/panic"

1. if claude_route and (store is None or not claude_interactions):
       404 {"error": "interactions are not enabled"}
2. if codex_route and (store is None or not codex_interactions):
       404 {"error": "interactions are not enabled"}
3. if claude_route or codex_route:
       if not _is_loopback():
           log.warning("hook POST from %s rejected — hooks may only come from this machine", ip)
           403 {"error": "hooks must be local"}
       if not _has_valid_loopback_host() or _header_values("Origin"):   # ANY Origin, even "null"
           403 {"error": "hook ingress rejected"}          (no log line)
4. if (answer_route or panic_route) and store is None:
       404 {"error": "interactions are not enabled"}
5. if (claude_route or codex_route or answer_route or panic_route) \
        and not _has_json_content_type():
       415 {"error": "application/json required"}
6. dispatch:
   claude_route            → _handle_hook("question" if path.endswith("question") else "approval")
   "/api/codex/question"   → _handle_codex_question()
   "/api/codex/permission" → _handle_codex_permission()
   store is None           → 404 {"error": "interactions are not enabled"}
   answer_route            → _handle_answer(path[len("/api/interaction/"):])
   panic_route             → _handle_panic()
   else                    → 404 {"error": "not found"}
```

Consequences worth preserving:

- Disabled routes are answered on headers alone; the body is never parsed
  (tests assert `_read_json_body` not called) but IS drained by `_send`.
- The Claude flag alone does not enable Claude routes; the store must also
  exist (and vice versa). Provider switches are independent: Claude on,
  Codex off → `/api/codex/*` 404; and the reverse.
- `/api/interaction/*` and `/api/panic` accept LAN peers (the panel), any
  Host, any Origin. Only the HMAC protects them (verified in the store).
- An unknown POST path returns 404 "interactions are not enabled" when
  interactions are off, "not found" when on.
- Every rejection happens before parking; tests assert nothing appears in
  `/api/agent-status.pending`.

### 3.3 `_handle_hook(kind)` — Claude Code hooks

```python
event = self._read_json_body()                         # limit 64 KiB
if not isinstance(event, dict): return self._send_no_decision()
park = store.park_legacy if self.legacy_claude_panel_v1 else store.park
entry = park(kind, event, self.interaction_timeout_s)  # kind: "question" | "approval"
if entry is None: return self._send_no_decision()      # unrenderable or queue full (8)
try:
    body = store.await_verdict(entry, is_alive=lambda: not self._hook_client_gone())
except Exception:
    log.exception("the interaction crashed — leaving the decision to the terminal")
    body = None
try:
    if body is None: self._send_no_decision()
    else:            self._send(200, body)             # Claude hookSpecificOutput JSON
except (ConnectionError, TimeoutError, OSError): pass  # Claude Code gave up
```

- The request thread BLOCKS for up to `interaction_timeout_s` (default 120,
  min 5) holding its worker slot. `await_verdict` polls liveness every
  `interactions.ALIVE_POLL_S = 2.0` s.
- Garbage bodies (`null`, `[]`, `"nope"`, `{"tool_input":5}`) → 200 empty
  body immediately. Timeout → 200 empty body.
- Response bodies (built by the store): question approve →
  `{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"answers":{…}},…}}`;
  approval → `{"hookSpecificOutput":{"decision":{"behavior":"allow"|"deny"},…}}`.

`_hook_client_gone()`:

```python
readable, _, _ = select.select([self.connection], [], [], 0)
if not readable: return False
return self.connection.recv(1, socket.MSG_PEEK) == b""     # EOF → gone
# OSError/ValueError → True
```

The body was fully read before parking, so readability means EOF (or a
pipelined request, which hook clients never send → treated as alive).
Pinned at the wire: an abandoned hook leaves `pending` within
`ALIVE_POLL_S + 5` s.

### 3.4 `_handle_codex_question()`

```python
event = self._read_json_body()
identity = {"cwd", "session_id", "turn_id"}; question_fields = {"question", "header", "options"}
if (not isinstance(event, dict) or not identity <= set(event)
        or not {"question", "options"} <= set(event)
        or set(event) - identity - question_fields):          # unknown key → invalid
    return self._send(200, {"status": "computer", "reason": "invalid"})
question = {k: event[k] for k in question_fields if k in event}
normalized = normalize_codex_question(question, cwd=event["cwd"],
                                      session_id=event["session_id"], turn_id=event["turn_id"])
if normalized is None: return 200 {"status":"computer","reason":"invalid"}
if not self.interaction_detail:
    normalized = {**normalized,
        "options": [{k: v for k, v in o.items() if k != "recommended"} for o in normalized["options"]],
        "recommended_index": None,
        "view": {"kind": "question", "options_total": len(normalized["options"]),
                 "marked": False, "can_approve": False}}
entry = store.park_normalized(normalized, self.interaction_timeout_s)
if entry is None: return 200 {"status":"computer","reason":"unavailable"}
try:   result = store.await_result(entry, is_alive=lambda: not self._hook_client_gone())
except Exception:
    log.exception("the Codex question crashed — leaving the decision to the computer")
    result = None
try:
    if result is None:
        reason = "disconnected" if self._hook_client_gone() else "timeout"
        self._send(200, {"status": "computer", "reason": reason})
    else:
        self._send(200, codex_question_result(result.verdict, normalized))
except (ConnectionError, TimeoutError, OSError): pass
```

- Always HTTP 200. Result bodies: approve →
  `{"status":"answered","option_index":0,"answer":"<label>"}` (only the
  explicit recommendation can be answered); deny →
  `{"status":"computer","reason":"deny"}`; leave-it →
  `{"status":"computer","reason":"leave_it"}`; timeout →
  `{"status":"computer","reason":"timeout"}`.
- Invalid envelopes pinned: extra key, nested `{"question": {...}}` shape,
  `session_id: null`, a single option → `invalid`, never parked, returns in
  < 5 s. Empty `{}` → `invalid`.
- Detail off: no question/option text, `can_approve=false`,
  `marked=false`; an approve answer is refused with 409 by the store.
- `legacy_claude_panel_v1` never affects Codex (always v2-bound).

### 3.5 `_handle_codex_permission()`

```python
event = self._read_json_body()
normalized = normalize_codex_permission(event, reveal=self.interaction_detail)
if normalized is None: return self._send_no_decision()
entry = store.park_normalized(normalized, self.interaction_timeout_s)
if entry is None: return self._send_no_decision()
try:   result = store.await_result(entry, is_alive=...)
except Exception:
    log.exception("the Codex permission crashed — leaving the decision to the computer")
    result = None
body = codex_permission_response(result.verdict) if result is not None else None
body is None → _send_no_decision() else _send(200, body)     # write errors ignored
```

Bodies: approve → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`;
deny → `…"decision":{"behavior":"deny","message":"Denied from VibePulse"}`;
leave-it / timeout / invalid (`null`, `[]`, `{"hook_event_name":"PreToolUse"}`)
→ 200 empty body.

### 3.6 `_handle_answer(request_id)` — `POST /api/interaction/<id>`

```python
payload = self._read_json_body(limit=4096)
if not isinstance(payload, dict): return self._send(400, {"ok": False, "reason": "bad request"})
ok, reason = store.resolve(request_id, payload.get("verdict"), payload.get("ts"),
                           payload.get("hmac"), provider=payload.get("provider"),
                           view_sha256=payload.get("view_sha256"))
self._send(200 if ok else 409, {"ok": ok, "reason": reason})
```

- `request_id` = everything after the prefix, unvalidated here (may be empty
  or contain `/` or `?…`); the store validates.
- Body limit 4096 (firmware body buffer is 256 bytes). Device body v2:
  `{"provider","view_sha256","verdict","ts","hmac"}`; v1 legacy:
  `{"verdict","ts","hmac"}`.
- Forged HMAC → 409 `{"ok":false,…}` and the item stays pending.

### 3.7 `_handle_panic()` — `POST /api/panic`

```python
payload = self._read_json_body(limit=4096)
if not isinstance(payload, dict): 400 {"ok": False, "reason": "bad request"}
accepted, denied = store.panic(payload.get("ts"), payload.get("hmac"))
if not accepted: 409 {"ok": False, "reason": "signature rejected"}
log.warning("panic stop from the device: %d pending decisions denied", denied)
200 {"ok": True, "denied": denied}
```

Signed message is `sign_answer(secret, "panic", "deny", ts)`. Pinned: a
parked approval is denied and `denied == 1`; `hmac = "0"*64` → 409.

---------------------------------------------------------------------------

## 4. `GET /` diagnostics payload (`_root_payload`, 3891–3960)

Never parsed by the firmware; consumed by `smoke.py`, `vibepulse_setup.py
doctor`, the Swift menu-bar app (`tools/vibepulse-bar`,
`ServerDiagnostics.swift`), and humans. Fields may be ADDED freely; existing
names/types must not change.

Exact key order and types (insertion order of the Python dict):

```jsonc
{
  "service": "torget-tokenserver",            // constant; smoke FAILs otherwise
  "rev": "81c8f46",                           // git rev-parse --short HEAD at start, or "unknown"
  "srcFingerprint": "48aff3d4a708",           // 12 hex, or "unknown" (§4.2)
  "startedAt": "2026-09-23T17:56:48+08:00",   // local time, ISO-8601, seconds, with offset; import time
  "endpoint": "/api/tokens",                  // constant
  "endpoints": ["/api/tokens", "/api/agent-status", "/api/max-tracker", "/api/github"],
  "github": { "v": 1, "enabled": false },     // same object as GET /api/github

  // ---- _probe_view(): one locked read of the Claude probe state ----
  "claudeProbe": "usage_http_200 + ok",       // str status word (e.g. "not_run", "no_claude_oauth_token: keychain_no_entry", "usage_http_401", …)
  "claudeProbeStreak": 0,                     // int consecutive misses
  "claudeProbeIntervalS": 240,                // int(current probe interval)
  "claudeProbeCooldownLeftS": null,           // int ceil(seconds of 429 rest left) or null when <= 0
  "claudeProbeAgeS": 17,                      // int seconds since last completed probe, or null if never (monotonic 0.0 = never)
  "claudeCredential": {"status": "ready", "expiresInMin": 480},
      // status ∈ "unknown" (initial) | "unavailable" | "expired" | "expiring" | "ready";
      // "expiresInMin": int (present for expired=0/expiring/ready);
      // optional "reason": keychain word (macOS, when no candidates)
  "ratelimitHeaders": ["anthropic-ratelimit-unified-7d-utilization"],  // header NAMES only, never values
  "unknownRateLimitBuckets": ["7d_haiku"],    // list[str]

  // ---- _codex_probe_view() ----
  "codexProbe": "usage_http_200 + ok",        // str ("not_run", "cli", "usage_request_failed", "probe_held_by_other_instance", "usage_http_429 + backoff_until_…", …)
  "codexProbeStreak": 0,
  "codexProbeIntervalS": 240,
  "codexProbeCooldownLeftS": null,
  "codexProbeAgeS": 1262,

  // ---- subscription_quota.diagnostics(): grok then cursor ----
  "grokProbe": "usage_http_200 + ok",  "grokProbeIntervalS": 240,
  "grokProbeCooldownLeftS": null,      "grokProbeAgeS": 1262,
  "cursorProbe": "usage_http_200 + ok","cursorProbeIntervalS": 240,
  "cursorProbeCooldownLeftS": null,    "cursorProbeAgeS": 1262,

  "claudeLocalUsage": "missing",
      // _claude_plan_usage_status: "not_checked" | "missing" | "invalid" | "invalid_size" |
      // "unsupported" | "stale" | "fresh" | "oauth_newer" | "fresh_without_reset" |
      // "not_higher" | "fresh_applied"
  "claudeStatusline": {
      "status": "not_installed",   // "not_checked"|"not_installed"|"missing"|"unreadable"|"invalid"|"empty"|"stale"|"fresh"
      "ageS": null,                // int|null
      "claudeCodeVersion": null,   // str|null
      "bridged": false,            // bool: both statusline windows cover the probe
      "account": "assumed-single"  // constant
  },
  "quotaRegressions": [            // unexpired OBS-39 evidence, pruned at read (resetAt <= now), sorted by "at"
      // {"provider": "claude", "scope": "week", "livePct": 41.2, "cachedPct": 43.0,
      //  "resetAt": 1790000000, "at": 1789000000}
  ],
  "usageComputeOk": true,                      // _compute_failing_since is None
  "usageComputeFailingForS": null,             // int(now - failing_since) or null — from ONE read
  "usageTotals": {"state": "ready", "ageS": 1263, "placeholder": false},
      // or {"state": "refreshing"|"failing", "sinceS": int, "placeholder": true}
      // or {"state": "failing", "ageS": int|null, "placeholder": false}
  "maxTrackerSaveOk": true,                    // _max_tracker_save_failing_since is None
  "maxTrackerSaveFailingForS": null,           // int or null — from ONE read
  "discovery": {"status": "ready"},            // + "reason": str only when not None
      // status: "off" (not started) | "ready" | "unavailable" (reason "dependency-missing" | "no-lan-address")
      //         | "error" (reason "invalid-port" | exception class name)
  "interactions": {
      "claude": false, "codex": false, "detail": false,
      "legacyClaudePanelV1": false,
      "relay": {"status": "off"},              // + "reason" only when not None
      "agentStatusRelay": {"status": "off"},   // + "reason" only when not None
      "panel": {"status": "waiting"},          // or {"status":"ready"|"stale","ageS":int,"route":str,"httpStallRecoveryBoot":bool}
      "transport": "lan"                       // "lan+encrypted-relay" iff either relay status == "ready"
  }
}
```

### 4.1 Consistency rules (keep them)

- `failing_since` and `save_failing_since` are each read ONCE into locals;
  the `ok` flag and the `…ForS` duration derive from the same read (a
  recovery between two reads would put None into the subtraction → 500 on
  the diagnostics route itself).
- `_probe_view` copies status, credential (a copy), headers, unknown
  buckets, streak, interval, last-probed time and cooldown under ONE lock
  (`_limits_lock`), so status and evidence always describe the same cycle.
  `claudeProbeCooldownLeftS = int(ceil(cooldown_until - wall_now))` if > 0
  else null. `claudeProbeAgeS = int(monotonic_now - last_probed)` if
  `last_probed` is truthy else null. Codex identically under
  `_codex_limits_lock`.
- `usageTotals` is computed under `_cache_lock` with
  `have_result = (_last_result is not None)`:
  - no result: `{"state": "failing" if compute_failing else "refreshing",
    "sinceS": int(monotonic_now - _SERVER_STARTED_MONO), "placeholder": true}`;
  - result: `{"state": "failing" if compute_failing else "ready",
    "ageS": int(monotonic_now - _last_result_at) or null if unset,
    "placeholder": false}`.
  `_SERVER_STARTED_MONO` is captured at module import.
- Privacy: no header values, response bodies, tokens, keys, paths, IPs, or
  secrets. Test asserts the serialized `interactions` block contains neither
  "secret" nor "key" (case-insensitive) and "response body" is absent from
  the whole payload. The panel IP is never included.
- Relay/discovery `reason` keys are omitted (not null) when there is no
  reason. Pinned: `{"status":"off"}`, `{"status":"ready"}`,
  `{"status":"disabled","reason":"mac-token-missing"}`.

### 4.2 `rev`, `srcFingerprint`, `startedAt` (computed once at import)

- `rev` = stdout of `git rev-parse --short HEAD` run with cwd = the
  directory of `tokenserver.py`, 5 s timeout, stripped; empty or any error →
  `"unknown"`.
- `srcFingerprint` = first 12 hex chars of SHA-256 over, for each `*.py`
  file directly in the tokenserver directory, sorted by path, skipping names
  starting with `test_` and `smoke.py`: `digest.update(name_utf8)` then
  `digest.update(file_text_utf8)` where the text is read in text mode
  (universal newlines → CRLF/CR normalized to LF). Any error → `"unknown"`.
- **Porting hazard**: `smoke.py` and `vibepulse_setup.py doctor` recompute
  this from the Python sources on disk (`_read_source_fingerprint()`) and
  compare. smoke WARNs ("the server runs different source than the
  checkout … restart the service") and doctor prints `FIX Tokenserver
  source` on mismatch; a missing/None fingerprint is not judged by smoke
  but IS a FIX in doctor (`!=`). A Swift binary must either (a) compute the
  same hash over the same `tools/tokenserver/*.py` set at start (keeps both
  tools green but is then not a fingerprint of the running code), or
  (b) the tools must be updated in the same change. Decide explicitly.
- Likewise `rev` is compared by smoke to the checkout's
  `git rev-parse --short HEAD` (WARN on mismatch).
- `startedAt` = `datetime.now().astimezone().isoformat(timespec="seconds")`,
  e.g. `2026-09-23T17:56:48+08:00` (local offset, no fractional seconds).

---------------------------------------------------------------------------

## 5. Command line (`_build_arg_parser`, 3972–4079)

`argparse.ArgumentParser(description=<first line of module docstring>)`:
"The token meter's service: Claude Code usage as flat JSON over the LAN."
argparse semantics that matter: `--flag=value` and `--flag value` both
work; unique-prefix abbreviations are accepted (`--por 8737`,
`--interaction-t 30`); errors print usage to stderr and exit **2**; `-h`
prints help, exit 0; mutually exclusive violations print
`argument X: not allowed with argument Y` (pinned substring).

| Flag | Type / action | Default | Notes |
|---|---|---|---|
| `--port` | int | 8737 | bind port (0.0.0.0) |
| `--dir` | str | `os.path.expanduser("~/.claude/projects")` | Claude projects dir → `Handler.projects_dir` |
| `--claude-plan` | choice `pro`, `max5x`, `max20x` | None | Max Tracker badge; unknown → exit 2 |
| `--plan` | append, `PROVIDER=USD` | `[]` | repeatable; parsed by `value_meter.parse_plan_costs` |
| `--plan-cost-usd` | float | None | deprecated alias for `--plan claude=USD` |
| `--prices` | path | None | JSON merged over `prices.json`; bad file = hard startup failure |
| `--codex-plan` | choice `plus`, `pro` | None | Max Tracker badge |
| `--github-repo` | `normalize_repo` | env `VIBEPULSE_GITHUB_REPO` or None | must match `^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$` after strip; argparse applies the type to a string default too, so an invalid env value exits 2 (`invalid normalize_repo value`) |
| `--publish` | str `RELAY_URL` | None | numbers relay mailbox URL incl. secret path |
| `--publish-name` | str | None → `socket.gethostname().split(".")[0]` | publisher name |
| `--interactions` | store_true | False | deprecated alias = `--claude-interactions`; mutually exclusive with `--claude-interactions/--no-claude-interactions` |
| `--claude-interactions` / `--no-claude-interactions` | BooleanOptionalAction | None | tri-state; saved |
| `--codex-interactions` / `--no-codex-interactions` | BooleanOptionalAction | None | saved |
| `--interaction-detail` / `--no-interaction-detail` | BooleanOptionalAction | None | saved; privacy widening |
| `--legacy-claude-panel-v1` / `--no-legacy-claude-panel-v1` | BooleanOptionalAction | None | saved; INSECURE compat |
| `--interaction-relay HTTPS_ORIGIN` | str | None | mutually exclusive with `--no-interaction-relay`; saved (URL + enable) |
| `--no-interaction-relay` | store_const False, dest `interaction_relay` | — | so `interaction_relay` ∈ {None, False, "<url>"} |
| `--agent-status-relay` / `--no-agent-status-relay` | BooleanOptionalAction | None | saved |
| `--interaction-timeout` | float | 120.0 | seconds to hold a hook; clamped to ≥ 5.0 in `_configure_interactions` |

Help text must contain (pinned): `--no-claude-interactions`,
`--no-codex-interactions`, `--no-interaction-detail`,
`--legacy-claude-panel-v1`, `--no-legacy-claude-panel-v1`,
`--interaction-relay`, `--no-interaction-relay`, `--agent-status-relay`,
`--no-agent-status-relay`, and the words "saved" and "disable"
(case-insensitive).

Who passes which flags in production: the launchd plist passes NONE
(`python -u tokenserver.py`, cwd `tools/tokenserver`); interaction
switches come from the saved config. `run-windows-task.ps1` may pass
`--github-repo`, `--claude-plan`, `--codex-plan`, `--plan claude=…`,
`--plan codex=…`, `--publish`, `--publish-name`. VibePulse Bar passes
`--port N` (and parses `--port` from user-configured args). All flags must
be accepted by a drop-in replacement.

### 5.1 Environment variables read by this range (directly or at startup)

| Variable | Used for |
|---|---|
| `VIBEPULSE_GITHUB_REPO` | default of `--github-repo` |
| `GITHUB_TOKEN`, then `TG_GITHUB_TOKEN` | GitHub token (first non-blank, stripped) |
| `VIBEPULSE_DEVICE_KEY`, then `TK_VIBEPULSE_DEVICE_KEY` | device HMAC key (`interactions.read_device_key`) |
| `VIBEPULSE_INTERACTION_MAC_TOKEN` | relay Mac-role bearer |
| `CODEX_HOME` | `CODEX_SESSIONS = ($CODEX_HOME or ~/.codex)/sessions`, resolved at import |
| `LOCALAPPDATA` | Windows state dir |
| `HOME` (via `Path.home()`) | everything under `~` |

### 5.2 Files read/written by this range

| Path (macOS) | Purpose |
|---|---|
| `~/Library/Application Support/VibePulse/` | state dir (`_state_dir()`); Windows `%LOCALAPPDATA%\VibePulse` (fallback `~/AppData/Local/VibePulse`) |
| `<state>/config.json` | saved interaction switches (strict JSON, ≤ 16 KiB, mode 0600, dir 0700) |
| `<state>/.config.json.lock` | cross-process `flock` for config transactions |
| `<state>/max-tracker.json` | MaxTrackerStore |
| `~/Library/Logs/torget-tokenserver.log` (+ `.old`) | log (Windows: `<state>/Logs/…`) |
| `~/.torget-github-token`, `<repo>/.github-token`, `<repo>/secrets.h` | GitHub token fallbacks |
| `~/.vibepulse-device-key`, `<repo>/secrets.h` (`TK_VIBEPULSE_DEVICE_KEY`) | device key fallbacks |
| `~/.vibepulse-interaction-relay-token` | relay Mac token (must be a regular file, mode exactly 0600 on POSIX) |

`<repo>` = `Path(tokenserver.py).resolve().parents[2]` (the checkout root).

---------------------------------------------------------------------------

## 6. Interaction configuration

### 6.1 `_resolve_interaction_config(args, path=None)` → `VibePulseConfig`

`VibePulseConfig` fields (frozen, validated): `claude_interactions`,
`codex_interactions`, `interaction_detail`, `legacy_claude_panel_v1`,
`interaction_relay`, `agent_status_relay` (all strict `bool`, default
False), `interaction_relay_url: str|None` (must be an `https://` origin:
printable ASCII, host present, no userinfo, path `""`/`"/"`, no query/
fragment, port 1–65535), `interaction_mailbox: str|None` (fullmatch
`vp_[A-Za-z0-9_-]{16}`). Invalid values raise `ConfigError`.

Algorithm (entire read-merge-write under `config_lock(config_path)`: an
in-process RLock + `flock(LOCK_EX)` on `<dir>/.config.json.lock`):

```python
config_path = Path(path) if path else _state_dir() / "config.json"
with config_lock(config_path):
    invalid_saved = False
    try: saved = load_config(config_path)          # missing file → all-default config
    except ConfigError:
        log.error("invalid VibePulse configuration in %s — saved interactions are turned off",
                  config_path, exc_info=True)
        saved = VibePulseConfig(); invalid_saved = True
    claude_override = True if args.interactions else args.claude_interactions
    chosen = lambda saved_v, override: saved_v if override is None else override
    resolved = VibePulseConfig(
        claude_interactions   = chosen(saved.claude_interactions, claude_override),
        codex_interactions    = chosen(saved.codex_interactions, args.codex_interactions),
        interaction_detail    = chosen(saved.interaction_detail, args.interaction_detail),
        legacy_claude_panel_v1= chosen(saved.legacy_claude_panel_v1, args.legacy_claude_panel_v1),
        interaction_relay     = chosen(saved.interaction_relay,
                                       True if isinstance(args.interaction_relay, str)
                                       else args.interaction_relay),        # None | False | True
        agent_status_relay    = chosen(saved.agent_status_relay, args.agent_status_relay),
        interaction_relay_url = args.interaction_relay if isinstance(args.interaction_relay, str)
                                else saved.interaction_relay_url,
        interaction_mailbox   = saved.interaction_mailbox)                   # never from CLI
    explicit = any of (claude_override, codex, detail, legacy, interaction_relay,
                       agent_status_relay) is not None
    if explicit: save_config(config_path, resolved)      # may repair a bad file
    elif invalid_saved: return VibePulseConfig()          # fail closed
    return resolved
```

- `--no-interaction-relay` sets `interaction_relay=False` but keeps the URL
  and mailbox. `--interaction-relay URL` sets both enable and URL.
- Explicit choices persist BEFORE the port is bound (they survive a bind
  failure).
- An invalid CLI URL (e.g. `http://…`) raises `ConfigError` out of
  `VibePulseConfig(...)` → uncaught → traceback, exit 1.
- `save_config`: `mkstemp(prefix=".config.json.", dir)`, fchmod 0600, write
  `json.dumps(asdict(cfg), sort_keys=True, separators=(",",":")) + "\n"`,
  fsync, `os.replace`, chmod 0600, fsync the directory. `load_config`:
  refuses symlinks/non-regular files, > 16 KiB, duplicate keys, unknown
  keys, non-bool switches.

Pinned tests: saved all-on + `--no-codex-interactions` flips only codex
and persists; all `--no-*` → all off but URL/mailbox kept; concurrent
`--claude-interactions` and `--codex-interactions` in two forked processes
merge to both True (no lost update); legacy alias enables only Claude;
no-arg run returns the persisted config; invalid saved file +
`--claude-interactions` → logs ERROR, returns and saves
`VibePulseConfig(claude_interactions=True)`; `--legacy-claude-panel-v1` then
`--no-legacy-claude-panel-v1` round-trips without touching others; relay
enable/disable keeps providers, URL, mailbox.

### 6.2 `_configure_interactions(config, interaction_timeout, audit=None)` → secret|None

```python
Handler.claude_interactions = config.claude_interactions
Handler.codex_interactions  = config.codex_interactions
Handler.interaction_detail  = config.interaction_detail
Handler.legacy_claude_panel_v1 = config.legacy_claude_panel_v1
Handler.interaction_store = None
Handler.interaction_timeout_s = max(5.0, interaction_timeout)
if not (config.claude_interactions or config.codex_interactions): return None
secret = interactions.read_device_key()          # env → ~/.vibepulse-device-key → secrets.h
Handler.interaction_store = InteractionStore(secret=secret or "",
                                              reveal_detail=config.interaction_detail, audit=audit)
return secret
```

Store exists iff at least one provider is enabled (pinned; `detail` alone →
no store). A store with an empty secret parks hooks but refuses every
answer (they fall back to the terminal on timeout).

### 6.3 `_read_interaction_mac_token(path=None, environ=None)`

Valid token: fullmatch `[A-Za-z0-9_-]{43}`, base64url-decodes (with one `=`
appended, strict) to exactly 32 bytes, and re-encodes (unpadded base64url)
to the identical string (canonical).

1. If env `VIBEPULSE_INTERACTION_MAC_TOKEN` is set: valid → return it;
   invalid → return None (do NOT fall back to the file).
2. File `~/.vibepulse-interaction-relay-token` (or `path`): `lstat` must be
   a regular non-symlink file; on POSIX mode must be exactly 0600; open
   `O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK`; `fstat` must be regular and
   identical (dev/ino) to both the before- and after-`lstat`, mode still
   0600; read up to 257 bytes, > 256 → None; strict ASCII; strip ONE
   trailing `\n`; must be valid. Any OSError → None. Value never logged.

Pinned: mode 0644 → None, 0600 → token; `short`, token+`=`, 42 or 44 `A`s,
43 `é` → rejected before the relay factory is called.

### 6.4 `_configure_interaction_relay(config, secret, *, environ=None, relay_factory=None, audit=None)` → adapter|None

```python
reset all four Handler relay status/reason fields to "off"/None
want_i, want_s = config.interaction_relay, config.agent_status_relay
if not (want_i or want_s): return None          # optional crypto never imported
pub_i, pub_s = want_i, want_s
if pub_i and (not (claude or codex) or Handler.interaction_store is None):
    disable_i("provider-required"); pub_i = False
if pub_i and not config.interaction_detail:
    disable_i("detail-required"); pub_i = False
status_source = getattr(Handler.agent_status, "snapshot", None)
if pub_s and not callable(status_source):
    disable_s("status-source-missing"); pub_s = False
if not (pub_i or pub_s): return None
# shared requirements; failure disables whichever of the two is still wanted:
secret must fullmatch [0-9A-Fa-f]{64}        else "device-key-missing"
config.interaction_relay_url is not None     else "url-missing"
config.interaction_mailbox is not None       else "mailbox-missing"
mac_token = _read_interaction_mac_token(environ=environ) else "mac-token-missing"
adapter = relay_factory or InteractionRelay (lazy import) (
    store=Handler.interaction_store if pub_i else None,
    publish_interactions=pub_i, publish_agent_status=pub_s,
    status_source=status_source if pub_s else None,
    base_url=config.interaction_relay_url, mailbox=config.interaction_mailbox,
    mac_token=mac_token, device_key_hex=secret, audit=audit)
adapter.start()
ImportError → "crypto-unavailable"; any other Exception → best-effort adapter.stop(), "configuration-invalid"
success: pub_i → interaction_relay_status="ready", reason None; pub_s → agent_status_relay_status="ready", reason None
return adapter
```

"disabled" sets `status="disabled"` + reason. Reasons are fixed,
content-free strings (pinned that an ImportError message containing a path
never leaks into the reason). Pinned: default off never calls the factory
and leaves the store untouched; status-only relay starts without providers,
detail or store (`store=None`, `publish_interactions=False`,
`status_source()` returns the agent-status snapshot); both relays share one
adapter; missing status source disables only the status relay; each missing
requirement yields its reason and `adapter is None`.

In `main`, the relay is called with the secret from `_configure_interactions`,
or — when no provider is on but `agent_status_relay` is saved — with
`interactions.read_device_key()`.

---------------------------------------------------------------------------

## 7. Background workers

| Thread name | Started in | Cadence | Stops |
|---|---|---|---|
| `log-rotation-watch` | main, right after logging setup | every 3600 s (`_LOG_ROTATE_CHECK_S`) | never (its Event is never set; daemon) |
| `github-monitor` | `GitHubMonitor.start()` if `--github-repo` | poll every 120 s; 10 min backoff on failure | `stop()` → join ≤ max(1, min(poll, 5)) s |
| `first-scan-warmup` | main before AgentStatusService | once | daemon |
| AgentStatusService thread(s) | `status_service.start()` | 0.5 s poll (`agent_status.POLL_S`) | `status_service.stop()` |
| `relay-publisher` | `Publisher.start()` if `--publish` | first pass immediately, then every 30 s check | `stop()` → join ≤ 5 s |
| InteractionRelay threads | `adapter.start()` if relay ready | (relay part) | `adapter.stop()` |
| `max-tracker-backfill` | main | `MAX_TRACKER_BACKFILL_TICK_S = 0.5` s | `backfill_stop.set()` + join ≤ max(1.0, 0.5×4)=2.0 s |
| `max-tracker-writer` | on demand by `_mark_max_tracker_dirty` | one-shot coalescing writer | exits when not dirty |
| zeroconf threads | `DiscoveryAdvertiser.start()` | — | `discovery.stop()` |
| per-request threads | server | — | daemon |
| (on-demand) `codex-limit-scan`, usage refresh threads | other parts | — | daemon |

### 7.1 `_run_max_tracker_backfill(store, stop_event)`

```python
last_error_logged = None          # None, NOT 0.0 (monotonic counts from boot)
while not stop_event.is_set():
    try:
        if store.backfill_step():            # True = progress made
            _mark_max_tracker_dirty(store)   # queue an async atomic save
    except Exception as exc:
        now = monotonic()
        if last_error_logged is None or now - last_error_logged >= 600:
            last_error_logged = now
            log.warning("max-tracker backfill step failed: %s: %s", type(exc).__name__, exc)
    if stop_event.wait(MAX_TRACKER_BACKFILL_TICK_S): break
```

Never switches itself off (idle steps only glob + stat). Pinned: first
failure logs immediately even at monotonic 42.0; subsequent ones within
600 s are throttled (3 calls → 1 line containing `RuntimeError: <msg>`);
progress marks dirty each tick; idle never marks dirty; stops promptly.

`_mark_max_tracker_dirty(store)`: under a lock set `dirty=True`; if no
writer is running, mark running and start one `max-tracker-writer` thread.
The writer loops: take-and-clear dirty → `store.save()`; on success, if an
error episode was open, log `max-tracker: save succeeded again after %.0f s`
and clear `_max_tracker_save_failing_since`; on exception set
`failing_since` (first time), log `max-tracker: save failed — the
observations stay in memory and the next attempt is coming` with traceback
at most every 300 s (`_ERROR_LOG_THROTTLE_S`), re-mark dirty, stop running
(no hot loop; the next mark or the final flush retries). Feeds
`maxTrackerSaveOk`/`maxTrackerSaveFailingForS`.

### 7.2 `_first_scan_warmup()` (nested in main)

```python
t0 = monotonic()
with _cache_lock:
    claimed = _last_result is None and not _snapshot_refreshing
    if claimed: _snapshot_refreshing = True
if claimed: _refresh_usage_totals(Handler.projects_dir)       # NOTE: max_tracker_store not passed
else:
    while _last_result is None and monotonic() - t0 < FIRST_SCAN_WAIT_S:  # 600 s
        sleep(0.2)
snap = _last_result
if snap is None:
    log.warning("the first scan produced no result in %.0f s — /api/tokens serves "
                "placeholders until a recompute succeeds", monotonic() - t0); return
if not snap.get("claudeSourcePresent", True):
    log.info("first scan %.1f s: no Claude source on this machine — volume unknown, not zero",
             monotonic() - t0); return
log.info("first scan %.1f s: %s tokens today, %d sessions, %s this month",
         monotonic() - t0,
         f"{snap['dayTokens']:,}".replace(",", " "),     # thousands separated by SPACES
         snap["daySessions"],
         f"{snap['monthTokens']:,}".replace(",", " "))
```

Pinned (source inspection): the `claudeSourcePresent` check precedes the
counter formatting. `_refresh_usage_totals` (other part) swaps the result
in under `_cache_lock`, sets `_last_result_at`, clears `_snapshot_refreshing`,
and on crash sets `_compute_failing_since` + logs
`usage recompute crashed — /api/tokens serves frozen figures until it
succeeds again` (throttled 300 s), recovery logs
`usage recompute healthy again after %.0f s`.

### 7.3 Log rotation

- `DEFAULT_LOG_PATH = _log_dir() / "torget-tokenserver.log"`; `_log_dir()`
  = `~/Library/Logs` (macOS/Linux) or `<state>/Logs` (Windows).
- `_LOG_CAP_BYTES = 5*1024*1024`, `_LOG_TAIL_KEEP_BYTES = 256*1024`.

`_maybe_rotate_own_log(path=None, stderr_fd=2)` → bool:

```python
path = path or DEFAULT_LOG_PATH
st = path.stat()                      # OSError → return False (terminal run / fresh install)
acquire every root-logger handler lock (in order)
try:
    if st.st_size <= CAP: return False
    own = fstat(stderr_fd)
    if (own.st_dev, own.st_ino) != (st.st_dev, st.st_ino): return False   # stderr is not this file
    with open(path, "rb+") as fh:
        fh.seek(max(0, st.st_size - TAIL_KEEP))
        tail = fh.read()                              # to the ACTUAL EOF (may exceed 256 KiB)
        (path + ".old").write_bytes(tail)             # overwrite
        fh.truncate(0)                                # truncate in place, never rename
    log.info("log file rotated (%d bytes > the cap %d; the tail is in %s.old)",
             st.st_size, CAP, path.name)
    return True
except Exception:
    log.warning("log rotation of %s failed", path, exc_info=True); return False
finally: release handler locks in reverse order
```

Why truncation: launchd holds the fd with `O_APPEND`; a rename would keep
writing into the moved file. The handler locks (re-entrant) keep log lines
from other threads out of the read→truncate window; raw stderr writes
(agent_status diagnostics) are not covered. Pinned: rotates only when
stderr IS the file; `.old` = last 256 KiB ending with the file's last line;
file size 0 afterwards; handler lock acquired ≥ 1×; `stderr_fd=2` in a
terminal → untouched; under cap / missing file → no-op.

`_run_log_rotation_watch(stop_event, interval_s=None)`:
`while not stop_event.wait(interval or 3600): _maybe_rotate_own_log()`.
Pinned: repeats until stopped, exits on stop.

---------------------------------------------------------------------------

## 8. `main()` — startup order (4390–4645)

1. `args = _build_arg_parser().parse_args()` (exit 2 on bad args; nothing
   logged yet).
2. `logging.basicConfig(stream=sys.stderr, level=INFO,
   format="%(asctime)s %(levelname)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S")`.
   Line format: `2026-08-13 21:21:47 INFO starting: rev 7385cb3`. Level
   names: `INFO`, `WARNING`, `ERROR`. `log.exception` appends a Python
   traceback (`Traceback (most recent call last):` …) on following lines.
   All modules log through logger `"tokenserver"` (the root handler).
3. `_maybe_rotate_own_log()` then start the `log-rotation-watch` daemon
   thread with a fresh (never-set) Event.
4. `log.info("starting: rev %s", _SERVER_REV)`.
5. Globals: `_claude_plan = args.claude_plan`, `_codex_plan =
   args.codex_plan`, `_plan_costs = value_meter.parse_plan_costs(args.plan,
   legacy_claude=args.plan_cost_usd)` (ValueError on `--plan` without `=`,
   non-positive amounts → uncaught traceback, exit 1), `_price_table =
   value_meter.load_prices(args.prices)` (bad file → uncaught, exit 1).
6. `interaction_config = _resolve_interaction_config(args)` (§6.1; may
   write config.json).
7. GitHub: if `args.github_repo`: `token = _read_github_token()`,
   `GitHubMonitor(repo, token=token)`, `.start()`, log
   `GitHub monitor started for the public repo %s (stargazers: %s)` with
   `auth` or `anonymous — the name becomes 'someone'`. Set
   `Handler.github_monitor` (None otherwise).
   `_read_github_token()`: env `GITHUB_TOKEN`, `TG_GITHUB_TOKEN` (first
   non-blank, stripped) → `~/.torget-github-token` → `<repo>/.github-token`
   (stripped, non-empty) → `<repo>/secrets.h` regex
   `#\s*define\s+TG_GITHUB_TOKEN\s+"([^"]+)"` (stripped, non-empty) → None.
8. `Handler.projects_dir = Path(args.dir)`. If neither `projects_dir` nor
   `CODEX_SESSIONS` is a directory:
   `log.warning("found neither %s nor %s — is Claude Code or Codex on this
   machine? Waiting for one of them to appear (Ctrl-C aborts).", …)`, then
   poll every 30 s; Ctrl-C → `SystemExit(1)`; on success
   `log.info("found a provider directory — continuing startup.")`. The port
   is NOT bound while waiting (deliberate: avoids a launchd respawn loop).
9. If `projects_dir` is still not a directory (Codex-only):
   `log.info("%s missing — continuing without Claude figures (Codex found).")`.
10. Start `first-scan-warmup` thread (§7.2).
11. `status_service = AgentStatusService(projects_dir=…, codex_sessions=CODEX_SESSIONS)`;
    `poll_once()` synchronously; `start()`; `Handler.agent_status = status_service`.
12. `max_tracker_store = MaxTrackerStore(<state>/max-tracker.json,
    CODEX_SESSIONS, projects_dir)`; `Handler.max_tracker_store`,
    `Handler.plans = {"claude": args.claude_plan, "codex": args.codex_plan}`.
13. `secret = _configure_interactions(interaction_config,
    args.interaction_timeout, audit=lambda action, row: log.info(
    "interaction %s: %s", action, json.dumps(row, sort_keys=True)))`.
14. If `secret is None and interaction_config.agent_status_relay`:
    `secret = interactions.read_device_key()`.
15. If legacy v1 on: `log.warning("UNSAFE COMPATIBILITY ON: the old Claude
    panel's v1 answers lack the provider/digest binding. Turn it off with
    --no-legacy-claude-panel-v1 once old firmware is no longer in use.
    Codex stays v2.")`.
16. If a store exists: `log.info("Needs You on: Claude=%s, Codex=%s on
    127.0.0.1:%d, holding %.0f s. Device key: %s. Content to the screen:
    %s", yes/no, yes/no, port, timeout, "present" | "MISSING — the device
    cannot answer", "yes (--interaction-detail)" | "no, only that something
    is waiting")`; if no secret additionally
    `log.warning("no device key found — hooks are parked and fall back to
    the terminal. Set TK_VIBEPULSE_DEVICE_KEY in secrets.h (the same value
    the screen is built with) to be able to answer.")`.
17. `interaction_relay_adapter = _configure_interaction_relay(config,
    secret, audit=lambda a, row: log.info("encrypted interaction relay %s:
    %s", a, json.dumps(row, sort_keys=True)))`, then log:
    ready → `encrypted Needs You relay ready (E2E; no questions or commands
    are logged)`; disabled → WARNING `encrypted Needs You relay off: %s;
    LAN and the terminal fallback continue`; status relay ready →
    `encrypted agent-status relay ready (E2E; fixed size, short lifetime,
    no plaintext at the cloud)`; disabled → WARNING `encrypted agent-status
    relay off: %s; direct LAN continues`. ("off" logs nothing.)
18. If `--publish`: build producers (identical logic to the handler's, not
    calling the handler): `/api/tokens` → `get_snapshot(projects_dir,
    max_tracker_store=store)` (placeholder skipped by the publisher);
    `/api/max-tracker` → same as `_max_tracker_payload`; `/api/github` →
    monitor snapshot or disabled snapshot. Agent status and Needs You are
    NEVER published. `machine = args.publish_name or
    socket.gethostname().split(".")[0]`; `Publisher(url, machine,
    producers).start()`; log `publishing figures to the relay as "%s" (at
    most every 5 min for quotas and every 30 min for GitHub/Max Tracker;
    agent status and Needs You are NEVER published)`.
    Publisher contract: POST `<url.rstrip("/")><path>` with
    `json.dumps(payload, sort_keys=True)`, headers `Content-Type:
    application/json`, `User-Agent: vibepulse-publisher/1`,
    `X-VibePulse-Publisher: <machine>`, 10 s timeout; send on change or
    heartbeat, minimum intervals tokens 300 s, max-tracker/github 1800 s,
    heartbeat 300 s, check every 30 s; tokens recovering from a stale flag
    bypass the interval once.
19. Start `max-tracker-backfill` thread.
20. `discovery = DiscoveryAdvertiser(log)`; inside `try`:
    `srv = BoundedThreadingHTTPServer(("0.0.0.0", args.port), Handler)`
    (bind + listen), then `discovery.start(args.port)` (only after the bind
    succeeded — never advertise a port that is not open), copy
    `discovery.status/reason` into `Handler`, log
    `serving http://0.0.0.0:%d/api/tokens, /api/agent-status,
    /api/max-tracker and /api/github (LAN — do not expose it outward)`,
    `srv.serve_forever()`.

Discovery (`discovery.py`): requires the optional `zeroconf` package;
registers service type `_vibepulse._tcp.local.`, instance
`VibePulse-<label>._vibepulse._tcp.local.`, server
`vibepulse-<label>.local.`, all non-loopback/non-link-local IPv4 addresses
of `gethostname()`, the port, TXT `v=1`; `<label>` = hostname lowercased,
non-ASCII-alnum → `-`, collapsed/stripped, ≤ 48 chars, default `host`;
`allow_name_change=True`. Logs `local VibePulse discovery advertised via
mDNS` / `… not advertised (zeroconf missing)` / `… waiting (no LAN address
found)` / WARNING `… could not be advertised (<ExcName>)`. Never fatal.

### 8.1 Shutdown order (`finally`, 4648–4665)

Triggered by `KeyboardInterrupt` (SIGINT; swallowed) or by any exception
from bind/serve (propagates after the `finally`, exit 1 with an uncaught
traceback — e.g. `OSError: [Errno 48] Address already in use`).

1. `discovery.stop()` (unregister + close; warnings on failure).
2. `interaction_relay_adapter.stop()` if any.
3. `relay_publisher.stop()` if any (join ≤ 5 s).
4. `github_monitor.stop()` if any.
5. `backfill_stop.set()`; `backfill_thread.join(timeout=2.0)`.
6. `max_tracker_store.save()` — final flush; exception →
   `log.exception("max-tracker: final flush failed — today's peaks may be
   missing after a restart")`.
7. `status_service.stop()`.
8. `srv.server_close()` if bound (closes the listen socket; does not join
   request threads).

SIGTERM is NOT handled: Python's default SIGTERM action kills the process
without running the `finally` (no final flush, no mDNS unregister).
launchd `kickstart -k` / unload sends SIGTERM; VibePulse Bar sends SIGINT.
A Swift port may handle SIGTERM gracefully (strictly better) but must keep
SIGINT graceful.

Exit codes observed by supervisors: the process never exits on its own
while healthy (serve forever); SIGINT while serving → `finally` → `main`
returns → exit 0; exit 1 on uncaught startup errors (bad `--plan`/`--prices`,
invalid relay URL, bind failure) or Ctrl-C during the provider-directory
wait; exit 2 on argparse errors; SIGTERM → killed by signal (no cleanup).

---------------------------------------------------------------------------

## 9. Log lines other tools depend on

| Text | Level | Consumer |
|---|---|---|
| `serving http://` (start of the serving line) | INFO | `smoke.py` counts occurrences in log + `.old` (≥ 10 → respawn-loop WARN; the old Swedish `serverar http://` also counts); VibePulse Bar `RealTokenServerTests` asserts exactly 2 after one restart |
| `Traceback (most recent call last)` | (traceback text) | `smoke.py` counts → WARN "N traceback(s) in the log"; docs: a traceback without a preceding `500 on` line is "doubly interesting" |
| `500 on /api/…` (+ traceback) | ERROR | `docs/observability.md` comb routine |
| `starting: rev <rev>` | INFO | observability "healthy boot" example |
| `first scan <s> s: <n> tokens today, <n> sessions, <n> this month` | INFO | observability example |
| `the first scan produced no result` / `usage recompute crashed` | WARNING/ERROR | `docs/agent-setup.md` troubleshooting table |
| `found neither … — is Claude Code or Codex on this machine?` | WARNING | observability symptom table |
| `startup-health: panel contact READY via <path>` | INFO | test asserts substring `panel contact READY` |
| `max-tracker backfill step failed: <Class>: <msg>` | WARNING | test + `observability-backlog.md` |
| `log file rotated (…)` | INFO | — |
| `http <ip>: <stdlib message>` | WARNING | test asserts message reaches the log |

Timestamp format `YYYY-MM-DD HH:MM:SS` (local time) + space + level +
space + message, one line per record (tracebacks continue on following
lines). VibePulse Bar appends its own lines in the same format (marked
`vibepulse-bar:`) to the same file, opened `O_APPEND`, so in-place
truncation must keep working.

---------------------------------------------------------------------------

## 10. Firmware-facing constraints (from `components/`)

| Endpoint | Firmware client | Body cap (reject at ≥) | Timeout | Required |
|---|---|---|---|---|
| `/api/tokens` | `net.c` via `torget_http_get_service` every 30 s (backoff cap 300 s) | 4096 bytes (`BODY_MAX`; overflow if `len + chunk >= cap`) | 10 s configured URL (`TG_NET_LOCAL_TIMEOUT_MS`), 2 s for an mDNS-discovered origin (`TG_NET_REPROBE_TIMEOUT_MS`) | status 200; no top-level `error`; `v == 2`; numeric `dayTokens`, `dayTokensPerHour`, `daySessions`, `monthTokens`; unknown top-level keys skipped |
| `/api/max-tracker` | `net.c` every 5 min (cap 30 min) | 8192 (`MT_BODY_MAX`) | same | 200; no `error`; `v == 1`; `weeks == TK_MT_WEEKS`; bool `stale`; `claude`/`codex` objects |
| `/api/github` | `github_net.c` | 768 (`GITHUB_BODY_MAX`) | same | 200; v1 |
| `/api/agent-status` | `agent_net.c` every 1 s (backoff cap 30 s), keep-alive client, open/fetch_headers/read loop | 4096 (`TK_AGENT_HTTP_BODY_CAP`): `Content-Length >= 4096` → overflow; `Content-Length < 0` (missing and not chunked) → IO error | 2.5 s | 200; strict lexical JSON (no NaN, trailing bytes only whitespace); no `error`; root keys `v`,`seq`,`agents` exactly once; `v == 2`; `seq` uint32; optional `pending` |
| `POST /api/interaction/<id>`, `POST /api/panic` | `needs_you_net.c` | device body ≤ 256 bytes | 2.5 s | `Content-Type: application/json`; 200 = success; 408/429/5xx/transport = uncertain; other = hard reject; response body ignored |

Headers the firmware sends on every GET: `X-VibePulse-Accepts:
usage-totals`; on LAN GETs after an HTTP-stall recovery reboot:
`X-VibePulse-Recovery-Boot: http-stall-v1`. The Host header is
`<ip>:<port>` (not loopback) — fine because GET/answer routes do not check
Host. `Content-Length` must always be present and correct on 200s (Python
always sends it). The firmware follows up to 3 redirects on GETs (never
used). Discovery-built URLs are `<advertised origin><path>`.

---------------------------------------------------------------------------

## 11. Tests covering this range

### `tools/tokenserver/test_tokenserver.py`

- `JsonBodyReadSafetyTests`
  - `test_incomplete_framing_is_not_parsed_as_a_complete_object` — `{}` with CL 100 → None.
  - `test_body_read_sets_a_short_deadline_then_restores_socket_timeout` — settimeout calls `[0.25, 7.0]`; TimeoutError → None.
  - `test_deep_and_huge_integer_json_are_bounded_failures` — deep nesting / 5000-digit int → None, no exception.
- `BoundedHTTPServerTests`
  - `test_busy_rejection_drains_request_before_graceful_close` — order timeout→recv→send(503)→shutdown(SHUT_WR).
  - `test_worker_cap_rejects_promptly_then_recovers_after_completion` — max_workers=2: third request 503, peak concurrency 2, recovers to 200.
  - `test_thread_start_failure_releases_its_worker_slot` — slot released; `daemon_threads` True; `block_on_close` False.
  - `test_default_capacity_leaves_headroom_above_held_hook_limit` — default ≥ MAX_PENDING+16; `main` constructs `BoundedThreadingHTTPServer(`.
- `HandlerPrivacyTests`
  - `test_tokens_error_is_sanitized_but_cause_reaches_the_local_log`.
  - `test_root_diagnostics_contain_names_but_no_header_values_or_body` — keys `ratelimitHeaders`, `unknownRateLimitBuckets`, `claudeLocalUsage`, `claudeStatusline.{status,ageS,claudeCodeVersion,bridged,account="assumed-single"}`, `quotaRegressions` list, `claudeCredential`, four `claudeProbe*` backoff keys.
  - `test_root_diagnostics_report_only_safe_interaction_switches` — exact `interactions` dict (see §4), no "secret"/"key".
  - `test_root_reports_ready_or_generic_relay_failure_without_values` — ready → transport `lan+encrypted-relay`; disabled + reason → `lan`.
- `PanelStartupHealthTests` — the four §2.2 cases (ready after two polls + READY log, loopback/one LAN poll → waiting, stale at 16 s, exact recovery-boot header).
- `HandlerErrorLoggingTests`
  - `test_agent_status_route_keeps_the_error_contract` — producer RuntimeError → 500 error form + logged.
  - `test_client_disconnect_is_quiet_and_not_a_500` — BrokenPipe on write → no log, one `_send`.
  - `test_producer_connection_error_is_a_server_error_not_a_disconnect`.
  - `test_unwritable_payload_logs_and_falls_back_to_500` — "response write" in log, second send 500.
  - `test_log_error_reaches_the_log_while_access_log_stays_muted`.
- `UsageComputeHealthTests` — `usageComputeOk`/`usageComputeFailingForS` on `GET /` during and after a crash episode; throttling; recovery resets throttle.
- `StartupSnapshotTests`
  - `test_first_request_answers_at_once_with_a_marked_placeholder` (get_snapshot side).
  - `test_the_totals_block_describes_the_counters_it_rides_on`.
  - `test_placeholders_go_only_to_clients_that_declared_they_understand` — 503/200 matrix for `X-VibePulse-Accepts` (§3.1).
  - `test_a_crashing_first_scan_is_retried_on_the_cadence_not_per_request`.
  - `test_root_payload_names_the_three_usage_total_states` — refreshing / failing-placeholder / ready (ageS ≥ 12) / failing-frozen.
  - `test_placeholder_satisfies_the_smoke_shape_and_the_device_budget`.
- `MaxTrackerBackfillLoopTests.test_the_first_backfill_failure_logs_even_on_a_freshly_booted_host`.
- `MaxTrackerBackfillFailureLogTests` — `test_loop_ticks_forever_and_marks_dirty_only_on_progress`, `test_loop_keeps_polling_after_backfill_step_goes_idle`.
- `MaxTrackerDirtyWriterTests` / `MaxTrackerSingleWriterTests` — coalescing writer, error episode, `maxTrackerSaveOk` (writer is out of range but feeds `GET /`).
- `MaxTrackerEndpointTests` — `stale` mirroring (3 cases), plans passed as 2nd arg, sanitized error, `/api/max-tracker` in `endpoints`.
- `ArgumentParsingTests` — plan choices reject/accept/default None; interaction switch defaults (all None, `interactions` False) and each flag's value (`--no-interaction-relay` → `False` exactly); saved-true switches can be disabled and persisted; concurrent fork merge; legacy alias conflicts (`not allowed with argument`); help text flags; Handler defaults strictly off; relay enable/disable keeps providers; legacy panel choice persists; legacy alias enables only Claude + persistence; invalid saved config + explicit CLI → fail-closed repair; store iff a provider is enabled.
- `InteractionRelayConfigTests` — default off (factory never called), ready relay kwargs, status-only relay, both relays, missing status source, each missing requirement reason, ImportError → `crypto-unavailable`, token file mode 0600, non-canonical tokens.
- `LogRotationTests` — rotates when stderr is the file (tail = 256 KiB ending with the last line, file emptied); holds handler locks; terminal run untouched; under cap / missing file no-op.
- `SourceFingerprintTests` — CRLF == LF; fingerprint `^[0-9a-f]{12}$`, stable, equals `GET /`'s `srcFingerprint`.
- `LogRotationWatchTests.test_watch_keeps_checking_until_stopped`.

### `tools/tokenserver/test_interactions.py` (wire-level parts)

- `DeviceBudgetTests` — `RESPONSE_CEILING_BYTES < 4096`; `response_fits` true for a small snapshot, false for 4000-byte padding; full snapshot (2×4 jobs) + pending still fits.
- `HttpEndToEndTests` (real `BoundedThreadingHTTPServer` on 127.0.0.1:0) — question round trip (blocks until answered; hook body `permissionDecision: allow` + `updatedInput.answers`); internal AskUserQuestion permission not parked (returns 200 empty promptly); approval allow; legacy v1 Claude answer; timeout → 200 empty; unrenderable → 200 empty immediately; garbage bodies → 200 empty; panic → `denied == 1` and hook gets deny; unsigned panic → 409; forged answer → 409 and still pending; abandoned connection reaped within ALIVE_POLL_S+5; agent-status without pending has no `pending` and `v == 2`; POST 404 when store None; `_is_loopback` accept/reject lists.
- `AbandonedHookTests` — liveness semantics used by `_hook_client_gone`.

### `tools/tokenserver/test_codex_interactions.py`

- `CodexRouteTests` — structured answer `{"status":"answered","option_index":0,"answer":…}`; legacy mode never downgrades Codex; deny → `computer/deny`; detail-off hides text, approve 409, leave_it → `computer/leave_it`; unmarked cannot approve; permission allow/deny exact `hookSpecificOutput`; leave_it → empty body; detail-off permission hides command; invalid envelopes → `invalid` without parking; invalid permission → empty; timeouts (`computer/timeout`, empty); provider switches independent and disabled routes never parse; injected store does not enable Claude; non-loopback → 403 `hooks must be local` before parsing; attacker Host / wrong port → 403; any Origin (incl. `null`) → 403; `text/plain` → 415 on all six JSON routes; accepted loopback Host forms; Content-Type accept/reject lists; partial advertised body → `invalid` in < 1 s; deep/huge JSON → `invalid`; early rejections answer even when the body is written (403/415 with 8 KiB padding); disabled route 404 with body written; early rejection drains exactly the body length; a parsed body is never drained twice (`[0]`).
- `RequestDrainBoundsTests` — byte cap, short timeout set+restored (≤ 0.05), EOF + runs once, nothing without an advertised body / non-numeric CL.

### `tools/tokenserver/test_provider_gate.py`

- `ProviderGateTest` — `_any_provider_dir` (Claude only, Codex only, both, neither, file ≠ dir).
- `CodexHomeTest` — `CODEX_SESSIONS` follows `CODEX_HOME`.
- `CodexOnlyEndToEndTest` — `/api/tokens` via `Handler.do_GET` with no Claude dir: 200, `v == 2`, Claude pcts null, `claudeSourcePresent` false/true.
- `WarmupLogHonestyTest` — `claudeSourcePresent` check precedes `snap['dayTokens']` in `main` source.

### `tools/tokenserver/test_interaction_relay_integration.py`

Exercises the Handler with a relay-backed store (`interaction_timeout_s = 1.0`) — relay part.

### `tools/tokenserver/test_smoke.py` + `smoke.py` expectations

`smoke.py [--base-url http://localhost:8737] [--log-file …] [--state-dir …]`,
every GET sends `X-VibePulse-Accepts: usage-totals`, 5 s timeout; exit 0 all
ok, 1 warnings, 2 any FAIL. Checks against the server:

- `GET /`: unreachable → FAIL (endpoint checks skipped); non-200 → FAIL;
  not an object or `service != "torget-tokenserver"` → FAIL. `rev` vs
  checkout rev → WARN on mismatch else OK `torget-tokenserver rev X, up
  since <startedAt>`; `srcFingerprint` mismatch (both present) → WARN;
  `claudeProbe == "usage_http_200 + ok"` → OK, `"not_run"` → WARN, other →
  WARN with `(<streak> misses in a row, next try in ≤<interval> s[, 429 rest
  <cooldown> s left])` when `claudeProbeStreak`/`claudeProbeIntervalS` are
  ints and `claudeProbeCooldownLeftS` int; `claudeCredential`
  ready+int → OK, expiring → WARN, expired → WARN (wording depends on
  probe ok), other → WARN, missing → WARN; `claudeStatusline.status` fresh
  → OK (uses `ageS`, `claudeCodeVersion`, `bridged is True`), stale → WARN
  (`ageS // 60`), missing/empty → WARN, invalid/unreadable → WARN,
  not_installed/absent → nothing; non-empty `unknownRateLimitBuckets` →
  WARN; `usageComputeOk is False` → FAIL (uses `usageComputeFailingForS`);
  `usageTotals.state == "refreshing"` → WARN (uses int `sinceS`);
  `maxTrackerSaveOk is False` → WARN (uses `maxTrackerSaveFailingForS`).
  Missing keys on an older server are not judged.
- Endpoints (`/api/tokens` v2 + 4 numeric non-bool counters;
  `/api/agent-status` v2 + `seq`, `agents` object with `claude` and
  `codex`; `/api/max-tracker` v1 + `weeks`, `stale` bool,
  `codingStreakDays`, non-empty `claude`/`codex` objects): body with
  `error` → FAIL (even on 500); non-200 → FAIL; non-object → FAIL; wrong
  `v` → FAIL; missing fields → FAIL; shape error → FAIL; any of
  `claudeWeekStale`, `claudeModelWeekStale`, `codexWeekStale`, `stale`
  true → WARN; else OK. `/api/github` is not checked.
- Log file (`DEFAULT_LOG_PATH` + `.old`): missing → WARN; size >
  `_LOG_CAP_BYTES` → WARN; tracebacks → WARN; ≥ 10 `serving http://` /
  `serverar http://` → WARN.
- State dir (`_state_dir()`): `usage-history.json` `{v:1, samples:[…]}`
  (and mtime ≤ 24 h), `quota-cache.json` exactly `{v:1, records:[…]}`,
  `max-tracker.json` with `claude`/`codex` objects; corrupt → FAIL; wrong
  shape → FAIL; missing → WARN.
- `test_smoke.py` covers each of those verdicts with a canned server
  (fixtures from `sim-fixtures/`), including
  `test_compute_failure_still_checks_every_endpoint` and
  `test_unreachable_server_skips_endpoint_checks_and_exits_2`.

---------------------------------------------------------------------------

## 12. Tricky semantics checklist for the Swift port

1. HTTP/1.0 status line and close-after-response; always `Content-Length`;
   `_send_no_decision` has no Content-Type and an empty body.
2. Drain up to 64 KiB / 50 ms of an unread announced body before EVERY
   response; drain at most once; never after a full `_read_json_body`.
3. 32-slot admission with the exact busy 503 bytes (HTTP/1.1 status line,
   `Content-Length: 0`, `Connection: close`) after a bounded header drain,
   then half-close.
4. POST gate order: provider-enabled 404 → loopback 403 (+ WARNING) →
   Host/Origin 403 → store-missing 404 for answer/panic → Content-Type 415
   → dispatch. Answer/panic have no loopback/Host/Origin checks.
5. Hook threads block for the hold time; liveness via non-blocking
   readability + `MSG_PEEK` EOF.
6. `/api/tokens` placeholder → 503 unless `X-VibePulse-Accepts` contains
   `usage-totals` (substring, case-insensitive, first header only).
7. `/api/max-tracker` calls `get_snapshot` first and overwrites `stale`.
8. `/api/agent-status` adds `pending` last and drops it if the encoded body
   would exceed 3584 bytes — measure with the port's own encoder.
9. `_reply`: producer exceptions (any type) → log + sanitized 500;
   write-time connection errors silent; other write errors → log + 500.
10. Panel evidence: two non-loopback polls from one IP within 10 s; fresh
    15 s; READY log on transition; never expose the IP.
11. `GET /` is built from single consistent reads; optional `reason` keys
    omitted rather than null; `srcFingerprint`/`rev` compatibility with
    `smoke.py`/doctor must be decided explicitly.
12. Explicit interaction CLI choices are persisted (under a cross-process
    lock) before the port is bound; invalid saved config fails closed
    unless an explicit choice repairs it.
13. Bind happens late (after all subsystems start), discovery only after a
    successful bind; wait (not exit) when no provider directory exists.
14. Final flush + orderly stops only on SIGINT/exception path; SIGTERM is
    currently abrupt.
15. Log format `%Y-%m-%d %H:%M:%S LEVEL message` to stderr; start-up
    in-place truncation rotation + hourly re-check only when stderr is the
    log file (dev/ino match); keep the `serving http://` marker.
