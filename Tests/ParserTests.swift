import Foundation
import XCTest

@testable import SparshurPlatform

final class ParserTests: XCTestCase {
  private func post(_ body: String = "{}", headers: String = "") -> Data {
    Data(
      "POST /paired-message HTTP/1.1\r\nHost: localhost:8787\r\nContent-Type: Application/JSON; charset=UTF-8\r\nContent-Length: \(body.utf8.count)\r\n\(headers)\r\n\(body)"
        .utf8)
  }
  func testPartialAndCoalescedReads() throws {
    let raw = post("{\"counter\":1}")
    for split in 1..<raw.count {
      var parser = HTTPRequestParser()
      XCTAssertNil(try parser.append(raw.prefix(split), port: 8787))
      let request = try XCTUnwrap(parser.append(raw.dropFirst(split), port: 8787))
      XCTAssertEqual(request.path, "/paired-message")
      XCTAssertEqual(request.body, Data("{\"counter\":1}".utf8))
    }
    var parser = HTTPRequestParser()
    for byte in raw.dropLast() { XCTAssertNil(try parser.append(Data([byte]), port: 8787)) }
    XCTAssertNotNil(try parser.append(Data([raw.last!]), port: 8787))
  }
  func testAmbiguousOrUnsupportedHTTPFailsClosed() {
    let failures: [Data] = [
      post(headers: "Content-Length: 2\r\n"), post(headers: "Transfer-Encoding: chunked\r\n"),
      post(headers: "Origin: https://evil.example\r\n"), post(headers: " Folded: value\r\n"),
      post() + Data("x".utf8), post() + post(),
      Data("POST /api/pairing/new HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}".utf8),
      Data("GET /health HTTP/1.1\r\n\r\n".utf8),
      Data("POST /message HTTP/1.1\r\nHost: localhost\r\nContent-Length: +2\r\n\r\n{}".utf8),
      Data(
        "POST /message HTTP/1.1\r\nHost: localhost\r\nContent-Length: 99999999999999999999999\r\n\r\n"
          .utf8),
      Data(
        "POST /message HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}"
          .utf8),
    ]
    for raw in failures {
      var parser = HTTPRequestParser()
      XCTAssertThrowsError(try parser.append(raw, port: 8787))
    }
  }
  func testLimitsAndPeerScope() {
    var headers = HTTPRequestParser()
    XCTAssertThrowsError(try headers.append(Data(repeating: 65, count: 8193), port: 8787))
    var body = HTTPRequestParser()
    XCTAssertThrowsError(try body.append(post(String(repeating: "a", count: 32769)), port: 8787))
    for peer in ["10.1.2.3", "192.168.1.1", "172.31.0.1", "127.0.0.2"] {
      XCTAssertTrue(LocalHTTPServer.allowedPeer(peer))
    }
    for peer in ["8.8.8.8", "::1", "0.0.0.0", "127.999.0.1", "10.00.1.1", "172.32.0.1"] {
      XCTAssertFalse(LocalHTTPServer.allowedPeer(peer))
    }
  }
  func testStrictJSONRejectsDuplicateKeysIncludingEscapes() throws {
    let invalid = [
      "{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "{\"o\":{\"x\":0,\"x\":1}}", "{\"a\":1.0}",
      "{\"a\":1e2}", "{\"a\":01}", "{\"a\":1,}", "{}{}", "{\"a\":NaN}", "{\"a\":\"\\uD800\"}",
    ]
    for value in invalid {
      XCTAssertThrowsError(try StrictJSON.decodeObject(Data(value.utf8)), value)
    }
    XCTAssertThrowsError(try StrictJSON.decodeObject(Data([123, 34, 255, 34, 58, 48, 125])))
    XCTAssertThrowsError(
      try StrictJSON.decodeObject(
        Data(
          (String(repeating: "{\"a\":", count: 20) + "0" + String(repeating: "}", count: 20)).utf8))
    )
    let value = try StrictJSON.decodeObject(
      Data("{\"a\":\"line\\n🔐\",\"b\":[true,false,null,-12]}".utf8))
    XCTAssertEqual(value["a"] as? String, "line\n🔐")
  }
  func testBoundedFuzzInputDoesNotCrashParsers() {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<400 {
      let data = Data(
        (0..<Int.random(in: 0...512, using: &generator)).map { _ in
          UInt8.random(in: 0...255, using: &generator)
        })
      _ = try? StrictJSON.decodeObject(data)
      var parser = HTTPRequestParser()
      _ = try? parser.append(data, port: 8787)
    }
  }
}
