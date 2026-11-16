import Foundation
import XCTest

@testable import SparshurPlatform

final class PlatformTests: XCTestCase {
  func testOnlyCanonicalPrivateIPv4AddressesAreOffered() {
    for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.100"] {
      XCTAssertTrue(LocalAddress.isPrivateIPv4(host), host)
    }
    for host in [
      "0.0.0.0", "127.0.0.1", "8.8.8.8", "169.254.1.1", "172.15.0.1", "172.32.0.1",
      "192.169.1.1", "10.256.0.1", "10.00.0.1", "10.0.0", "10.0.0.1.", "::1", "10.0.0.-1",
      "+10.0.0.1",
    ] {
      XCTAssertFalse(LocalAddress.isPrivateIPv4(host), host)
    }
  }

  func testPrivateVPNAddressesUseCanonicalSharedIPv4Space() {
    for host in ["100.64.0.0", "100.127.255.255"] {
      XCTAssertTrue(privateVPNHost(host), host)
      XCTAssertFalse(LocalAddress.isPrivateIPv4(host), host)
    }
    for host in ["100.63.255.255", "100.128.0.0", "100.064.0.1", "100.65.256.0", "::1"] {
      XCTAssertFalse(privateVPNHost(host), host)
    }
  }

  func testEmulatorChoiceIsExplicitAndSeparateFromAnInterface() {
    XCTAssertTrue(LocalAddress.emulator.isEmulator)
    XCTAssertEqual(LocalAddress.emulator.host, "10.0.2.2")
    XCTAssertNotEqual(
      LocalAddress.emulator.id,
      LocalAddress(interface: "en0", host: "10.0.2.2", isEmulator: false).id)
  }

  func testLegacyPublicFingerprintMatchesFrozenAndroidInteropFixture() throws {
    // PUBLIC fixture seeds from Android spec/paired-test-vectors.json.
    let data = try JSONSerialization.data(withJSONObject: fixture())
    let summary = try PublicIdentity.read(from: data)
    XCTAssertEqual(summary.recipientID, "33333333-3333-4333-8333-333333333333")
    XCTAssertEqual(
      summary.fingerprint, "0b586e4a729968b321ffc949fc7088b8c50041639d830e675f29ac1da8ead8b8")
    XCTAssertNil(summary.senderID)
    XCTAssertNil(summary.highestCounter)
  }

  func testSavedPairingReportsPublicCounter() throws {
    var state = fixture()
    state["pair"] = ["sender_id": "22222222-2222-4222-8222-222222222222", "highest": 97]
    let data = try JSONSerialization.data(withJSONObject: state, options: .sortedKeys)
    let summary = try PublicIdentity.read(from: data)
    XCTAssertEqual(summary.senderID, "22222222-2222-4222-8222-222222222222")
    XCTAssertEqual(summary.highestCounter, 97)
  }

  func testMalformedIdentityDoesNotBecomeFreshIdentity() throws {
    for name in ["recipient_id", "hpke_seed", "signing_seed"] {
      var state = fixture()
      state[name] = "invalid"
      XCTAssertThrowsError(
        try PublicIdentity.read(from: JSONSerialization.data(withJSONObject: state)))
    }
    XCTAssertThrowsError(try PublicIdentity.read(from: Data("{}".utf8)))
    XCTAssertThrowsError(try PublicIdentity.read(from: Data("broken".utf8)))
  }

  func testMalformedReplayCounterIsNotPresentedAsValidMigrationState() throws {
    let invalidCounters: [Any] = [true, -1, 1.5, 1_000_001, "12", NSNull()]
    for counter in invalidCounters {
      var state = fixture()
      state["pair"] = ["sender_id": "22222222-2222-4222-8222-222222222222", "highest": counter]
      XCTAssertThrowsError(
        try PublicIdentity.read(from: JSONSerialization.data(withJSONObject: state)))
    }
  }

  private func fixture() -> [String: Any] {
    [
      "recipient_id": "33333333-3333-4333-8333-333333333333",
      "hpke_seed": Data(repeating: 0x11, count: 32).base64EncodedString(),
      "signing_seed": Data(repeating: 0x22, count: 32).base64EncodedString(),
    ]
  }
}
