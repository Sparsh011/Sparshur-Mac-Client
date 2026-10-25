import CryptoKit
import Foundation
import XCTest

@testable import SparshurPlatform

final class NativeProtocolTests: XCTestCase {
  func testOriginalSwiftProtocolSuiteAgainstSharedCore() throws { try selfTests() }

  func testFrozenAndroidVectorDecryptsAndSignedReceiptMatches() throws {
    let fixture = try object(
      Data(
        contentsOf: XCTUnwrap(
          Bundle.module.url(
            forResource: "paired-test-vectors", withExtension: "json", subdirectory: "Fixtures"))))
    let bundle = try XCTUnwrap(fixture["bundle"] as? Object)
    let request = try XCTUnwrap(fixture["pair_request"] as? Object)
    let memory = try fixtureStore()
    var state = try object(XCTUnwrap(memory.data))
    var digestInput = request
    digestInput.removeValue(forKey: "signature")
    let t =
      try transcript(bundle) + "|" + text(request, "sender_id") + "|" + text(request, "sender_key")
    state["pair"] = [
      "pairing_id": try text(bundle, "pairing_id"), "sender_id": try text(request, "sender_id"),
      "sender_key": try text(request, "sender_key"), "highest": 0, "seen": [],
      "request_digest": Data(SHA256.hash(data: try json(digestInput))).base64EncodedString(),
      "transcript": t, "ack": fixture["pair_ack"]!,
    ]
    memory.data = try json(state)
    let endpoint = try Endpoint(memory, allowCreate: false)
    XCTAssertEqual(
      try json(endpoint.pair(request)), try json(XCTUnwrap(fixture["pair_ack"] as? Object)))
    let message = try XCTUnwrap(fixture["message"] as? Object)
    let result = try endpoint.receive(message)
    XCTAssertEqual(result["decrypted_text"] as? String, fixture["plaintext"] as? String)
    let receipt = try XCTUnwrap(result["receipt"] as? Object)
    var expected = try XCTUnwrap(fixture["receipt"] as? Object)
    var actual = receipt
    expected.removeValue(forKey: "signature")
    actual.removeValue(forKey: "signature")
    XCTAssertEqual(try json(actual), try json(expected))
    let signed =
      "bridge-v2/receipt|\(try text(receipt, "pairing_id"))|\(try text(receipt, "message_id"))|\(try number(receipt, "counter"))|\(try text(receipt, "digest"))|0"
    let publicKey = try Curve25519.Signing.PublicKey(
      rawRepresentation: bytes(text(bundle, "signing_key"), 32...32))
    XCTAssertTrue(
      publicKey.isValidSignature(try bytes(text(receipt, "signature"), 64...64), for: utf8(signed)))
    let restarted = try Endpoint(memory, allowCreate: false)
    XCTAssertNil(try restarted.receive(message)["decrypted_text"])
    let duplicate = try XCTUnwrap(restarted.receive(message)["receipt"] as? Object)
    XCTAssertEqual(duplicate["duplicate"] as? Bool, true)
    var changed = message
    changed["counter"] = 2
    XCTAssertThrowsError(try restarted.receive(changed))
  }

  func testPersistenceFailureDoesNotCommitPairOrDiscloseMessage() throws {
    let backing = try fixtureStore()
    let store = FailingStore(data: try XCTUnwrap(backing.data))
    let endpoint = try Endpoint(store, allowCreate: false)
    let android = try Curve25519.Signing.PrivateKey(
      rawRepresentation: Data(repeating: 0x33, count: 32))
    let (created, request) = try testPair(endpoint, android)
    store.fail = true
    XCTAssertThrowsError(try endpoint.pair(request, now: 1_000_000_001))
    XCTAssertEqual(try endpoint.status()["paired"] as? Bool, false)
    store.fail = false
    _ = try endpoint.pair(request, now: 1_000_000_001)
    let message = try testMessage(object(utf8(text(created, "bundle"))), android, 1)
    let before = store.data
    store.fail = true
    XCTAssertThrowsError(try endpoint.receive(message))
    XCTAssertEqual(store.data, before)
    store.fail = false
    XCTAssertNotNil(try endpoint.receive(message)["decrypted_text"])
    XCTAssertNil(try Endpoint(store, allowCreate: false).receive(message)["decrypted_text"])
  }

  func testMissingIdentityNeverCreatesReplacementInNativeMode() {
    let store = MemoryStore()
    XCTAssertThrowsError(try Endpoint(store, allowCreate: false))
    XCTAssertNil(store.data)
  }

  func testReplacingQRAndCancellingInvalidateOldHandshake() throws {
    let endpoint = try Endpoint(fixtureStore())
    let android = Curve25519.Signing.PrivateKey()
    let (_, first) = try testPair(endpoint, android)
    let (_, second) = try testPair(endpoint, android)
    XCTAssertThrowsError(try endpoint.pair(first, now: 1_000_000_001))
    endpoint.cancelPairing()
    XCTAssertThrowsError(try endpoint.pair(second, now: 1_000_000_001))
  }
}

private final class FailingStore: ProtectedStore {
  var data: Data
  var fail = false
  init(data: Data) { self.data = data }
  func load() -> Data? { data }
  func save(_ data: Data) throws {
    guard !fail else { throw Rejected.keychain }
    self.data = data
  }
}
