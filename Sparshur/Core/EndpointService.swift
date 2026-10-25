import CryptoKit
import Foundation

struct PairingCode: Sendable {
  let revision: UInt64
  let bundle: String
  let png: Data
  let expiresAt: Date
  let fingerprint: String
  let host: String
}

struct WireReceipt: Sendable {
  let body: Data
  let duplicate: Bool
}

struct LocalObservation: Identifiable, Sendable {
  enum Kind: String, Sendable { case paired, readable, phoneOnly }
  let id: String
  let receivedAt: Date
  let kind: Kind
  let plaintext: String?
  let envelope: Data
  let sender: String?
  let stages: [String]
}

enum ReceiverStatus: Equatable, Sendable {
  case stopped, starting, listening, paused
  case failed(String)
  case identityAccessRequired(String)
  var title: String {
    switch self {
    case .stopped: "Receiver stopped"
    case .starting: "Starting receiver…"
    case .listening: "Receiving on port 8787"
    case .paused: "Receiver paused"
    case .failed(let reason): reason
    case .identityAccessRequired(let reason): reason
    }
  }
  var shortTitle: String {
    switch self {
    case .stopped: "Receiver stopped"
    case .starting: "Starting receiver…"
    case .listening: "Receiving on 8787"
    case .paused: "Receiver paused"
    case .failed: "Receiver unavailable"
    case .identityAccessRequired: "Keychain access required"
    }
  }
}

enum ServiceEvent: Sendable {
  case observation(LocalObservation)
  case duplicate
  case identity(PublicIdentity)
  case pairingCleared(UInt64)
  case status(ReceiverStatus)
  case relayStatus(RelayStatus)
  case rejected, networkChanged, storageFailed
}

struct EndpointResponse: Sendable {
  let status: Int
  let body: Data
  static func failure(_ status: Int) -> Self {
    Self(status: status, body: Data("{\"error\":\"Request could not be accepted\"}".utf8))
  }
}

