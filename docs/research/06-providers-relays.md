# 06 — Providers, relays, discovery, GitHub monitor (behavioral spec for a Swift port)

Source of truth: `tools/tokenserver/` at the worktree `bright-octopus` (Python 3.12+; the
host has 3.14). Everything below was read line by line from:

| Python module | Lines | What it is |
|---|---|---|
| `interaction_relay_crypto.py` | 505 | Pure crypto/framing for the E2E "Needs You" + agent-status relay (v1). |
| `interaction_relay.py` | 672 | Outbound-only HTTP adapter: PUT/DELETE requests, poll verdicts, PUT status. |
| `publisher.py` | 218 | Plain-JSON "numbers" publisher to the numbers mailbox (`--publish`). |
| `github_monitor.py` | 263 | Public GitHub repo stars/forks poller → `/api/github`. |
| `discovery.py` | 138 | Optional DNS-SD (mDNS) advertisement via `zeroconf`. |
| `codex_oauth.py` | 205 | Codex CLI `auth.json` reader + ChatGPT usage URL mapping. |
| `codex_usage.py` | 269 | Month-to-date Codex $ value from rollout JSONL logs. |
| `cursor_usage.py` | 271 | Cursor usage via local SQLite `state.vscdb` token + cursor.com API. |
| `grok_billing.py` | 252 | Grok credits via `~/.grok/auth.json` + cli-chat-proxy billing API. |
| helpers pulled in | | `quota_http.py` (shared no-redirect JSON GET/POST), `codex_rollout.py` (rollout line acceptance), `subscription_quota.py` (the consumer of cursor/grok), the `interactions.py` store boundary used by the relay. |

Server side of the protocols (read fully): `tools/relay/worker.js` + `merge.js` (numbers mailbox,
Cloudflare Worker + Durable Object), `tools/interaction-relay/src/{index,mailbox,envelope}.ts`
(encrypted interaction/status mailbox).

Known-answer vectors: `test-vectors/interaction-relay-v1.json`,
`test-vectors/agent-status-relay-v1.json` (copy both files into the Swift test bundle verbatim).

**Credential sources in this scope do NOT include the macOS Keychain.** The only `security
find-generic-password` call in the tokenserver is the Claude OAuth probe in `tokenserver.py`
(`_read_keychain_oauth`, ~line 994), which belongs to the Claude-quota spec, not this one. No
module in this scope spawns a subprocess. The only SQLite access is Cursor's `state.vscdb`.

---

## 0. Cross-cutting Python semantics the port must replicate

1. **"int" means int, never bool.** Python `bool` is a subclass of `int`; the code repeatedly
   writes `type(x) is not int` or `isinstance(x, bool) or not isinstance(x, (int, float))` to
   reject JSON `true/false` where numbers are expected. In Swift with `JSONSerialization`,
   `NSNumber` conflates bools and numbers — use `CFGetTypeID(n) == CFBooleanGetTypeID()` or a
   custom JSON parser. Also distinguish JSON ints from floats where the code says `type(...) is int`
   (e.g. `1.0` is rejected as a protocol integer, `1e3` too).
2. **Two clocks.** `time.monotonic()` (for cadence, backoff, TTLs) and `time.time()` (wall; for
   protocol timestamps, Retry-After, expiry). Swift: `ContinuousClock`/`DispatchTime.now()` or
   `ProcessInfo.systemUptime` for monotonic; `Date().timeIntervalSince1970` for wall. Both are
   injectable in every class (tests rely on it).
