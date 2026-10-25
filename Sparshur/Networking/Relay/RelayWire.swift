import CryptoKit
import Foundation

enum RelayError: Error, Equatable {
  case configuration, malformedFrame, authentication, notConnected, backpressure
  case peerUpgradeRequired, timeout, stopped
}

struct RelayConfiguration: Sendable {
  let url: URL
  let relayID: String

  init(url: String, relayID: String) throws {
    guard url.utf8.count <= 2048, let parts = URLComponents(string: url), parts.scheme == "wss",
      let host = parts.host, !host.isEmpty, host == host.lowercased(),
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.path == "/v1/relay", parts.port == nil || (1...65535).contains(parts.port!),
      let parsed = parts.url, parsed.absoluteString == url,
      !relayID.isEmpty, relayID.utf8.count <= 128,
      relayID.utf8.allSatisfy({ (33...126).contains($0) && $0 != 124 })
    else { throw RelayError.configuration }
    self.url = parsed
    self.relayID = relayID
  }
}

// The endpoint, not the transport or relay, must construct/verify protectedBody.
// Transport hashes are correlation checks, never proof of sender authenticity.
struct RelayPacket: Sendable, Equatable {
  enum Kind: UInt64, Sendable {
    case envelope = 1
    case receipt = 2
  }
  let senderID: String
  let recipientID: String
  let pairingID: String
  let messageID: String
  let protectedBody: Data
  let kind: Kind

  init(
    senderID: String, recipientID: String, pairingID: String, messageID: String,
    protectedBody: Data, kind: Kind
  ) throws {
    for value in [senderID, recipientID, pairingID, messageID] { try uuid(value) }
    guard senderID != recipientID, (1...32768).contains(protectedBody.count) else {
      throw RelayError.malformedFrame
    }
    self.senderID = senderID
    self.recipientID = recipientID
    self.pairingID = pairingID
    self.messageID = messageID
    self.protectedBody = protectedBody
    self.kind = kind
  }

  var encoded: Data {
    RelayProto.encode([
      1: .bytes(utf8(senderID)), 2: .bytes(utf8(recipientID)), 3: .bytes(utf8(pairingID)),
      4: .bytes(utf8(messageID)), 5: .bytes(protectedBody),
      6: .bytes(utf8("bridge-relay-e2ee-v1")), 7: .integer(kind.rawValue),
    ])
  }
  var digest: Data { Data(SHA256.hash(data: encoded)) }

  init(encoded: Data) throws {
    let p = try RelayProto.decode(encoded)
    try p.exact([1, 2, 3, 4, 5, 6, 7])
    guard try p.string(6) == "bridge-relay-e2ee-v1",
      let kind = Kind(rawValue: try p.integer(7))
    else { throw RelayError.malformedFrame }
    try self.init(
      senderID: p.string(1), recipientID: p.string(2), pairingID: p.string(3),
      messageID: p.string(4), protectedBody: p.data(5), kind: kind)
  }
}

struct RelayChallenge: Sendable, Equatable {
  let relayID: String
  let sessionID: String
  let clientNonce: Data
  let challenge: Data
  let expiresAt: UInt64

  func validate(configuration: RelayConfiguration, nonce: Data, now: Date = .now) throws {
    try uuid(sessionID)
    let seconds = UInt64(max(0, now.timeIntervalSince1970))
    guard relayID == configuration.relayID, clientNonce == nonce,
      nonce.count == 32, challenge.count == 32, expiresAt > seconds,
      expiresAt - seconds <= 30
    else { throw RelayError.authentication }
  }

  // No JSON canonicalization or arbitrary signing oracle. Each component is
  // bounded; URL/relay IDs exclude the delimiter, UUID/base64 cannot contain it.
  func signingBytes(configuration: RelayConfiguration, deviceID: String) throws -> Data {
    try uuid(deviceID)
    try validate(configuration: configuration, nonce: clientNonce)
    return try relayAuthenticationBytes(
      relayURL: configuration.url.absoluteString, relayID: relayID, deviceID: deviceID,
      sessionID: sessionID, clientNonce: clientNonce, challenge: challenge, expiresAt: expiresAt)
  }
}

