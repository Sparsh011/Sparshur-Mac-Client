import CryptoKit
import Foundation
import LocalAuthentication
import Network
import Security

struct PublicIdentity: Sendable, Equatable {
  let recipientID: String
  let fingerprint: String
  let senderID: String?
  let highestCounter: Int?

  // Read the existing helper's schema without creating an Endpoint or writing it.
  // Only public facts leave this function; private seeds never reach the UI.
  static func read(from data: Data) throws -> PublicIdentity {
    guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let recipient = state["recipient_id"] as? String,
      UUID(uuidString: recipient)?.uuidString.lowercased() == recipient,
      let hpkeSeed = state["hpke_seed"] as? String,
      let signingSeed = state["signing_seed"] as? String,
      let hpkeData = Data(base64Encoded: hpkeSeed), hpkeData.count == 32,
      let signingData = Data(base64Encoded: signingSeed), signingData.count == 32
    else { throw IdentityError.invalid }
    let hpke = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hpkeData)
    let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: signingData)
    let digest = SHA256.hash(
      data: hpke.publicKey.rawRepresentation + signing.publicKey.rawRepresentation)
    var senderID: String?
    var highest: Int?
    if let peerValue = state["pair"] {
      guard let peer = peerValue as? [String: Any],
        let sender = peer["sender_id"] as? String,
        UUID(uuidString: sender)?.uuidString.lowercased() == sender,
        let counter = peer["highest"] as? NSNumber,
        CFGetTypeID(counter) != CFBooleanGetTypeID(),
        counter.doubleValue == Double(counter.intValue),
        (0...1_000_000).contains(counter.intValue)
      else { throw IdentityError.invalid }
      senderID = sender
      highest = counter.intValue
    }
    return PublicIdentity(
      recipientID: recipient,
      fingerprint: digest.map { String(format: "%02x", $0) }.joined(),
      senderID: senderID, highestCounter: highest)
  }

  private enum IdentityError: Error { case invalid }
}

enum IdentityCheck: Sendable, Equatable {
  case unchecked, notFound, authorizationRequired, invalid, unavailable
  case available(PublicIdentity)

  var title: String {
    switch self {
    case .unchecked: "Not checked"
    case .notFound: "Identity not visible to this app"
    case .authorizationRequired: "Keychain authorization required"
    case .invalid: "Saved state needs review"
    case .unavailable: "Keychain unavailable"
    case .available: "Existing identity readable"
    }
  }
  var detail: String {
    switch self {
    case .unchecked: "Check access to the existing learning identity."
    case .notFound: "The item may be absent or hidden by the sandbox. No replacement was created."
    case .authorizationRequired:
      "The app cannot read the existing item without authorization. The old identity is preserved."
    case .invalid: "The existing item was left untouched. Review its schema before migrating."
    case .unavailable: "Unlock your login keychain and check again. No keys were changed."
    case .available:
      "Public fingerprint and saved replay counter are available. Only public identity facts are shown here."
    }
  }
}

enum ListenerCheck: Sendable, Equatable {
  case unchecked, available, failed
  var title: String {
    switch self {
    case .unchecked: "Not checked"
    case .available: "Loopback listener available"
    case .failed: "Loopback listener unavailable"
    }
  }
  var detail: String {
    switch self {
    case .unchecked: "Test a temporary socket on this Mac only."
    case .available:
      "A temporary local socket opened and closed. LAN permissions and phone reachability still need testing."
    case .failed:
      "A temporary local socket could not open. Check the app's incoming-connections entitlement."
    }
  }
}

actor PlatformService {
  func localAddresses() throws -> [LocalAddress] { try LocalAddress.discover() }

  func checkLegacyIdentity() -> IdentityCheck {
    _ = SecKeychainSetUserInteractionAllowed(false)
    let context = LAContext()
    context.interactionNotAllowed = true
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.sparsh.bridge.learning.v2",
      kSecAttrAccount as String: "identity-and-replay-state",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      // A readiness check must not cause repeated authorization dialogs.
      kSecUseAuthenticationContext as String: context,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecItemNotFound: return .notFound
    case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
      return .authorizationRequired
    case errSecSuccess:
      guard let data = result as? Data else { return .invalid }
      do { return .available(try PublicIdentity.read(from: data)) } catch { return .invalid }
    default: return .unavailable
    }
  }

  func checkLoopbackListener() async -> ListenerCheck {
    await ListenerProbe().run()
  }
}

// All mutable probe state lives on one private serial queue. The listener is
// temporary, loopback-only and never touches port 8787 or the existing receiver.
private final class ListenerProbe: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.sparsh.Sparshur.listener-probe")
  private var listener: NWListener?
  private var completion: CheckedContinuation<ListenerCheck, Never>?

  func run() async -> ListenerCheck {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        completion = continuation
        do {
          let parameters = NWParameters.tcp
          parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
          let socket = try NWListener(using: parameters)
          listener = socket
          socket.newConnectionHandler = { $0.cancel() }
          socket.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.finish(.available)
            case .failed: self?.finish(.failed)
            default: break
            }
          }
          socket.start(queue: queue)
          queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish(.failed) }
        } catch { finish(.failed) }
      }
    }
  }

  private func finish(_ result: ListenerCheck) {
    guard let continuation = completion else { return }
    completion = nil
    listener?.stateUpdateHandler = nil
    listener?.cancel()
    listener = nil
    continuation.resume(returning: result)
  }
}
