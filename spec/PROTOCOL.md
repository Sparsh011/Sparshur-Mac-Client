# Bridge relay transport draft 1

The Go relay implements this transport, and the Mac and Android clients use it
for relay connections. The contract remains a draft pending human protocol and
crypto review. Both app handlers reject deliveries until the end-to-end upgrade
is available. Local paired-v2 HTTP lessons use their own specification.

The Mac checkout is the source of truth for this contract, the
`relay_transport.proto` schema and the frozen JSON fixtures in `vectors/`.

## Connection and limits

Both endpoints initiate outbound WebSockets to the configured
`wss://<host>[:port]/v1/relay`. Require TLS 1.3, normal platform certificate/hostname
verification, no redirects, userinfo, query, fragments, cookies or HTTP credentials.
Configure the relay URL and stable relay ID independently of incoming frames.
No trust-on-first-use peer key enrollment and no TLS bypass for development.
WebSocket subprotocol is exactly `bridge.relay.v1`; reject missing/different selection.

One binary message contains one `Frame` from `relay_transport.proto`. Maximum
reassembled message is 65,536 bytes, including all continuation frames. Reject
text messages. Integer encodings are minimal unsigned varints; only wire types
0 and 2 are supported. Reject unknown/duplicate fields, zero/default values,
empty bytes, invalid UTF-8, wrong wire types, overflow, truncated lengths, fields
outside the kind's exact schema, unsupported versions and nested unknown fields.
Field ordering is arbitrary on receive. Encoders output ascending field numbers.
Every identifier is a canonical lowercase UUID. New E2EE message IDs must be
UUIDv7; the transport accepts canonical UUIDs without imposing ID generation.

| Kind | Exact populated fields (version and kind always required) |
| --- | --- |
| HELLO | device_id, client_nonce |
| CHALLENGE | client_nonce, relay_id, session_id, challenge, expires_at |
| AUTHENTICATE | device_id, client_nonce, relay_id, session_id, challenge, expires_at, signature |
| READY | device_id, session_id |
| SUBMIT / DELIVER | packet |
| FORWARDED / UNAVAILABLE | message_id, digest |
| AUTH_REJECTED | none |

Strings/byte lengths: device/session/message/pairing IDs are 36 ASCII bytes;
relay ID 1–128 visible ASCII bytes (33–126) excluding `|`; client nonce and challenge
exactly 32 bytes; signature 64 bytes; digest 32 bytes. URL maximum 2,048 UTF-8
bytes and excludes `|`. A packet's protected body is 1–32,768 bytes. No private key, QR secret,
unwrapped content key, plaintext, or plaintext preview is a frame field.

Independent Python protobuf byte fixtures for all nine frame kinds are in
`vectors/relay-wire.json`; regenerate with `tools/generate_relay_wire_vectors.py`.
Their protected packet bytes are symbolic, not an E2EE vector. Swift validates
these frozen bytes separately from its own encode/decode roundtrip tests.

The strict protobuf subset is intentional. Standard Go/Kotlin protobuf decoders
must add the same validation before accepting frames (ordinary protobuf merge
semantics for duplicate fields are insufficient). It is not a generic protobuf
implementation. A future incompatible wire revision gets a new subprotocol.

## Challenge-response

1. Client sends HELLO with saved device ID and fresh CSPRNG 32-byte client nonce.
2. Relay looks up an **already authorized** enrolled Ed25519 key. For an
   unknown device, it sends AUTH_REJECTED and closes with `4401`. For an
   enrolled device, it creates a fresh 32-byte challenge and UUIDv4 session ID
   on this socket.
3. Relay sends CHALLENGE echoing the client nonce and configured relay ID.
   The relay sets `expires_at` to its current Unix second plus 20. On the client
   it must be strictly in the future and
   at most 30 seconds ahead of the client's current time. Clock skew fails closed.
4. Client signs the following exact UTF-8 bytes, no newline:

```text
bridge-relay-v1/auth|<configured_absolute_wss_url>|<relay_id>|<device_id>|<session_id>|<client_nonce_base64>|<challenge_base64>|<expires_at_decimal>
```

Base64 is standard, padded, unwrapped. UUIDs and URL must not be normalized after
configuration; both sides use the same configured external URL, including port.
Session ID, both nonces, device, purpose, URL and relay identity are bound. A
signature from paired-v2 or another relay/session cannot authenticate here.

5. Client sends AUTHENTICATE. Relay verifies against its enrolled key and the
   **exact outstanding challenge on that socket**, checking expiry again.
   Consume the challenge atomically before READY. No replay on this or another
   socket, repeated signing challenges, arbitrary signing requests, or fresh key
   registration through HELLO/AUTHENTICATE. Never enroll a key based on device ID.
