import Foundation
import Network

actor ReceiverCoordinator {
  enum PairingError: Error { case vpnAddressUnavailable }

  nonisolated let events: AsyncStream<ServiceEvent>
  private let continuation: AsyncStream<ServiceEvent>.Continuation
  private let service: EndpointService
  private let server: LocalHTTPServer
  private var requested = false
  private var shuttingDown = false
  private var pathMonitor: NWPathMonitor?
  func queueFile(_ file: PairedFile) async throws {
    try await service.queueFile(file)
  }

  func cancelOutgoingFile() async { await service.cancelOutgoingFile() }

  private var relay: RelayClient?
  private let relayEnvironment: [String: String]

  init(
    store: sending ProtectedStore = KeychainStore(allowInsert: false, interactive: false),
    port: UInt16 = 8787,
    relayEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    let stream = AsyncStream<ServiceEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
    events = stream.stream
    continuation = stream.continuation
    let publish: @Sendable (ServiceEvent) -> Void = { stream.continuation.yield($0) }
    let endpoint = EndpointService(store: store, publish: publish)
    service = endpoint
    server = LocalHTTPServer(service: endpoint, port: port, publish: publish)
    self.relayEnvironment = relayEnvironment
  }
  func start() async {
    guard !shuttingDown, !requested else { return }
    requested = true
    if pathMonitor == nil {
      let monitor = NWPathMonitor()
      let continuation = continuation
      monitor.pathUpdateHandler = { _ in continuation.yield(.networkChanged) }
      monitor.start(queue: DispatchQueue(label: "com.sparsh.Sparshur.network-path"))
      pathMonitor = monitor
    }
    do {
      try await service.activate()
      guard requested else { return }
      server.start()
      await startRelay()
    } catch Rejected.identityInUse {
      requested = false
      continuation.yield(.status(.failed("Another recipient owns this identity — quit it first")))
    } catch Rejected.keychainStatus(let status) {
      requested = false
      continuation.yield(
        .status(
          .identityAccessRequired(
            "Keychain access required (OSStatus \(status)); identity preserved")))
    } catch Rejected.missingIdentity {
      requested = false
      continuation.yield(.status(.failed("Legacy identity is not visible; no replacement created")))
    } catch {
      requested = false
      continuation.yield(.status(.failed("Existing Keychain identity unavailable — check access")))
    }
  }
  func pause() async {
    requested = false
    await relay?.stop()
    await server.stop()
    await service.deactivate()
    continuation.yield(.status(.paused))
  }
  func authorizeIdentity() async {
    guard !shuttingDown, !requested else { return }
    requested = true
    do {
      try await service.authorizeIdentity()
      guard requested else { return }
      server.start()
      await startRelay()
    } catch {
      requested = false
      continuation.yield(
        .status(
          .identityAccessRequired("Keychain authorization did not complete; identity preserved")))
    }
  }
  func createPairing(at address: LocalAddress) async throws -> PairingCode {
    if address.isPrivateVPN, (try? LocalAddress.discover().contains(address)) != true {
      throw PairingError.vpnAddressUnavailable
    }
    return try await service.createPairing(host: address.host, overPrivateVPN: address.isPrivateVPN)
  }
  func stopAfterFailure() async {
    requested = false
    await relay?.stop()
    await server.stop()
    await service.deactivate()
  }
  func cancelPairing() async { await service.cancelPairing() }
  func tick() async { await service.expirePairing() }
  private func startRelay() async {
    guard requested else { return }
    guard let url = relayEnvironment["SPARSHUR_RELAY_URL"],
      let relayID = relayEnvironment["SPARSHUR_RELAY_ID"]
    else {
      continuation.yield(
        .relayStatus(
          relayEnvironment["SPARSHUR_RELAY_URL"] == nil
            && relayEnvironment["SPARSHUR_RELAY_ID"] == nil
            ? .disabled : .blocked))
      return
    }
    do {
      if relay == nil {
        let configuration = try RelayConfiguration(url: url, relayID: relayID)
        let deviceID = try await service.relayDeviceID()
        guard requested else { return }
        let service = service
        let continuation = continuation
        relay = try RelayClient(
          configuration: configuration, deviceID: deviceID,
          signer: { challenge, configuration in
            try await service.signRelayChallenge(challenge, configuration: configuration)
          },
          handlePacket: { _ in
            // Local paired-v2 lacks Android's authenticated receiving key.
            // Fail closed until relay E2EE pairing + endpoint storage land.
            throw RelayError.peerUpgradeRequired
          },
          publish: { continuation.yield(.relayStatus($0)) })
      }
      guard requested else { return }
      await relay?.start()
    } catch {
      continuation.yield(.relayStatus(.blocked))
    }
  }
  func shutdown() async {
    guard !shuttingDown else { return }
    shuttingDown = true
    pathMonitor?.cancel()
    pathMonitor = nil
    await pause()
    continuation.yield(.status(.stopped))
    continuation.finish()
  }
}
