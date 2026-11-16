import Darwin
import Foundation

// Socket callbacks and the connection table stay on this one queue.
// Protocol work is awaited on EndpointService, never on the UI executor.
final class LocalHTTPServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.sparsh.Sparshur.http")
  private let service: EndpointService
  private let publish: @Sendable (ServiceEvent) -> Void
  private var listener: DispatchSourceRead?
  private var generation = UUID()
  private var sessions: [UUID: Session] = [:]
  private let port: UInt16

  private final class Session {
    let channel: DispatchIO
    let overPrivateVPN: Bool
    var parser = HTTPRequestParser()
    var deadline: DispatchWorkItem?
    var task: Task<Void, Never>?
    var responding = false
    init(_ channel: DispatchIO, overPrivateVPN: Bool) {
      self.channel = channel
      self.overPrivateVPN = overPrivateVPN
    }
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
      publish(.status(.starting))
      do {
        let socket = try Self.openListener(port: port)
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(from: socket, generation: current) }
        source.setCancelHandler { close(socket) }
        listener = source
        source.activate()
        publish(.status(.listening))
      } catch let error as POSIXError where error.code == .EADDRINUSE {
        publish(.status(.failed("Port \(port) is already in use")))
      } catch { publish(.status(.failed("Receiver unavailable — check network permission"))) }
    }
  }

  func stop() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        generation = UUID()
        for id in Array(sessions.keys) { finish(id) }
        guard let listener else {
          continuation.resume()
          return
        }
        let socket = Int32(listener.handle)
        listener.setCancelHandler {
          close(socket)
          continuation.resume()
        }
        listener.cancel()
        self.listener = nil
      }
    }
  }

  private static func openListener(port: UInt16) throws -> Int32 {
    // Use a BSD socket so one IPv4 listener serves LAN, loopback, and the VPN.
    // Network.framework timed out on this Mac's utun address even when bound to it.
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    var reuse: Int32 = 1
    guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
      fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
      setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        == 0,
      address.withSocketAddress({ bind(descriptor, $0, $1.pointee) }) == 0,
      listen(descriptor, 8) == 0
    else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      close(descriptor)
      throw error
    }
    return descriptor
  }

  private func accept(from listener: Int32, generation current: UUID) {
    guard current == generation else { return }
    // Bound work per callback so queued deadlines get a chance to run.
    for _ in 0..<8 {
      var address = sockaddr_in()
      let descriptor = address.withSocketAddress { Darwin.accept(listener, $0, $1) }
      if descriptor < 0 {
        if errno == EINTR { continue }
        return
      }
      openSession(descriptor, peer: address.host, generation: current)
    }
  }
  private func openSession(_ descriptor: Int32, peer: String, generation current: UUID) {
    let overPrivateVPN = privateVPNHost(peer)
    var noSignal: Int32 = 1
    guard sessions.count < 8,
      overPrivateVPN ? Self.isVPNConnection(descriptor) : Self.allowedPeer(peer),
      fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
      setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    else {
      close(descriptor)
      return
    }
    let id = UUID()
    let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
      close(descriptor)
    }
    channel.setLimit(lowWater: 1)
    channel.setLimit(highWater: 4096)
    let session = Session(channel, overPrivateVPN: overPrivateVPN)
    sessions[id] = session
    let deadline = DispatchWorkItem { [weak self] in
      self?.respond(.failure(408), id: id, generation: current)
    }
    session.deadline = deadline
    queue.asyncAfter(deadline: .now() + 5, execute: deadline)
    receive(id, generation: current)
  }
  static func allowedPeer(_ host: String) -> Bool {
    localHost(host) || ipv4Octets(host)?.first == 127
  }
  private static func isVPNConnection(_ descriptor: Int32) -> Bool {
    // Shared IPv4 space also exists outside VPNs. Match the actual destination.
    var address = sockaddr_in()
    guard address.withSocketAddress({ getsockname(descriptor, $0, $1) }) == 0 else { return false }
    return allowedVPNDestination(address.host, addresses: (try? LocalAddress.discover()) ?? [])
  }
  static func allowedVPNDestination(_ host: String, addresses: [LocalAddress]) -> Bool {
    return addresses.contains { $0.isPrivateVPN && $0.host == host }
  }
  private func receive(_ id: UUID, generation current: UUID) {
    guard let session = sessions[id], current == generation else { return }
    let limit = HTTPRequestParser.maxHeaders + HTTPRequestParser.maxFileBody + 1
    session.channel.read(offset: 0, length: limit, queue: queue) { [weak self] done, data, error in
      guard let self, self.generation == current, let session = self.sessions[id],
        !session.responding, session.task == nil
      else { return }
      do {
        let startedFile = session.parser.receivesFile
        let request = try data.flatMap { try session.parser.append(Data($0), port: self.port) }
        if !startedFile, session.parser.receivesFile {
          session.deadline?.cancel()
          let deadline = DispatchWorkItem { [weak self] in
            self?.respond(.failure(408), id: id, generation: current)
          }
          session.deadline = deadline
          self.queue.asyncAfter(deadline: .now() + 30, execute: deadline)
        }
        if let request {
          let overPrivateVPN = session.overPrivateVPN
          session.task = Task { [weak self, service = self.service] in
            guard !Task.isCancelled else { return }
            let response = await service.handle(request, overPrivateVPN: overPrivateVPN)
            self?.queue.async { [weak self] in self?.respond(response, id: id, generation: current)
            }
          }
        } else if done || error != 0 {
          self.respond(.failure(400), id: id, generation: current)
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
    let bytes = (Data(headers.utf8) + response.body).withUnsafeBytes { DispatchData(bytes: $0) }
    session.channel.write(offset: 0, data: bytes, queue: queue) { [weak self] done, _, error in
      if done || error != 0 { self?.finish(id) }
    }
    // Bound send completion too; a peer that stops reading cannot retain a slot.
    queue.asyncAfter(deadline: .now() + (response.body.count > HTTPRequestParser.maxBody ? 30 : 5))
    { [weak self] in
      guard self?.generation == current else { return }
      self?.finish(id)
    }
  }
  private func finish(_ id: UUID) {
    guard let session = sessions.removeValue(forKey: id) else { return }
    session.deadline?.cancel()
    session.task?.cancel()
    session.channel.close(flags: .stop)
  }
}

extension sockaddr_in {
  fileprivate mutating func withSocketAddress<T>(
    _ body: (UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> T
  ) -> T {
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    return withUnsafeMutablePointer(to: &self) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, &length) }
    }
  }

  fileprivate var host: String {
    let ip = UInt32(bigEndian: sin_addr.s_addr)
    return [24, 16, 8, 0].map { String((ip >> $0) & 255) }.joined(separator: ".")
  }
}
