import Foundation

// A bounded JSON grammar pass before Foundation decoding. Foundation alone
// accepts duplicate object keys, losing the evidence needed to reject them.
enum StrictJSON {
  static func decodeObject(_ data: Data, maxBytes: Int = 65_536) throws -> Object {
    guard data.count <= maxBytes, String(data: data, encoding: .utf8) != nil else {
      throw Rejected.invalid
    }
    var parser = Parser(bytes: Array(data))
    try parser.value(depth: 0)
    parser.space()
    guard parser.index == parser.bytes.count,
      let result = try JSONSerialization.jsonObject(with: data) as? Object
    else { throw Rejected.invalid }
    return result
  }

  private struct Parser {
    let bytes: [UInt8]
    var index = 0
    mutating func space() {
      while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    mutating func take(_ byte: UInt8) throws {
      space()
      guard index < bytes.count, bytes[index] == byte else { throw Rejected.invalid }
      index += 1
    }
    mutating func string() throws -> String {
      space()
      let start = index
      try take(34)
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 34 {
          let data = Data(bytes[start..<index])
          guard
            let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
              as? String
          else { throw Rejected.invalid }
          return value
        }
        guard byte >= 32 else { throw Rejected.invalid }
        if byte == 92 {
          guard index < bytes.count else { throw Rejected.invalid }
          let escape = bytes[index]
          index += 1
          if escape == 117 {
            guard index + 4 <= bytes.count,
              bytes[index..<index + 4].allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              })
            else { throw Rejected.invalid }
            index += 4
          } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escape) {
            throw Rejected.invalid
          }
        }
      }
      throw Rejected.invalid
    }
    mutating func value(depth: Int) throws {
      space()
      guard depth < 16, index < bytes.count else { throw Rejected.invalid }
      switch bytes[index] {
      case 123:
        index += 1
        space()
        if index < bytes.count, bytes[index] == 125 {
          index += 1
          return
        }
        var keys: Set<String> = []
        while true {
          let key = try string()
          guard keys.insert(key).inserted else { throw Rejected.invalid }
          try take(58)
          try value(depth: depth + 1)
          space()
          if index < bytes.count, bytes[index] == 125 {
            index += 1
            return
          }
          try take(44)
        }
      case 91:
        index += 1
        space()
        if index < bytes.count, bytes[index] == 93 {
          index += 1
          return
        }
        while true {
          try value(depth: depth + 1)
          space()
          if index < bytes.count, bytes[index] == 93 {
            index += 1
            return
          }
          try take(44)
        }
      case 34: _ = try string()
      case 116: try literal("true")
      case 102: try literal("false")
      case 110: try literal("null")
      default:
        let start = index
        if bytes[index] == 45 { index += 1 }
        guard index < bytes.count, (48...57).contains(bytes[index]) else { throw Rejected.invalid }
        if bytes[index] == 48 {
          index += 1
        } else {
          while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        }
        // The lab's schemas contain only integers; do not coerce floats/exponents.
        guard Int(String(decoding: bytes[start..<index], as: UTF8.self)) != nil else {
          throw Rejected.invalid
        }
      }
    }
    mutating func literal(_ value: String) throws {
      let expected = Array(value.utf8)
      guard index + expected.count <= bytes.count,
        Array(bytes[index..<index + expected.count]) == expected
      else { throw Rejected.invalid }
      index += expected.count
    }
  }
}
