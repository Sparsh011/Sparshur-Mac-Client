import AppKit
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

  func testVPNUsesPairedV2QRAndReceipt() async throws {
    let recorder = EventRecorder()
    let service = EndpointService(store: try fixtureStore(), publish: { recorder.append($0) })
    try await service.activate()
    let host = "100.90.20.10"
    let qr = try await service.createPairing(host: host, overPrivateVPN: true)
    let bundle = try object(utf8(qr.bundle))
    try fields(
      bundle,
      "bridge_pairing pairing_id recipient_id hpke_key signing_key host port expires_at secret")
    XCTAssertEqual(try number(bundle, "bridge_pairing"), 2)
    XCTAssertEqual(try text(bundle, "host"), host)
    XCTAssertEqual(try number(bundle, "port"), 8787)

    let android = Curve25519.Signing.PrivateKey()
    let completed = await service.handle(
      HTTPRequest(
        method: "POST", path: "/pairing/complete", body: try json(testPairRequest(bundle, android))),
      overPrivateVPN: true)
    XCTAssertEqual(completed.status, 200)
    let message = HTTPRequest(
      method: "POST", path: "/paired-message", body: try json(testMessage(bundle, android, 1)))
    let receipt = await service.handle(message, overPrivateVPN: true)
    XCTAssertEqual(receipt.status, 202)
    try fields(
      try object(receipt.body), "accepted duplicate message_id pairing_id counter digest signature")
    let retry = await service.handle(message, overPrivateVPN: true)
    XCTAssertEqual(try object(retry.body)["duplicate"] as? Bool, true)
    XCTAssertEqual(recorder.observations.count, 1)
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

  func testFileUploadAndPullUseVerifiedPairAndClearOnlyOnAcknowledgement() async throws {
    let recorder = EventRecorder()
    let service = EndpointService(store: try fixtureStore(), publish: { recorder.append($0) })
    try await service.activate()
    let qr = try await service.createPairing(host: "100.90.20.10", overPrivateVPN: true)
    let bundle = try object(utf8(qr.bundle))
    let android = Curve25519.Signing.PrivateKey()
    let paired = await service.handle(
      HTTPRequest(
        method: "POST", path: "/pairing/complete", body: try json(testPairRequest(bundle, android))),
      overPrivateVPN: true)
    XCTAssertEqual(paired.status, 200)

    let file = try PairedFile(
      name: "image.png", mime: "image/png", data: Data(repeating: 255, count: 64 * 1024))
    let message = try testMessage(bundle, android, 1, type: "file", payload: file.encode())
    let upload = HTTPRequest(method: "POST", path: "/paired-file", body: try json(message))
    let sent = await service.handle(upload, overPrivateVPN: true)
    XCTAssertEqual(sent.status, 202)
    try fields(
      try object(sent.body), "accepted duplicate message_id pairing_id counter digest signature")
    XCTAssertEqual(recorder.observations.first?.file?.data, file.data)
    let resent = await service.handle(upload, overPrivateVPN: true)
    XCTAssertEqual(try object(resent.body)["duplicate"] as? Bool, true)
    XCTAssertEqual(recorder.observations.count, 1)

    try await service.queueFile(file)
    let pullKey = try random(32)
    let pull = try testMessage(bundle, android, 2, type: "file_pull", payload: pullKey)
    let pulled = await service.handle(
      HTTPRequest(method: "POST", path: "/paired-file/pull", body: try json(pull)),
      overPrivateVPN: true)
    XCTAssertEqual(pulled.status, 200)
    let reply = try object(pulled.body)
    let id = try text(reply, "file_id")
    let sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(reply["sealed"] as? String)))
    let context = try
      "bridge-v2/file-response|\(text(bundle, "pairing_id"))|\(text(pull, "message_id"))|\(id)"
    let opened = try ChaChaPoly.open(
      ChaChaPoly.SealedBox(combined: sealed), using: SymmetricKey(data: pullKey),
      authenticating: utf8(context))
    XCTAssertEqual(try PairedFile.decode(opened).data, file.data)
    let verifyQueue = try testMessage(bundle, android, 3, type: "file_pull", payload: random(32))
    let queued = await service.handle(
      HTTPRequest(method: "POST", path: "/paired-file/pull", body: try json(verifyQueue)),
      overPrivateVPN: true)
    XCTAssertEqual(try text(object(queued.body), "file_id"), id)
    let ack = try testMessage(bundle, android, 4, type: "file_ack", payload: utf8(id))
    let acked = await service.handle(
      HTTPRequest(method: "POST", path: "/paired-file/ack", body: try json(ack)),
      overPrivateVPN: true)
    XCTAssertEqual(acked.status, 200)
    let next = try testMessage(bundle, android, 5, type: "file_pull", payload: random(32))
    let empty = await service.handle(
      HTTPRequest(method: "POST", path: "/paired-file/pull", body: try json(next)),
      overPrivateVPN: true)
    XCTAssertEqual(try text(object(empty.body), "file_id"), "")
  }

  func testComparisonIsSeparateAndConflictingIDsFail() async throws {
    let recorder = EventRecorder()
    let service = EndpointService(store: try fixtureStore(), publish: { recorder.append($0) })
    try await service.activate()
    var sample: Object = [
      "lab_version": 1, "mode": "plaintext", "message_id": UUID().uuidString.lowercased(),
      "text": "Invented comparison sample",
    ]
    let comparison = HTTPRequest(method: "POST", path: "/message", body: try json(sample))
    let vpnComparison = await service.handle(comparison, overPrivateVPN: true)
    XCTAssertEqual(vpnComparison.status, 404)
    XCTAssertTrue(recorder.observations.isEmpty)
    let first = await service.handle(comparison)
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
  func testVerifiedHTTPDeliveryCopiesOnlyTextAndImages() async throws {
    let memory = try fixtureStore()
    let endpoint = try Endpoint(memory)
    let android = Curve25519.Signing.PrivateKey()
    let (code, pairing) = try testPair(endpoint, android)
    let bundle = try object(utf8(text(code, "bundle")))
    _ = try endpoint.pair(pairing, now: 1_000_000_001)
    let message = try testMessage(bundle, android, 1)
    let restored = MemoryStore()
    restored.data = memory.data
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("Existing clipboard contents", forType: .string))

    let receiver = ReceiverCoordinator(store: restored, port: 18788, relayEnvironment: [:])
    let model = AppModel(receiver: receiver, pasteboard: pasteboard)
    addTeardownBlock { await model.shutdown() }
    model.beginSession()
    try await wait { model.receiverStatus == .listening }
    XCTAssertEqual(model.pairedSenderID, try text(pairing, "sender_id"))
    XCTAssertNil(model.lastContact)

    func send(_ payload: Object, to path: String) async throws -> Int? {
      let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18788\(path)"))
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try json(payload)
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode
    }

    var rejected = message
    rejected["counter"] = true
    let rejection = try await send(rejected, to: "/paired-message")
    XCTAssertEqual(rejection, 400)
    let comparison = try await send(
      [
        "lab_version": 1, "message_id": UUID().uuidString.lowercased(), "mode": "plaintext",
        "text": "Comparison text",
      ], to: "/message")
    XCTAssertEqual(comparison, 202)
    try await wait { model.comparisons.count == 1 && model.rejectedCount == 1 }
    XCTAssertNil(model.clipboardUpdate)
    XCTAssertNil(model.lastContact)
    XCTAssertEqual(pasteboard.string(forType: .string), "Existing clipboard contents")

    let accepted = try await send(message, to: "/paired-message")
    XCTAssertEqual(accepted, 202)
    try await wait { model.clipboardUpdate?.succeeded == true }
    let clip = try XCTUnwrap(model.verifiedMessages.first)
    XCTAssertEqual(pasteboard.string(forType: .string), clip.plaintext)
    let contact = try XCTUnwrap(model.lastContact)
    XCTAssertEqual(contact.senderID, model.pairedSenderID)
    XCTAssertFalse(contact.overPrivateVPN)

    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("Copied elsewhere", forType: .string))
    let retry = try await send(message, to: "/paired-message")
    XCTAssertEqual(retry, 200)
    try await wait { model.duplicateCount == 1 }
    XCTAssertEqual(model.verifiedMessages.count, 1)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.lastContact?.date), contact.date)
    XCTAssertEqual(pasteboard.string(forType: .string), "Copied elsewhere")

    model.copyToClipboard(clip)
    XCTAssertEqual(pasteboard.string(forType: .string), clip.plaintext)

    // A one-pixel red PNG. The clipboard should use the content type even when
    // Android supplied a generic MIME type.
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
      ))
    let files = [
      try PairedFile(name: "document.pdf", mime: "application/pdf", data: utf8("%PDF-1.4")),
      try PairedFile(name: "notes.txt", mime: "text/plain", data: utf8("Shared as a file")),
      try PairedFile(name: "broken.png", mime: "image/png", data: Data(png.prefix(24))),
    ]
    let changeCount = pasteboard.changeCount
    for (index, file) in files.enumerated() {
      let payload = try testMessage(
        bundle, android, index + 2, type: "file", payload: file.encode())
      let received = try await send(payload, to: "/paired-file")
      XCTAssertEqual(received, 202)
      try await wait { model.verifiedMessages.first?.file?.name == file.name }
      let observation = try XCTUnwrap(model.verifiedMessages.first)
      XCTAssertNil(observation.clipboardContent)
      XCTAssertEqual(observation.file?.data, file.data)
      model.copyToClipboard(observation)
      XCTAssertEqual(pasteboard.changeCount, changeCount)
      XCTAssertEqual(pasteboard.string(forType: .string), clip.plaintext)
    }

    let image = try PairedFile(name: "image.png", mime: "application/octet-stream", data: png)
    let imagePayload = try testMessage(bundle, android, 5, type: "file", payload: image.encode())
    let imageReceipt = try await send(imagePayload, to: "/paired-file")
    XCTAssertEqual(imageReceipt, 202)
    try await wait { model.verifiedMessages.first?.file?.name == image.name }
    XCTAssertEqual(pasteboard.data(forType: .png), png)
  }

  @MainActor
  func testAppLaunchRestoresPairingAndReceivesOnTheSamePortWithoutAWindow() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appending(path: "paired-state.json")
    let initial = try fixtureStore()
    let endpoint = try Endpoint(initial)
    let android = Curve25519.Signing.PrivateKey()
    let (code, pairing) = try testPair(endpoint, android)
    let bundle = try object(utf8(text(code, "bundle")))
    _ = try endpoint.pair(pairing, now: 1_000_000_001)
    try RestartStore(url: stateURL).save(try XCTUnwrap(initial.data))
    let sender = try text(pairing, "sender_id")
    let firstClip = try testMessage(bundle, android, 1)
    let nextClip = try testMessage(bundle, android, 2)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    func launch() -> AppDelegate {
      let receiver = ReceiverCoordinator(
        store: RestartStore(url: stateURL), port: 18789, relayEnvironment: [:])
      let delegate = AppDelegate(model: AppModel(receiver: receiver, pasteboard: pasteboard))
      addTeardownBlock {
        await delegate.model.shutdown()
        await delegate.applicationWillTerminate(
          Notification(name: NSApplication.willTerminateNotification))
      }
      delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification))
      return delegate
    }

    func deliver(_ message: Object) async throws -> (status: Int, receipt: Object) {
      let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18789/paired-message"))
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try json(message)
      let (data, response) = try await URLSession.shared.data(for: request)
      return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, try object(data))
    }

    let first = launch().model
    try await wait { first.receiverStatus == .listening }
    let accepted = try await deliver(firstClip)
    XCTAssertEqual(accepted.status, 202)
    try await wait { first.clipboardUpdate?.succeeded == true }
    let fingerprint = try XCTUnwrap(first.savedIdentity?.fingerprint)
    await first.shutdown()

    let reopened = launch().model
    try await wait { reopened.receiverStatus == .listening }
    XCTAssertEqual(reopened.savedIdentity?.fingerprint, fingerprint)
    XCTAssertEqual(reopened.pairedSenderID, sender)
    XCTAssertEqual(reopened.savedIdentity?.highestCounter, 1)
    XCTAssertNil(reopened.pairingCode)

    let retry = try await deliver(firstClip)
    XCTAssertEqual(retry.status, 200)
    XCTAssertEqual(retry.receipt["duplicate"] as? Bool, true)
    try await wait { reopened.duplicateCount == 1 }
    XCTAssertNil(reopened.clipboardUpdate)

    let next = try await deliver(nextClip)
    XCTAssertEqual(next.status, 202)
    try await wait { reopened.clipboardUpdate?.succeeded == true }
    XCTAssertEqual(reopened.savedIdentity?.highestCounter, 2)
    XCTAssertEqual(reopened.verifiedMessages.first?.id, try text(nextClip, "message_id"))
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

private final class RestartStore: ProtectedStore {
  let url: URL
  init(url: URL) { self.url = url }
  func load() throws -> Data? { try Data(contentsOf: url) }
  func save(_ data: Data) throws { try data.write(to: url, options: .atomic) }
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
