# Relay transport verification

The Mac, Android and Go relay use the shared [transport contract](../spec/PROTOCOL.md).
The authentication and nine protobuf frame fixtures are frozen under
[`spec/vectors`](../spec/vectors). Each project checks the same byte sequences.
Fixture signing keys are public test material.

The Mac relay tests verify CryptoKit signatures over the shared auth transcript,
all nine wire fixtures, strict parsing, challenge ordering and expiry,
reconnects with fresh nonces, bounded pending sends and acknowledgement
correlation. The relay tests also check that the loaded identity exposes its
public signing key and that close codes 4401, 4403 and 4409 block retries.
Incoming deliveries require the end-to-end upgrade.

Run Swift tests, the Xcode Debug build and swift-format using the commands in
the [README](../README.md). Swift tests covering the local listener require
loopback access. Keychain-free unit fixtures use in-memory stores.

For the live test, install the Go service behind a trusted TLS 1.3 terminator
on the tailnet. Enroll the public data from Settings → Diagnostics and from
the Android debug relay screen. Configure the exact same external URL and
relay ID on all three. With the phone on mobile data, check both apps report
authentication. Check revocation and replacement in a controlled enrollment.
The live test still needs to be run on the deployed service.

Encrypted-envelope processing, relay pairing, Android receiving keys and
durable queues remain tracked in the [implementation plan](MAC_MINI_RELAY_PLAN.md).