enum RelayFrame: Sendable, Equatable {
  case hello(deviceID: String, nonce: Data)
  case challenge(RelayChallenge)
  case authenticate(deviceID: String, challenge: RelayChallenge, signature: Data)
  case ready(deviceID: String, sessionID: String)
  case submit(RelayPacket)
  case deliver(RelayPacket)
  case forwarded(messageID: String, digest: Data)
  case unavailable(messageID: String, digest: Data)
  case authRejected

  func encode() -> Data {
    var p: [Int: RelayProto.Value] = [1: .integer(1)]
    func identity(_ device: String, _ nonce: Data) {
      p[3] = .bytes(utf8(device))
      p[4] = .bytes(nonce)
    }
    func challenge(_ value: RelayChallenge) {
      p[4] = .bytes(value.clientNonce)
      p[5] = .bytes(utf8(value.relayID))
      p[6] = .bytes(utf8(value.sessionID))
      p[7] = .bytes(value.challenge)
      p[8] = .integer(value.expiresAt)
    }
    switch self {
    case .hello(let device, let nonce):
      p[2] = .integer(1)
      identity(device, nonce)
    case .challenge(let value):
      p[2] = .integer(2)
      challenge(value)
    case .authenticate(let device, let value, let signature):
      p[2] = .integer(3)
      p[3] = .bytes(utf8(device))
      challenge(value)
      p[9] = .bytes(signature)
    case .ready(let device, let session):
      p[2] = .integer(4)
      p[3] = .bytes(utf8(device))
      p[6] = .bytes(utf8(session))
    case .submit(let packet):
      p[2] = .integer(5)
      p[10] = .bytes(packet.encoded)
    case .forwarded(let id, let digest):
      p[2] = .integer(6)
      p[11] = .bytes(utf8(id))
      p[12] = .bytes(digest)
    case .deliver(let packet):
      p[2] = .integer(7)
      p[10] = .bytes(packet.encoded)
    case .unavailable(let id, let digest):
      p[2] = .integer(8)
      p[11] = .bytes(utf8(id))
      p[12] = .bytes(digest)
    case .authRejected: p[2] = .integer(9)
    }
    return RelayProto.encode(p)
  }

  static func decode(_ bytes: Data) throws -> Self {
    do { return try decodeChecked(bytes) } catch { throw RelayError.malformedFrame }
  }

  private static func decodeChecked(_ bytes: Data) throws -> Self {
    let p = try RelayProto.decode(bytes)
    guard try p.integer(1) == 1 else { throw RelayError.malformedFrame }
    func challenge() throws -> RelayChallenge {
      let session = try p.string(6)
      try uuid(session)
      guard try p.data(4).count == 32, try p.data(7).count == 32,
        try p.string(5).utf8.count <= 128
      else { throw RelayError.malformedFrame }
      return try RelayChallenge(
        relayID: p.string(5), sessionID: session, clientNonce: p.data(4),
        challenge: p.data(7), expiresAt: p.integer(8))
    }
    switch try p.integer(2) {
    case 1:
      try p.exact([1, 2, 3, 4])
      try uuid(p.string(3))
      guard try p.data(4).count == 32 else { throw RelayError.malformedFrame }
      return try .hello(deviceID: p.string(3), nonce: p.data(4))
    case 2:
      try p.exact([1, 2, 4, 5, 6, 7, 8])
      return try .challenge(challenge())
    case 3:
      try p.exact([1, 2, 3, 4, 5, 6, 7, 8, 9])
      try uuid(p.string(3))
      guard try p.data(9).count == 64 else { throw RelayError.malformedFrame }
      return try .authenticate(deviceID: p.string(3), challenge: challenge(), signature: p.data(9))
    case 4:
      try p.exact([1, 2, 3, 6])
      try uuid(p.string(3))
      try uuid(p.string(6))
      return try .ready(deviceID: p.string(3), sessionID: p.string(6))
    case 5, 7:
      try p.exact([1, 2, 10])
      let packet = try RelayPacket(encoded: p.data(10))
      return try p.integer(2) == 5 ? .submit(packet) : .deliver(packet)
    case 6, 8:
      try p.exact([1, 2, 11, 12])
      try uuid(p.string(11))
      guard try p.data(12).count == 32 else { throw RelayError.malformedFrame }
      return try p.integer(2) == 6
        ? .forwarded(messageID: p.string(11), digest: p.data(12))
        : .unavailable(messageID: p.string(11), digest: p.data(12))
    case 9:
      try p.exact([1, 2])
      return .authRejected
    default: throw RelayError.malformedFrame
    }
  }
}

