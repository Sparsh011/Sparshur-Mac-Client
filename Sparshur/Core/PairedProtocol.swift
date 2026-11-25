import CoreGraphics
import CoreImage
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

// Shared paired-v2 recipient. Used directly by the native app and the reference CLI.
typealias Object = [String: Any]
enum Rejected: Error {
  case invalid, state, keychain, missingIdentity, identityInUse
  case keychainStatus(OSStatus)
}
let suiteName = "X25519-SHA256-CHACHA20POLY1305"
func text(_ o: Object, _ k: String) throws -> String {
  guard let s = o[k] as? String, s.utf8.count <= 12000 else { throw Rejected.invalid }
  return s
}
func number(_ o: Object, _ k: String) throws -> Int {
  guard let n = o[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
    n.doubleValue == Double(n.intValue), n.doubleValue.isFinite
  else { throw Rejected.invalid }
  return n.intValue
}
func uuid(_ s: String) throws {
  guard let value = UUID(uuidString: s), value.uuidString.lowercased() == s else {
    throw Rejected.invalid
  }
}
func fields(_ o: Object, _ names: String) throws {
  guard Set(o.keys) == Set(names.split(separator: " ").map(String.init)) else {
    throw Rejected.invalid
  }
}
func bytes(_ s: String, _ size: ClosedRange<Int>) throws -> Data {
  guard let d = Data(base64Encoded: s), size.contains(d.count), d.base64EncodedString() == s else {
    throw Rejected.invalid
  }
  return d
}
func utf8(_ s: String) -> Data { Data(s.utf8) }
func json(_ o: Object) throws -> Data {
  try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
}
func object(_ d: Data) throws -> Object {
  guard let result = try JSONSerialization.jsonObject(with: d) as? Object else {
    throw Rejected.invalid
  }
  return result
}
func random(_ count: Int) throws -> Data {
  var data = Data(count: count)
  let status = data.withUnsafeMutableBytes {
    SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
  }
  guard status == errSecSuccess else { throw Rejected.state }
  return data
}
func fingerprint(_ hpke: Data, _ signing: Data) -> String {
  SHA256.hash(data: hpke + signing).map { String(format: "%02x", $0) }.joined()
}
func transcript(_ q: Object) throws -> String {
  let names = ["pairing_id", "recipient_id", "hpke_key", "signing_key", "host"]
  return "bridge-pair-v2|" + (try names.map { try text(q, $0) }).joined(separator: "|")
    + "|\(try number(q, "port"))|\(try number(q, "expires_at"))"
}
private func envelopeCiphertext(_ m: Object) throws -> String {
  if try text(m, "message_type") != "file" { return try text(m, "ciphertext") }
  guard let value = m["ciphertext"] as? String, value.utf8.count <= PairedFile.maxWireBytes
  else { throw Rejected.invalid }
  return value
}
func aad(_ m: Object) throws -> String {
  "bridge-lab|2|\(try text(m, "pairing_id"))|\(try text(m, "sender_id"))|"
    + "\(try text(m, "recipient_id"))|\(try text(m, "message_type"))|\(try number(m, "counter"))|\(try text(m, "message_id"))"
}
func signedMessage(_ m: Object) throws -> String {
  "bridge-v2/message|" + (try aad(m)) + "|\(try text(m, "nonce"))|"
    + "\(try envelopeCiphertext(m))|\(try text(m, "wrapped_key"))"
}
func ipv4Octets(_ host: String) -> [Int]? {
  let parts = host.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count == 4 else { return nil }
  let ints = parts.compactMap { Int($0) }
  guard ints.count == 4,
    zip(parts, ints).allSatisfy({ String($0.1) == $0.0 && (0...255).contains($0.1) })
  else { return nil }
  return ints
}
func localHost(_ host: String) -> Bool {
  guard let ints = ipv4Octets(host) else { return false }
  return ints[0] == 10 || (ints[0] == 172 && (16...31).contains(ints[1]))
    || (ints[0] == 192 && ints[1] == 168) || host == "127.0.0.1"
}
func privateVPNHost(_ host: String) -> Bool {
  guard let ints = ipv4Octets(host) else { return false }
  return ints[0] == 100 && (64...127).contains(ints[1])
}
// Shared with the relay adapter without making the reference CLI depend on it.
func relayAuthenticationBytes(
  relayURL: String, relayID: String, deviceID: String, sessionID: String,
  clientNonce: Data, challenge: Data, expiresAt: UInt64
) throws -> Data {
  try uuid(deviceID)
  try uuid(sessionID)
  guard let url = URLComponents(string: relayURL), url.scheme == "wss",
    url.host != nil, url.path == "/v1/relay", url.user == nil, url.password == nil,
    url.query == nil, url.fragment == nil, relayURL.utf8.count <= 2048,
    !relayURL.contains("|"), !relayID.isEmpty, relayID.utf8.count <= 128,
    relayID.utf8.allSatisfy({ (33...126).contains($0) && $0 != 124 }),
    clientNonce.count == 32, challenge.count == 32, expiresAt > 0
  else { throw Rejected.invalid }
  return utf8(
    "bridge-relay-v1/auth|\(relayURL)|\(relayID)|\(deviceID)|\(sessionID)|"
      + "\(clientNonce.base64EncodedString())|\(challenge.base64EncodedString())|\(expiresAt)")
}
protocol ProtectedStore {
  func load() throws -> Data?
  func save(_ data: Data) throws
}
final class KeychainStore: ProtectedStore {
  // Separate from any existing app, with no passwords/keys stored in the checkout.
  private let query: Object = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.sparsh.bridge.learning.v2",
    kSecAttrAccount as String: "identity-and-replay-state",
  ]
  private var lease: IdentityLease?
  private let allowInsert: Bool
  private var interactive: Bool
  init(allowInsert: Bool = true, interactive: Bool = true) {
    self.allowInsert = allowInsert
    self.interactive = interactive
  }
  private func lookup() -> Object {
    var result = query
    if !interactive {
      // The existing item lives in the legacy login keychain. LAContext alone
      // does not suppress its CSSM authorization UI. Keep background loads bounded.
      _ = SecKeychainSetUserInteractionAllowed(false)
      let context = LAContext()
      context.interactionNotAllowed = true
      result[kSecUseAuthenticationContext as String] = context
    }
    return result
  }
  func authorize<T>(_ operation: () throws -> T) rethrows -> T {
    let previous = interactive
    interactive = true
    _ = SecKeychainSetUserInteractionAllowed(true)
    defer {
      interactive = previous
      _ = SecKeychainSetUserInteractionAllowed(false)
    }
    return try operation()
  }
  func load() throws -> Data? {
    if lease == nil { lease = try IdentityLease() }
    var q = lookup()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw Rejected.keychainStatus(status)
    }
    return data
  }
  func save(_ data: Data) throws {
    if lease == nil { lease = try IdentityLease() }
    let status = SecItemUpdate(lookup() as CFDictionary, [kSecValueData: data] as CFDictionary)
    if status == errSecItemNotFound {
      guard allowInsert else { throw Rejected.missingIdentity }
      var q = query
      q[kSecValueData as String] = data
      q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw Rejected.keychain }
    } else if status != errSecSuccess {
      throw Rejected.keychain
    }
  }
}
final class MemoryStore: ProtectedStore {
  var data: Data?
  func load() -> Data? { data }
  func save(_ value: Data) { data = value }
}
final class Endpoint {
  private let store: ProtectedStore
  private var state: Object
  private var pending: Object?
  private let hpke: Curve25519.KeyAgreement.PrivateKey
  private let signing: Curve25519.Signing.PrivateKey
  init(_ store: ProtectedStore, allowCreate: Bool = true) throws {
    self.store = store
    if let data = try store.load() {
      state = try object(data)
    } else {
      guard allowCreate else { throw Rejected.missingIdentity }
      state = [
        "recipient_id": UUID().uuidString.lowercased(),
        "hpke_seed": Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString(),
        "signing_seed": Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString(),
      ]
      try store.save(json(state))
    }
    hpke = try .init(rawRepresentation: bytes(text(state, "hpke_seed"), 32...32))
    signing = try .init(rawRepresentation: bytes(text(state, "signing_seed"), 32...32))
    try uuid(text(state, "recipient_id"))
  }
  func cancelPairing() { pending = nil }

