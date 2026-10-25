import CryptoKit
import Foundation
import XCTest

@testable import SparshurPlatform

private let macID = "33333333-3333-4333-8333-333333333333"
private let phoneID = "22222222-2222-4222-8222-222222222222"
private let pairingID = "55555555-5555-4555-8555-555555555555"
private let sessionID = "44444444-4444-4444-8444-444444444444"

final class RelayTests: XCTestCase {
  func testConfigurationRefusesDowngradesCredentialsAndAmbiguousURLs() throws {
    _ = try config()
    for url in [
      "ws://relay.example/v1/relay", "https://relay.example/v1/relay",
      "wss://user:password@relay.example/v1/relay", "wss://relay.example/v1/relay?token=secret",
      "wss://relay.example/v1/relay#fragment", "wss://relay.example/other",
      "wss://relay.example:0/v1/relay", "wss://relay.example:65536/v1/relay",
    ] {
      XCTAssertThrowsError(try RelayConfiguration(url: url, relayID: "mini-test"))
    }
    XCTAssertThrowsError(
      try RelayConfiguration(url: "wss://relay.example/v1/relay", relayID: "x|y"))
  }

  func testChallengeBindsRelaySessionNonceExpiryAndDevice() throws {
    let configuration = try config()
    let nonce = Data(repeating: 0x55, count: 32)
    let challenge = challenge(nonce: nonce)
    try challenge.validate(configuration: configuration, nonce: nonce)
    XCTAssertThrowsError(
      try challenge.validate(configuration: configuration, nonce: Data(repeating: 1, count: 32)))
    XCTAssertThrowsError(
      try challenge.validate(configuration: config(relayID: "other-mini"), nonce: nonce))
    XCTAssertThrowsError(
      try challenge.validate(
        configuration: configuration, nonce: nonce, now: .now.addingTimeInterval(60)))
    XCTAssertThrowsError(
      try challenge.validate(
        configuration: configuration, nonce: nonce, now: .now.addingTimeInterval(-60)))
    XCTAssertNotEqual(
      try challenge.signingBytes(configuration: configuration, deviceID: macID),
      try challenge.signingBytes(configuration: configuration, deviceID: phoneID))
  }

  func testStrictProtobufFramesRoundTripAndRejectAmbiguity() throws {
    let challenge = challenge(nonce: Data(repeating: 0x55, count: 32))
    let packet = try packet()
    let frames: [RelayFrame] = [
      .hello(deviceID: macID, nonce: challenge.clientNonce), .challenge(challenge),
      .authenticate(
        deviceID: macID, challenge: challenge, signature: Data(repeating: 1, count: 64)),
      .ready(deviceID: macID, sessionID: sessionID), .submit(packet), .deliver(packet),
      .forwarded(messageID: packet.messageID, digest: packet.digest),
      .unavailable(messageID: packet.messageID, digest: packet.digest), .authRejected,
    ]
    for frame in frames {
      XCTAssertEqual(try RelayFrame.decode(frame.encode()), frame)
      // Duplicate version and unknown field.
      XCTAssertThrowsError(try RelayFrame.decode(frame.encode() + Data([8, 1])))
      XCTAssertThrowsError(try RelayFrame.decode(frame.encode() + Data([104, 1])))
      for length in 0..<frame.encode().count {
        XCTAssertThrowsError(try RelayFrame.decode(frame.encode().prefix(length)))
      }
    }
    XCTAssertThrowsError(try RelayFrame.decode(Data([8, 129, 0, 16, 9])))  // overlong varint
    XCTAssertThrowsError(try RelayFrame.decode(Data(repeating: 255, count: 65537)))
    XCTAssertThrowsError(try RelayFrame.decode(Data("{\"lab_version\":2}".utf8)))
    XCTAssertThrowsError(try RelayPacket(encoded: Data("plaintext".utf8)))
  }

  func testBoundedParserFuzz() {
    var seed: UInt64 = 0xc0ffee
    for count in 0..<2000 {
      let bytes = (0..<(count % 300)).map { _ -> UInt8 in
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return UInt8(truncatingIfNeeded: seed >> 32)
      }
      _ = try? RelayFrame.decode(Data(bytes))
    }
  }

