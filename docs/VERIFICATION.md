# Verification evidence — 21 October 2026

## Passed

- Xcode Debug build, local signing, macOS 14 deployment target, sandbox and incoming
  network entitlement. No outgoing-network entitlement or remote dependency.
- 27 Swift tests: preserved model/navigation/platform/shortcut coverage, public
  Android vectors, pairing expiry/replacement, signatures/HPKE/payload tampering,
  replay/restart, failed persistence before disclosure, and genuine observation vs
  receipt separation. Tests use public or random memory identities, never Keychain.
- HTTP parser split at every boundary and byte by byte; malformed framing, duplicate
  headers/decoded JSON keys, limits, UTF-8/nesting and 400 bounded fuzz inputs.
- Actual native listener lifecycle with injected memory identity: repeated model
  startup/navigation, QR preservation across navigation, pause and sleep/wake.
- Signed sandboxed native app with Android emulator: ten Android instrumentation
  tests passed. Actual native pairing/decryption, signed receipts, tamper rejection,
  duplicate suppression, QR clearing and pause/resume. Raw socket tests confirmed
  five-second timeout and eight-connection limit. Python only orchestrated this run.
- The first emulator run used a temporary memory identity. After owner approval
  in macOS, the final signed native app passed all ten Android instrumentation
  tests using the existing Keychain identity, including actual state writes.
- A fresh native app process restored the same Mac public fingerprint and saved
  counter. An additional Android test verified its signed duplicate receipt; the
  fresh process recorded one duplicate and zero new paired inbox rows. No Python
  receiver or reference helper ran in this proof. The harness closed both native
  processes and cleaned its Android test cache files.
- Reference CLI self-tests and the existing eleven Python receiver tests passed.
- Own-view offscreen renders at normal/compact sizes preserve the dark pink design;
  they contain no fabricated live inbox or usable pairing secrets.

## Still to establish

The protected identity migration gate passed after the owner approved macOS
Keychain access. The same existing item was read and updated, then restored in a
fresh native process. No identity replacement, key export or programmatic ACL
change was used. The integration run intentionally paired the emulator, replacing
the saved phone/pairing epoch. Re-pair the physical phone before using it.

Interactive toolbar shortcuts, focus/VoiceOver, close/reopen through MenuBarExtra,
and real desktop sleep/wake still require desktop access. Model/isolated AppKit
checks do not substitute for them. Physical-phone camera scanning, hotspot/firewall
reachability, denied network access and macOS 14 runtime remain separate checks.

## Reproduce

See README.md for build/test commands. Build Android debug + androidTest APKs using
Android Studio's JBR. With an emulator booted and other recipients quit:

```sh
python3 tools/test_android_native.py --memory-only
# Real identity: pairs emulator, changes saved phone/epoch, then tests native restart.
python3 tools/test_android_native.py --authorize-keychain
```

The real run must preserve the public Mac fingerprint and restore the exact saved
counter in a fresh native process. Android verifies the signed duplicate receipt;
the new process must show zero new paired rows and one duplicate. The harness
cleans its Android cache files and closes its native process. Do not run competing
reference/native writers. The sibling default `tools/test_paired_android.py`
selects this harness; `--reference` explicitly selects the old receiver proof.

Final follow-up: Debug and Release Xcode builds, strict swift-format lint,
Android JVM/lint checks and pinned ktlint passed. Release has no integration
controller symbol. Signed Debug entitlements confirm sandbox + incoming network,
with a 14.0 minimum. An initial noninteractive attempt returned OSStatus -25293
and an initial authorization attempt timed out. The owner then approved access;
the subsequent full real-item delivery/restart run passed as recorded above.
Desktop UI automation timed out; no interactive UI result is claimed.

The pinned code-review-graph index was refreshed locally for both checkouts.
Its useful coverage here is Python/Kotlin; this installed parser did not index
the Swift implementation. Native source review/tests remain necessary.