  // Relay authentication is a separate signing domain from pairing/messages.
  // The transport receives a signature, never the existing private seed.
  func relayDeviceID() throws -> String { try text(state, "recipient_id") }

  func relaySigningPublicKey() -> Data { signing.publicKey.rawRepresentation }

  func signRelayAuthentication(
    relayURL: String, relayID: String, sessionID: String, clientNonce: Data,
    challenge: Data, expiresAt: UInt64
  ) throws -> Data {
    try signing.signature(
      for: relayAuthenticationBytes(
        relayURL: relayURL, relayID: relayID, deviceID: relayDeviceID(), sessionID: sessionID,
        clientNonce: clientNonce, challenge: challenge, expiresAt: expiresAt))
  }

  func status() throws -> Object {
    let peer = state["pair"] as? Object
    return [
      "recipient_id": try text(state, "recipient_id"),
      "fingerprint": fingerprint(
        hpke.publicKey.rawRepresentation, signing.publicKey.rawRepresentation),
      "paired": peer != nil, "sender_id": peer?["sender_id"] ?? NSNull(),
      "highest": peer?["highest"] ?? NSNull(),
    ]
  }
  func newPair(
    _ request: Object, now: Int = Int(Date().timeIntervalSince1970), overPrivateVPN: Bool = false
  ) throws -> Object {
    try fields(request, "host port")
    let host = try text(request, "host")
    let port = try number(request, "port")
    guard overPrivateVPN ? privateVPNHost(host) : localHost(host), (1024...65535).contains(port)
    else { throw Rejected.invalid }
    let bundle: Object = [
      "bridge_pairing": 2, "pairing_id": UUID().uuidString.lowercased(),
      "recipient_id": try text(state, "recipient_id"),
      "hpke_key": hpke.publicKey.rawRepresentation.base64EncodedString(),
      "signing_key": signing.publicKey.rawRepresentation.base64EncodedString(),
      "host": host, "port": port, "expires_at": now + 300,
      "secret": try random(32).base64EncodedString(),
    ]
    pending = nil
    let encoded = String(data: try json(bundle), encoding: .utf8)!
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(utf8(encoded), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage else { throw Rejected.state }
    let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
      .cropped(to: image.extent.insetBy(dx: -4, dy: -4))
    let padded = image.composited(over: background).transformed(
      by: CGAffineTransform(scaleX: 6, y: 6))
    guard
      let png = CIContext(options: [.useSoftwareRenderer: true]).pngRepresentation(
        of: padded, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    else { throw Rejected.state }
    pending = bundle
    return [
      "bundle": encoded, "qr_png": png.base64EncodedString(), "expires_at": now + 300,
      "fingerprint": fingerprint(
        hpke.publicKey.rawRepresentation, signing.publicKey.rawRepresentation),
    ]
  }
  func pair(_ r: Object, now: Int = Int(Date().timeIntervalSince1970)) throws -> Object {
    try fields(r, "pairing_id sender_id sender_key proof signature")
    var retryContent = r
    retryContent.removeValue(forKey: "signature")
    let requestDigest = Data(SHA256.hash(data: try json(retryContent))).base64EncodedString()
    if let peer = state["pair"] as? Object, peer["request_digest"] as? String == requestDigest,
      let acknowledgement = peer["ack"] as? Object
    {
      guard
        try Curve25519.Signing.PublicKey(
          rawRepresentation: bytes(text(peer, "sender_key"), 32...32)
        )
        .isValidSignature(
          bytes(text(r, "signature"), 64...64),
          for: utf8("bridge-v2/pair|" + text(peer, "transcript")))
      else { throw Rejected.invalid }
      return acknowledgement
    }
    guard let q = pending, try text(r, "pairing_id") == text(q, "pairing_id"),
      now < (try number(q, "expires_at"))
    else { throw Rejected.invalid }
    let sender = try text(r, "sender_id")
    let pub = try bytes(text(r, "sender_key"), 32...32)
    try uuid(sender)
    let t = try transcript(q) + "|\(sender)|\(pub.base64EncodedString())"
    let secret = SymmetricKey(data: try bytes(text(q, "secret"), 32...32))
    guard
      HMAC<SHA256>.isValidAuthenticationCode(
        try bytes(text(r, "proof"), 32...32),
        authenticating: utf8("bridge-v2/pair|" + t), using: secret),
      try Curve25519.Signing.PublicKey(rawRepresentation: pub).isValidSignature(
        bytes(text(r, "signature"), 64...64), for: utf8("bridge-v2/pair|" + t))
    else { throw Rejected.invalid }
    let confirmed = utf8("bridge-v2/paired|" + t)
    let ack: Object = [
      "pairing_id": try text(q, "pairing_id"), "recipient_id": try text(state, "recipient_id"),
      "sender_id": sender,
      "proof": Data(HMAC<SHA256>.authenticationCode(for: confirmed, using: secret))
        .base64EncodedString(),
      "signature": try signing.signature(for: confirmed).base64EncodedString(),
    ]
    var next = state
    next["pair"] = [
      "pairing_id": try text(q, "pairing_id"), "sender_id": sender,
      "sender_key": pub.base64EncodedString(), "highest": 0, "seen": [],
      "request_digest": requestDigest, "transcript": t, "ack": ack,
    ]
    try store.save(json(next))
    state = next
    pending = nil
    return ack
  }
  func activePairingID() throws -> String {
    guard let peer = state["pair"] as? Object else { throw Rejected.state }
    return try text(peer, "pairing_id")
  }

  func receive(_ m: Object, type: String = "text") throws -> Object {
    try fields(
      m,
      "lab_version mode suite pairing_id sender_id recipient_id message_id message_type counter nonce ciphertext wrapped_key signature"
    )
    guard try number(m, "lab_version") == 2, try text(m, "mode") == "paired",
      try text(m, "suite") == suiteName, try text(m, "message_type") == type,
      let peer = state["pair"] as? Object,
      try text(m, "pairing_id") == text(peer, "pairing_id"),
      try text(m, "sender_id") == text(peer, "sender_id"),
      try text(m, "recipient_id") == text(state, "recipient_id")
    else { throw Rejected.invalid }
    for name in ["pairing_id", "sender_id", "recipient_id", "message_id"] {
      try uuid(text(m, name))
    }
    let counter = try number(m, "counter")
    guard (1...1_000_000).contains(counter) else { throw Rejected.invalid }
    let nonce = try bytes(text(m, "nonce"), 12...12)
    let cipherLength: ClosedRange<Int>
    switch type {
    case "text": cipherLength = 17...4112
    case "file": cipherLength = 21...(PairedFile.maxPayload + 16)
    case "file_pull": cipherLength = 48...48
    case "file_ack": cipherLength = 52...52
    default: throw Rejected.invalid
    }
    let ciphertext = try bytes(envelopeCiphertext(m), cipherLength)
    let wrapped = try bytes(text(m, "wrapped_key"), 80...80)
    let s = try signedMessage(m)
    let digest = Data(SHA256.hash(data: utf8(s))).base64EncodedString()
    guard
      try Curve25519.Signing.PublicKey(rawRepresentation: bytes(text(peer, "sender_key"), 32...32))
        .isValidSignature(bytes(text(m, "signature"), 64...64), for: utf8(s))
    else { throw Rejected.invalid }
    let seen = peer["seen"] as? [Object] ?? []
    let known = seen.first { $0["message_id"] as? String == m["message_id"] as? String }
    if let known {
      guard known["digest"] as? String == digest, try number(known, "counter") == counter else {
        throw Rejected.invalid
      }
      return ["receipt": try receipt(m, digest, true)]
    }
    guard counter > (try number(peer, "highest")) else { throw Rejected.invalid }
    var recipient = try HPKE.Recipient(
      privateKey: hpke, ciphersuite: .Curve25519_SHA256_ChachaPoly,
      info: utf8("bridge-v2/key-wrap|" + aad(m)), encapsulatedKey: wrapped.prefix(32))
    let contentKey = try recipient.open(wrapped.dropFirst(32))
    guard contentKey.count == 32 else { throw Rejected.invalid }
    let box = try ChaChaPoly.SealedBox(
      nonce: .init(data: nonce), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
    let plaintext = try ChaChaPoly.open(
      box, using: SymmetricKey(data: contentKey), authenticating: utf8(aad(m)))
    var result: Object
    switch type {
    case "text":
      guard let display = String(data: plaintext, encoding: .utf8) else { throw Rejected.invalid }
      result = ["decrypted_text": display]
    case "file":
      result = ["decrypted_file": try PairedFile.decode(plaintext)]
    case "file_pull":
      result = ["response_key": plaintext]
    default:
      guard let id = String(data: plaintext, encoding: .utf8) else { throw Rejected.invalid }
      try uuid(id)
      result = ["ack_file_id": id]
    }
    var nextPeer = peer
    var next = state
    nextPeer["highest"] = counter
    nextPeer["seen"] = Array(
      (seen + [["message_id": try text(m, "message_id"), "digest": digest, "counter": counter]])
        .suffix(128))
    next["pair"] = nextPeer
    try store.save(json(next))  // Commit replay protection before disclosure/receipt.
    state = next
    result["receipt"] = try receipt(m, digest, false)
    return result
  }
  private func receipt(_ m: Object, _ digest: String, _ duplicate: Bool) throws -> Object {
    let r =
      "bridge-v2/receipt|\(try text(m, "pairing_id"))|\(try text(m, "message_id"))|"
      + "\(try number(m, "counter"))|\(digest)|\(duplicate ? 1 : 0)"
    return [
      "accepted": true, "duplicate": duplicate, "message_id": try text(m, "message_id"),
      "pairing_id": try text(m, "pairing_id"), "counter": try number(m, "counter"),
      "digest": digest, "signature": try signing.signature(for: utf8(r)).base64EncodedString(),
    ]
  }
}

// A kernel-owned process lease, shared by both adapters, including while paused.
// Bind only: this loopback socket does NOT listen or accept any requests. The
// kernel releases it on exit/crash. No lock file can outlive the owning process.
private final class IdentityLease {
  private let descriptor: Int32
  init() throws {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Rejected.state }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(8786).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      Darwin.close(fd)
      throw Rejected.identityInUse
    }
    descriptor = fd
  }
  deinit { Darwin.close(descriptor) }
}
