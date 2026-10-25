# Relay transport verification

2026-10-24. Local implementation candidate; no mini deployment or real Android
relay interoperability is claimed.

- Full Swift suite: **40 tests passed**, including **13 relay tests**. Tests use
  public/disposable keys and in-memory stores, never the login Keychain.
- Full Xcode Debug macOS app: **BUILD SUCCEEDED** with local ad-hoc signing.
- Strict swift-format lint across app, tests and existing preview tool: passed.
- The original local paired-v2 frozen Android decryption/receipt test and QR/core
  tests still pass. Core also compiles independently, preserving the reference
  CLI's no-networking dependency boundary.
- Authentication signature vector is verified, not compared to a newly generated
  signature: compatible Ed25519 implementations can randomize their signing
  procedure while still producing valid standard signatures.
- Independent Python stdlib protobuf fixtures cover all nine frame kinds.
  Truncation tests, duplicate/unknown fields, varint overflow/overlong encodings,
  strict recipient checks and bounded deterministic parser fuzzing are included.
- Injected socket tests verify real CryptoKit challenge signatures, out-of-order
  authentication rejection, nonce/relay/expiry binding, fresh nonce on reconnect,
  byte-preserving retries, per-submission forwarding correlation, mismatched
  digests, pending-write bounds, stop fencing, timeout closure, and upgrade-required
  behavior without a fabricated endpoint receipt.

The normal restricted execution sandbox blocks local network and Core Image/macOS
services required by the pre-existing suite; the full suite was rerun successfully
outside that restriction. The Xcode macro/asset tools likewise required a normal
macOS build context. No app launch or real identity authorization was performed.

Not yet verified: live TLS certificate/redirect/subprotocol behavior through the
chosen proxy, mini reachability from mobile data, server challenge consumption,
Go/Kotlin interoperability, durable queues, pairing migration, Android HPKE
receiving keys, bidirectional endpoint verification or crash-safe persistence.
The app's relay delivery handler intentionally fails closed until those endpoint
requirements are implemented. See `MAC_MINI_RELAY_PLAN.md` for acceptance order.
