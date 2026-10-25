import Foundation

struct HTTPRequest: Sendable {
  let method: String
  let path: String
  let body: Data
}

struct HTTPFailure: Error, Sendable {
  let status: Int
  init(_ status: Int = 400) { self.status = status }
}

// Exactly one HTTP/1.1 request per TCP connection, then Connection: close.
struct HTTPRequestParser {
  static let maxHeaders = 8192
  static let maxBody = 32768
  private var buffer = Data()
  private var headerEnd: Int?
  private var length = 0
  private var method = ""
  private var path = ""

  mutating func append(_ data: Data, port: UInt16) throws -> HTTPRequest? {
    guard buffer.count + data.count <= Self.maxHeaders + Self.maxBody else {
      throw HTTPFailure(413)
    }
    buffer.append(data)
    if headerEnd == nil {
      guard let framing = buffer.range(of: Data([13, 10, 13, 10])) else {
        if buffer.count > Self.maxHeaders { throw HTTPFailure(431) }
        return nil
      }
      let end = framing.upperBound
      guard end <= Self.maxHeaders,
        let headers = String(data: buffer.prefix(framing.lowerBound), encoding: .ascii)
      else { throw HTTPFailure(431) }
      let lines = headers.components(separatedBy: "\r\n")
      guard let first = lines.first else { throw HTTPFailure() }
      let parts = first.split(separator: " ", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[2] == "HTTP/1.1" else { throw HTTPFailure() }
      method = String(parts[0])
      path = String(parts[1])
      guard ["GET", "POST"].contains(method) else { throw HTTPFailure(405) }
      guard
        (method == "GET" && path == "/health")
          || (method == "POST"
            && ["/message", "/pairing/complete", "/paired-message"].contains(path))
      else { throw HTTPFailure(404) }
      var values: [String: String] = [:]
      for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
          line.first != " ", line.first != "\t"
        else { throw HTTPFailure() }
        let key = String(line[..<colon]).lowercased()
        guard
          key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
          values[key] == nil
        else { throw HTTPFailure() }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
          throw HTTPFailure()
        }
        values[key] = value
      }
      guard let host = values["host"], !host.isEmpty else { throw HTTPFailure() }
      guard values["transfer-encoding"] == nil, values["expect"] == nil else { throw HTTPFailure() }
      if let origin = values["origin"],
        !["http://127.0.0.1:\(port)", "http://localhost:\(port)"].contains(origin)
      {
        throw HTTPFailure(403)
      }
      if let raw = values["content-length"] {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
          let parsed = Int(raw), parsed <= Self.maxBody
        else { throw HTTPFailure(413) }
        length = parsed
      } else if method == "POST" {
        throw HTTPFailure(411)
      }
      if method == "GET", length != 0 { throw HTTPFailure() }
      if method == "POST" {
        guard length > 0 else { throw HTTPFailure() }
        let type = values["content-type"]?.lowercased().split(
          separator: ";", omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let type, type.first == "application/json", type.count <= 2,
          type.count == 1 || ["charset=utf-8", "charset=\"utf-8\""].contains(type[1])
        else { throw HTTPFailure(415) }
      }
      headerEnd = end
    }
    guard let end = headerEnd else { return nil }
    guard buffer.count <= end + length else { throw HTTPFailure() }
    guard buffer.count == end + length else { return nil }
    return HTTPRequest(method: method, path: path, body: buffer.subdata(in: end..<buffer.count))
  }
}
