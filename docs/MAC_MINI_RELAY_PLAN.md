# Mac mini relay implementation and security plan

Date: 2026-10-24, Asia/Kolkata. Protocol/crypto design is a learning candidate
requiring human review, not a claim of production security.

## What exists and what this change starts

The [pairing walkthrough](https://bridge-pairing-walkthrough.sappypark256.chatgpt.site/)
was read, including all eleven internet-delivery steps and their technical details.
It describes the intended architecture, not a deployed wire specification.

| Area | Existing baseline | This change | Remaining |
| --- | --- | --- | --- |
| Identity | Mac X25519/Ed25519 protected by Keychain | Narrow relay-auth signing with same key, no export | Reviewed relay trust records and migration |
| Pairing | Local HTTP QR; Android signing key only | Preserve local behavior | Relay QR and authenticated Android HPKE key |
| Networking | Native HTTP receiver on 8787 | Outbound WSS, auth, protobuf, heartbeat/retry, lifecycle, diagnostics | Go/Android interoperability and deployment |
| Encrypted packets | Android → Mac paired-v2 | Opaque prepared-packet send/receive API; app handler fails closed | New bidirectional endpoint protocol |
| Delivery state | Persistent replay state, volatile history | Distinguish socket write and relay forwarding | Atomic inbox/outbox + signed endpoint receipts |
| Hosting | No mini application relay configured here | No host or credential invented | Network/TLS setup and Go service on mini |

```mermaid
sequenceDiagram
    participant A as Android
    participant R as Go relay on Mac mini
    participant M as Mac app
    A->>R: Outbound WSS + fresh Ed25519 challenge-response
    M->>R: Outbound WSS + fresh Ed25519 challenge-response
    A->>A: Reserve counter; encrypt/sign; persist exact outbox bytes
    A->>R: SUBMIT opaque envelope to authorized peer
    R->>M: DELIVER same protected envelope
    R-->>A: FORWARDED (transport only)
    M->>M: Verify pinned peer, context, replay, HPKE and AEAD
    M->>M: Atomically persist inbox + dedup + processing result
    M->>R: New signed endpoint receipt bound to original envelope
    R->>A: DELIVER receipt
    A->>A: Verify pinned Mac signature + exact pending envelope
    A->>A: Persist processed state; complete outbox entry
```

For Mac → Android, roles reverse. Both devices need authenticated receiving HPKE
keys; Ed25519 signing keys do not substitute for X25519 receiving keys. A receipt
and an encrypted clipboard reply are different messages with different meanings.

## 1. Reachable mini and service boundary

Start on a private overlay network with a stable DNS name and valid TLS certificate
if the phone and Mac can both join it. Otherwise choose intentional public ingress
(for example a DNS name, TLS proxy, firewall rule and forwarded port). CGNAT may
prevent home port forwarding; decide the path before promising mobile-data access.
Neither endpoint needs an inbound port. Public/private deployment is an operator
choice still outstanding; no network service or firewall changes are made here.

On mini: Go relay runs as a dedicated unprivileged service user; Caddy or another
reviewed TLS terminator exposes only the WebSocket endpoint, TLS 1.3 minimum.
Bind a plaintext Go backend to loopback or a Unix socket, not the LAN; firewall
blocks direct backend access. Use macOS launchd supervision, bounded restart
backoff, resource limits, file permissions and rotation. A per-user LaunchAgent
requires login; explicitly test reboot/unattended startup and sleep prevention.
Expose metrics/health only on loopback/private admin access. Keep the separate
Codex/Claude development bridge and its SSH credentials out of the application relay.

Pin SSH host identity for administration. Patch macOS/Go/TLS proxy. Keep relay
configuration outside Git and do not give the relay account access to either
client's Keychain, Android backups or development credentials.

Acceptance: both endpoints reach the same WSS URL on different networks; bad
certificate, wrong hostname, HTTP downgrade and redirects fail; direct backend
and admin endpoints are unreachable from unintended networks. Confirm TLS/subprotocol
behavior with the actual URLSession build and proxy, not only injected sockets.

## 2. Freeze transport and implement Go live routing

Review `spec/PROTOCOL.md`, `relay_transport.proto`, authentication vectors and ADR
0002 before implementing a server against this candidate. Go stack follows the
project guide: stdlib first, coder/websocket, later modernc SQLite. Dependency
approval remains required before introducing packages to the client checkout.

Relay owns connection authentication, authorized route lookup, limits and socket
writes. It holds enrolled **public** keys only. No decryption helper, pairing-secret
storage, plaintext debug route or arbitrary device-key replacement API.

Bootstrap initial device public-key enrollment through a separate operator-authorized
mechanism. Never allow the first HELLO with an ID to claim that identity. Complete
verified pairing later authorizes exactly the intended recipient route. Connection
authentication proves key possession; it does not by itself grant group membership.
For duplicate connections, newest successfully authenticated session wins; fence
the old session before routing and never let its close callback remove the new one.
Rate-limit failed auth by connection/source, pending challenges globally, frames,
bytes and recipient queue. Bound unauthenticated connection lifetime and enforce
one-use server challenges bound to their exact sockets.

Initial live behavior: FORWARDED only after writing the intended recipient socket;
UNAVAILABLE if offline/write fails. Never claim durable enqueue in this milestone.
Per-recipient ordered writers apply bounded backpressure; slow clients cannot
block all recipients or allocate unbounded memory. Endpoint E2EE must withstand
a relay that violates ordering, routing and acknowledgement rules anyway.

Acceptance: public vector verification in Go/Kotlin/Swift; wrong signatures,
captured auth from another socket, challenge reuse, unknown enrollment and
cross-pair routing rejected; old-session replacement race; offline recipient;
oversized/malformed frames; quota exhaustion and slow consumers. Use disposable
identities and synthetic payloads.

## 3. Relay-compatible pairing and trust migration

Define a new version. QR contains external relay URL, expected relay ID, public
Mac signing/HPKE keys, fresh invitation route/ID, expiry and 32-byte one-time QR
secret. Secret stays solely in protected pending client state and the trusted
scan. Send proofs, never the secret, through the relay. Treat QR/manual bundles
as credentials; five-minute expiry, one use, cancellation and no logs/screenshots.

Pairing transcript must bind protocol/suite, relay context, invitation/expiry,
pairing epoch, both device IDs, **both devices' signing and receiving HPKE public
keys**, and explicit roles. Use purpose-separated HMAC proofs and signatures;
HMAC verifies with vetted constant-time APIs. Specify exact canonical bytes and
negative/public vectors before implementation. The relay's invitation route is
not an authenticator, and a directory listing cannot install or rotate peer keys.
Both endpoints confirm the transcript, persist trust, and retain bounded retry
confirmation so losing the final acknowledgement does not create half-pairing.

Specify pairing crash recovery: protected pending handshake and retryable final
confirmation, or explicit fresh invitation. Reject silent trust resets. Migrate
legacy local pairing separately; it cannot synthesize Android's missing HPKE key.
Retain existing identity keys and original local lab behavior while the user
performs the new authenticated pairing. Review whether key reuse between local
and relay domains remains acceptable; otherwise rotate by an explicit migration.

Acceptance: scanned substitution, route takeover, changed relay/suite/keys/roles,
expired/reused secret, final-ack loss, process death, cancellation and re-pairing
vectors. Android HPKE key is pinned through verified transcript, never relay data.

## 4. Bidirectional endpoint E2EE

Use existing vetted CryptoKit/Android primitives: fresh random 32-byte content key
per new message, ChaCha20-Poly1305 for payload, HPKE base mode X25519/HKDF-SHA256/
ChaCha20-Poly1305 to wrap that key for each pinned recipient, Ed25519 to authenticate
the complete envelope. HPKE base mode alone does not authenticate the sender.
No new primitives, silent fallback suite or use of signing keys as agreement keys.

Version-specific AAD must bind purpose/direction, suite/version, pairing epoch,
sender, recipient, operation type, durable counter, UUIDv7 message ID, authenticated
request/reply correlation, and expiry. Define exact signed bytes, HPKE `info`,
payload encoding, sizes and receipt bytes with public cross-platform vectors.
Use distinct `info`/signature domains for pair, auth, key wrap, envelope and receipt.
Nonce proposal for review: random 96-bit payload nonce with a freshly generated
content key used for exactly one encryption; never re-encrypt on retry. HPKE library
owns its encapsulation and nonce sequence; never reuse a sender context for a
different envelope. State the probabilistic RNG assumption and per-key usage.

Before encrypting reserve counter/ID transactionally. After encryption persist
the exact signed envelope before any send. Crash gaps may skip counters; they
must never rewind. No counter/key reset after storage error or expired outbox.

Receive order: strict parse/limits → locally authorized pairing/recipient/type →
pinned signature verification → replay/dedup check → HPKE unwrap → AEAD open →
plaintext validation → atomic durable inbox/dedup/result commit → local disclosure
and receipt transmission. Wrong signature/tag/storage failure must create no
success, plaintext display or replay advancement. Do not put full preview text
in receipt or routing metadata. E2EE does not hide IPs, route IDs, sizes or timing.

This construction has **no ratchet/forward secrecy**: later compromise of a
receiving private key can expose recorded envelopes. Software keys protected at
rest by Keychain/Keystore are not claimed permanently hardware-confined. Device
compromise remains outside what transport encryption can repair.

Acceptance: shared Kotlin ↔ Swift encrypt/decrypt vectors both directions;
tamper each bound field; wrong recipient/pair/epoch/type; corrupted HPKE/tag;
signature substitution; replay; ID collision with changed content; persistence
failure before disclosure; keys never sent to relay; no secret-bearing logs.

## 5. Durable processing, receipts and reorder policy

Add a transactional client store. Decide SQLite access/encryption in an ADR
before adding GRDB/SQLCipher or another dependency. Keychain stores wrapping keys
and identity, not unbounded history. Encrypt sensitive history and outbox metadata
at rest; WAL, journals, backups, crash dumps and file permissions are part of the
storage design. Merely encrypting the text column leaves metadata visible.

Commit inbox content + replay metadata + processing result + prepared receipt
atomically in one database. Keep receive-state consistency across the existing
Keychain replay state and a future DB: migrate authority in a reviewed, crash-safe
step rather than pretending two stores share a transaction. Bound receipt/dedup
retention by a documented message TTL/retry window. Expired IDs must not later
be accepted as new, nor must quota eviction permit old counter reuse.

Replace the local strict high-water policy deliberately: a bounded replay window
per sender/pairing epoch permits limited reordering, deduplicates IDs and counters,
and rejects outside-window/expired messages. Define a maximum outstanding span
and sender behavior when exceeded; never silently drop an older queued message
and call delivery successful. Pin the policy and boundary vectors across clients.

Signed endpoint receipt binds original message ID, pairing/roles, counter, envelope
digest and precisely stated result (`persisted`, for example). Sender verifies
against its exact pending envelope and pinned recipient key, then transactionally
completes its outbox. Exact retries return a recorded result without redoing effects;
same ID/different content fails. A sender-side timeout means outcome unknown.

Clipboard writes and SMS sends are side effects outside a database transaction.
Specify explicit user actions, operation IDs, restart/uncertainty reconciliation
and late-retry policy; do not claim exactly-once external effects. A persisted
receipt is not a human-read or clipboard-copied receipt.

Acceptance: kill/restart at every commit boundary, lose receipt, resend exact bytes,
change reused ID, counters near replay-window limits, reorder/duplicate, disk-full,
Keychain unavailable, database rollback and reinstall/missing keys. No false
completion and no duplicate inbox row.

## 6. Offline queue on mini

After live E2EE and durable client processing work, add SQLite ciphertext queues
with per-device/total byte quotas, TTL, transactional ID+digest dedup and explicit
durably-queued response. The transport needs a reviewed new response/schema;
do not reinterpret FORWARDED. Durability means commit completed, including the
chosen SQLite WAL/synchronous configuration and restart tests, before replying.
Sender keeps its outbox until an authenticated endpoint receipt or explicit
expiry/failure, even after durable relay acceptance.

Recipient processing receipt (or separately specified authenticated queue ack)
must identify the exact delivery/digest/recipient before deletion. Store-and-forward
includes receipts too, otherwise an offline original sender never learns outcome.
Specify lease/redelivery, per-peer fairness, relay restart, expired queued messages,
clock changes and revocation cleanup. Ciphertext backups still expose metadata;
bound retention and protect permissions. A malicious relay can lose or withhold
items; cryptography detects alteration, not omission or guaranteed availability.

Acceptance: durable enqueue then forced relay restart; sender disconnect before
ack; receiver disconnect after processing before ack; lost receipts; duplicate
submissions; TTL expiry offline; quotas; session replacement and queue drain races.

## 7. Clipboard operations and Android reliability

Keep first payload synthetic/user-entered text. Add Mac → Android only after new
peer HPKE enrollment and receiver verification. For fetch history, Android issues
encrypted, bounded, correlated list/item requests. Mac keeps its own history;
NSPasteboard alone is not one. Previews/cursors are sensitive and E2EE too. Paginate
and limit page size, total bytes, outstanding requests and reply lifetime. Return
only authorized requested items. Copy on explicit Android action; previews never
overwrite clipboard. Respect sensitive-clip flags and Mac pasteboard access controls.

Begin Android in the foreground. Then implement foreground service/WorkManager
and high-priority FCM data wake for Mac → Android with appropriate platform policy.
Push is a wake hint containing no content or keys; the authenticated app reconnects
and fetches ciphertext. Keep FCM credentials solely on mini with minimal scope.
Test actual owner phone under Doze, network handover, OEM kills and permission
denial. No claim that a WebSocket survives app death or FCM guarantees delivery.
SMS and files remain later phases with existing project gates.

## 8. Membership, revocation and operations

Before the Phase 1 multi-device acceptance, define signed membership-chain and
revocation statements, epoch/order/conflict rules and anti-rollback persistence.
Clients verify their locally trusted chain. Relay's authorized route table is
enforcement/advisory metadata, never a substitute for that trust. Revocation
rejects new envelopes from removed devices, closes sockets, removes queued routes
and rotates affected group/pairing authorization. It cannot retract plaintext or
content keys a former member already received.

Bound and label observability: event names, counts, queue age, coarse error codes;
never raw frames, bodies, keys, QR bundles, auth signatures/tokens or previews.
Avoid message content in errors, analytics and crash reports. Configure TLS proxy
and relay logs as carefully as app logs. Operational runbook includes clock/TLS
expiry, service restart, quota exhaustion, stolen device, explicit re-pairing and
loss of keys. Deleted private keys are not recoverable through a relay directory.

## Ordered handover and release proof

1. Review transport/auth candidate and vectors; choose mini reachability and URL.
2. Implement matching Go relay + operator enrollment, enforce limits; disposable
   clients pass fresh-session/reconnect/live-forwarding tests.
3. Review and implement relay pairing with Android HPKE enrollment and vectors.
4. Review E2EE envelope, receipts, replay and transactional client storage together;
   implement both endpoint directions and crash tests; activate Mac handler.
5. Demonstrate a synthetic text roundtrip phone mobile-data ↔ Mac Wi-Fi, through
   the mini, with verified receipts and ciphertext-only relay data/logs.
6. Add durable relay queue/expiry and Android wake, then clipboard request/reply.
7. Add signed multi-device membership/revocation and run the complete Phase 1
   acceptance. Owner confirms before moving into later project phases.

Current verification is transport/unit evidence only. An injected socket fixture
does not prove TLS, proxy behavior, internet reachability, Android interop or
durable E2EE delivery. Do not enable a real encrypted-message UI on those results.

Apple references used for implementation:
[URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask),
[maximumMessageSize](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask/maximummessagesize),
[redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)).