3. **JSON serialization forms used** (bytes matter only where noted):
   - *Canonical protocol JSON* (crypto + relay): `json.dumps(v, ensure_ascii=True, allow_nan=False,
     sort_keys=True, separators=(",", ":"))`. Byte-exact parity required for the envelope and inner
     frames (all values there are ASCII strings or integers, so a fixed-order hand-written
     serializer is the safest Swift implementation). Rules if you implement it generally: keys
     sorted by Unicode code point; no whitespace; strings escape `"`→`\"`, `\`→`\\`, `\n \r \t \b \f`
     as short escapes, every other char outside `0x20..0x7E` as `\u%04x` (lowercase hex, UTF-16
     surrogate pairs for non-BMP, and 0x7F → `\u007f`); `/` not escaped; ints decimal; floats
     Python `repr`; NaN/Infinity → error.
   - *Publisher body*: `json.dumps(payload, sort_keys=True)` — default separators `", "` and
     `": "`, `ensure_ascii=True`, `allow_nan=True`. Byte parity is NOT needed (the Worker just
     `JSON.parse`s); only "stable & key-order independent" matters for the fingerprint.
   - *LAN responses* (e.g. `/api/github`): `json.dumps(payload)` (insertion order, `", "`/`": "`).
4. **Swallow-everything loops.** Every background loop catches all exceptions per cycle; a Swift
   port must not let a thrown error kill a worker thread/task.
5. **Tokens never logged**; `repr()` of auth views hides tokens. Keep `CustomStringConvertible`
   that prints `has_token=` only.

---

## 1. `interaction_relay_crypto` — strict v1 crypto (E2E relay)

Python library: `cryptography` (`AESGCM`, `HKDF(SHA256)`, `InvalidTag`), stdlib `hmac`,
`hashlib`, `secrets`, `base64`, `json`. Importing this module is the "optional dependency"
boundary: if `cryptography` is missing, tokenserver marks the relay `disabled`/`crypto-unavailable`.
In Swift this is always available (CryptoKit, macOS 11+), so that reason becomes unreachable (keep
the string for diagnostics parity if desired).

### 1.1 Constants

| Name | Value | Meaning |
|---|---|---|
| `REQUEST_FRAME_BYTES` | 2048 | plaintext size of a request frame (Mac→panel) |
| `VERDICT_FRAME_BYTES` | 1024 | plaintext size of a verdict frame (panel→Mac) |
| `STATUS_FRAME_BYTES` | 2816 | plaintext size of a status frame (Mac→panel) |
| `MAX_VIEW_BYTES` | 640 | max decision-view bytes inside a request |
| `MAX_STATUS_BYTES` | 2560 | max status JSON bytes inside a status frame (independent cap; the frame could hold 2766) |
| `MAX_ENVELOPE_BYTES` | 4096 | max outer envelope bytes accepted by decoders |
| `GCM_NONCE_BYTES` | 12 | |
| `GCM_TAG_BYTES` | 16 | |
| `_PROTOCOL` | `b"vibepulse-ir/v1"` | prefix of HKDF info and AAD |
| `_SALT` | `SHA256(b"VibePulse interaction relay v1")` = `536dc0d887a19368c80c5e72b5b6406edfb2d655b21712160f95c116aaee3570` | HKDF salt |
| `_MAILBOX_RE` | `^vp_[A-Za-z0-9_-]{16}$` (Python `fullmatch` + `\Z`) | mailbox id, 19 ASCII chars |
| `_HEX_KEY_RE` | `^[0-9A-Fa-f]{64}$` | device key hex |
| `_B64URL_RE` | `^[A-Za-z0-9_-]*$` | |
| `_OUTER_KEYS` | `{"v","nonce","ciphertext"}` | |
| `_REQUEST_KEYS` | `{"v","requestId","challenge","expiresAt","view","viewSha256"}` | |
| `_VERDICT_KEYS` | `{"v","requestId","challenge","viewSha256","verdict","hmac"}` | |
| `_VERDICT_CODES` | `approve=1, deny=2, terminal=3, panic=4` | |
| `_STATUS_MAGIC` | `b"VPS1"` | |
| `_STATUS_HEADER_BYTES` | 50 | 4 magic + 8 pubId + 4 expiry + 2 len + 32 sha256 |

### 1.2 Data types (all immutable)

```
RelayKeys   { request_aead: 32B, verdict_aead: 32B, verdict_mac: 32B, status_aead: 32B }
RelayRequest{ request_id: String, challenge: 32B, expires_at: UInt32(>0), view_bytes: 1..640 B, view_sha256: 32B }
RelayVerdict{ request_id: String, challenge: 32B, view_sha256: 32B, verdict: "approve"|"deny"|"terminal"|"panic", mac: 32B }
RelayStatus { publication_id: UInt64(>0), expires_at: UInt32(>0), status_bytes: 1..2560 B, status_sha256: 32B }
```

### 1.3 Base64url

- `b64url_encode(raw: bytes) -> str`: standard URL-safe alphabet (`-_`), padding stripped.
  Non-bytes input → `ValueError`.
- `b64url_decode(text) -> bytes`: must be `str` matching `_B64URL_RE` (so `=`, `+`, `/`, whitespace,
  non-ASCII all rejected); `len % 4 == 1` rejected; decode with re-added padding; then
  **canonicality check**: `b64url_encode(decoded) == text` else `ValueError("non-canonical")`
  (rejects non-zero trailing bits, e.g. `"AB"` style overlong tails). Empty string decodes to `b""`.
  Test-pinned rejects: `"AA=="`, `"AA="`, `"A"`, `"+A"`, `"/A"`, `"AA\n"`, `"å"`.
  Swift: translate `-_`→`+/`, pad, `Data(base64Encoded:)`, re-encode and compare.

### 1.4 Key handling

- `decode_device_key(hex_text: str) -> 32 bytes`: exactly 64 hex chars (either case), else
  `ValueError`. `None`, bytes, 63/65 chars, `"g"*64`, embedded space → error.
- `derive_keys(device_key: 32B, mailbox: str) -> RelayKeys`: device key must be exactly 32 bytes;
  mailbox must match `_MAILBOX_RE`. Each key:

  ```
  HKDF-SHA256(IKM = device_key, salt = _SALT, info = b"vibepulse-ir/v1|" + mailbox_ascii + b"|" + label, L = 32)
  labels: request_aead = "mac-to-panel-aead"
          verdict_aead = "panel-to-mac-aead"
          verdict_mac  = "panel-verdict-mac"
          status_aead  = "mac-to-panel-status-aead"
  ```
  (HKDF = RFC 5869 extract-then-expand; CryptoKit `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)` is identical.)

### 1.5 AAD strings (ASCII)

```
request_aad(mailbox, request_id) = "vibepulse-ir/v1|" + mailbox + "|" + request_id + "|request"
verdict_aad(mailbox, request_id) = "vibepulse-ir/v1|" + mailbox + "|" + request_id + "|verdict"
status_aad(mailbox)              = "vibepulse-ir/v1|" + mailbox + "|status"
```
`request_id` here is the **base64url text** (22 chars), and it must decode (canonically) to exactly
16 bytes, else `ValueError`. Mailbox validated by regex.

### 1.6 Canonical JSON helpers

- `_canonical_json(dict) -> bytes` — see §0.3 canonical form.
- `_decode_canonical_object(raw: bytes, keys: set) -> dict`:
  1. non-empty bytes; strict UTF-8 decode;
  2. `json.loads` with duplicate keys → error, `NaN/Infinity/-Infinity` → error;
     `RecursionError/OverflowError` → error;
  3. top-level must be an object whose key set **equals** `keys` exactly;
  4. `_canonical_json(value) == raw` (byte-exact) else "non-canonical JSON"
     (rejects whitespace, trailing space, key reordering, duplicate keys, `1.0` vs `1`, etc.).

### 1.7 Framing

- Request/verdict frame (`_frame(value, frame_size, padding)`):
  `u16be(len(json)) || json || padding`, total exactly `frame_size`. `json = _canonical_json(value)`.
  Overflow if `len(json) > 0xFFFF` or `frame_size - 2 - len(json) < 0` → `ValueError("frame overflow")`.
- Padding source (`_padding_bytes(padding, size)`): `None` → `secrets.token_bytes(size)` (CSPRNG);
  callable → `padding(size)`; else the value itself; result must be bytes of exactly `size`.
  Tests inject `lambda n: b"\xa5"*n` for known answers.
- `_unframe(frame, frame_size, keys)`: exact size; `length = u16be(frame[0:2])`; `length == 0` or
  `length > frame_size - 2` → error; decode `frame[2:2+length]` canonically with `keys`. **Padding
  content is ignored** on decode.
- Status frame (binary, not JSON):
  ```
  0..4   "VPS1"
  4..12  publication_id  u64 big-endian
  12..16 expires_at      u32 big-endian
  16..18 status_len      u16 big-endian
  18..50 SHA256(status_bytes)
  50..50+len status_bytes
  rest   padding (STATUS_FRAME_BYTES - 50 - len bytes)
  ```

### 1.8 Outer envelope

`_outer_envelope(nonce, ciphertext)` = canonical JSON
`{"ciphertext":"<b64url(ct||tag)>","nonce":"<b64url(12B)>","v":1}` (keys sorted, so always this
order). `ciphertext` is the `cryptography` AESGCM output = ciphertext **with the 16-byte tag
appended**.

`_decode_outer(envelope, ciphertext_size)`: bytes, non-empty, `len ≤ 4096`; canonical decode with
`_OUTER_KEYS`; `v` must be the integer 1 (`true`, `2`, `1.0` rejected); nonce decodes to exactly 12
bytes; ciphertext decodes to exactly `ciphertext_size` (= frame + 16) bytes.

Sizes: request ciphertext 2064 B, verdict 1040 B, status 2832 B. Resulting envelope lengths in the
vectors: request 2802 B, verdict 1437 B, status 3826 B (all < 4096).

### 1.9 Request encode/decode

`_validate_request_fields(request_id, challenge, expires_at, view_bytes) -> sha256(view)`:
request_id decodes to 16 B; challenge 32 B; `expires_at` is a true int with `0 < x ≤ 0xFFFFFFFF`
(pinned as uint32 Unix seconds because the ESP side parses via cJSON double); `0 < len(view) ≤ 640`.

`encode_request(keys, mailbox, request_id, challenge, expires_at, view_bytes, nonce=None, padding=None)`:
1. keys must be `RelayKeys`; mailbox valid; fields validated → digest.
2. nonce = 12 random bytes if None (must be 12 bytes).
3. inner = `{"v":1,"requestId":request_id,"challenge":b64u(challenge),"expiresAt":expires_at,"view":b64u(view),"viewSha256":b64u(digest)}`
   → canonical key order: `challenge, expiresAt, requestId, v, view, viewSha256`.
4. frame = `_frame(inner, 2048, padding)`.
5. `ct = AES-256-GCM(key=request_aead).encrypt(nonce, frame, aad=request_aad(mailbox, request_id))`.
6. return outer envelope bytes.

`decode_request(keys, mailbox, request_id, envelope) -> RelayRequest`: outer decode (ct size 2064);
AES-GCM decrypt with `request_aad`; `_unframe(…, 2048, _REQUEST_KEYS)`; `v` int == 1;
`requestId == request_id` argument; `challenge` 32 B; `view` decodes; `viewSha256` 32 B;
re-validate fields (expiry range, view size) and **constant-time** compare `viewSha256` against
SHA256(view). **Any** failure (InvalidTag, ValueError, TypeError, OverflowError) is re-raised as a
single `ValueError("invalid request envelope")` — the port must collapse all failures into one
opaque error.

### 1.10 Verdict MAC and encode/decode

`_validate_request_object(request)`: re-validates fields and constant-time checks
`request.view_sha256 == SHA256(request.view_bytes)`.

`verdict_mac_message(mailbox, request, verdict) -> bytes`:
```
b"vibepulse-ir-verdict-v1\x00"           (24 bytes, trailing NUL)
|| u16be(len(mailbox_ascii))             (always 0x0013)
|| mailbox_ascii                         (19 bytes)
|| raw 16-byte request id                (b64url-decoded)
|| challenge (32)
|| view_sha256 (32)
|| verdict code byte (approve=1 deny=2 terminal=3 panic=4)
```
Total 126 bytes. `verdict_mac_bytes = HMAC-SHA256(key=verdict_mac, msg)` (32 bytes).

`encode_verdict(keys, mailbox, request, verdict, nonce=None, padding=None)` (in production only the
panel does this; the host uses it only in tests — still port it for tests):
inner = `{"v":1,"requestId":…,"challenge":b64u,"viewSha256":b64u,"verdict":verdict,"hmac":b64u(mac)}`
→ canonical order `challenge, hmac, requestId, v, verdict, viewSha256`; frame 1024; AES-GCM with
`verdict_aead` and `verdict_aad(mailbox, request.request_id)`.

`decode_verdict(keys, mailbox, request_id, envelope) -> RelayVerdict`: outer (ct 1040); decrypt with
`verdict_aead` + `verdict_aad`; unframe with `_VERDICT_KEYS`; `v`==1; `requestId == request_id`;
challenge/viewSha256/hmac each exactly 32 bytes; verdict in the 4 codes. It does **not** check the
MAC or the binding (a verdict with a wrong challenge/digest/hmac still *decodes*; only
`verify_verdict_mac` fails). All failures → `ValueError("invalid verdict envelope")`.

`verify_verdict_mac(keys, mailbox, request, verdict) -> bool` (never throws; returns False on any
error): types correct; `verdict.request_id == request.request_id`; constant-time equal challenge;
constant-time equal view_sha256; recompute MAC with `verdict.verdict` and constant-time compare.

### 1.11 Status encode/decode

`_validate_status_fields(pub_id, expires_at, status_bytes)`: pub_id true int `0 < x ≤ 2^64−1`;
expires_at true int `0 < x ≤ 2^32−1`; `0 < len(status_bytes) ≤ 2560`; returns SHA256.

`encode_status(keys, mailbox, publication_id, expires_at, status_bytes, nonce=None, padding=None)`:
frame per §1.7; padding size `2816 − 50 − len`; AES-GCM with `status_aead`, AAD `status_aad(mailbox)`.
Note: `encode_status` does not itself regex-check the mailbox before building the frame, but
`status_aad` does, so an invalid mailbox still raises.

`decode_status(keys, mailbox, envelope) -> RelayStatus`: outer (ct 2832); decrypt; frame length 2816
and magic `VPS1`; parse fields; `status_len > 2766` → error; `status_bytes = frame[50:50+len]`;
re-validate (so `len==0`, `len>2560`, pubId 0, expiry 0 fail); constant-time digest compare. All
failures → `ValueError("invalid status envelope")`.

### 1.12 CryptoKit mapping

| Python | Swift/CryptoKit |
|---|---|
| `HKDF(SHA256(), 32, salt, info).derive(ikm)` | `HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: 32)` → `withUnsafeBytes { Data($0) }` |
| `AESGCM(k).encrypt(nonce, pt, aad)` → `ct‖tag` | `let box = try AES.GCM.seal(pt, using: SymmetricKey(data: k), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)`; wire = `box.ciphertext + box.tag` (do **not** use `box.combined`, which prefixes the nonce) |
| `AESGCM(k).decrypt(nonce, ct‖tag, aad)` | `let box = try AES.GCM.SealedBox(nonce: .init(data: nonce), ciphertext: ct.dropLast(16), tag: ct.suffix(16))`; `try AES.GCM.open(box, using: key, authenticating: aad)` (throws `CryptoKitError.authenticationFailure` ≙ `InvalidTag`) |
| `hmac.new(k, m, sha256).digest()` | `Data(HMAC<SHA256>.authenticationCode(for: m, using: SymmetricKey(data: k)))` |
| `hmac.compare_digest(a, b)` | constant-time compare (length check + XOR-accumulate), or `HMAC<SHA256>.isValidAuthenticationCode(_:authenticating:using:)` for the MAC itself |
| `hashlib.sha256(x).digest()` | `Data(SHA256.hash(data: x))` |
| `secrets.token_bytes(n)` | `SecRandomCopyBytes(kSecRandomDefault, n, &buf)` (check `errSecSuccess`), or `SystemRandomNumberGenerator` |
| `secrets.SystemRandom().random()` | `Double.random(in: 0..<1, using: &SystemRandomNumberGenerator())` |

AES key size is 256-bit (32-byte keys). Nonces are random 96-bit per envelope; a retry re-sends the
**same** envelope bytes (same nonce), never re-encrypts (see §2).

---

## 2. `interaction_relay` — `InteractionRelay` (outbound-only adapter)

### 2.1 Constants

| Name | Value |
|---|---|
| `MAX_RESPONSE_BYTES` | 4096 |
| `QUEUE_CAPACITY` | 8 (event queue from store → relay) |
| `DELETE_CAPACITY` | 8 (pending DELETE retries) |
| `MIN_BACKOFF_S` / `MAX_BACKOFF_S` | 0.5 / 5.0 |
| `POLL_INTERVAL_S` | 0.5 (verdict polling while something is published) |
| `STATUS_PUBLISH_INTERVAL_S` | 5.0 (after a *successful* status PUT) → 17,280/day max |
| `STATUS_EXPIRY_S` | 15 (signed expiry inside the status frame) |
| worker loop tick | `stop.wait(0.05)` (50 ms) between cycles |
| default `connect_timeout` / `read_timeout` | 2.0 s / 5.0 s |
| join timeout on stop | `max(1.0, connect + read + 0.5)` = 7.5 s per thread |

`tools/interaction-relay/README.md` says the status is replaced "about every two seconds" — the
code (and test `test_changing_status_has_a_full_day_budget_and_keeps_expiry`, exactly 17,280 PUTs in
86,400 s) says **5 s**. Port the code.

### 2.2 HTTP response object and validation

`HttpResponse(status: int, headers: tuple[(name, value)], body: bytes)` — headers are the raw list
(duplicates preserved).

`_header_values(resp, name)`: case-insensitive name match; values `.strip()`ed; returns a list.

`_validate_response(resp, json_body: bool)`:
- `status` true int; body bytes, `len ≤ 4096`.
- `Cache-Control` values must equal **exactly** `["no-store"]` (one header, value `no-store`);
  missing, duplicated, or `no-store, private` → reject ("relay response is cacheable").
- If `json_body`: exactly one `Content-Type`; split on `;`, strip+lowercase each part; first part
  must be `application/json`; every other part must be `charset=utf-8` or `charset="utf-8"`.
- If not `json_body`: **no** `Content-Type` header at all.

Swift note: `HTTPURLResponse.allHeaderFields` merges duplicates with `", "`, so "exactly one header
equal to no-store" becomes "value == `no-store`" (a duplicated header would appear as
`no-store, no-store` and still be rejected — equivalent). Use an ephemeral `URLSession`
(`URLCache` nil, no cookies), refuse redirects via delegate (Python `http.client` never follows
redirects; any 3xx fails the status check).

`_strict_json(raw)`: bytes, non-empty, ≤4096; strict UTF-8; duplicate keys rejected; NaN/Infinity
rejected. (Not required to be canonical.)

### 2.3 Origin validation `_origin(base_url) -> (origin, host, port)`

- Must be `str`; `urlsplit`; scheme `https`; hostname present; no username/password; path is `""`
  or `"/"`; no query; no fragment. Else `ValueError`.
- `port = parsed.port or 443` (non-numeric/out-of-range → `ValueError("invalid relay port")`;
  quirk: `:0` is falsy → treated as 443). Must be 1..65535.
- `host = parsed.hostname` (**lowercased** by urlsplit; IPv6 brackets removed). Authority =
  `[host]` if host contains `:`; append `:port` only if port ≠ 443.
- origin = `"https://" + authority` (no trailing slash).
- Test-pinned rejects: `http://…`, `https://user@…`, `https://relay.example/path`,
  `https://relay.example?x=1`.

### 2.4 Default transport `_default_transport(method, url, headers, body, connect_timeout, read_timeout)`

- Re-validates URL: https, hostname, no query/fragment/userinfo.
- `HTTPSConnection(host, port or 443, timeout=connect_timeout)` (default TLS verification);
  `connect()`; then socket timeout = `read_timeout` (per-read timeout).
- `request(method, path or "/", body=body or None, headers=dict(headers))`.
- Read at most 4097 bytes; >4096 → `ValueError("relay response too large")`.
- Returns `HttpResponse(status, tuple(getheaders()), raw)`; always closes the connection
  (no keep-alive reuse).
- Swift: URLSession has no separate connect timeout; use `timeoutIntervalForRequest = read_timeout`
  (idle) and `timeoutIntervalForResource ≈ connect + read`, or Network.framework for exact parity.
  Enforce the 4096-byte body cap while streaming.

Request headers always sent by the adapter (`_request`):
```
Authorization: Bearer <mac_token>      (43-char base64url of 32 bytes)
Accept: application/json
Content-Type: application/json         (only when body is non-empty)
```
URL = `origin + route`. Routes (mailbox and request id are `quote(…, safe='')`, which is a no-op
for their alphabets):

| Operation | Method + route | Body | Success condition | audit route name |
|---|---|---|---|---|
| publish request | `PUT /v1/mailboxes/{mailbox}/requests/{requestId}` | request envelope | status 200 or 201, **empty body**, no Content-Type, `Cache-Control: no-store` | `put_request` |
| delete request | `DELETE /v1/mailboxes/{mailbox}/requests/{requestId}` | none | status 204, empty body | `delete_request` |
| poll verdicts | `GET /v1/mailboxes/{mailbox}/verdicts` | none | 204 (empty, no CT) or 200 (JSON CT) | `list_verdicts` |
| publish status | `PUT /v1/mailboxes/{mailbox}/status` | status envelope | status **201** only, empty body | `put_status` |

### 2.5 Constructor `InteractionRelay(*, store, base_url, mailbox, mac_token, device_key_hex, transport=None, publish_interactions=True, publish_agent_status=False, status_source=None, now=monotonic, wall=time.time, random_bytes=secrets.token_bytes, jitter=SystemRandom().random, sleeper=time.sleep, audit=None, connect_timeout=2.0, read_timeout=5.0)`

