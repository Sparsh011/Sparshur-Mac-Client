# ADR 0001: Native receiver with one shared protocol core

Status: implemented; protected-item integration passed. Physical and interactive
checks remain tracked separately in VERIFICATION.md.

Use a BSD TCP listener with DispatchIO and a deliberately narrow, bounded HTTP/1.1
parser. Maintain the Android debug wire contract. On the development Mac, the
Network.framework listener timed out on the active tunnel address with both
wildcard and explicit binds. The BSD listener accepts that address on the same port.
Reject ambiguous framing before dispatch; close every connection after one request.

Pairing over a private VPN uses the existing paired-v2 QR and HTTP routes. Offer
IPv4 addresses from `100.64.0.0/10` on active macOS tunnel interfaces. For peers
from that range, require the connection to target one of those addresses before
dispatch. The `/message` comparison route remains available to LAN and loopback
peers. The direct receiver and the outbound hosted relay have separate settings.

Extract the tested Swift reference crypto/Keychain implementation into the Mac
source tree. The native app and sibling CLI compile those same files. Keep the CLI
as an explicit reference adapter, not a dependency of the native runtime. A local
Swift Package target exercises these same sources with memory-only public fixtures.

Keep mutable protocol state inside EndpointService. Transactions do not suspend
between verification and persistence. Separate local observations and receipts to
prevent local decrypted output from accidentally entering HTTP responses.

Acquire a process-lifetime exclusive loopback bind on 8786 before accessing the
shared Keychain item. This coordinates native/reference writers even while paused,
without a lock file, exported state or management listener. Existing identity and
counters must survive; absent/inaccessible state is an error, never an insert.

Use noninteractive background access, and allow macOS's own authorization only on
an explicit user action. Locally signed rebuilt binaries may lose prior legacy ACL
approval. Do not bypass this by changing access lists or replacing the identity.

The main window and MenuBarExtra share one app model. Window closure does not own
receiver lifetime. Pause/sleep clear temporary pairing material and close transport;
quit also clears local history. DEBUG test control is inherited-pipe-only and is
compiled out of Release. No third-party dependency or network management route.
