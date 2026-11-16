import Darwin
import Foundation

struct LocalAddress: Identifiable, Sendable, Equatable {
  let interface: String
  let host: String
  let isEmulator: Bool
  var isPrivateVPN: Bool { interface.hasPrefix("utun") && privateVPNHost(host) }
  var id: String { "\(interface)/\(host)" }
  var label: String {
    if isEmulator { return "Android emulator only" }
    return "\(isPrivateVPN ? "Private VPN" : interface) · \(host)"
  }

  static let emulator = LocalAddress(interface: "emulator", host: "10.0.2.2", isEmulator: true)

  static func isPrivateIPv4(_ host: String) -> Bool {
    host != "127.0.0.1" && localHost(host)
  }

  static func discover() throws -> [LocalAddress] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { throw AddressError.unavailable }
    defer { freeifaddrs(head) }
    var result: [LocalAddress] = []
    var cursor = head
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      let interface = entry.pointee
      guard let address = interface.ifa_addr,
        address.pointee.sa_family == UInt8(AF_INET),
        interface.ifa_flags & UInt32(IFF_UP) != 0,
        interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0
      else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          address, socklen_t(address.pointee.sa_len), &buffer,
          socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let host = String(
        decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      let found = LocalAddress(
        interface: String(cString: interface.ifa_name), host: host, isEmulator: false)
      guard
        isPrivateIPv4(host)
          || (found.isPrivateVPN && interface.ifa_flags & UInt32(IFF_POINTOPOINT) != 0)
      else { continue }
      if !result.contains(found) { result.append(found) }
    }
    return result.sorted { ($0.interface, $0.host) < ($1.interface, $1.host) } + [.emulator]
  }

  private enum AddressError: Error { case unavailable }
}