  func testIndependentPythonProtobufVectors() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "relay-wire", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try object(Data(contentsOf: url))
    let frames = try XCTUnwrap(fixture["frames_hex"] as? [String: String])
    XCTAssertEqual(frames.count, 9)
    for encoded in frames.values {
      var raw = Data()
      var offset = encoded.startIndex
      while offset < encoded.endIndex {
        let end = encoded.index(offset, offsetBy: 2)
        raw.append(try XCTUnwrap(UInt8(encoded[offset..<end], radix: 16)))
        offset = end
      }
      XCTAssertEqual(try RelayFrame.decode(raw).encode(), raw)
    }
  }

  func testFrozenAuthenticationVectorAndExistingIdentitySignature() async throws {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "relay-auth", withExtension: "json", subdirectory: "Fixtures"))
    let vector = try object(Data(contentsOf: url))
    let signedBytes = try relayAuthenticationBytes(
      relayURL: text(vector, "relay_url"), relayID: text(vector, "relay_id"),
      deviceID: text(vector, "device_id"), sessionID: text(vector, "session_id"),
      clientNonce: bytes(text(vector, "client_nonce"), 32...32),
      challenge: bytes(text(vector, "challenge"), 32...32),
      expiresAt: UInt64(number(vector, "expires_at")))
    XCTAssertEqual(String(decoding: signedBytes, as: UTF8.self), try text(vector, "signing_bytes"))
    let key = try Curve25519.Signing.PrivateKey(
      rawRepresentation: bytes(text(vector, "signing_seed"), 32...32))
    XCTAssertTrue(
      try key.publicKey.isValidSignature(
        bytes(text(vector, "signature"), 64...64), for: signedBytes))
    XCTAssertTrue(
      try key.publicKey.isValidSignature(key.signature(for: signedBytes), for: signedBytes))
    XCTAssertEqual(
      key.publicKey.rawRepresentation, try bytes(text(vector, "signing_public_key"), 32...32))
    let memory = try fixtureStore()
    let before = memory.data
    let current = challenge(nonce: Data(repeating: 7, count: 32))
    let endpoint = try Endpoint(memory, allowCreate: false)
    _ = try endpoint.signRelayAuthentication(
      relayURL: "wss://relay.example/v1/relay", relayID: current.relayID,
      sessionID: current.sessionID, clientNonce: current.clientNonce,
      challenge: current.challenge, expiresAt: current.expiresAt)
    XCTAssertEqual(memory.data, before)  // Authentication must not rewrite pairing/replay state.
    let service = EndpointService(store: try fixtureStore(), publish: { _ in })
    try await service.activate()
    let signature = try await service.signRelayChallenge(current, configuration: config())
    XCTAssertTrue(
      try key.publicKey.isValidSignature(
        signature, for: current.signingBytes(configuration: config(), deviceID: macID)))
    await service.deactivate()
    do {
      _ = try await service.signRelayChallenge(current, configuration: config())
      XCTFail("Paused signer accepted")
    } catch {}
  }

  func testAuthenticatedSendAndReceiveKeepForwardingSeparateFromProcessing() async throws {
    let socket = FakeRelaySocket()
    let recorder = RelayRecorder()
    let client = try client(socket: socket, recorder: recorder)
    await client.start()
    try await wait { recorder.statuses.contains(.connected) }
    XCTAssertTrue(socket.signatureVerified)
    let outgoing = try packet()
    try await client.sendPrepared(outgoing)
    try await client.sendPrepared(outgoing)  // Byte-identical retry.
    let submissions = socket.sent.compactMap { frame -> RelayPacket? in
      if case .submit(let p) = frame { return p }
      return nil
    }
    XCTAssertEqual(submissions, [outgoing, outgoing])
    XCTAssertTrue(recorder.events.isEmpty)  // A socket write is not a relay acknowledgement.
    socket.inject(.forwarded(messageID: outgoing.messageID, digest: outgoing.digest))
    try await wait { recorder.events.count == 1 }
    XCTAssertEqual(recorder.events, [.forwarded(messageID: outgoing.messageID)])
    socket.inject(.forwarded(messageID: outgoing.messageID, digest: outgoing.digest))
    try await wait { recorder.events.count == 2 }
    let incoming = try packet(sender: phoneID, recipient: macID)
    socket.inject(.deliver(incoming))
    try await wait { recorder.packets.count == 1 }
    XCTAssertEqual(recorder.packets, [incoming])
    XCTAssertEqual(socket.sent.count, 4)  // No automatically fabricated endpoint receipt.
    await client.stop()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(recorder.statuses.last, .paused)
  }

  func testWrongRecipientAndForgedForwardingResponseFailClosed() async throws {
    for wrongRecipient in [true, false] {
      let socket = FakeRelaySocket()
      let recorder = RelayRecorder()
      let client = try client(socket: socket, recorder: recorder)
      await client.start()
      try await wait { recorder.statuses.contains(.connected) }
      if wrongRecipient {
        socket.inject(.deliver(try packet()))
      } else {
        let p = try packet()
        try await client.sendPrepared(p)
        socket.inject(.forwarded(messageID: p.messageID, digest: Data(repeating: 0, count: 32)))
      }
      try await wait { recorder.statuses.last == .blocked }
      XCTAssertTrue(recorder.packets.isEmpty)
      XCTAssertTrue(recorder.events.isEmpty)
      await client.stop()
    }
  }

  func testMissingPeerUpgradeNeverAcknowledgesDelivery() async throws {
    let socket = FakeRelaySocket()
    let recorder = RelayRecorder()
    let client = try client(socket: socket, recorder: recorder, needsUpgrade: true)
    await client.start()
    try await wait { recorder.statuses.contains(.connected) }
    socket.inject(.deliver(try packet(sender: phoneID, recipient: macID)))
    try await wait { recorder.statuses.last == .upgradeRequired }
    XCTAssertEqual(socket.sent.count, 2)
    await client.stop()
  }

  func testOutOfOrderAuthenticationAndBadNonceNeverReachSigner() async throws {
    for mode in [FakeRelaySocket.Mode.badNonce, .prematureReady] {
      let socket = FakeRelaySocket(mode: mode)
      let recorder = RelayRecorder()
      let client = try client(socket: socket, recorder: recorder)
      await client.start()
      try await wait { recorder.statuses.last == .blocked }
      XCTAssertEqual(socket.sent.count, 1)
      XCTAssertFalse(socket.signatureVerified)
      await client.stop()
    }
  }

  func testBackpressureRejectsUnboundedPendingWritesAndConflictingIDs() async throws {
    let socket = FakeRelaySocket()
    let recorder = RelayRecorder()
    let client = try client(socket: socket, recorder: recorder)
    await client.start()
    try await wait { recorder.statuses.contains(.connected) }
    let first = try packet()
    try await client.sendPrepared(first)
    let conflict = try RelayPacket(
      senderID: macID, recipientID: phoneID, pairingID: pairingID,
      messageID: first.messageID, protectedBody: Data([9]), kind: .envelope)
    do {
      try await client.sendPrepared(conflict)
      XCTFail("Conflicting retry accepted")
    } catch {}
    for _ in 0..<31 { try await client.sendPrepared(packet()) }
    do {
      try await client.sendPrepared(packet())
      XCTFail("Unbounded write accepted")
    } catch { XCTAssertEqual(error as? RelayError, .backpressure) }
    await client.stop()
  }

  func testReconnectReauthenticatesWithFreshNonceAndStopFencesOldWork() async throws {
    let pool = SocketPool()
    let recorder = RelayRecorder()
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
    let client = try RelayClient(
      configuration: config(), deviceID: macID,
      factory: { _ in pool.next() },
      signer: { challenge, config in
        try key.signature(for: challenge.signingBytes(configuration: config, deviceID: macID))
      }, handlePacket: { _ in }, publish: { recorder.status($0) },
      retryDelay: { _ in .milliseconds(1) })
    await client.start()
    try await wait { recorder.statuses.filter { $0 == .connected }.count == 1 }
    pool.sockets[0].close()
    try await wait { recorder.statuses.filter { $0 == .connected }.count == 2 }
    let nonces = pool.sockets.compactMap { socket -> Data? in
      if case .hello(_, let nonce) = socket.sent.first { return nonce }
      return nil
    }
    XCTAssertEqual(nonces.count, 2)
    XCTAssertNotEqual(nonces[0], nonces[1])
    await client.stop()
    let count = pool.sockets.count
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(pool.sockets.count, count)
    XCTAssertEqual(recorder.statuses.last, .paused)
  }

  func testDeadlineClosesSuspendedReceive() async throws {
    let socket = FakeRelaySocket()
    do {
      _ = try await relayDeadline(.milliseconds(20), socket: socket) { try await socket.receive() }
      XCTFail("Deadline did not fire")
    } catch {}
    XCTAssertTrue(socket.isClosed)
  }

  private func config(relayID: String = "mini-test") throws -> RelayConfiguration {
    try RelayConfiguration(url: "wss://relay.example/v1/relay", relayID: relayID)
  }
  private func challenge(nonce: Data) -> RelayChallenge {
    RelayChallenge(
      relayID: "mini-test", sessionID: sessionID, clientNonce: nonce,
      challenge: Data(repeating: 0x66, count: 32),
      expiresAt: UInt64(Date().timeIntervalSince1970) + 20)
  }
  private func packet(sender: String = macID, recipient: String = phoneID) throws -> RelayPacket {
    // Symbolic protected bytes only. This test does not claim E2EE interoperability.
    try RelayPacket(
      senderID: sender, recipientID: recipient, pairingID: pairingID,
      messageID: UUID().uuidString.lowercased(), protectedBody: Data([1, 2, 3]), kind: .envelope)
  }
  private func client(socket: FakeRelaySocket, recorder: RelayRecorder, needsUpgrade: Bool = false)
    throws -> RelayClient
  {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
    return try RelayClient(
      configuration: config(), deviceID: macID,
      factory: { _ in socket },
      signer: { challenge, config in
        try key.signature(for: challenge.signingBytes(configuration: config, deviceID: macID))
      },
      handlePacket: { packet in
        if needsUpgrade { throw RelayError.peerUpgradeRequired }
        recorder.packet(packet)
      }, publish: { recorder.status($0) }, transportEvent: { recorder.event($0) })
  }
  private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Relay did not reach expected state")
    throw RelayError.timeout
  }
}

