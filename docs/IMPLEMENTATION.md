# Native receiver implementation

The primary path is SwiftUI → AppModel → ReceiverCoordinator → EndpointService →
CryptoKit/Keychain. Network.framework supplies TCP bytes to a bounded HTTP parser.
There is no Python receiver or helper subprocess in the app.

## Read in this order

1. `Sparshur/SparshurApp.swift` owns one `@State` AppModel shared by Window,
   Settings and MenuBarExtra. This is state hoisting above Compose destinations.
   `Views/StatusMenu.swift` wires close/reopen, sleep/wake and orderly quit.
2. `Sparshur/App/AppModel.swift` is `@MainActor @Observable`: view reads subscribe
   to changes, while the main actor serializes UI mutations. Navigation history
   does not own the receiver. The retained event task survives destination changes.
3. `Sparshur/Services/ReceiverCoordinator.swift` owns one server and protocol actor.
   `await` permits another task to run while waiting; actors protect their isolated
   state but can reenter at an await. EndpointService has no await inside a protocol
   transaction, so verify → deduplicate → persist → disclose stays serialized.
4. `Sparshur/Networking/LocalHTTPServer.swift` handles connections on a serial queue.
   An IP identifies an interface; port 8787 selects this receiver. TCP carries a
   stream, not messages: `HTTPRequestParser.swift` finds HTTP boundaries even when
   headers/body arrive in fragments. One request gets one response and closure.
5. `Sparshur/Core/EndpointService.swift` separates typed local observations from
   wire receipts. Verified plaintext crosses only to the local model. Comparison
   samples are unverified and cannot enter the paired inbox.
6. `Sparshur/Core/PairedProtocol.swift` is the extracted, shared reference core.
   Follow `newPair`, `pair`, then `receive`. The sibling CLI compiles these same
   sources directly; its `main.swift` is an adapter. Canonical bytes and public
   vectors remain defined by `SparshurAndroid/spec/PAIRED_V2.md`.
7. `Tests/EndpointServiceTests.swift`, `Tests/NativeProtocolTests.swift` and
   `Tests/ParserTests.swift` make the transaction and framing guarantees concrete.
   Then read `tools/test_android_native.py` for Android → signed native app proof.

Exercise: select an interface in Pair phone, navigate to Learn, then Back. Explain
why selection survives. Pause the receiver: explain why the QR is cleared even
though the window and app model still exist. Compare this with a ViewModel scoped
to an Activity versus state remembered inside one composable.

## Pairing and encryption

The Mac has software X25519 agreement and Ed25519 signing keys protected at rest
by Keychain. A QR carries public keys, a public pairing ID and a separate temporary
secret. Android confirms and sends an HMAC proof plus its signature, not the
secret. Mac verifies both, persists Android's public key and returns its proof and
signature. Android verifies using the scanned Mac public key and pins both keys.

HMAC authenticates with a shared secret; a signature uses a private signing key
and public verification key. Binding both public keys into the proof makes a key
substitution fail. Someone stealing a usable QR secret is a different threat:
they possess the pairing authenticator. Expiry and one-use handling narrow that
window. Replay checks remain necessary after authentication; a valid signature
alone does not mean a message is new.

For paired messages, CryptoKit HPKE unwraps a fresh content key; ChaChaPoly verifies
and decrypts the payload. The sender signature binds the envelope. Replay metadata
is saved before disclosure or successful acknowledgement. Exact duplicates receive
authenticated receipts with no redisplay. Persistence failures stop receiving and
require recovery of existing identity access; they never succeed silently.

Android's original AES key stays in Keystore. Its paired Ed25519 seed is software
material encrypted at rest by a separate Keystore AES key. Mac keys are software
material protected by Keychain, not keys permanently confined to secure hardware.
The construction has no ratchet or forward secrecy.

## Bounds and lifetime

The listener accepts private/loopback IPv4 peers, at most eight live connections,
with a five-second request/processing deadline and bounded response lifetime.
Headers are limited to 8 KiB and bodies to 32 KiB. The parser rejects transfer
encoding, duplicate headers, unexpected Origin, malformed framing and observed
trailing/pipelined bytes. It never processes a second request on a connection;
bytes arriving after dispatch cannot retroactively invalidate the first request.
StrictJSON rejects decoded duplicate fields, floats, bad UTF-8 and excess nesting
before schema/crypto validation. No LAN routes generate QRs or return history.

App history retains the newest 40 genuine observations in memory. The core keeps
128 replay records persistently. Legacy comparison deduplication is session-only,
bounded to 1,000 IDs. QR material expires after five minutes, and is discarded on
replacement, success, cancellation, interface removal, pause, sleep or quit.

A process-lifetime loopback socket bound to port 8786 guards the shared identity.
It does not listen or expose a management endpoint. Native and reference writers
both acquire it before loading state. Pause retains it; process exit releases it.

## Identity access

Native loading and saving use the original Keychain service/account and refuse
insertion. No reset, export, new identity or broadened ACL is used for migration.
Background reads suppress interaction, including the legacy Keychain API needed
for this existing item. Only the explicit authorize action allows a system prompt.
The deprecated interaction API is retained for legacy compatibility; LAContext
alone did not prevent this legacy item from blocking in securityd.

Read-only readiness returns public facts and a temporary loopback probe. It does
not prove write permission, LAN reachability or migration. See VERIFICATION.md
for the evidence actually collected and the checks still requiring the owner.
