import Foundation

enum RelayStatus: Equatable, Sendable {
  case disabled, connecting, authenticating, connected, paused
  case retrying(Int)
  case blocked, upgradeRequired

  var title: String {
    switch self {
    case .disabled: "Relay not configured"
    case .connecting: "Connecting to Mac mini…"
    case .authenticating: "Authenticating relay connection…"
    case .connected: "Relay authenticated — message protocol upgrade pending"
    case .paused: "Relay paused"
    case .retrying(let attempt): "Relay reconnect \(attempt) of 8"
    case .blocked: "Relay unavailable — check configuration, enrollment, TLS and network"
    case .upgradeRequired: "Relay messages need upgraded peer keys and endpoint verification"
    }
  }
}

enum RelayTransportEvent: Sendable, Equatable {
  // Neither of these is an endpoint delivery receipt.
  case forwarded(messageID: String)
  case unavailable(messageID: String)
}

actor RelayClient {
  typealias Factory = @Sendable (RelayConfiguration) throws -> any RelaySocket
  typealias Signer = @Sendable (RelayChallenge, RelayConfiguration) async throws -> Data
  typealias PacketHandler = @Sendable (RelayPacket) async throws -> Void

  private let configuration: RelayConfiguration
  private let deviceID: String
  private let factory: Factory
  private let signer: Signer
  private let handlePacket: PacketHandler
  private let publish: @Sendable (RelayStatus) -> Void
  private let transportEvent: @Sendable (RelayTransportEvent) -> Void
  private let retryDelay: @Sendable (Int) -> Duration
  private var runner: Task<Void, Never>?
  private var socket: (any RelaySocket)?
  private var generation: UInt64 = 0
  private var connectionRevision: UInt64 = 0
  private var connected = false
  private var writing = false
  private struct Pending {
    let digest: Data
    var attempts: Int
  }
  private var pending: [String: Pending] = [:]

  init(
    configuration: RelayConfiguration, deviceID: String,
    factory: @escaping Factory = { URLSessionRelaySocket(configuration: $0) },
    signer: @escaping Signer, handlePacket: @escaping PacketHandler,
    publish: @escaping @Sendable (RelayStatus) -> Void,
    transportEvent: @escaping @Sendable (RelayTransportEvent) -> Void = { _ in },
    retryDelay: @escaping @Sendable (Int) -> Duration = { attempt in
      .milliseconds(
        Int(Double(min(60_000, 1000 << min(attempt - 1, 6))) * Double.random(in: 0.5...1)))
    }
  ) throws {
    try uuid(deviceID)
    self.configuration = configuration
    self.deviceID = deviceID
    self.factory = factory
    self.signer = signer
    self.handlePacket = handlePacket
    self.publish = publish
    self.transportEvent = transportEvent
    self.retryDelay = retryDelay
  }

  func start() {
    guard runner == nil else { return }
    generation &+= 1
    let token = generation
    runner = Task { await run(token: token) }
  }

  func stop() {
    generation &+= 1
    runner?.cancel()
    runner = nil
    socket?.close()
    socket = nil
    connected = false
    writing = false
    pending.removeAll()
    publish(.paused)
  }

  // Caller retains prepared bytes for retries; no automatic re-encryption or
  // volatile transport queue masquerades as a durable outbox. Only one write
  // is outstanding. Relay forwarding notifications are bounded to 32 entries.
  func sendPrepared(_ packet: RelayPacket) async throws {
    guard connected, let socket else { throw RelayError.notConnected }
    guard packet.senderID == deviceID else { throw RelayError.authentication }
    guard !writing, pending.values.reduce(0, { $0 + $1.attempts }) < 32 else {
      throw RelayError.backpressure
    }
    if let previous = pending[packet.messageID], previous.digest != packet.digest {
      throw RelayError.malformedFrame
    }
    let token = generation
    let revision = connectionRevision
    writing = true
    pending[packet.messageID] = Pending(
      digest: packet.digest, attempts: (pending[packet.messageID]?.attempts ?? 0) + 1)
    defer { if generation == token, connectionRevision == revision { writing = false } }
    do {
      try await relayDeadline(.seconds(10), socket: socket) {
        try await socket.send(RelayFrame.submit(packet).encode())
      }
      try check(token)
      guard revision == connectionRevision else { throw RelayError.stopped }
    } catch {
      // A failed write can still have reached the relay. Keep the sender's
      // outcome unknown; close and reauthenticate before any further writes.
      if generation == token, connectionRevision == revision {
        connected = false
        socket.close()
      }
      throw error
    }
  }

  private func check(_ token: UInt64) throws {
    guard token == generation, !Task.isCancelled else { throw RelayError.stopped }
  }

  private func run(token: UInt64) async {
    var failures = 0
    while token == generation, !Task.isCancelled {
      let began = ContinuousClock.now
      do {
        publish(.connecting)
        let connection = try factory(configuration)
        connectionRevision &+= 1
        socket = connection
        defer { connection.close() }
        try await session(connection, token: token)
      } catch {
        guard token == generation, !Task.isCancelled else { return }
        connected = false
        writing = false
        pending.removeAll()
        if let error = error as? RelayError, error != .timeout {
          publish(error == .peerUpgradeRequired ? .upgradeRequired : .blocked)
          runner = nil
          return
        }
        if let error = error as? URLError,
          [
            .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected,
            .clientCertificateRequired, .userAuthenticationRequired,
          ].contains(error.code)
        {
          publish(.blocked)
          runner = nil
          return
        }
        if began.duration(to: .now) > .seconds(60) { failures = 0 }
        failures += 1
        guard failures <= 8 else {
          publish(.blocked)
          runner = nil
          return
        }
        publish(.retrying(failures))
        do { try await Task.sleep(for: retryDelay(failures)) } catch { return }
      }
    }
  }

  private func session(_ socket: any RelaySocket, token: UInt64) async throws {
    let nonce = try random(32)
    publish(.authenticating)
    // One absolute deadline covers hello, challenge, local signing and ready.
    let configuration = configuration
    let deviceID = deviceID
    let signer = signer
    try await relayDeadline(.seconds(10), socket: socket) {
      try await socket.send(RelayFrame.hello(deviceID: deviceID, nonce: nonce).encode())
      guard case .challenge(let challenge) = try RelayFrame.decode(await socket.receive()) else {
        throw RelayError.authentication
      }
      try challenge.validate(configuration: configuration, nonce: nonce)
      let signature = try await signer(challenge, configuration)
      try Task.checkCancellation()
      try challenge.validate(configuration: configuration, nonce: nonce)
      guard signature.count == 64 else { throw RelayError.authentication }
      try await socket.send(
        RelayFrame.authenticate(deviceID: deviceID, challenge: challenge, signature: signature)
          .encode())
      guard
        case .ready(let readyDevice, let readySession) = try RelayFrame.decode(
          await socket.receive()),
        readyDevice == deviceID, readySession == challenge.sessionID
      else { throw RelayError.authentication }
    }
    try check(token)
    connected = true
    publish(.connected)
    let heartbeat = Task {
      do {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(25))
          try await relayDeadline(.seconds(10), socket: socket) { try await socket.ping() }
        }
      } catch {
        if !Task.isCancelled { socket.close() }
      }
    }
    defer { heartbeat.cancel() }
    while true {
      let frame = try RelayFrame.decode(await socket.receive())
      try check(token)
      switch frame {
      case .deliver(let packet):
        guard packet.recipientID == deviceID else { throw RelayError.authentication }
        // Await processing to apply backpressure. Never send an automatic
        // endpoint receipt, expose plaintext, or trust a relay-provided key.
        try await handlePacket(packet)
        try check(token)
      case .forwarded(let id, let digest), .unavailable(let id, let digest):
        guard var outstanding = pending[id], outstanding.digest == digest else {
          throw RelayError.malformedFrame
        }
        outstanding.attempts -= 1
        if outstanding.attempts == 0 {
          pending.removeValue(forKey: id)
        } else {
          pending[id] = outstanding
        }
        if case .forwarded = frame {
          transportEvent(.forwarded(messageID: id))
        } else {
          transportEvent(.unavailable(messageID: id))
        }
      case .authRejected: throw RelayError.authentication
      default: throw RelayError.malformedFrame
      }
    }
  }
}