private final class RelayRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var statusStorage: [RelayStatus] = []
  private var eventStorage: [RelayTransportEvent] = []
  private var packetStorage: [RelayPacket] = []
  var statuses: [RelayStatus] { lock.withLock { statusStorage } }
  var events: [RelayTransportEvent] { lock.withLock { eventStorage } }
  var packets: [RelayPacket] { lock.withLock { packetStorage } }
  func status(_ value: RelayStatus) { lock.withLock { statusStorage.append(value) } }
  func event(_ value: RelayTransportEvent) { lock.withLock { eventStorage.append(value) } }
  func packet(_ value: RelayPacket) { lock.withLock { packetStorage.append(value) } }
}

private final class FakeRelaySocket: RelaySocket, @unchecked Sendable {
  enum Mode { case normal, badNonce, prematureReady }
  private let lock = NSLock()
  private let mode: Mode
  private var queue: [Data] = []
  private var waiter: CheckedContinuation<Data, Error>?
  private var sentStorage: [RelayFrame] = []
  private var closed = false
  private var verified = false
  init(mode: Mode = .normal) { self.mode = mode }
  var sent: [RelayFrame] { lock.withLock { sentStorage } }
  var signatureVerified: Bool { lock.withLock { verified } }
  var isClosed: Bool { lock.withLock { closed } }
  func send(_ data: Data) async throws {
    let frame = try RelayFrame.decode(data)
    lock.withLock { sentStorage.append(frame) }
    switch frame {
    case .hello(_, let nonce):
      if mode == .prematureReady {
        inject(.ready(deviceID: macID, sessionID: sessionID))
        return
      }
      inject(
        .challenge(
          RelayChallenge(
            relayID: "mini-test", sessionID: sessionID,
            clientNonce: mode == .badNonce ? Data(repeating: 0, count: 32) : nonce,
            challenge: Data(repeating: 0x66, count: 32),
            expiresAt: UInt64(Date().timeIntervalSince1970) + 20)))
    case .authenticate(let device, let challenge, let signature):
      let key = try Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(repeating: 0x22, count: 32))
      let config = try RelayConfiguration(url: "wss://relay.example/v1/relay", relayID: "mini-test")
      let valid = try key.publicKey.isValidSignature(
        signature, for: challenge.signingBytes(configuration: config, deviceID: device))
      lock.withLock { verified = valid }
      inject(valid ? .ready(deviceID: device, sessionID: challenge.sessionID) : .authRejected)
    default: break
    }
  }
  func receive() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        if closed {
          continuation.resume(throwing: URLError(.networkConnectionLost))
        } else if !queue.isEmpty {
          continuation.resume(returning: queue.removeFirst())
        } else {
          precondition(waiter == nil)
          waiter = continuation
        }
      }
    }
  }
  func inject(_ frame: RelayFrame) {
    lock.withLock {
      guard !closed else { return }
      if let continuation = waiter {
        waiter = nil
        continuation.resume(returning: frame.encode())
      } else {
        queue.append(frame.encode())
      }
    }
  }
  func ping() async throws {}
  func close() {
    lock.withLock {
      closed = true
      waiter?.resume(throwing: URLError(.networkConnectionLost))
      waiter = nil
    }
  }
}

private final class SocketPool: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [FakeRelaySocket] = []
  var sockets: [FakeRelaySocket] { lock.withLock { storage } }
  func next() -> FakeRelaySocket {
    lock.withLock {
      let socket = FakeRelaySocket()
      storage.append(socket)
      return socket
    }
  }
}