// Small, schema-specific protobuf subset; no crypto primitives or dependencies.
// Reject ambiguous encodings before they can reach authentication or routing.
enum RelayProto {
  enum Value: Equatable {
    case integer(UInt64)
    case bytes(Data)
  }
  static func encode(_ fields: [Int: Value]) -> Data {
    var data = Data()
    for key in fields.keys.sorted() {
      switch fields[key]! {
      case .integer(let n):
        data += varint(UInt64(key << 3))
        data += varint(n)
      case .bytes(let bytes):
        data += varint(UInt64(key << 3 | 2))
        data += varint(UInt64(bytes.count))
        data += bytes
      }
    }
    return data
  }
  static func varint(_ value: UInt64) -> Data {
    var n = value
    var data = Data()
    while n >= 128 {
      data.append(UInt8(n & 127) | 128)
      n >>= 7
    }
    data.append(UInt8(n))
    return data
  }
  static func decode(_ data: Data) throws -> [Int: Value] {
    guard !data.isEmpty, data.count <= 65536 else { throw RelayError.malformedFrame }
    let bytes = Array(data)
    var offset = 0
    func read() throws -> UInt64 {
      let start = offset
      var n: UInt64 = 0
      for shift in stride(from: 0, through: 63, by: 7) {
        guard offset < bytes.count else { throw RelayError.malformedFrame }
        let b = bytes[offset]
        offset += 1
        guard shift != 63 || b <= 1 else { throw RelayError.malformedFrame }
        n |= UInt64(b & 127) << shift
        if b < 128 {
          guard varint(n).count == offset - start else { throw RelayError.malformedFrame }
          return n
        }
      }
      throw RelayError.malformedFrame
    }
    var fields: [Int: Value] = [:]
    while offset < bytes.count {
      let tag = try read()
      guard tag >> 3 > 0, tag >> 3 <= 12 else { throw RelayError.malformedFrame }
      let key = Int(tag >> 3)
      guard fields[key] == nil else { throw RelayError.malformedFrame }
      switch tag & 7 {
      case 0:
        let n = try read()
        guard n > 0 else { throw RelayError.malformedFrame }
        fields[key] = .integer(n)
      case 2:
        let size = try read()
        guard size > 0, size <= UInt64(bytes.count - offset) else {
          throw RelayError.malformedFrame
        }
        fields[key] = .bytes(Data(bytes[offset..<offset + Int(size)]))
        offset += Int(size)
      default: throw RelayError.malformedFrame
      }
    }
    return fields
  }
}

extension Dictionary where Key == Int, Value == RelayProto.Value {
  fileprivate func exact(_ fields: Set<Int>) throws {
    guard Set(keys) == fields else { throw RelayError.malformedFrame }
  }
  fileprivate func integer(_ key: Int) throws -> UInt64 {
    guard case .integer(let n) = self[key] else { throw RelayError.malformedFrame }
    return n
  }
  fileprivate func data(_ key: Int) throws -> Data {
    guard case .bytes(let bytes) = self[key] else { throw RelayError.malformedFrame }
    return bytes
  }
  fileprivate func string(_ key: Int) throws -> String {
    guard let value = String(data: try data(key), encoding: .utf8) else {
      throw RelayError.malformedFrame
    }
    return value
  }
}