actor EndpointService {
  private var endpoint: Endpoint?
  private var active = false
  private var samples: [String: Data] = [:]
  private var pendingExpiry: Date?
  private var pairingRevision: UInt64 = 0
  private let store: ProtectedStore
  private let publish: @Sendable (ServiceEvent) -> Void

  init(
    store: sending ProtectedStore = KeychainStore(allowInsert: false, interactive: false),
    publish: @escaping @Sendable (ServiceEvent) -> Void
  ) {
    self.store = store
    self.publish = publish
  }

  // No await inside a transaction: actor re-entrancy cannot split persistence
  // from disclosure. A missing/inaccessible item is never silently replaced.
  func activate() throws {
    let restored = try Endpoint(store, allowCreate: false)
    if let endpoint {
      guard try text(endpoint.status(), "fingerprint") == text(restored.status(), "fingerprint")
      else { throw Rejected.state }
    }
    endpoint = restored
    active = true
    try publishIdentity()
  }
  func authorizeIdentity() throws {
    guard let keychain = store as? KeychainStore else {
      try activate()
      return
    }
    let restored = try keychain.authorize { try Endpoint(keychain, allowCreate: false) }
    if let endpoint {
      guard try text(endpoint.status(), "fingerprint") == text(restored.status(), "fingerprint")
      else { throw Rejected.state }
    }
    endpoint = restored
    active = true
    try publishIdentity()
  }
  func deactivate() {
    active = false
    cancelPairing()
  }
  func relayDeviceID() throws -> String {
    guard active, let endpoint else { throw Rejected.state }
    return try endpoint.relayDeviceID()
  }
  func signRelayChallenge(_ challenge: RelayChallenge, configuration: RelayConfiguration) throws
    -> Data
  {
    guard active, let endpoint else { throw Rejected.state }
    try challenge.validate(configuration: configuration, nonce: challenge.clientNonce)
    return try endpoint.signRelayAuthentication(
      relayURL: configuration.url.absoluteString, relayID: challenge.relayID,
      sessionID: challenge.sessionID, clientNonce: challenge.clientNonce,
      challenge: challenge.challenge, expiresAt: challenge.expiresAt)
  }
  func expirePairing(now: Date = .now) {
    if let pendingExpiry, now >= pendingExpiry {
      cancelPairing()
    }
  }
  func cancelPairing() {
    endpoint?.cancelPairing()
    pendingExpiry = nil
    pairingRevision += 1
    publish(.pairingCleared(pairingRevision))
  }
  func createPairing(host: String, port: Int = 8787, now: Date = .now) throws -> PairingCode {
    guard active, let endpoint else { throw Rejected.state }
    endpoint.cancelPairing()
    pendingExpiry = nil
    pairingRevision += 1
    let result = try endpoint.newPair(
      ["host": host, "port": port], now: Int(now.timeIntervalSince1970))
    let expiry = Date(timeIntervalSince1970: Double(try number(result, "expires_at")))
    pendingExpiry = expiry
    guard let png = result["qr_png"] as? String else { throw Rejected.state }
    return PairingCode(
      revision: pairingRevision, bundle: try text(result, "bundle"),
      png: try bytes(png, 1...1_000_000),
      expiresAt: expiry, fingerprint: try text(result, "fingerprint"), host: host)
  }
  private func publishIdentity() throws {
    guard let endpoint else { throw Rejected.state }
    let status = try endpoint.status()
    publish(
      .identity(
        PublicIdentity(
          recipientID: try text(status, "recipient_id"),
          fingerprint: try text(status, "fingerprint"), senderID: status["sender_id"] as? String,
          highestCounter: status["highest"] as? Int)))
  }

  func handle(_ request: HTTPRequest) -> EndpointResponse {
    guard active, !Task.isCancelled, let endpoint else { return .failure(503) }
    do {
      if request.method == "GET", request.path == "/health" {
        return EndpointResponse(
          status: 200,
          body: Data("{\"service\":\"bridge-learning-observer\",\"lab_version\":1}".utf8))
      }
      guard request.method == "POST" else { return .failure(405) }
      let body = try StrictJSON.decodeObject(request.body)
      switch request.path {
      case "/pairing/complete":
        let acknowledgement = try endpoint.pair(body)
        pendingExpiry = nil
        pairingRevision += 1
        publish(.pairingCleared(pairingRevision))
        try publishIdentity()
        return EndpointResponse(status: 200, body: try json(acknowledgement))
      case "/paired-message":
        let result = try endpoint.receive(body)
        guard let receiptObject = result["receipt"] as? Object,
          let duplicate = receiptObject["duplicate"] as? Bool
        else { throw Rejected.state }
        let receipt = WireReceipt(body: try json(receiptObject), duplicate: duplicate)
        try publishIdentity()
        if duplicate {
          publish(.duplicate)
        } else {
          let observation = LocalObservation(
            id: try text(body, "message_id"), receivedAt: .now,
            kind: .paired, plaintext: try text(result, "decrypted_text"), envelope: request.body,
            sender: try text(body, "sender_id"),
            stages: [
              "Received", "Sender verified", "Key unwrapped",
              "Payload verified and decrypted", "Replay state saved", "Receipt signed",
            ])
          publish(.observation(observation))
        }
        // Only the typed wire receipt is serialized. LocalObservation never crosses HTTP.
        return EndpointResponse(status: receipt.duplicate ? 200 : 202, body: receipt.body)
      case "/message": return try acceptSample(body, raw: request.body)
      default: return .failure(404)
      }
    } catch Rejected.keychain {
      publish(.storageFailed)
      return .failure(503)
    } catch Rejected.keychainStatus {
      publish(.storageFailed)
      return .failure(503)
    } catch Rejected.missingIdentity {
      publish(.storageFailed)
      return .failure(503)
    } catch {
      publish(.rejected)
      return .failure(400)
    }
  }

  private func acceptSample(_ body: Object, raw: Data) throws -> EndpointResponse {
    guard try number(body, "lab_version") == 1 else { throw Rejected.invalid }
    let id = try text(body, "message_id")
    try uuid(id)
    let mode = try text(body, "mode")
    let kind: LocalObservation.Kind
    var plaintext: String?
    if mode == "plaintext" {
      try fields(body, "lab_version mode message_id text")
      let sample = try text(body, "text")
      guard (1...4096).contains(sample.utf8.count) else { throw Rejected.invalid }
      plaintext = sample
      kind = .readable
    } else if mode == "encrypted" {
      try fields(
        body,
        "lab_version mode algorithm message_id sender_id recipient_id message_type counter nonce aad ciphertext"
      )
      try uuid(text(body, "sender_id"))
      guard try text(body, "algorithm") == "AES-256-GCM",
        try text(body, "recipient_id") == "laptop-observer",
        try text(body, "message_type") == "text", (1...10000).contains(try number(body, "counter"))
      else { throw Rejected.invalid }
      _ = try bytes(text(body, "nonce"), 12...12)
      _ = try bytes(text(body, "ciphertext"), 17...4112)
      let expected =
        "bridge-lab|1|\(try text(body, "sender_id"))|laptop-observer|text|\(try number(body, "counter"))|\(id)"
      guard try bytes(text(body, "aad"), 1...256) == utf8(expected) else { throw Rejected.invalid }
      kind = .phoneOnly
    } else {
      throw Rejected.invalid
    }
    let digest = Data(SHA256.hash(data: try json(body)))
    let duplicate = samples[id] != nil
    if let previous = samples[id] {
      guard previous == digest else { return .failure(409) }
    } else {
      guard samples.count < 1000 else { return .failure(409) }
      samples[id] = digest
      publish(
        .observation(
          LocalObservation(
            id: id, receivedAt: .now, kind: kind, plaintext: plaintext,
            envelope: raw, sender: body["sender_id"] as? String,
            stages: [
              "Received",
              kind == .readable
                ? "Readable sample — sender unverified" : "Phone-only AES — Mac has no key",
            ])))
    }
    if duplicate { publish(.duplicate) }
    return EndpointResponse(
      status: duplicate ? 200 : 202, body: try json(["accepted": true, "duplicate": duplicate]))
  }
}
