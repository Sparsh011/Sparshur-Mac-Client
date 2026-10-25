# ADR 0002: isolated Mac relay transport candidate

Date: 2026-10-24. Status: proposed for human review; transport implemented locally.

The existing paired-v2 lab uses local HTTP, one receiving HPKE key, strict high-water
counters and a volatile inbox. The pairing walkthrough explicitly distinguishes it
from the planned internet protocol. Transport reuse must not silently upgrade those
semantics or treat Android's signing key as an encryption key.

Use Apple's URLSessionWebSocketTask, TLS 1.3, system certificate validation, a
dedicated ephemeral session and no redirects/cookies/HTTP credentials. Authenticate
with the existing Keychain Ed25519 key in a new domain that binds the configured
relay URL, relay ID, device, server session and fresh client/server nonces. No new
key or broader Keychain ACL is required. Relay enrollment remains an operator/verified
pairing operation, not an unauthenticated registration endpoint.

Retain the project's protobuf choice without adding a package dependency. Draft 1
uses only a small strict protobuf subset documented in `spec/`; test malformed,
duplicate, overlong, truncated and unknown encodings. This is more restrictive than
normal protobuf decoding and every implementation must enforce those restrictions.
A generated implementation with an approved dependency can replace this small
codec after demonstrating identical validation and vectors.

Build a transport API for opaque prepared envelopes and signed receipts, with an
awaited endpoint-handler boundary. Disable the app's message handler until a
reviewed pairing/E2EE/storage revision exists. Keep a relay-authenticated diagnostic
distinct from messaging readiness. This makes foundational code testable without
inventing trusted peer keys or claiming an unbuilt reverse path.

Initial milestone is live routing. No volatile queue is called durable; FORWARDED
is distinct from a signed processing receipt. Bound frame sizes, pending transport
correlations and retry attempts. Keep secrets and message contents out of logs.

Consequences: this change alone cannot exchange user messages with Android. It
needs a matching Go relay, authorized enrollment, an actual reachable TLS URL,
and the separately reviewed relay endpoint protocol. Full implementation and
acceptance order are in `docs/MAC_MINI_RELAY_PLAN.md`.