6. Relay binds the authenticated device to this socket and returns matching READY.
   Authentication deadline is 10 seconds for the whole exchange. The newest
   authenticated session for a device replaces the previous one, which loses
   its routing access before the relay closes it with `4409`. Receiving READY
   before CHALLENGE, another device/session, or unexpected frames terminates it.

Public authentication test vector: `vectors/relay-auth.json`. Its fixed seed and
nonces are **test only**. Current Keychain identity signs in the app; no seed is
exported or new identity created. The vector's timestamp is fixed for reproducibility;
testing byte construction does not bypass live expiry checks.

The relay's TLS certificate authenticates the server; no extra relay signing key
is added in this draft. A compromised relay can inspect metadata and disrupt
delivery. Client peer authentication must remain independent of this connection.

## Live routing

Only after READY can a client send SUBMIT. Relay validates that packet.sender_id
equals the socket identity, recipient differs from sender, and this pairing route
is currently authorized. The relay closes spoofed-sender, self-send and
unauthorized-route submissions with `1008`.

`Packet` has exactly seven populated fields. `protocol` is exactly
`bridge-relay-e2ee-v1`; kind 1 is an encrypted envelope and kind 2 a signed endpoint
receipt. All body bytes are opaque to the transport. The transport cannot prove
that arbitrary bytes are encrypted: only an endpoint implementation can produce
and verify these bodies. Local paired-v2 JSON must never be wrapped here as if
it implemented the new endpoint protocol. Receipts use their own outer message
IDs and bind the original envelope ID/digest inside the signed receipt.

`digest` = SHA-256 of the ascending-field protobuf encoding of the entire Packet,
including routing context, kind and exact protected bytes. This correlates
transport responses with outstanding submissions; it is **not an endpoint signature**.

Relay forwards a DELIVER to the recipient's current authenticated socket. On a
completed recipient socket write, return FORWARDED to sender. If no eligible
socket exists, its queue is full or writing fails, return UNAVAILABLE. Both echo exact ID and digest.
Unknown or unmatched acknowledgements close the client session. There is no durable
queue in draft 1; neither FORWARDED nor socket-write success means endpoint
processing, storage, decryption, human reading or clipboard change.

At most one client send write can be in flight and 32 transport outcomes pending
(including individual retry submissions of the same envelope).
If full, reject new sends rather than silently evict. There is no implicit local
queue or automatic message resubmission. Caller retains the same prepared bytes;
an interrupted write has an **unknown** outcome. On reconnect, volatile transport
correlations clear; a future durable outbox must resubmit exact stored bytes.
An acknowledgement that arrives twice after its correlation is cleared is a
protocol violation in this live draft. Relay must emit one per SUBMIT on that
connection; endpoint message/receipt retries are separate messages/submissions.

Receiver serially awaits a supplied endpoint handler before receiving the next
application frame. It checks recipient ID first; handler must verify sender,
pairing, signature, replay and payload before any local effect or receipt. No
automatic success response, key installation or UI inbox insertion happens here.
The app's current handler rejects deliveries pending the endpoint upgrade.

## Lifecycle

| Close code | Meaning |
| --- | --- |
| 1001 | Relay draining |
| 1002 | Malformed binary frame or wrong frame for the current state |
| 1003 | Text message received |
| 1008 | Submission violates routing policy |
| 1009 | WebSocket message exceeds the frame limit |
| 4001 | Slow consumer exceeded its relay send queue |
| 4401 | Authentication rejected |
| 4403 | Enrollment removed or signing key replaced |
| 4409 | Newer authenticated connection replaced this session |

The apps stop automatic retries on `4401`, `4403` and `4409`. On shutdown,
the relay rejects upgrades with HTTP 503, closes sessions with `1001` and
force-closes sockets at the shutdown deadline.

Ping every 25 seconds, pong deadline 10 seconds. On timeout close the socket to
unblock pending I/O. Reconnect with fresh client nonce and full authentication,
using exponential backoff with 50–100% jitter, 1s initial ceiling and platform-specific caps. The Mac retries up to eight
times with a 60s cap. Android retries up to six times with a 30s cap.
Protocol/authentication/certificate failures halt automatic retry. User resume
starts a new bounded attempt; network changes never reset trust or pairing.

Pause, sleep and quit cancel retry/heartbeat/receive work and close the session.
Generation and connection revisions fence stale asynchronous completions. Wake
resumes only if receiving was active before sleep. Closing the main window keeps
the existing app-owned receiver/coordinator alive. Relay status is separate from
local HTTP readiness and from encrypted-message capability.

## Endpoint protocol still to specify

No relay-compatible encryption, pairing, deduplication or membership wire bytes
are approved by this transport draft. The implementation plan lists the required
reviewed E2EE revision and public vectors before activating its handler. This
explicit boundary preserves the existing local protocol and avoids claiming
forward secrecy, durable delivery or reverse encryption that does not exist.
