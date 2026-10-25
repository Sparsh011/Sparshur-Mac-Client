import Foundation
import Network

// NWConnection callbacks and the connection table stay on this one queue.
// Protocol work is awaited on EndpointService, never on the UI executor.
final class LocalHTTPServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.sparsh.Sparshur.http")
  private let service: EndpointService
  private let publish: @Sendable (ServiceEvent) -> Void
  private var listener: NWListener?
  private var generation = UUID()
  private var sessions: [UUID: Session] = [:]
  private let port: UInt16

  private final class Session {
    let connection: NWConnection
    var parser = HTTPRequestParser()
    var deadline: DispatchWorkItem?
    var task: Task<Void, Never>?
    var responding = false
    init(_ connection: NWConnection) { self.connection = connection }
  }

  init(
    service: EndpointService, port: UInt16 = 8787,
    publish: @escaping @Sendable (ServiceEvent) -> Void
  ) {
    self.service = service
    self.port = port
    self.publish = publish
  }

  func start() {
    queue.async { [self] in
      guard listener == nil else { return }
      generation = UUID()
      let current = generation
      do {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
          host: "0.0.0.0", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false
        let socket = try NWListener(using: parameters)
        listener = socket
        socket.newConnectionHandler = { [weak self] connection in
          self?.accept(connection, generation: current)
        }
        socket.stateUpdateHandler = { [weak self] state in
          guard let self, self.generation == current else { return }
          switch state {
          case .ready: self.publish(.status(.listening))
          case .failed(let error):
            let reason: String
            if case .posix(.EADDRINUSE) = error {
              reason = "Port 8787 is already in use"
            } else {
              reason = "Receiver unavailable — check network permission"
            }
            self.stopOnQueue()
            self.publish(.status(.failed(reason)))
          case .waiting: self.publish(.status(.failed("Waiting for local-network access")))
          default: break
          }
        }
        publish(.status(.starting))
        socket.start(queue: queue)
      } catch { publish(.status(.failed("Could not create the native listener"))) }
    }
  }

  func stop() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        stopOnQueue()
        continuation.resume()
      }
    }
  }
  private func stopOnQueue() {
    generation = UUID()
    listener?.stateUpdateHandler = nil
    listener?.cancel()
    listener = nil
    for session in sessions.values {
      session.deadline?.cancel()
      session.task?.cancel()
      session.connection.cancel()
    }
    sessions.removeAll()
  }
  private func accept(_ connection: NWConnection, generation current: UUID) {
    guard current == generation, sessions.count < 8,
      case .hostPort(let host, _) = connection.endpoint,
      case .ipv4(let address) = host,
      Self.allowedPeer(String(describing: address))
    else {
      connection.cancel()
      return
    }
    let id = UUID()
    let session = Session(connection)
    sessions[id] = session
    let deadline = DispatchWorkItem { [weak self] in
      self?.respond(.failure(408), id: id, generation: current)
    }
    session.deadline = deadline
    queue.asyncAfter(deadline: .now() + 5, execute: deadline)
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.finish(id) }
    }
    connection.start(queue: queue)
    receive(id, generation: current)
  }
  static func allowedPeer(_ host: String) -> Bool {
    localHost(host)
      || (host.hasPrefix("127.") && host.split(separator: ".").count == 4
        && host.split(separator: ".").allSatisfy { part in
          guard let n = Int(part), (0...255).contains(n) else { return false }
          return String(n) == part
        })
  }
  private func receive(_ id: UUID, generation current: UUID) {
    guard let session = sessions[id], current == generation else { return }
    session.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, complete, error in
      guard let self, self.generation == current, let session = self.sessions[id],
        !session.responding
      else { return }
      do {
        if let data, let request = try session.parser.append(data, port: self.port) {
          session.task = Task { [weak self, service = self.service] in
            guard !Task.isCancelled else { return }
            let response = await service.handle(request)
            self?.queue.async { [weak self] in self?.respond(response, id: id, generation: current)
            }
          }
        } else if complete || error != nil {
          self.respond(.failure(400), id: id, generation: current)
        } else {
          self.receive(id, generation: current)
        }
      } catch let failure as HTTPFailure {
        self.respond(.failure(failure.status), id: id, generation: current)
      } catch { self.respond(.failure(400), id: id, generation: current) }
    }
  }
  private func respond(_ response: EndpointResponse, id: UUID, generation current: UUID) {
    guard current == generation, let session = sessions[id], !session.responding else { return }
    session.responding = true
    session.deadline?.cancel()
    let reasons = [
      200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
      405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict", 411: "Length Required",
      413: "Payload Too Large", 415: "Unsupported Media Type", 431: "Headers Too Large",
      503: "Unavailable",
    ]
    let headers =
      "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
    session.connection.send(
      content: Data(headers.utf8) + response.body,
      completion: .contentProcessed { [weak self] _ in
        self?.finish(id)
      })
    // Bound send completion too; a peer that stops reading cannot retain a slot.
    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard self?.generation == current else { return }
      self?.finish(id)
    }
  }
  private func finish(_ id: UUID) {
    guard let session = sessions.removeValue(forKey: id) else { return }
    session.deadline?.cancel()
    session.task?.cancel()
    session.connection.stateUpdateHandler = nil
    session.connection.cancel()
  }
}