Validation order (each failure is `ValueError`):
1. `_origin(base_url)`.
2. `b64url_decode(mac_token)` must be 32 bytes (canonical base64url).
3. Timeouts: int/float, not bool, finite, > 0.
4. `publish_interactions` / `publish_agent_status` are real bools and at least one is True.
5. interactions ⇒ `store is not None`; status ⇒ `callable(status_source)`.
6. `derive_keys(decode_device_key(device_key_hex), mailbox)` (validates mailbox).
Then state init; if interactions: `store.set_relay_listener(self)`. `sleeper` is accepted but
unused.

State: `_events` bounded FIFO (8); `_publishes: OrderedDict[request_id → {job, envelope,
published=False, next_attempt, failures=0}]`; `_deletes: OrderedDict[request_id → {next_attempt,
failures}]`; `_next_poll = 0.0`; `_poll_failures = 0`; `_status_state: {envelope, publication_id,
next_attempt, failures}?`; `_next_status = 0.0`; `_last_publication_id = 0`;
`_status_prepare_failures = 0`.

Properties: `publish_queue_size` (current queue length), `thread` (main worker thread).

### 2.6 Store → relay listener callbacks (called from store threads, outside the store lock)

- `on_park(job: RelayPublishJob)`: ignored unless interactions enabled and job has the right type.
  `put_nowait(("park", job))`; if full → audit `("queue_full", route "put_request")` and **drop**.
- `on_remove(request_id: str, reason: str)`: ignored unless interactions enabled and both are str.
  `put_nowait(("remove", (request_id, reason)))`; if full: under the queue mutex, scan queued events
  and **replace in place** the first event (park or remove) whose request id equals `request_id`
  with this remove event; if none found but there is room (race), append; if still not placed →
  audit `("queue_full", "delete_request")` (removal dropped; Worker TTL is the backstop).
  Reasons emitted by the store: `timeout`, `abandoned`, `provider-mismatch`, `resolved`, `terminal`,
  `panic` (the relay ignores the reason value).

