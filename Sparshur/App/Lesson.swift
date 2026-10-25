import Foundation

enum Lesson: String, CaseIterable, Identifiable {
  case views, state, lifetime, pairing, networking, concurrency, encryption, replay, journey
  var id: Self { self }
  var number: Int { Self.allCases.firstIndex(of: self)! + 1 }
  var title: String {
    switch self {
    case .views: "Read a SwiftUI view"
    case .state: "Navigation & state"
    case .lifetime: "The lifetime of an app"
    case .pairing: "Pairing & the QR"
    case .networking: "From phone to socket"
    case .concurrency: "Async & isolation"
    case .encryption: "Inside the envelope"
    case .replay: "Storage, retries & replays"
    case .journey: "Follow one message"
    }
  }
  var symbol: String {
    switch self {
    case .views: "rectangle.3.group"
    case .state: "sidebar.left"
    case .lifetime: "app.connected.to.app.below.fill"
    case .pairing: "qrcode"
    case .networking: "network"
    case .concurrency: "arrow.triangle.branch"
    case .encryption: "lock.shield"
    case .replay: "clock.arrow.circlepath"
    case .journey: "arrow.right.circle"
    }
  }
  var summary: String {
    switch self {
    case .views: "A view describes what the screen should look like for its current state."
    case .state: "One selected destination changes the detail view. The app model stays alive."
    case .lifetime: "A window's lifetime and the receiver's lifetime are different things."
    case .pairing: "The address tells your phone where to go. The keys tell it whom to trust."
    case .networking: "The Mac waits for a request. Android initiates the connection."
    case .concurrency: "Keep UI changes on the main actor and protocol work in its own actor."
    case .encryption: "Encryption hides the payload. Authentication binds it to the paired sender."
    case .replay: "A lost response does not necessarily mean a lost message."
    case .journey: "Trace the boundary between a local observation and a signed wire receipt."
    }
  }
  var steps: [String] {
    switch self {
    case .views:
      [
        "A struct conforms to View. Its body returns another view description.",
        "VStack arranges vertically, HStack horizontally, and ZStack layers content. These correspond to Column, Row and Box in Compose.",
        "Modifiers wrap the preceding view. Padding before a background changes which area the background fills.",
      ]
    case .state:
      [
        "SparshurApp owns one @State AppModel reference, much like hoisting a ViewModel above a navigation destination.",
        "@Observable tracks properties read by the UI. @Environment passes that same reference down the view tree.",
        "@Bindable makes bindings for controls. Selecting a List row changes destination; ContentView's switch chooses the detail screen.",
      ]
    case .lifetime:
      [
        "The App defines scenes; Window defines one main window. Returning to a screen does not recreate AppModel.",
        "MenuBarExtra shares the same AppModel and receiver as the window. Closing the window does not stop receiving.",
        "Pause explicitly stops the listener and discards any pending QR. Quit cancels connections and clears session history. The status label reports the actual listener state.",
      ]
    case .pairing:
      [
        "The Mac keeps a long-term encryption key and signing key in Keychain. A new QR must reuse that identity.",
        "The QR contains UTF-8 JSON: public keys, recipient and pairing IDs, host, port, expiry and a fresh 32-byte random secret. Only binary fields are Base64.",
        "Android scans, reviews and confirms. It sends an HMAC proof and signature over the transcript; the secret itself is not sent over HTTP.",
        "Mac verifies and saves the sender, then returns its own proof and signature. Android verifies these before pinning the Mac's public keys.",
      ]
    case .networking:
      [
        "An IP address identifies a network endpoint. Port 8787 selects the listening program; /paired-message selects an operation.",
        "NWListener accepts TCP connections. TCP delivers ordered bytes, which may arrive in partial headers or partial bodies.",
        "The native receiver must assemble a bounded HTTP request, validate its JSON and invoke the protocol engine. URLSession is a client and cannot replace a listener.",
        "A private address can belong to Wi-Fi, a hotspot or a VPN. Seeing an address does not prove that the phone can reach it.",
      ]
    case .concurrency:
      [
        "@MainActor serializes presentation state changes on the UI executor. Async work can suspend without blocking a thread.",
        "EndpointService owns mutable protocol and replay state. Views receive typed public results, never key objects.",
        "Actors can be re-entered at await. Verification, deduplication, persistence and committed state updates must form one serialized transaction with no suspension inside it.",
      ]
    case .encryption:
      [
        "Android makes a fresh random content key. ChaCha20-Poly1305 encrypts the text; associated data binds the message's context and counter.",
        "HPKE wraps the content key for the pinned Mac key. Base mode does not authenticate the sender, so Android also signs the complete envelope with Ed25519.",
        "Mac verifies the sender, unwraps the key, verifies the payload and commits replay state before displaying plaintext or signing a receipt.",
        "This local protocol still needs human review. HTTP exposes metadata; there is no ratchet or forward secrecy against later compromise of the Mac's long-term HPKE key.",
      ]
    case .replay:
      [
        "Identity keys and replay counters live in Keychain. The inbox is memory-only, bounded to 40 observations.",
        "After a timeout, retry the exact envelope. An accepted duplicate receives a signed receipt and must not create a second inbox row.",
        "An unknown counter below the saved high-water mark is rejected. This strict lab rule does not implement a reordering window.",
        "If persistence fails, do not disclose plaintext or acknowledge success. Restarting must preserve replay protection.",
      ]
    case .journey:
      [
        "Android turns text into bytes, encrypts and signs an envelope, then sends an HTTP POST to the Mac.",
        "LocalHTTPServer and HTTPRequestParser bound and validate input. The protocol engine authenticates, decrypts and saves replay state.",
        "A LocalObservation updates SwiftUI. A separate WireReceipt goes back over HTTP, so decrypted text cannot accidentally be serialized in the response.",
        "Android verifies the receipt's signature. That confirms authenticated processing, not that a human read the message.",
      ]
    }
  }
  var code: String {
    switch self {
    case .views: "Views/MessagesView.swift · Theme.swift"
    case .state: "App/AppModel.swift · ContentView.swift"
    case .lifetime: "SparshurApp.swift · App/AppModel.swift"
    case .pairing: "Views/PairPhoneView.swift · Core/PairedProtocol.swift"
    case .networking: "Networking/LocalHTTPServer.swift · HTTPRequestParser.swift"
    case .concurrency: "Core/EndpointService.swift · Services/ReceiverCoordinator.swift"
    case .encryption: "Core/PairedProtocol.swift · Android spec/PAIRED_V2.md"
    case .replay: "Core/PairedProtocol.swift · Tests/NativeProtocolTests.swift"
    case .journey:
      "Networking/LocalHTTPServer.swift → Core/EndpointService.swift → Views/MessagesView.swift"
    }
  }
  var exercise: String {
    switch self {
    case .views:
      "Find the Inbox label in MessagesView. Change its text, build, and locate the change on screen."
    case .state: "Use ⌘2, then ⌘1. Which property changed? Why didn't this create another AppModel?"
    case .lifetime:
      "Close the window, send a sample from Android, then reopen from the menu bar. Explain why the receiver instance survived."
    case .pairing:
      "Name the QR fields that can stay the same across attempts, and the fields that must be fresh."
    case .networking:
      "Refresh the interface list after changing networks. Explain why an address change must not replace trusted keys."
    case .concurrency:
      "Find handle() in EndpointService. Why is there no await between verification, saving replay state and publishing plaintext?"
    case .encryption:
      "Match ciphertext, wrapped_key, signature and counter to the job each field performs."
    case .replay:
      "Imagine the Mac accepted a message but the receipt was lost. Why should Android resend exactly the same bytes?"
    case .journey:
      "Narrate the message path and identify the exact boundary where decrypted text must stay on the Mac."
    }
  }
}
