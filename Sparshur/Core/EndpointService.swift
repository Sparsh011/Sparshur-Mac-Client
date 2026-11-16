import CryptoKit
import Foundation
import UniformTypeIdentifiers

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
  enum ClipboardContent {
    case text(String)
    case image(Data, UTType)
  }
  let id: String
  let receivedAt: Date
  let kind: Kind
  let plaintext: String?
  let envelope: Data
  var file: PairedFile? = nil
  let sender: String?
  let stages: [String]

  var clipboardContent: ClipboardContent? {
    guard kind == .paired else { return nil }
    if let file {
      guard let type = file.imageType else { return nil }
      return .image(file.data, type)
    }
    return plaintext.map(ClipboardContent.text)
  }
}

struct PeerContact: Sendable {
  let senderID: String
  let date: Date
  let overPrivateVPN: Bool

  var route: String { overPrivateVPN ? "Private VPN" : "Local network" }
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
    case .listening: "Receiver ready"
    case .paused: "Receiver paused"
    case .failed: "Receiver unavailable"
    case .identityAccessRequired: "Keychain access required"
    }
  }
}

enum ServiceEvent: Sendable {
  case observation(LocalObservation)
  case peerContact(PeerContact)
  case duplicate
  case outgoingFileQueued(name: String)
  case outgoingFileCleared(delivered: Bool)
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
  private struct OutgoingFile {
    let id: String
    let pairing: String
    let payload: Data
  }
  private var outgoingFile: OutgoingFile?
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
  func createPairing(
    host: String, port: Int = 8787, now: Date = .now, overPrivateVPN: Bool = false
  ) throws -> PairingCode {
    guard active, let endpoint else { throw Rejected.state }
    endpoint.cancelPairing()
    pendingExpiry = nil
    pairingRevision += 1
    let result = try endpoint.newPair(
      ["host": host, "port": port], now: Int(now.timeIntervalSince1970),
      overPrivateVPN: overPrivateVPN)
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

  func queueFile(_ file: PairedFile) throws {
    guard active, let endpoint, outgoingFile == nil else { throw Rejected.state }
    outgoingFile = try OutgoingFile(
      id: UUID().uuidString.lowercased(), pairing: endpoint.activePairingID(),
      payload: file.encode())
    publish(.outgoingFileQueued(name: file.name))
  }

  func cancelOutgoingFile() { outgoingFile = nil }

  func handle(_ request: HTTPRequest, overPrivateVPN: Bool = false) -> EndpointResponse {
    guard active, !Task.isCancelled, let endpoint else { return .failure(503) }
    if overPrivateVPN && request.path == "/message" { return .failure(404) }
    do {
      if request.method == "GET", request.path == "/health" {
        return EndpointResponse(
          status: 200,
          body: Data("{\"service\":\"bridge-learning-observer\",\"lab_version\":1}".utf8))
      }
      guard request.method == "POST" else { return .failure(405) }
      let body = try StrictJSON.decodeObject(
        request.body, maxBytes: request.path == "/paired-file" ? PairedFile.maxWireBytes : 65_536)
      switch request.path {
      case "/pairing/complete":
        let acknowledgement = try endpoint.pair(body)
        if let queued = outgoingFile, queued.pairing != (try endpoint.activePairingID()) {
          outgoingFile = nil
          publish(.outgoingFileCleared(delivered: false))
        }
        pendingExpiry = nil
        pairingRevision += 1
        publish(.pairingCleared(pairingRevision))
        try publishIdentity()
        publish(.peerContact(try contact(body, overPrivateVPN: overPrivateVPN)))
        return EndpointResponse(status: 200, body: try json(acknowledgement))
      case "/paired-file/pull":
        let result = try endpoint.receive(body, type: "file_pull")
        guard let key = result["response_key"] as? Data else { throw Rejected.invalid }
        let response = try queuedFileResponse(
          key: key, request: body, id: outgoingFile?.id ?? "",
          payload: outgoingFile?.payload ?? Data())
        try publishIdentity()
        publish(.peerContact(try contact(body, overPrivateVPN: overPrivateVPN)))
        return EndpointResponse(status: 200, body: try json(response))
      case "/paired-file/ack":
        let result = try endpoint.receive(body, type: "file_ack")
        guard let receipt = result["receipt"] as? Object else { throw Rejected.state }
        if let id = result["ack_file_id"] as? String, id == outgoingFile?.id {
          outgoingFile = nil
          publish(.outgoingFileCleared(delivered: true))
        }
        try publishIdentity()
        publish(.peerContact(try contact(body, overPrivateVPN: overPrivateVPN)))
        return EndpointResponse(status: 200, body: try json(receipt))
      case "/paired-message", "/paired-file":
        let isFile = request.path == "/paired-file"
        let result = try endpoint.receive(body, type: isFile ? "file" : "text")
        guard let receiptObject = result["receipt"] as? Object,
          let duplicate = receiptObject["duplicate"] as? Bool
        else { throw Rejected.state }
        let receipt = WireReceipt(body: try json(receiptObject), duplicate: duplicate)
        try publishIdentity()
        let contact = try contact(body, overPrivateVPN: overPrivateVPN)
        publish(.peerContact(contact))
        if duplicate {
          publish(.duplicate)
        } else {
          let observation = LocalObservation(
            id: try text(body, "message_id"), receivedAt: contact.date,
            kind: .paired, plaintext: result["decrypted_text"] as? String,
            envelope: isFile ? Data() : request.body, file: result["decrypted_file"] as? PairedFile,
            sender: contact.senderID,
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

  private func contact(_ body: Object, overPrivateVPN: Bool) throws -> PeerContact {
    PeerContact(senderID: try text(body, "sender_id"), date: .now, overPrivateVPN: overPrivateVPN)
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