Swift: a small `final class` with a lock-protected ring buffer of capacity 8 (needs "replace by
id" operation, which `AsyncStream` can't do).

### 2.7 Threads

`start()`: no-op if main thread alive. Clears stop flag. If interactions enabled: thread
`vibepulse-interaction-relay` runs `_run_interactions`; if **also** status enabled, a second thread
`vibepulse-agent-status-relay` runs `_run_status`. If only status: the main thread is
`vibepulse-agent-status-relay` running `_run_status`. Both daemon. Independence is test-pinned: a
blocked status PUT must not delay a request PUT (`test_blocked_status_http_cannot_hold_the_verdict_worker`).

`stop()`: if interactions: `store.set_relay_listener(None)`; set stop; join each thread with 7.5 s
timeout.

Loop body (both): `while !stop { try cycle() catch { audit("cycle_failed", "interaction_worker" |
"status_worker") }; stop.wait(0.05) }`.

`run_once()` (tests): runs `_run_interactions_once()` if interactions, then `_run_status_once()` if
status, synchronously.

`_cycle_time()`: `now()`; if not a finite non-bool number → skip the cycle.

### 2.8 Backoff

```
base   = min(5.0, 0.5 * 2 ** max(0, failures - 1))
sample = clamp(float(jitter()) or 0.0 on exception / non-finite, 0, 1)
delay  = min(5.0, base * (1 + 0.2 * sample))
```
failures 1→0.5–0.6 s, 2→1.0–1.2, 3→2.0–2.4, 4→4.0–4.8, ≥5→5.0.

### 2.9 Interaction cycle `_run_interactions_once()`

```
now = cycle_time(); if nil return
drain_events(now); process_deletes(now); process_publishes(now)
if any(state.published for state in publishes) and now >= next_poll: poll(now)
```

`_drain_events(now)` — non-blocking drain of the whole queue:
- `park`: `envelope = encode_request(keys, mailbox, job.request_id, job.challenge, job.expires_at,
  job.view_bytes, nonce=random_bytes(12), padding=random_bytes)`; on exception →
  audit `encode_failed/put_request`, skip. Else remove any pending delete for that id and set
  `publishes[id] = {job, envelope, next_attempt=now}` (replaces an existing state).
- `remove`: `publishes.pop(id)`; **unconditionally** `_schedule_delete(id, now)` (a PUT whose
  response was lost may still have committed; the Worker DELETE is idempotent).

`_schedule_delete(id, now=0.0)`: if already scheduled → no-op. If 8 deletes pending → drop the
**oldest** (insertion order) and audit `backlog_full/delete_request`. Insert `{next_attempt=now}`.

`_process_deletes(now)`: for each (in insertion order) with `now ≥ next_attempt`: DELETE; validate
(no JSON body); require 204 and empty body → remove entry, audit `ok/delete_request/204`; else
`failures += 1; next_attempt = now + backoff(failures)`; audit `failed/delete_request`.

`_process_publishes(now)`: for each not-yet-published with `now ≥ next_attempt`: PUT the **stored
envelope bytes** (a retry is byte-identical — the Worker returns 200 for identical, 409 for
different); validate; status ∈ {200, 201} and empty body → `published = True; failures = 0;
next_poll = min(next_poll, now)` (i.e. poll in this same cycle) and audit `ok/put_request/status`;
else failure + backoff + audit `failed/put_request`.

`_poll(now)`: GET verdicts.
- 204: validate non-JSON; body must be empty.
- 200: validate JSON; `_consume_verdict_response(body)`.
- else: error.
- Success: `poll_failures = 0; next_poll = now + 0.5`; audit `ok/list_verdicts/status`.
- Failure (any exception, including from consume): `poll_failures += 1;
  next_poll = now + backoff(poll_failures)`; audit `failed/list_verdicts`.

`_consume_verdict_response(raw)`:
1. `_strict_json`; must be `{"verdicts": [ exactly one item ]}` (only key `verdicts`, a list of
   length **exactly 1**).
2. item keys exactly `{"envelope","requestId","verdictAtMs"}`; envelope is an object; requestId str;
   `verdictAtMs` a true int in `0..2^53−1`.
3. requestId base64url-decodes to 16 bytes, else error (poll failure).
4. `envelope_bytes = _canonical_object(item["envelope"])` (re-serialize the parsed object in
   canonical form; the Worker re-serializes via `JSON.parse`/`JSON.stringify`, so the host restores
   canonical bytes this way).
5. If there is no local publish state for that id, or it's not `published` →
   `_schedule_delete(id)` (with `now=0.0` ⇒ due immediately) and return (poll counts as success).
6. `decode_verdict(keys, mailbox, id, envelope_bytes)`; on `ValueError` → schedule delete, return.
7. Build `RelayResolution(request_id, challenge, view_sha256, verdict, mac)` and call
   `store.resolve_relay(result, self._verify_resolution)` → `(accepted, reason)`. If not accepted →
   schedule delete. If accepted, nothing more here: the store queues `on_remove(id, reason)`, which
   the next drain turns into publish-state removal + DELETE.

`_verify_resolution(job, result) -> bool`: rebuild `RelayRequest` from the job and `RelayVerdict`
from the result and return `verify_verdict_mac(...)`; any exception → False. This is the only
function called **under the store lock** — must be pure and non-blocking.

Consequences pinned by tests:
- Wrong HMAC / wrong device key / tampered envelope ⇒ never resolves; the local entry stays pending
  until it times out to the terminal; the remote row gets deleted.
- Challenge or digest mismatch, unknown request id, expired entry, or `approve` on a
  `can_approve=false` job ⇒ never resolves.
- Authenticated `panic` on any live request denies **all** pending entries (store semantics).
- Relay outage never extends the local deadline.

### 2.10 Status cycle `_run_status_once()` → `_process_status(now)`

`_prepare_status(now)` runs only if no status is in flight and `now ≥ next_status`
(`next_status` starts at 0 ⇒ first publish immediately):
1. `wall = wall()`; must be finite, non-bool, > 0.
2. `snapshot = status_source()` must be a dict (it is `AgentStatusService.snapshot()` from the
   agent-status spec).
3. `public = snapshot minus the top-level key "pending"` (Needs You content never goes into the
   status channel).
4. `status_bytes = canonical JSON (ensure_ascii, sorted, compact, no NaN)`; must be 1..2560 bytes.
5. `publication_id = max(last_publication_id + 1, int(wall * 1000))` (strictly increasing ms);
   `expires_at = int(wall) + 15`; range-check u64/u32.
6. `encode_status(…, nonce=random_bytes(12), padding=random_bytes)`; commit
   `last_publication_id`; `status_state = {envelope, publication_id, next_attempt=now}`;
   `status_prepare_failures = 0`.
7. On any exception: `status_prepare_failures += 1; next_status = now + backoff(n)`;
   audit `encode_failed/put_status`.

Then if a state exists and `now ≥ state.next_attempt`: PUT status; validate non-JSON; require
**201** and empty body → `status_state = nil; next_status = now + 5.0`; audit `ok/put_status/201`.
Failure → `state.failures += 1; next_attempt = now + backoff`; audit `failed/put_status`.
**The same ciphertext is retried until it succeeds** (even after its 15-s expiry has passed — a
faithful port keeps this; the panel rejects expired frames, and the next fresh snapshot follows
5 s after the eventual success). Test: publication_id at wall 50,000.0 s is `50_000_000`; expiry
`50_015`; `pending` key absent.

### 2.11 Audit trail

`audit(event: str, fields: dict)` with `fields = {"origin": origin, "route": <name>}` plus
`"status": int` for ok events. Events: `ok`, `failed`, `queue_full`, `encode_failed`,
`backlog_full`, `cycle_failed`. Audit exceptions are swallowed. **Never** include the token,
mailbox, request id, or any content (test `test_logs_are_redacted_to_origin_and_route_kind`).
tokenserver logs each as `INFO encrypted interaction relay <event>: <json.dumps(fields, sort_keys=True)>`
(this includes an `ok list_verdicts` line every 0.5 s while something is published and an
`ok put_status` line every 5 s — that is current behavior).

### 2.12 Store boundary the relay needs (defined in `interactions.py`, other spec)

```
RelayPublishJob(frozen): request_id: str (22-char b64url of 16 random bytes), challenge: 32B (random),
                         view_bytes: bytes (stable view JSON, ensure_ascii=False UTF-8, sorted, compact),
                         view_sha256: 32B, expires_at: int = ceil(wall + hold_s) (uint32),
                         provider: "claude"|"codex", can_approve: bool
RelayResolution(frozen): request_id, challenge(32), view_sha256(32), verdict, mac(32)
store.set_relay_listener(listener | None)
store.resolve_relay(result, verify) -> (accepted: bool, reason: str)
   reasons: "bad request", "no such pending interaction", "interaction binding rejected",
            "signature rejected", "this one has to be approved at the terminal", "panic", "ok"
```
Only `requires_v2` entries are parked to the relay; at most 8 pending (`MAX_PENDING = 8`).

### 2.13 Server side: interaction mailbox Worker (`tools/interaction-relay`)

- Env: `MAILBOX_ID` (must match `^vp_[A-Za-z0-9_-]{16}$` and equal the path mailbox), `MAC_TOKEN`,
  `PANEL_TOKEN` (Worker secrets, 43-char base64url of 32 bytes), DO binding `INTERACTION_MAILBOX`.
- Any query string, unknown path, or mailbox mismatch → 404 `text/plain`. Auth failures also 404.
  Auth: `Authorization: Bearer ([A-Za-z0-9_-]{43})` and timing-safe compare of SHA-256 of tokens.
- Routes:

| Route | Token | Behavior |
|---|---|---|
| `PUT /v1/mailboxes/{box}/requests/{id}` (id 22 chars, decodes to 16 B) | MAC | body = canonical envelope with 2064-B ciphertext → 201 created, 200 identical re-put, 409 different body, 429 when 8 live rows |
| `DELETE …/requests/{id}` | MAC | 204 always (idempotent) |
| `GET …/requests/next` | PANEL | 204 or 200 `{"envelope":{…},"expiresAtMs":n,"requestId":id}` oldest first |
| `POST …/requests/{id}/verdict` | PANEL | 1040-B envelope → 201/200 identical/409 conflict/404 missing |
| `GET …/verdicts` | MAC | 204 or 200 `{"verdicts":[{"envelope":{…},"requestId":id,"verdictAtMs":ms}]}` — **at most one item** (oldest verdict first) |
| `PUT …/status` | MAC | 2832-B envelope → 201; single latest row |
| `GET …/status` | PANEL | 204 or 200 `{"envelope","expiresAtMs","storedAtMs"}` |

- Envelope reading: Content-Type must match `^application/json(\s*;\s*charset\s*=\s*(utf-8|"utf-8"))?$`i
  (415 otherwise); Content-Length > 4096 → 413; body > 4096 → 413; empty/BOM/invalid UTF-8 → 400;
  must be exactly `JSON.stringify({ciphertext, nonce, v:1})` (i.e. canonical order), nonce 12 B,
  ciphertext exact size, both canonical base64url → else 400.
- Every response has `Cache-Control: no-store`; empty responses have no Content-Type; JSON responses
  `Content-Type: application/json`.
- TTLs: request rows expire 120 s after first receipt; status row 20 s after store. Alarms purge.

---

## 3. Interaction-relay configuration in `tokenserver.py` (how the adapter is created)

Saved config `<state_dir>/config.json` (see config spec) fields used here: `claude_interactions`,
`codex_interactions`, `interaction_detail`, `interaction_relay: bool`, `agent_status_relay: bool`,
`interaction_relay_url: https origin | null`, `interaction_mailbox: vp_… | null`.
CLI: `--interaction-relay HTTPS_ORIGIN` (enables + saves URL), `--no-interaction-relay`,
`--agent-status-relay/--no-agent-status-relay`.

Credentials:
- **Device key** (`interactions.read_device_key`): first non-blank of env `VIBEPULSE_DEVICE_KEY`,
  env `TK_VIBEPULSE_DEVICE_KEY`, file `~/.vibepulse-device-key` (stripped), then
  `<repo>/secrets.h` regex `#\s*define\s+TK_VIBEPULSE_DEVICE_KEY\s+"([^"]+)"` (stripped). The relay
  additionally requires `^[0-9A-Fa-f]{64}$`.
- **Mac token** (`_read_interaction_mac_token`): env `VIBEPULSE_INTERACTION_MAC_TOKEN` — if set and
  valid, use it; **if set but invalid → None (no file fallback)**. Else file
  `~/.vibepulse-interaction-relay-token`: `lstat` must be a regular file, not a symlink, mode
  exactly `0600` (POSIX); open with `O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK`; `fstat` must be the
  same inode as before and after (`samestat`), still regular and 0600; read ≤ 257 bytes (>256 →
  None); strict ASCII; strip **one** trailing `\n`; valid = `^[A-Za-z0-9_-]{43}$` that decodes to 32
  bytes and re-encodes identically.

`_configure_interaction_relay(config, secret)` → adapter or None; sets
`interaction_relay_status/reason` and `agent_status_relay_status/reason` (`off` | `disabled` |
`ready`):
1. Both statuses `off`; if neither relay wanted → return.
2. Interactions wanted but no provider enabled or no store → `disabled/provider-required`;
   wanted but `interaction_detail` false → `disabled/detail-required`.
3. Status wanted but `Handler.agent_status.snapshot` not callable → `disabled/status-source-missing`.
4. If nothing left → return. Shared requirements (failures disable every still-wanted feature
   with the same reason): device key 64-hex → `device-key-missing`; URL → `url-missing`; mailbox →
   `mailbox-missing`; Mac token → `mac-token-missing`.
5. Construct `InteractionRelay(store if interactions else None, publish_interactions,
   publish_agent_status, status_source if status else None, base_url, mailbox, mac_token,
   device_key_hex=secret, audit)` and `start()`. `ImportError` → `crypto-unavailable`; any other
   exception → stop adapter best-effort, `configuration-invalid`.
6. Success → wanted features `ready`.

Also: when the store is off but `agent_status_relay` is on, tokenserver reads the device key
separately (`secret = interactions.read_device_key()`).

Diagnostics in `GET /` → `interactions.relay = {status, reason?}`,
`interactions.agentStatusRelay = {status, reason?}`,
`interactions.transport = "lan+encrypted-relay"` if either is `ready`, else `"lan"`.
Shutdown order in `main`: discovery.stop → relay.stop → publisher.stop → github.stop.

---

## 4. `publisher.py` — numbers publisher (`--publish RELAY_URL`)

Purpose: POST the same three LAN payloads (`/api/tokens`, `/api/max-tracker`, `/api/github`) to a
plain-JSON mailbox (no encryption; access control is a secret URL path). Agent status and Needs You
are never published.

### 4.1 Constants

| Name | Value |
|---|---|
| `CHECK_EVERY_S` | 30.0 (loop period) |
| `HEARTBEAT_EVERY_S` | 300.0 |
| `MIN_SEND_INTERVAL_S` | `{"/api/tokens": 300.0, "/api/max-tracker": 1800.0, "/api/github": 1800.0}`; other paths default to 300 |
| `USER_AGENT` | `"vibepulse-publisher/1"` (test: must start with `vibepulse-publisher/`) |

### 4.2 Pure functions

- `payload_fingerprint(payload) -> hex str` = `sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()`
  — key-order independent; any value change changes it.
- `is_startup_placeholder(payload) -> bool` = payload is dict and `payload["usageTotals"]` is a dict
  with `placeholder` **identically** `True`.
- `stale_fields(payload) -> frozenset[str]` = top-level keys ending in `"Stale"` whose value is
  identically `True` (non-dict → empty).
- `should_send(last_fp, last_sent_at, fp, now, min_interval=0.0) -> bool`:
  ```
  if last_fp is None: return True                  # never sent
  elapsed = now - last_sent_at
  if elapsed < min_interval: return False
  if fp != last_fp: return True
  return elapsed >= max(HEARTBEAT_EVERY_S, min_interval)
  ```
  (Effective: tokens every ≥300 s whether changed or not once changed/heartbeat; max-tracker and
  github at most every 1800 s.)

### 4.3 `Publisher(relay_url, machine, producers: ordered dict path→() -> payload, post=None, clock=time.time)`

- `relay_url.rstrip("/")`; POST URL = `relay_url + path` (e.g.
  `https://relay.example/u/s3cret/api/tokens`; trailing slash never doubles).
- `_state[path] = (fingerprint, sent_at, stale_fields_of_last_successful_payload)`.
- Default `post(url, body) -> bool`: `POST`, headers
  `Content-Type: application/json`, `User-Agent: vibepulse-publisher/1`,
  `X-VibePulse-Publisher: <machine>`; timeout 10 s; success iff `200 ≤ status < 300`;
  `URLError`/`OSError`/`TimeoutError` → False. (Python `urlopen` follows 301/302/303 by
  converting to GET; a Swift port should refuse redirects and treat them as failure — note as a
  deliberate tightening.) In Swift catch **all** errors → false.
- `publish_once() -> int sends`, for each `(path, produce)` in insertion order:
  1. `payload = produce()`; exception → `log.exception("publish: the %s producer raised")`, skip.
  2. If path is `/api/tokens` and `is_startup_placeholder(payload)` → skip silently (no state change).
  3. `fp = fingerprint(payload)`, `current_stale = stale_fields(payload)`;
     `(last_fp, sent_at, last_stale) = state.get(path, (None, 0.0, ∅))`; `now = clock()`;
     `min_interval = MIN_SEND_INTERVAL_S.get(path, 300)`.
  4. `recovered = path == "/api/tokens" and any(payload.get(f) is False for f in last_stale)` —
     a stale→fresh flip on tokens bypasses the ceiling once.
  5. If not recovered and not `should_send(...)` → skip.
  6. `body = json.dumps(payload, sort_keys=True).encode()`; `post(url, body)`; success →
     `state[path] = (fp, now, current_stale)`, `sends += 1`; failure → state **untouched** (next tick
     retries), `log.warning("publish: %s did not reach the relay")`.
- `start()`: thread `relay-publisher` (daemon): first `publish_once()` immediately **on the thread**
  (never blocks server startup), then `while not stop.wait(30): publish_once()`.
- `stop()`: set, join 5 s.

Wiring (`tokenserver.main`): `machine = --publish-name or gethostname().split(".")[0]`; producers:
`/api/tokens` → `get_snapshot(projects_dir, max_tracker_store=…)`; `/api/max-tracker` →
`max_tracker_store.snapshot(today_iso_local, plans)` plus `"stale": bool(tokens.claudeWeekStale or
tokens.codexWeekStale)`; `/api/github` → monitor snapshot or `{"v":1,"enabled":false}`.

### 4.4 Server side: numbers mailbox (`tools/relay/worker.js`)

- Path must be `/u/<RELAY_SECRET>/api/{tokens|max-tracker|github}` (secret ≥ 32 chars; else 503).
- `POST`/`PUT`: publisher name = `X-VibePulse-Publisher` (default `unnamed`), first 64 chars,
  `[^A-Za-z0-9._-]` → `_`. Body ≤ 64 KiB (JS string length) else 413; must be JSON else 400; more
  than 8 distinct publishers → 409; storage failure → 503; success → **200 `ok`**.
- `GET`: `/api/tokens` merged "freshest per pool": start from the newest-received document; for
  every key prefix `G` that has a numeric `GObservedAt` in any doc, take all keys starting with `G`
  (and `GObservedAt`) from the doc with the largest `GObservedAt`. Other endpoints: newest received
  wins. No data → 404 `{"error":"no data yet"}`.

---

## 5. `github_monitor.py` — `GitHubMonitor`

### 5.1 Constants

`POLL_SECONDS = 120`, `EVENT_TTL_SECONDS = 600`, `FAILURE_BACKOFF_SECONDS = 600`,
`STALE_AFTER_SECONDS = 300`, `_REPO_RE = ^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$`.

`normalize_repo(value)`: `(value or "").strip()`, must fullmatch → returned; else
`ValueError("GitHub repository must be owner/repository")`. Pinned rejects: `""`, `"owner"`,
`"https://github.com/a/b"`, `"a/b/c"`, `"a b/repo"`; `" niclas/vibepulse "` → `"niclas/vibepulse"`.
Used as the argparse type for `--github-repo` (default env `VIBEPULSE_GITHUB_REPO`).

### 5.2 Token (`tokenserver._read_github_token`)

First non-blank of: env `GITHUB_TOKEN`, env `TG_GITHUB_TOKEN`, file `~/.torget-github-token`,
file `<repo>/.github-token`, `<repo>/secrets.h` regex `#\s*define\s+TG_GITHUB_TOKEN\s+"([^"]+)"`.
All stripped. Optional (anonymous works; only the actor name degrades).

### 5.3 HTTP

Headers (every request):
```
Accept: application/vnd.github+json
User-Agent: VibePulse-public-repo-monitor/1
X-GitHub-Api-Version: 2022-11-28
Authorization: Bearer <token>        (only if a token)
```
(`_headers(stargazers=True)` would send `application/vnd.github.star+json`, but no call path uses it
any more — test pins the events request's Accept as `application/vnd.github+json`.)

`_fetch_json(url)`: `urlopen(request, timeout=8)` (**follows redirects**, e.g. renamed repos);
status ≠ 200 → `RuntimeError`; HTTP ≥ 400 raises `HTTPError`; read ≤ 256 KiB + 1, larger →
`ValueError`; `json.loads(raw)`.

1. **Repo**: `GET https://api.github.com/repos/{owner}/{repo}` (each part percent-encoded with no
   safe chars; no-op for the allowed alphabet).
2. **Latest stargazer** (only when the star count rose): `GET
   https://api.github.com/repos/{owner}/{repo}/events?per_page=30`. Must be a JSON array. Iterate in
   order (newest first); return the first item that is an object with `type == "WatchEvent"`,
   `actor.login` a non-empty string, and `created_at` parseable as ISO-8601 **with** timezone
   (`Z` accepted). Items failing any condition are skipped (keep scanning). Returns
   `(login, created_at normalized to UTC, isoformat with "+00:00" replaced by "Z")`, e.g.
   `"2026-08-14T18:02:00Z"` (Python would emit 6 fractional digits if the source had fractions).
   None found → `(None, None)`.

### 5.4 `poll_once() -> bool` (never throws)

```
now = clock()  (monotonic)
payload = fetch repo
require dict; payload["private"] is False (exactly; missing → error "not public")
stars, forks: true ints (not bool) in 0..2_147_483_647
name: non-empty str ≤ 100 chars
previous = stars under lock
event = nil
if previous != nil and stars > previous:
    (actor, starred_at) = latest_stargazer()  — exception → (nil, nil) + log.warning
    event = {"eventId": starred_at ?? "count:<stars>", "actor": actor (may be null), "eventStars": stars}
under lock: stars, forks, project=name, last_success_at=now, last_error=nil,
            next_poll_at = now + poll_seconds; if event: event, event_seen_at = now
return True
```
First successful poll only sets the baseline (never replays an old star). A decrease/equal count
keeps the previous event until its TTL.

On any exception: `delay = _retry_delay(exc, wall_clock())`; under lock `last_error = "<Type>: <msg>"`,
`next_poll_at = now + delay`; `log.warning("GitHub poll failed for %s; next attempt in %ds: %s")`;
return False.

`_retry_delay(err, wall_now)`: non-HTTPError or code ∉ {403, 429} → 600; else
`max(600, float(Retry-After or 0), float(X-RateLimit-Reset or 0) − wall_now, 0)` (unparsable → 0).
Test: 403 with `Retry-After: 900` → `next_poll_at = now + 900`.

### 5.5 `snapshot() -> dict` (= the `/api/github` body; also embedded in `GET /` under `github`)

```json
{"v": 1, "enabled": true, "repo": "owner/name", "project": "<name>", "stale": false,
 "stars": 42, "forks": 3,
 "eventId": "2026-08-14T18:02:00Z", "actor": "octocat", "eventStars": 42}
```
- `project` initially the configured repo part after `/`, then GitHub's `name`.
- `stale = last_success is None or last_error is not None or now − last_success > 300`.
- `stars`/`forks` present only once known (kept through failures).
- Event keys present only if an event exists and `now − event_seen_at ≤ 600`; `actor` may be `null`,
  `eventId` may be `"count:<n>"`.
- Disabled (no repo configured): `{"v": 1, "enabled": false}` (`disabled_snapshot()`).

### 5.6 Threading

`run()`: `while !stop { delay = max(0, next_poll_at − clock()) (under lock); if stop.wait(delay):
break; poll_once() }` — first poll immediately. `start()` idempotent (thread `github-monitor`,
daemon). `stop()`: set + join `max(1, min(poll_seconds, 5))`. A `threading.Lock` guards all fields;
the HTTP happens outside the lock.

---

## 6. `discovery.py` — DNS-SD advertisement

Constants: `SERVICE_TYPE = "_vibepulse._tcp.local."`, `PROTOCOL_VERSION = "1"`.

`_safe_dns_label(value)`: map each char to lowercase if ASCII alphanumeric else `-`; strip `-` from
both ends; collapse runs of `--` repeatedly; empty → `"host"`; truncate to 48 chars (after collapse;
may end with `-`). Pinned: `"PC å Ä / Test"` → `"pc-test"`, `"---"` → `"host"`, `"x"*100` → ≤48.

`_local_ipv4_addresses() -> tuple[4-byte packed]` (**the test hook**; tests monkeypatch it):
`getaddrinfo(gethostname(), None, AF_INET, SOCK_DGRAM)` (OSError → []); keep IPv4 that are not
loopback (127/8), not link-local (169.254/16), not unspecified; dedupe; **sort by dotted string**
(lexicographic, so `10.0.0.10` < `10.0.0.2`); return `inet_aton` bytes. Swift: make this an
injectable `() -> [IPv4Address]` closure; implement with `getaddrinfo` for parity (or `getifaddrs`
if you intentionally change semantics).

`DiscoveryAdvertiser(logger)`: fields `status = "off"`, `reason = None`.

`start(port) -> bool`:
1. `port ∉ 1..65535` → `status="error", reason="invalid-port"`, False.
2. `import zeroconf` fails → `"unavailable"/"dependency-missing"`, info log, False.
3. addresses empty → `"unavailable"/"no-lan-address"`, info log, False. (No retry later — the
   advertiser is started once, right after the HTTP server binds.)
4. `label = _safe_dns_label(gethostname())`; register
   - instance name `"VibePulse-<label>._vibepulse._tcp.local."`
   - host (server) `"vibepulse-<label>.local."`
   - addresses = the IPv4 list, port = bound port (default `--port 8737`)
   - TXT properties exactly `{b"v": b"1"}` (nothing else — no rev, no account data)
   - `allow_name_change=True` (auto-rename on conflict)
5. Exception → close zeroconf best-effort, `"error"/<ExceptionClassName>`, warning, False.
6. Success → `"ready"/None`, info log, True.

`stop()`: unregister then close (each failure → warning), idempotent.

Diagnostics: `GET /` → `"discovery": {"status": …, "reason"?: …}`.

Swift mapping: `DNSServiceRegister(name: "VibePulse-<label>", regtype: "_vibepulse._tcp",
domain: "local.", host: nil, port: htons(port), txtRecord: "v=1")` (auto-rename is the default
unless `kDNSServiceFlagsNoAutoRename`), or `NetService`/`NWListener.Service`. Behavioral delta to
document: Bonjour answers with the system host name and **all** interface addresses (incl. IPv6),
not a custom `vibepulse-<label>.local.` host with a filtered IPv4 list. For exact parity, register a
custom host via `DNSServiceRegisterRecord` A records for the filtered list. The "zeroconf missing"
state becomes unreachable (keep the status vocabulary).

---

## 7. `quota_http.exchange` — shared JSON request for Cursor/Grok

```
exchange(url, *, method="GET", headers, body=None, timeout=15, now_ts=0.0, opener=None)
  -> (status: int, payload: dict | None, retry_after: int)
```
- Opener refuses redirects (a 3xx becomes an `HTTPError` with that code) so a bearer/cookie never
  leaves the host.
- `HTTPError` (any ≥ 300 non-followed/≥ 400) → `(code, None, retry_after_seconds(Retry-After, now_ts))`.
- Any other exception (DNS, TLS, timeout) → `(0, None, 0)`.
- Read ≤ 1 MiB + 1; larger → `(0, None, 0)`.
- `status = response.status or 200`; UTF-8 JSON; not an object or undecodable → `(status, None, 0)`.
- Success → `(status, dict, 0)`.

`retry_after_seconds(value, now_ts)` (identical copy in `codex_oauth`): None → 0; `int(text.strip())`
if ≥ 0 (Python `int()` also accepts `+42`, `4_2`, surrounding whitespace); otherwise
`parsedate_to_datetime` (RFC 7231 HTTP-date) → `max(0, round(when − now))`; unparsable → 0. Pinned:
`"42"` → 42, `"Thu, 01 Jan 1970 00:02:00 GMT"` at now 0 → 120.

Swift: `URLSession` with a delegate returning `nil` from
`willPerformHTTPRedirection`; that yields the 3xx response itself → treat as `(code, nil, retry)`.

---

## 8. `codex_oauth.py` — Codex quota via ChatGPT usage API

Constants: `DEFAULT_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"`, `_AUTH_MAX_BYTES = 262144`,
`_BASE_RE = (?m)^[ \t]*chatgpt_base_url[ \t]*=[ \t]*(['"])([^'"]+)\1[ \t]*$`.

- `auth_path(environ, home)`: `$CODEX_HOME` (expanduser) if set and non-empty, else `~/.codex`;
  `+ "/auth.json"`. `config_path` = sibling `config.toml`.
- `token_fingerprint(token)` = SHA-256 hex of UTF-8 (used for tokenserver's dead-token set).
- `usage_url(base) -> str | None`:
  - None or blank (after `strip().rstrip("/")`) → default.
  - `urlsplit`; require `https`, hostname, no username/password (truthy), no query, no fragment;
    else **None** (caller maps to `transport`).
  - `path = parts.path.rstrip("/")`; if it ends with `/wham/usage` or `/api/codex/usage` keep;
    elif it **contains** `/backend-api` → `+ "/wham/usage"`; else `+ "/api/codex/usage"`.
  - Rebuild `scheme://netloc + path` (netloc keeps a port).
  - Pinned: None → default; `https://chatgpt.com/backend-api` → `…/backend-api/wham/usage`;
    `https://example.com` → `https://example.com/api/codex/usage`; `http://…` → None;
    `https://user:pass@…` → None.
- `base_url_from_config(text)`: first regex match (commented lines never match because `#` precedes
  the key); returns group 2 stripped or None. A trailing inline comment makes the line not match.
- `_jwt_expiry(token)`: split `.`, need ≥ 2 parts; base64url-decode `parts[1]` with re-padding
  (Python's decoder is lenient about stray characters — Swift should be lenient too: strip anything
  outside the alphabet before decoding); JSON; `exp` int/float not bool → float; else None.
- `load_auth(path, now_ts) -> AuthView(status, access_token?, account_id?, expires_at?)`:
  - `stat`: not found → `missing`; other OSError → `malformed`; size ≤ 0 or > 256 KiB → `malformed`.
  - UTF-8 JSON; any error → `malformed`.
  - `tokens` must be an object else `missing` (an API-key-only file is `missing`).
  - `tokens.access_token`: non-blank str containing **no** whitespace anywhere, else `missing`.
  - `tokens.account_id`: non-empty str or None.
  - JWT `exp` present and `≤ now_ts` → `expired` (token **not** returned); else `ready` (exp may be None).
  - The refresh token is never read into memory beyond the JSON parse; `repr` hides tokens.
- `app_server_body(payload) -> dict | None`: maps the `wham/usage` document to the app-server shape:
  ```
  payload.rate_limit.primary_window / secondary_window each →
    {"usedPercent": used_percent (raw), "windowDurationMins": limit_window_seconds/60, "resetsAt": reset_at (raw)}
  window dropped unless limit_window_seconds is a number (not bool) > 0 and divisible by 60
  → {"rateLimits": {"limitId": null, "limitName": null, "primary": p|null, "secondary": s|null}}
  None if payload/rate_limit not dicts or both windows dropped. additional_rate_limits ignored.
  ```
  Pinned: `limit_window_seconds: 18001` → None.

How tokenserver uses it (`_read_codex_oauth_limits`, belongs to the Codex-quota spec but listed here
for the HTTP contract): `GET <usage_url>` with headers
`Authorization: Bearer <access_token>`, `Accept: application/json`, `User-Agent: vibepulse`,
`ChatGPT-Account-Id: <account_id>` (if any); timeout 15 s; no redirects; guarded by a non-blocking
file lock `<state_dir>/codex-probe.lock` (held → kind `held`). Mapping: 429 → `rate_limited` with
Retry-After; 401/403 → remember token fingerprint as dead (bounded to 8, FIFO eviction) →
`unauthorized` (further reads with the same token short-circuit to `unauthorized`); other HTTP or
exception → `transport`; config URL rejected → `transport`; then `app_server_body` →
`_parse_codex_rate_limits_response` (other spec) → `ok` | `unmapped`.

---

## 9. `codex_usage.py` — month-to-date Codex value (+ `codex_rollout.py`)

### 9.1 `default_sessions_dir()`

Module override `DEFAULT_SESSIONS_DIR` (tests) wins; else `$CODEX_HOME` (expanduser) or `~/.codex`,
`+ "/sessions"`, resolved **at call time**. tokenserver's `CODEX_SESSIONS` also comes from here
(import-time).

### 9.2 Rollout line acceptance (`codex_rollout.py`, pure)

- `codex_rollout_session_id(obj)`: `obj.type == "session_meta"` and `payload.session_id` non-empty
  str → it (fork/resume keep the parent `session_id`; `payload.id` is ignored).
- `codex_rollout_turn_model(obj)`: `obj.type == "turn_context"` and `payload.model` non-empty str.
- `codex_rollout_last_token_usage(obj)`: `obj.type == "event_msg"`, `payload.type == "token_count"`,
  `payload.info` dict, `info.last_token_usage` dict → it (**never** `total_token_usage`).
- (`codex_rollout_rate_limits`, `observation_timestamp` are used by other specs.)

### 9.3 `month_value(sessions_dir=None, now=None, table=None) -> (usd: float, priced_tokens: int, unpriced_tokens: int)`

```
root = sessions_dir ?? default_sessions_dir(); if !isDirectory(root): return (0.0, 0, 0)
now = now ?? local-aware now; month_start = local midnight of day 1; month_key = "YYYY-MM"
LOCK (module-global)
  live = {}
  for path in recursive glob root/**/rollout-*.jsonl (includes root itself):
      stat (OSError → skip)
      if local(mtime) < month_start: skip (and it will be evicted)
      live.add(path)
      stat_key = (mtime, size); identity = (dev, ino)
      cached = cache[path]
      if cached and cached.stat == stat_key and cached.identity == identity: continue
      can_append = cached and cached.month == month_key and cached.identity == identity
                   and size > cached.stat.size
      if can_append:
          (new, until, model, sid) = parse(path, month_start, cached.offset, cached.model, cached.session_id)
          cached.records += new; cached.stat = stat_key; cached.offset = until; cached.model = model; cached.session_id = sid
      else:
          (records, until, model, sid) = parse(path, month_start, 0, nil, nil)
          cache[path] = {stat_key, identity, offset: until, month: month_key, model, session_id: sid, records}
  evict cache entries not in live
  best = {}
  for (path, entry) in cache (insertion order):
      usd, priced, unpriced = sums over entry.records
      key = entry.session_id ?? ("\0nometa", path)          # meta-less files never merge
      tokens = priced + unpriced
      if key not in best or tokens > best[key].tokens: best[key] = (tokens, usd, priced, unpriced)
  return (Σ usd, Σ priced, Σ unpriced) over best
```
Rationale (pinned by tests): resume/fork files replay the parent history under the same
`session_id`; each conversation is counted once from its most complete rollout (largest token
volume; ties keep the first seen).

`_parse_file(path, month_start, offset, model, session_id, table)` → `(records, parsed_until,
model, session_id)`:
- open binary, seek offset; loop `readline()`; EOF → stop. A final line without `\n` → set
  `parsed_until` to its start and stop (torn write is re-read next time). Else `parsed_until = tell()`.
- `json.loads(line)`; invalid → skip.
- If `session_id` is None and the line is session_meta → set, continue.
- If turn_context → `model = …`, continue.
- If last_token_usage → `stamp = fromisoformat(timestamp with Z→+00:00).astimezone()` (**naive
  timestamps are interpreted as local time**); None or `< month_start` → skip.
  `(usd, unpriced) = table.price(model, usage)` (value_meter; exactly one non-zero; unknown or None
  model → `(0, countable_tokens)`); `priced = 0 if unpriced else _counted(usage)`;
  append `(local day "YYYY-MM-DD", usd, priced, unpriced)` if any is non-zero.
- `OSError` mid-read → return what was parsed.
- `_counted(usage)` = `input_tokens + output_tokens + cache_write_input_tokens`, each: int/float not
  bool, `> 0` else 0, truncated with `int()` (`cached_input_tokens` is inside `input_tokens`;
  reasoning inside output).

`reset_cache()` clears the cache (tests; changed prices). Called by tokenserver's `_compute` as
`codex_usage.month_value(now=now, table=_price_table)`.

---

## 10. `cursor_usage.py` — Cursor plan usage

### 10.1 Constants

`USAGE_URL = "https://cursor.com/api/usage-summary"`,
`SAND_URL = "https://cursor.com/api/dashboard/get-sand-usage-status"`,
`_TOKEN_KEY = "cursorAuth/accessToken"`, `_SKEW_S = 60`, `_USER_ID = ^[A-Za-z0-9._-]+$`.

### 10.2 Credential: Cursor's SQLite state DB

`db_path(environ, home)`:
- macOS: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- Windows: `%APPDATA%` (or `~/AppData/Roaming`) `/Cursor/User/globalStorage/state.vscdb`
- other: `$XDG_CONFIG_HOME` (only if absolute) or `~/.config`, `/Cursor/User/globalStorage/state.vscdb`

`load_token(path, now_ts) -> (status, token?)`:
1. Not a regular file → `("missing", nil)`.
2. `wal = path + "-wal"`; URI = `"file:" + percent-encode(posix path, safe "/:") + "?mode=ro&immutable=1"`
   if the WAL file does **not** exist, else `"?mode=ro"`. Open with URI mode (read-only).
   Open error → missing.
3. Query exactly: `SELECT value FROM ItemTable WHERE key = ?` bound to `"cursorAuth/accessToken"`;
   `fetchone`. SQL error → missing. Close always.
4. No row → missing. `decode_token(row[0])`; None or fewer than 2 `.` → missing.
5. `jwt_expiry(token)` None or `≤ now_ts + 60` → `("expired", nil)`. Else `("ready", token)`.

Swift: `sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)`; prepare/bind/step;
read by `sqlite3_column_type` (TEXT → `String`, BLOB → `Data`). Never write; never refresh the token.

`decode_token(raw)`:
- `str` → as is. `bytes` → UTF-16LE (errors replaced) if it starts with `FF FE` **or** (non-empty,
  even length, every odd-index byte is 0); else UTF-8 (errors replaced). (With a leading BOM, the
  decoded U+FEFF stays in the string — quirk.) Other types → None.
- Strip chars `\0`, space, `\t`, `\r`, `\n` from both ends; if length ≥ 2 and wrapped in `"` → remove
  one pair; `strip()` whitespace; empty → None.
- Pinned: UTF-16LE bytes and `"\"<token>\""` both decode to the token.

`jwt_expiry` = same algorithm as codex `_jwt_expiry`.

`session_user_id(token)`: JWT payload `sub` str → `sub.split("|")[-1].strip()` must fullmatch
`_USER_ID`, else None. `session_cookie(token)` = `"WorkosCursorSessionToken=<uid>%3A%3A<token>"`
(literal `%3A%3A`). Pinned: `sub "auth0|user_01ABC"` → `user_01ABC`; `"auth0|not a user"` → None.

### 10.3 Parsing

`as_percent`, `parse_time` are imported from `grok_billing` (§11.2).

- `plan_block(payload)`: `individualUsage.plan` if it is a dict; else `planUsage` if dict; else None.
- `_lane(block, key, reset_at)`: if block None or `key ∉ block` → `{"pct": null, "reset_at": reset_at
  if block (truthy: non-empty dict) else null}`; else `{"pct": as_percent(block[key]), "reset_at": reset_at}`.
- `parse_summary(payload)`: dict and block required else None; `reset_at = parse_time(billingCycleEnd)`;
  returns `{"total": lane("totalPercentUsed"), "models": lane("autoPercentUsed"), "third": lane("apiPercentUsed")}`.
  Pinned: `totalPercentUsed 0.36` → 0.4; `17.2` → 17.2; `0` → 0.0; `billingCycleEnd "1771077734000"`
  (ms string) parses; `planUsage` shape accepted, missing `autoPercentUsed` → pct null.
- `parse_sand(payload, now_ts)` (Grok Bot lane; "no allowance" is an empty lane, not a failure):
  ```
  empty = {"pct": null, "reset_at": null}; non-dict → empty
  if includedLimitZero is bool: has_limit = !includedLimitZero
  elif hasNonZeroIncludedLimit is bool: has_limit = it
  else has_limit = nil
  trial = parse_time(sandTrialExpiresAt)
  has_trial = has_limit != true and trial != nil and trial > now
  if has_limit != true and !has_trial: return empty
  pct = as_percent(usagePercent); nil → empty
  reset_at = has_limit == true ? parse_time(nextResetTimestampUtc) : nil
  return {"pct": pct, "reset_at": reset_at}
  ```

### 10.4 `fetch(now_ts, opener=None) -> dict` (no token in result)

```
(status, token) = load_token(db_path(), now_ts)
expired → {"auth":"expired","summary":"skipped","sand":"skipped"}
not ready / no cookie (bad sub) → {"auth":"missing","summary":"skipped","sand":"skipped"}
GET USAGE_URL headers: Cookie: <session_cookie>, Accept: application/json, User-Agent: vibepulse  (exchange, 15 s, no redirects)
result = {"auth":"ready","retry_after":retry,"sand":"skipped"}
429 → summary "rate_limited", return
401/403 → auth "unauthorized", summary "unauthorized", return
≠200 or payload nil → summary "transport", return
parsed nil → summary "unmapped" (continue to sand!)  else summary "ok" and merge total/models/third into result
POST SAND_URL body "{}" headers: Cookie, Accept, User-Agent: vibepulse, Origin: https://cursor.com, Content-Type: application/json
  200 & dict → result.bot = parse_sand(...); sand = "none" if bot.pct nil else "ok"
  else sand "failed"; if 429: retry_after = max(retry, sand_retry), sand "rate_limited"
return result
```

---

## 11. `grok_billing.py` — Grok credits

### 11.1 Constants / credential

`BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"`, `_AUTH_MAX_BYTES = 262144`,
`_PREFERRED_PREFIX = "https://auth.x.ai::"`. `auth_path`: `$GROK_HOME` (expanduser) or `~/.grok`,
`+ "/auth.json"` — a JSON object mapping issuer names to entries `{key, refresh_token, expires_at, …}`.

`load_auth(path, now_ts) -> AuthView(status, access_token?)`:
- stat: not found → `missing`; other OSError → `unreadable`; size ≤ 0 or > 256 KiB → `malformed`;
  JSON error → `malformed`; not an object → `malformed`.
- For each `(name, entry)` in **file order**: skip unless entry is a dict with string `key`.
  `expires = parse_time(expires_at)`; if `expires ≤ now` → mark `expired = true` and skip. Put into
  `preferred` if `name` starts with `https://auth.x.ai::`, else `rest`.
- For entries in `preferred + rest`: first with a usable token (`!startsWith("xai-")` — management
  API keys are not bearers — and at least 2 `.`) and not expired → `ready`.
- None: `expired` flag → `expired`; else `missing`. Refresh token never kept; `repr` hides token.

### 11.2 Shared parsers (also used by Cursor)

`parse_time(value) -> epoch seconds? `:
- bool/None → None. int/float: if `> 10_000_000_000` treat as ms (`/1000`); if `< 1_000_000_000` → None.
- str: strip; empty → None; all digits → recurse as int; trailing `Z` → `+00:00`;
  `datetime.fromisoformat` (Python 3.11+ grammar: date-only, `T` or space separator, fractional
  seconds, offsets) else None; **naive → UTC**; return `.timestamp()`.
  Swift: `ISO8601DateFormatter` with several option sets (`.withInternetDateTime`, `+ .withFractionalSeconds`,
  `.withFullDate`) and default UTC; or a small hand parser.
- `as_percent(value) -> Double?`: number not bool; NaN or `< 0` → None; `> 1000` → None; `> 100` → 100.0;
  `round(x, 1)` (Python rounds the exact binary value half-to-even; Swift parity:
  `Double(String(format: "%.1f", x))!`). ±inf → None/`>1000` → None.
- `_money(node)`: `{"val": n}` or `n`; number not bool, not NaN, `≥ 0`.

### 11.3 `quota_label(start, end)`: `"CREDITS"` if either None or `end ≤ start`; days = (end−start)/86400;
`6 ≤ days ≤ 8` → `"WEEKLY"`; `27 ≤ days ≤ 32` → `"MONTHLY"`; else `"CREDITS"`.

`_period_bounds(config)`: `currentPeriod.start/end` (if a dict); if `end` None → `billingPeriodEnd`,
and if `start` None → `billingPeriodStart`.

`parse_billing(payload) -> {"pct", "reset_at", "label"}?`:
- `config = payload.config` if dict else `{}`.
- Look for key `creditUsagePercent` in `config`, then in `payload` — **the first place where the
  key exists wins**, even if its value is invalid (→ pct None → return None).
- If the key exists nowhere: `used = _money(config.onDemandUsed) ?? _money(payload.onDemandUsed)`,
  `cap = _money(config.onDemandCap) ?? _money(payload.onDemandCap)`; if both and `cap > 0`:
  `pct = as_percent(used / cap * 100)`.
- pct None → None. Else `{"pct": pct, "reset_at": end, "label": quota_label(start, end)}`.
- Pinned: 0.4 with a 7-day period → WEEKLY; 25/100 with Sept 1→Oct 1 → 25.0 MONTHLY; period only →
  None; cap 0 → None.

### 11.4 `fetch(now_ts, opener=None)`

```
auth = load_auth(auth_path(), now)
expired → {"auth":"expired","status":"token_expired"}
not ready → {"auth":"missing","status": {"missing":"no_grok_oauth_token","malformed":"grok_auth_malformed","unreadable":"grok_auth_unreadable"}[status] ?? "no_grok_oauth_token"}
GET BILLING_URL headers: Authorization: Bearer <key>, x-xai-token-auth: xai-grok-cli, Accept: application/json, User-Agent: vibepulse
429 → {"auth":"ready","status":"rate_limited","retry_after":retry}
401/403 → {"auth":"unauthorized","status":"token_dead_awaiting_refresh"}
≠200 or nil → {"auth":"ready","status":"transport"}
parse nil → {"auth":"ready","status":"unmapped"}
→ {"auth":"ready","status":"ok","reading":{pct, reset_at, label}}
```

---

## 12. Consumer: `subscription_quota.py` (how Cursor/Grok results reach `/api/tokens`)

(Listed for completeness; may also be covered by the quota spec.) Two module-level `Probe`s:
`grok` (fetch = `grok_billing.fetch`) and `cursor` (fetch = `cursor_usage.fetch`).

- Cadence: `LIMITS_EVERY_S = 240`; interval = 15 s (`AUTH_RECOVERY_EVERY_S`) when `auth ∈
  {missing, expired, unauthorized}`, else `240 * 2^min(failure_streak, 2)` (240/480/960).
  429 → `cooldown_until = wall + max(retry, 600)`.
- `kick()` (called on every `/api/tokens` build via `_subscription_wire`): if due and not refreshing:
  in cooldown → `failure_streak += 1; last_mono = now` (no request); else spawn thread
  `grok-quota`/`cursor-quota` → `fetch(time.time())` → `note(raw)`; exceptions become
  `{"auth": previous, "status": "probe_crashed: <Type>", "summary": "transport", "sand": "failed"}`.
- `note`: Grok: ok → store lane `credit` + label; unmapped → drop lane/label, streak+1;
  rate_limited → mark stale + cooldown; transport → mark stale, streak+1; auth states → mark stale,
  streak 0, status = the fetch status. Cursor: summary ok/unmapped → store the three lanes (unmapped
  lanes are all-null); otherwise mark lanes stale (and `bot` if sand skipped); sand ok/none → store
  `bot`; sand failed/rate_limited → mark bot stale; then status strings
  `usage_http_429 + backoff_until_HH:MM`, `usage_request_failed`, `token_dead_awaiting_refresh`,
  `token_expired` / `no_cursor_session`, `usage_http_200 + no_mapped_limits`,
  `usage_http_200 + ok[; sand_failed]`.
- Wire fields (`fields(now_wall)`), each lane → `<prefix>Pct`, `<prefix>ResetMin` =
  `floor((reset_at − now)/60)` if future else null, `<prefix>Stale`; a lane with no pct or a past
  reset is all-null/false. Prefixes: `grokCredit` (+ `grokQuotaLabel`), `cursorTotal`, `cursorModels`,
  `cursorThird`, `cursorBot`.
- Diagnostics (`GET /`): `grokProbe`, `grokProbeIntervalS`, `grokProbeCooldownLeftS`, `grokProbeAgeS`,
  and the same with `cursor`.

---

## 13. External dependency inventory

### 13.1 HTTP endpoints

| Component | Method + URL | Auth | Timeout | Redirects | Retry/backoff |
|---|---|---|---|---|---|
| Interaction relay | PUT/DELETE/GET/PUT `<origin>/v1/mailboxes/{box}/…` (§2.4) | `Bearer <mac token>` | connect 2 s, read 5 s | never | 0.5→5 s exp backoff + ≤20 % jitter per item; poll 0.5 s |
| Numbers publisher | POST `<relay_url>/api/{tokens,max-tracker,github}` | secret path; `X-VibePulse-Publisher` | 10 s | urllib follows (port: refuse) | next 30-s tick; ceilings 300/1800/1800 s |
| GitHub | GET `https://api.github.com/repos/{o}/{r}` and `…/events?per_page=30` | optional `Bearer` | 8 s | followed | 120 s poll; failure 600 s or Retry-After / X-RateLimit-Reset for 403/429 |
| Codex usage | GET `https://chatgpt.com/backend-api/wham/usage` (or config-derived) | `Bearer` + `ChatGPT-Account-Id` | 15 s | refused | tokenserver ladder (other spec) |
| Cursor | GET `https://cursor.com/api/usage-summary`; POST `https://cursor.com/api/dashboard/get-sand-usage-status` body `{}` | `Cookie: WorkosCursorSessionToken=<uid>%3A%3A<jwt>` | 15 s | refused | subscription_quota cadence |
| Grok | GET `https://cli-chat-proxy.grok.com/v1/billing?format=credits` | `Bearer` + `x-xai-token-auth: xai-grok-cli` | 15 s | refused | subscription_quota cadence |

### 13.2 Local files / DB / env

| Source | Used by | Details |
|---|---|---|
| `$CODEX_HOME/auth.json` or `~/.codex/auth.json` | codex_oauth | `tokens.access_token`, `tokens.account_id`; ≤256 KiB; never written |
| `$CODEX_HOME/config.toml` | tokenserver→codex_oauth | `chatgpt_base_url = "…"`; ≤256 KiB |
| `$CODEX_HOME/sessions/**/rollout-*.jsonl` | codex_usage | incremental JSONL scan |
| `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (+ `-wal` presence check) | cursor_usage | SQLite `SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'`, read-only (`immutable=1` when no WAL) |
| `$GROK_HOME/auth.json` or `~/.grok/auth.json` | grok_billing | issuer → `{key, expires_at}` |
| `~/.vibepulse-device-key`, env `VIBEPULSE_DEVICE_KEY`/`TK_VIBEPULSE_DEVICE_KEY`, `<repo>/secrets.h` | relay | 64-hex device key |
| `~/.vibepulse-interaction-relay-token` (0600, no symlink) or env `VIBEPULSE_INTERACTION_MAC_TOKEN` | relay | 43-char Mac bearer |
| env `GITHUB_TOKEN`/`TG_GITHUB_TOKEN`, `~/.torget-github-token`, `<repo>/.github-token`, `secrets.h TG_GITHUB_TOKEN` | github | optional |
| env `VIBEPULSE_GITHUB_REPO` | github | default for `--github-repo` |
| `<state_dir>/config.json` | relay config | see §3 |
| env `APPDATA`, `XDG_CONFIG_HOME` | cursor (non-macOS) | |

Keychain: none in this scope. Subprocesses: none in this scope. Network listeners: none in this scope
(mDNS registration only).

### 13.3 Threads (all daemon)

| Thread name | Owner | Period |
|---|---|---|
| `vibepulse-interaction-relay` | InteractionRelay (interactions) | 50 ms tick |
| `vibepulse-agent-status-relay` | InteractionRelay (status) | 50 ms tick; PUT ≤ every 5 s |
| `relay-publisher` | Publisher | immediate, then 30 s |
| `github-monitor` | GitHubMonitor | 120 s (600+ s on failure) |
| `grok-quota` / `cursor-quota` | subscription_quota Probe | one-shot per kick |
| (zeroconf internal threads) | discovery | library-owned |

Locks: relay event-queue mutex; store lock (callback `_verify_resolution` runs under it);
GitHubMonitor `_lock`; codex_usage module `_lock` around the whole scan; Probe `_lock`.

---

## 14. Tests and the behavior each pins (re-express in XCTest/Swift Testing)

### 14.1 `test_interaction_relay_crypto.py`
Fixtures: device key `000102…1f`, mailbox `vp_A1b2C3d4E5f6G7h8`, request id
`ABEiM0RVZneImaq7zN3u_w` (= bytes `00 11 22 … ff`), challenge `2021…3f`, request nonce
`404142…4b`, verdict nonce `505152…5b`, expiresAt `1787097720`, view bytes =
`{"provider":"codex","kind":"question","prompt":"How should Codex handle approvals?","title":"Use the trusted hook","subtitle":"Desktop + CLI, one setup","can_approve":true}`,
status pubId `1787097600123`, status expiry `1787097615`, status nonce `606162…6b`, status bytes
`{"agents":{"claude":{"active_count":1,"jobs":[]},"codex":{"active_count":0,"jobs":[]}},"seq":7,"v":2}`,
padding `0xa5` fill.
- **StatusRelayCryptoTests**
  - `test_status_key_is_direction_separated`: 4 distinct 32-B keys; `status_aad` exact string.
  - `test_status_roundtrip_uses_an_exact_fixed_frame`: ciphertext 2832 B; envelope equals canonical
    re-serialization; decode returns all fields + SHA256.
  - `test_status_plaintext_layout_and_padding_are_pinned`: byte layout of §1.7 incl. padding bytes.
  - `test_tamper_wrong_key_and_wrong_mailbox_are_rejected`: flip nonce[0], ct[0], ct[-1] (tag);
    wrong key (`0xff`*32); wrong mailbox `vp_Z9y8X7w6V5u4T3s2` → error.
  - `test_authenticated_malformed_status_frames_are_rejected` (re-encrypt with the right key):
    bad magic, zero pubId, zero expiry, zero length, length 2561, zero digest, frame one byte short.
  - `test_status_encode_rejects_invalid_fields_and_sources`: pubId 0/True/2^64; expiry 0/True/2^32;
    status empty/2561 B/non-bytes; nonce `b"short"`; padding wrong size / non-bytes callable.
  - `test_status_outer_envelope_remains_strict`: `{}`, `[]`, trailing space, extra key, `v:true`,
    nonce `AA`, ciphertext `AA`, duplicate `v`.
- **ProtocolVectorTests**
  - `test_fixed_vector_reconstructs_every_protocol_boundary`: salt, 3 keys, both AADs, view digest
    (hex + b64url), request ciphertext/tag/frame SHA/inner JSON/envelope, verdict HMAC (hex +
    b64url), MAC message hex, verdict ciphertext/tag/frame SHA/inner JSON/envelope; round-trips.
  - `test_base64url_is_canonical_and_unpadded`: round-trip `b""`, `b"\0"`, `range(32)`, `range(255)`;
    reject list in §1.3.
- **StrictDecodingTests**
  - `test_device_key_shape_is_exact`.
  - `test_nonce_ciphertext_tag_and_aad_tampering_are_rejected` (+ wrong mailbox/request id AAD).
  - `test_outer_envelope_is_exact_bounded_json`: also `not json`, `v:2`, `{` + 4096 spaces + `}`.
  - `test_authenticated_inner_request_tampering_is_rejected`: requestId changed, view changed,
    digest zero, `expiresAt: true`, `-1`, unknown key; frame length 0, 0xFFFF, short frame.
  - `test_verdict_and_mac_tampering_are_rejected`: outer tampering; AAD mismatch; all 4 verdicts
    round-trip and verify; wrong challenge request → verify False; wrong keys → verify False and
    decode errors; inner changes: requestId/unknown key → decode error; challenge/digest/verdict/hmac
    changes → decode OK but verify False.
  - `test_view_and_frame_caps_are_enforced`: 640 B ok, 641 B rejected.
  - `test_expiry_is_an_exact_cross_language_uint32`: `0xFFFFFFFF` ok; 0, −1, True, 2^32 rejected.

### 14.2 `test_interaction_relay.py` (fake transport = in-memory Worker; wall 50,000; monotonic 1000; jitter 0; deterministic random: n-th call returns `bytes([n & 0xff]) * size`; store random `0x42`*n)
- `test_is_idle_without_pending_and_publish_queue_is_nonblocking_bounded`: no calls when idle; 8
  parks fill the queue; a 9th `on_park` is dropped (size stays 8).
- `test_valid_verdict_resolves_once_and_remote_row_is_deleted`: publish → verdict → resolves
  `approve`; next cycle DELETEs remote request+verdict; store empty.
- `test_retry_reuses_exact_ciphertext_and_backoff_is_bounded`: first PUT fails; a second cycle at
  the same time does nothing; after +0.5 s retries with identical body; timeouts 2.0/5.0; bearer header.
- `test_wrong_hmac_wrong_key_and_tampering_never_resolve`.
- `test_binding_expiry_unknown_and_disallowed_approve_fail_closed`: challenge, digest, expired (1-s
  hold +2 s → None), unknown id, `rm -rf important` (can_approve false) approve.
- `test_authenticated_panic_denies_only_the_current_snapshot`: both pending → deny.
- `test_outage_never_extends_deadline_or_suppresses_terminal_fallback`.
- `test_direct_answer_enqueues_remote_delete_and_thread_is_daemon`: LAN v2 answer → DELETE; thread
  alive/daemon; stops.
- `test_full_queue_coalesces_remove_and_cleans_uncertain_publish`: full queue + resolve → the park is
  replaced by the remove → only `DELETE` for that id (no PUT); a PUT whose response was lost
  (`OSError`) still gets a DELETE on remove.
- `test_logs_are_redacted_to_origin_and_route_kind`.
- `test_constructor_rejects_ambiguous_origins_tokens_and_timeouts`.
- `test_untrusted_or_oversize_http_response_never_resolves`: missing Cache-Control; duplicate
  Cache-Control; `text/plain`; 4097-byte body.
- `test_failed_delete_backlog_stays_bounded`: 24 failing deletes → ≤ 8 retained.
- **StatusPublisherTests**
  - `test_publishes_immediately_then_at_most_every_five_seconds`: pubId `50_000_000`, expiry
    `50_015`, `pending` stripped; nothing at +4.999 s; publish at +5.000 s; pubId increases;
    envelope differs.
  - `test_changing_status_has_a_full_day_budget_and_keeps_expiry`: 86,400 one-second ticks →
    exactly 17,280 PUTs; each expiry = `int(wall)+15`.
  - `test_retry_reuses_exact_ciphertext_then_rotates_after_success`.
  - `test_status_failure_cannot_delay_an_interaction_publish` (run_once: request still PUT).
  - `test_blocked_status_http_cannot_hold_the_verdict_worker` (threads: request PUT within 0.5 s
    while the status PUT blocks).
  - `test_status_only_requires_a_source_but_not_an_interaction_store`.

### 14.3 `test_interaction_relay_integration.py` (real local HTTP "Worker", real tokenserver HTTP handler)
- `test_codex_question_round_trip_matches_exact_store_view_and_deletes`: hook `/api/codex/question`
  → relay PUT → panel GET next → decrypted view bytes equal the store's job bytes → panel POST
  verdict (201; duplicate 200) → hook returns `{"status":"answered","option_index":0,"answer":"Use the trusted hook"}` → remote emptied.
- `test_claude_permission_deny_returns_exact_hook_decision`: `/api/hook/permission` deny →
  `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from VibePulse"}}}`.
- `test_wrong_key_times_out_to_computer_and_cleans_remote_state` → `{"status":"computer","reason":"timeout"}`.
- `test_direct_lan_answer_wins_and_enqueues_remote_cleanup` → `{"status":"computer","reason":"deny"}`.

### 14.4 `test_publisher.py`
Fingerprint key-order independence and value sensitivity; `should_send` fresh/unchanged/changed/
heartbeat edge (299 s false, 300 s true); per-path URLs without double slash; unchanged not resent;
change waits for the 300-s ceiling, then heartbeat; failed send retries next tick; failed throttled
update doesn't restart the ceiling; tokens stale→fresh bypass once; failed recovery retries; non-token
stale change waits; startup placeholder never published (and the first real payload goes out at
once); broken producer isolated; `start()` returns < 0.2 s while the first producer blocks; UA
prefix; **two publishers with continuously changing payloads over 24 h (2,880 ticks) ≤ 768 sends**.

### 14.5 `test_github_monitor.py`
Repo validation; first poll baseline snapshot exact dict + timeout 8; count increase picks the first
`WatchEvent` (skips `PushEvent`), eventId = its created_at, request URL contains
`/events?per_page=30`, Accept `application/vnd.github+json`; stargazer failure → count-only event
(`count:8`, actor null, not stale); a legacy stargazers-shaped list → count-only event; 403 with
Retry-After 900 → keeps stars, stale, next poll +900; event expires after 601 s but stars stay;
private repo → failure + stale; disabled payload exact.

### 14.6 `test_discovery.py`
Label sanitization; address filter (loopback, link-local removed, dupes collapsed); missing
dependency non-fatal (`unavailable`/`dependency-missing`); registration with fake zeroconf
(`allow_name_change=True`, type, port 8737, properties exactly `{b"v": b"1"}`, hostname `"My PC"`),
stop unregisters + closes; port 0 → `error`.

### 14.7 `test_codex_oauth.py`
URL mapping (5 cases); config regex ignores a commented line; expired token not returned and hidden
from repr (also refresh token); ready token hidden from repr, account id kept; API-key-only file →
missing; Retry-After seconds + HTTP-date; non-minute window → None.

### 14.8 `test_codex_usage.py` (price fixture `test/fixtures/codex-prices.json`: gpt-5.6-sol $5/M input, $30/M output, $0.50/M cache-read, `cache_included_input`; gpt-5.6-luna 1M fresh input = $0.20)
Missing dir → zeros; honors `CODEX_HOME`; 1M fresh → $5.00, priced 1,000,000; only last usage summed
(3 events → $15 not $50); usage before any turn_context → unpriced 1,000,000; model switch
($5.20); previous-month rows skipped; unknown model unpriced; rate-limit-only events contribute
nothing; incremental read keeps model; torn row re-read; malformed lines skipped; nested dirs; deleted
file evicted; real scrubbed rows (6 usages) → $0.436806 (±1e-4), 225,616 tokens; resume+fork
replays counted once; most complete rollout wins (+1M, +$5); distinct sessions both counted; meta-less
files stand alone ($10); session_id persists across incremental reads (sibling dropped);
`codex_rollout_session_id` accepts only session_meta.

### 14.9 `test_cursor_usage.py`
UTF-16LE and quoted token decode; missing DB → missing, expired JWT → expired, valid → ready + token
(SQLite fixture: `CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)` with UTF-8 bytes);
percent units kept (0.36 → 0.4); `planUsage` shape; sand gating (limit-zero → null; live → 12.5 +
reset; trial → 3.0, reset null); cookie from JWT subject suffix; invalid subject → None.

### 14.10 `test_grok_billing.py`
Preferred `https://auth.x.ai::` entry wins and repr hides token/refresh; expired login → `expired`,
no token; `xai-` key → missing; `creditUsagePercent` beats the on-demand ratio (WEEKLY); ratio
fallback (MONTHLY 25.0); period-only → None; zero cap → None; labels CREDITS for None/3-day spans.

Also related: `test/test_interaction_relay_vectors.py` generates C fixtures from the same vectors to
prove panel (Mbed TLS) ↔ Python byte identity; its negative cases (padded nonce `…=`, 11/13-byte
nonce, short tag, flipped tag, bad length, unknown key, 31-byte challenge, 641-byte view, zero digest,
and the status variants) are good extra Swift negatives.

---

## 15. Known-answer vectors (extracted; full ciphertexts live in the JSON files)

Inputs (both files): device key `000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f`,
mailbox `vp_A1b2C3d4E5f6G7h8`, padding byte `a5`.

```
protocolSaltHex   536dc0d887a19368c80c5e72b5b6406edfb2d655b21712160f95c116aaee3570
requestKeyHex     e230e96ca31cbb25de7f7981620ceb7fed185b0570c68f3395efc68ad9a080db
verdictKeyHex     e1898a3892ac3a1992b62233516d90a3fce754e1c27969ef29c5650b5d77b753
verdictMacKeyHex  00c7722823f400429cd4faa696ecff8aa664c875a9047a77bedb4e4432827580
statusKeyHex      a6789b90017ba65d845ecb8325f51491949bbfa055fd8c31336d436c7780ab46

HKDF info strings:
  vibepulse-ir/v1|vp_A1b2C3d4E5f6G7h8|mac-to-panel-aead
  vibepulse-ir/v1|vp_A1b2C3d4E5f6G7h8|panel-to-mac-aead
  vibepulse-ir/v1|vp_A1b2C3d4E5f6G7h8|panel-verdict-mac
  vibepulse-ir/v1|vp_A1b2C3d4E5f6G7h8|mac-to-panel-status-aead

requestAad  vibepulse-ir/v1|vp_A1b2C3d4E5f6G7h8|ABEiM0RVZneImaq7zN3u_w|request
verdictAad  vibepulse-ir/v1|vp_A1b2C3d4E5f6G7h8|ABEiM0RVZneImaq7zN3u_w|verdict
statusAad   vibepulse-ir/v1|vp_A1b2C3d4E5f6G7h8|status

viewSha256Hex        bfe99f65fead48c1640331c921b30ac82ba4ce8060ccb0188089ee0295de34f3
viewSha256Base64url  v-mfZf6tSMFkAzHJIbMKyCukzoBgzLAYgInuApXeNPM

requestInnerJsonUtf8 (424 bytes → frame prefix 0x01a8):
{"challenge":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8","expiresAt":1787097720,"requestId":"ABEiM0RVZneImaq7zN3u_w","v":1,"view":"eyJwcm92aWRlciI6ImNvZGV4Iiwia2luZCI6InF1ZXN0aW9uIiwicHJvbXB0IjoiSG93IHNob3VsZCBDb2RleCBoYW5kbGUgYXBwcm92YWxzPyIsInRpdGxlIjoiVXNlIHRoZSB0cnVzdGVkIGhvb2siLCJzdWJ0aXRsZSI6IkRlc2t0b3AgKyBDTEksIG9uZSBzZXR1cCIsImNhbl9hcHByb3ZlIjp0cnVlfQ","viewSha256":"v-mfZf6tSMFkAzHJIbMKyCukzoBgzLAYgInuApXeNPM"}
requestFrameSha256Hex  9187bac866b2da743fa4a39e797d4148e6888af802e23b3c0cf087af4ff05408
requestTagHex          489a8677b69f0928034a22e9566e9fa8
request envelope: 2802 bytes, nonce "QEFCQ0RFRkdISUpL", sha256 292d9d7a010bfc32278445226544a3e8f6653801c9c9c5ea8dd714c55318853b

verdictMacMessageHex (126 bytes):
7669626570756c73652d69722d766572646963742d763100001376705f4131623243336434453566364737683800112233445566778899aabbccddeeff202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3fbfe99f65fead48c1640331c921b30ac82ba4ce8060ccb0188089ee0295de34f301
(= "vibepulse-ir-verdict-v1\0" | 0x0013 | mailbox | request-id bytes 00112233…ff | challenge 20…3f | view digest | code 01)
verdict HMACs (key verdictMacKey, same request):
  approve  3b060a291ef9134285b2cde0aee3c6db3002c7b5a6a143a96b1fe84dbe825a5d  (b64url OwYKKR75E0KFss3gruPG2zACx7WmoUOpax_oTb6CWl0)
  deny     ae86c86a73a615bd76cdd9b502c8bda7e7e5f3859974c28e3eb0fd06f39352a0
  terminal 9a6ecfd764e77cf95ea603f2470517fdacff289c800bea1aa648fc0cb2777a5a
  panic    cb21b1ee5a6840bc4375c10965b9bcd00457fe3db2e9cd48991dd084351a94f7
verdict envelopes (nonce 505152…5b "UFFSU1RVVldYWVpb", padding a5) — GCM tag / envelope SHA-256:
  approve  6f129bed1e43d5450029248d5b2a2d2f / e505c918b35f76e0857704391c254e54caff430d2cbc3acc53e62f1d4252eb99
  deny     ed804da34d93c751c0d2db6aa5d42ce7 / b30d094c9131d1c7a44a8860a2ac4be2486c2d2628f78827a5c6535121028d61
  terminal 6ec42e82ca861261f7a2a94587ca788e / e36637fe3618c96068be52d6f9b80c477dfa566fa8ac8f0037a0dac5fbd0e1de
  panic    35a802c0b1feb3008cd6477597546c0b / ef93d7e458b20a8f77f3212bd489709aef7e9552c7e01f90b3ed2d760ec98ab3
verdictInnerJsonUtf8 (approve, 234 bytes → prefix 0x00ea):
{"challenge":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8","hmac":"OwYKKR75E0KFss3gruPG2zACx7WmoUOpax_oTb6CWl0","requestId":"ABEiM0RVZneImaq7zN3u_w","v":1,"verdict":"approve","viewSha256":"v-mfZf6tSMFkAzHJIbMKyCukzoBgzLAYgInuApXeNPM"}
verdictFrameSha256Hex (approve) 0648b121b830828da2e5d955a9f290fa9312bb2663ff2bf3e7be3a16f7838b15
verdict envelope (approve): 1437 bytes

status (agent-status-relay-v1.json):
  statusSha256Hex        3a5ffdbec29fe697833df45697630ce6351a48e960b8ef4e6230ba137569e253 (status bytes 101 B)
  status frame header    56505331 000001a01751507b 6a84f20f 0065 3a5ffdbe…e253
  statusFrameSha256Hex   d3300c1f222102d7994f546748649509085948faf8b9b4e70c7de20503febebd
  statusTagHex           84b2301af13c64dbde9eec051f8e8409
  status envelope: 3826 bytes, nonce "YGFiY2RlZmdoaWpr", sha256 b99bc7ba89d01e9802c8eeb7616c263a7fe83bafc060051a69ea97f0d6802a3e
```
(The extra deny/terminal/panic and envelope-hash values were computed with the repo's Python module
and `cryptography` 50.0.1; they're consistent with the JSON vectors, which this run re-verified.)
The relay tests' Mac token is `b64url(0x11 × 32)` = `ERERERERERERERERERERERERERERERERERERERERERE`.

---

## 16. Tricky semantics & porting pitfalls (checklist)

1. **Ciphertext = ct‖tag**, envelope keys always `ciphertext, nonce, v`; retries re-send identical
   bytes; the Worker 409s on any byte difference.
2. **Canonical JSON checks** on decode: re-serialize and compare bytes. For Swift, parse the inner
   frames with a strict tokenizer (flat objects of ASCII strings and ints) or a
   JSONSerialization + custom canonical re-encoder that distinguishes `1`/`1.0`/`true`.
3. **Verdict list**: the Worker returns at most one item; the host requires exactly one; it
   re-canonicalizes the embedded envelope object before decoding.
4. **All crypto decode failures collapse to one opaque error**; `verify_verdict_mac` returns Bool.
5. **Request id**: 22-char unpadded base64url; AAD uses the *text*, the MAC uses the *16 raw bytes*.
6. **uint32 expiry** (`0 < x ≤ 0xFFFFFFFF`), uint64 publication id (strictly increasing
   `max(last+1, wall_ms)`), expiry `int(wall)+15`.
7. **Status strips `pending`** from the agent-status snapshot before encryption.
8. **DELETE on every remove**, even if the PUT never "succeeded"; delete backlog capped at 8 dropping
   the oldest; queue-full remove replaces a queued event for the same id.
9. **Poll only while something is published**; first poll happens in the same cycle as the first
   successful PUT.
10. **Response trust**: `Cache-Control: no-store` exactly; JSON content-type only on 200 poll; no
    content-type on empty responses; body ≤ 4096.
11. **Publisher**: placeholders never published; stale→fresh tokens bypass the ceiling exactly once;
    failed sends don't touch state; the first pass runs on the worker thread immediately.
12. **GitHub**: `private` must be literally `false`; first poll is a baseline; event TTL 600 s from
    the monotonic time it was seen; `eventId` falls back to `count:<n>`; `stale` also true when the
    *last* poll failed even if data exists.
13. **Discovery**: TXT only `v=1`; filtered IPv4 list sorted as strings; no retry after
    `no-lan-address`.
14. **Timestamps**: codex rollout naive timestamps → local time; grok/cursor `parse_time` naive → UTC;
    numbers > 1e10 are milliseconds; < 1e9 rejected.
15. **`as_percent` rounding**: Python `round(x, 1)`; > 100 clamps to 100 up to 1000, beyond → None.
16. **Cursor**: WAL presence decides `immutable=1`; token may be TEXT or BLOB (UTF-16LE heuristic);
    cookie `WorkosCursorSessionToken=<uid>%3A%3A<jwt>`; the dashboard POST sends `Origin` +
    `Content-Type`; summary `unmapped` still proceeds to the sand call.
17. **Grok**: first *present* `creditUsagePercent` key wins even when invalid; `xai-` keys are not
    bearers; preferred issuer prefix `https://auth.x.ai::`.
18. **Codex month scan** groups by `session_id` and takes the max-volume file per conversation; the
    incremental cache is keyed by path with (mtime,size) + (dev,ino) identity and month key.
19. **Redirects**: refused for all bearer/cookie calls (Codex, Cursor, Grok) and the relay; followed
    only by GitHub (and, incidentally, the Python publisher).
20. Doc/code mismatch: interaction-relay README says status "about every two seconds"; the code is
    5 s (test-pinned). Port the code.
