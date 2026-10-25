import Foundation
import Security

protocol RelaySocket: Sendable {
  func send(_ data: Data) async throws
  func receive() async throws -> Data
  func ping() async throws
  func close()
}

// URLSession is thread-safe; immutable references are shared by the heartbeat,
// receive loop, and cancellation path. No custom trust or credential handler.
final class URLSessionRelaySocket: NSObject, RelaySocket, @unchecked Sendable {
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  private let delegate: RelaySessionDelegate

  init(configuration: RelayConfiguration) {
    let options = URLSessionConfiguration.ephemeral
    options.tlsMinimumSupportedProtocolVersion = .TLSv13
    options.httpCookieStorage = nil
    options.httpShouldSetCookies = false
    options.urlCredentialStorage = nil
    options.urlCache = nil
    options.requestCachePolicy = .reloadIgnoringLocalCacheData
    options.timeoutIntervalForRequest = 15
    // Lifetime is owned by the client; a WebSocket is expected to remain open.
    options.timeoutIntervalForResource = 86400
    delegate = RelaySessionDelegate(expectedURL: configuration.url)
    session = URLSession(configuration: options, delegate: delegate, delegateQueue: nil)
    var request = URLRequest(url: configuration.url)
    request.setValue("bridge.relay.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
    task = session.webSocketTask(with: request)
    task.maximumMessageSize = 65536
    super.init()
    task.resume()
  }

  func send(_ data: Data) async throws {
    guard data.count <= 65536 else { throw RelayError.malformedFrame }
    try await task.send(.data(data))
  }
  func receive() async throws -> Data {
    let message: URLSessionWebSocketTask.Message
    do { message = try await task.receive() } catch {
      if task.closeCode == .policyViolation { throw RelayError.authentication }
      if task.closeCode == .protocolError || task.closeCode == .unsupportedData
        || task.closeCode == .messageTooBig
      {
        throw RelayError.malformedFrame
      }
      throw error
    }
    guard case .data(let data) = message, data.count <= 65536 else {
      throw RelayError.malformedFrame
    }
    return data
  }
  func ping() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      task.sendPing { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }
  func close() {
    task.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
}

private final class RelaySessionDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
  let expectedURL: URL
  init(expectedURL: URL) { self.expectedURL = expectedURL }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    guard `protocol` == "bridge.relay.v1", webSocketTask.currentRequest?.url == expectedURL else {
      webSocketTask.cancel(with: .protocolError, reason: nil)
      return
    }
  }
}

// Cancellation alone need not resume a suspended socket operation. On timeout
// explicitly close its socket, which releases Foundation's pending continuations.
func relayDeadline<T: Sendable>(
  _ duration: Duration, socket: any RelaySocket,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      socket.close()
      throw RelayError.timeout
    }
    defer { group.cancelAll() }
    guard let value = try await group.next() else { throw RelayError.stopped }
    return value
  }
}
