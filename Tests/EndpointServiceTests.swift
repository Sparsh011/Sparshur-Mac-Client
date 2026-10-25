import CryptoKit
import Foundation
import XCTest

@testable import SparshurPlatform

private final class EventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ServiceEvent] = []
  func append(_ event: ServiceEvent) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(event)
  }
  var observations: [LocalObservation] {
    lock.lock()
    defer { lock.unlock() }
    return storage.compactMap {
      if case .observation(let value) = $0 { return value }
      return nil
    }
  }
}

final class EndpointServiceTests: XCTestCase {
  func testNativePairingAcceptsFullLocallyGeneratedPNG() async throws {
    let service = EndpointService(store: try fixtureStore(), publish: { _ in })
    try await service.activate()
    let code = try await service.createPairing(host: "10.0.2.2")
    XCTAssertFalse(code.png.isEmpty)
    XCTAssertEqual(try object(utf8(code.bundle))["host"] as? String, "10.0.2.2")
    XCTAssertTrue(code.expiresAt > .now)
    await service.cancelPairing()
  }
  func testOnlyTypedReceiptCrossesNetworkAndDuplicatesDoNotRedisplay() async throws {
    let memory = try fixtureStore()
    let reference = try Endpoint(memory)
    let android = Curve25519.Signing.PrivateKey()
    let (code, request) = try testPair(reference, android)
    let bundle = try object(utf8(text(code, "bundle")))
    _ = try reference.pair(request, now: 1_000_000_001)
    let copied = MemoryStore()
    copied.data = memory.data
    let recorder = EventRecorder()
    let service = EndpointService(store: copied, publish: { recorder.append($0) })
    try await service.activate()
    let message = try testMessage(bundle, android, 1)
    let input = HTTPRequest(method: "POST", path: "/paired-message", body: try json(message))
    let response = await service.handle(input)
    XCTAssertEqual(response.status, 202)
    let receipt = try object(response.body)
    try fields(receipt, "accepted duplicate message_id pairing_id counter digest signature")
    XCTAssertNil(receipt["decrypted_text"])
    XCTAssertEqual(recorder.observations.count, 1)
    XCTAssertNotNil(recorder.observations.first?.plaintext)
    XCTAssertEqual(recorder.observations.first?.stages.last, "Receipt signed")
    let retry = await service.handle(input)
    XCTAssertEqual(retry.status, 200)
    XCTAssertEqual(try object(retry.body)["duplicate"] as? Bool, true)
    XCTAssertEqual(recorder.observations.count, 1)
    var bad = message
    bad["counter"] = true
    let rejected = await service.handle(
      HTTPRequest(method: "POST", path: "/paired-message", body: try json(bad)))
    XCTAssertEqual(rejected.status, 400)
    XCTAssertEqual(recorder.observations.count, 1)
    await service.deactivate()
    let paused = await service.handle(input)
    XCTAssertEqual(paused.status, 503)
  }

  func testComparisonIsSeparateAndConflictingIDsFail() async throws {
    let recorder = EventRecorder()
    let service = EndpointService(store: try fixtureStore(), publish: { recorder.append($0) })
    try await service.activate()
    var sample: Object = [
      "lab_version": 1, "mode": "plaintext", "message_id": UUID().uuidString.lowercased(),
      "text": "Invented comparison sample",
    ]
    let first = await service.handle(
      HTTPRequest(method: "POST", path: "/message", body: try json(sample)))
    XCTAssertEqual(first.status, 202)
    XCTAssertEqual(recorder.observations.first?.kind, .readable)
    XCTAssertFalse(String(decoding: first.body, as: UTF8.self).contains("Invented"))
    sample["text"] = "Changed sample"
    let conflict = await service.handle(
      HTTPRequest(method: "POST", path: "/message", body: try json(sample)))
    XCTAssertEqual(conflict.status, 409)
    XCTAssertEqual(recorder.observations.count, 1)
  }

  @MainActor
  func testAppModelOwnsOneListenerAcrossNavigationAndPauseResume() async throws {
    let receiver = ReceiverCoordinator(
      store: try fixtureStore(), port: 18787, relayEnvironment: [:])
    let model = AppModel(receiver: receiver)
    model.beginSession()
    try await wait { model.receiverStatus == .listening }
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18787/health"))
    let (_, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    model.addresses = [.emulator]
    model.selectedAddressID = LocalAddress.emulator.id
    await model.createPairing()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNotNil(model.pairingCode)
    let revision = model.pairingCode?.revision
    model.destination = .learn
    model.beginSession()  // A reopened window must not start another service.
    model.destination = .pairPhone
    XCTAssertEqual(model.pairingCode?.revision, revision)
    let (_, again) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((again as? HTTPURLResponse)?.statusCode, 200)
    await model.sleep()
    XCTAssertNil(model.pairingCode)
    try await wait { model.receiverStatus == .paused }
    await model.wake()
    try await wait { model.receiverStatus == .listening }
    let (_, resumed) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((resumed as? HTTPURLResponse)?.statusCode, 200)
    await model.shutdown()
  }

  @MainActor
  private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("Native receiver did not reach its expected lifecycle state")
    throw Rejected.state
  }
}

private final class ControlledStore: ProtectedStore, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data
  private var fail = false
  init(_ data: Data) { self.data = data }
  func rejectWrites(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    fail = value
  }
  func load() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
  func save(_ value: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !fail else { throw Rejected.keychain }
    data = value
  }
}

extension EndpointServiceTests {
  func testStorageFailureNeverPublishesPlaintextOrSuccess() async throws {
    let memory = try fixtureStore()
    let endpoint = try Endpoint(memory)
    let android = Curve25519.Signing.PrivateKey()
    let (code, request) = try testPair(endpoint, android)
    _ = try endpoint.pair(request, now: 1_000_000_001)
    let store = ControlledStore(try XCTUnwrap(memory.data))
    let recorder = EventRecorder()
    let service = EndpointService(store: store, publish: { recorder.append($0) })
    try await service.activate()
    let message = try testMessage(object(utf8(text(code, "bundle"))), android, 1)
    let input = HTTPRequest(method: "POST", path: "/paired-message", body: try json(message))
    store.rejectWrites(true)
    let failed = await service.handle(input)
    XCTAssertEqual(failed.status, 503)
    XCTAssertTrue(recorder.observations.isEmpty)
    XCTAssertNil(try object(failed.body)["decrypted_text"])
    store.rejectWrites(false)
    let retried = await service.handle(input)
    XCTAssertEqual(retried.status, 202)
    XCTAssertEqual(recorder.observations.count, 1)
  }
}
