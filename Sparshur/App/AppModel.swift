import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum Destination: String, CaseIterable, Identifiable {
  case messages, pairPhone, learn

  var id: Self { self }
  var title: String {
    switch self {
    case .messages: "Clipboard"
    case .pairPhone: "Devices"
    case .learn: "Learn"
    }
  }
  var symbol: String {
    switch self {
    case .messages: "clipboard"
    case .pairPhone: "iphone"
    case .learn: "book.closed"
    }
  }
  var shortcut: KeyEquivalent {
    switch self {
    case .messages: "1"
    case .pairPhone: "2"
    case .learn: "3"
    }
  }
}

@MainActor @Observable
final class AppModel {
  struct ClipboardUpdate {
    let date: Date
    let succeeded: Bool
  }

  private var currentDestination: Destination = .messages
  private var backStack: [Destination] = []
  private var forwardStack: [Destination] = []

  // Sidebar selection, shortcuts and in-page links all use the same history.
  var destination: Destination {
    get { currentDestination }
    set {
      guard newValue != currentDestination else { return }
      backStack.append(currentDestination)
      forwardStack.removeAll()
      currentDestination = newValue
    }
  }

  var canGoBack: Bool { !backStack.isEmpty }
  var canGoForward: Bool { !forwardStack.isEmpty }
  var previousDestination: Destination? { backStack.last }
  var nextDestination: Destination? { forwardStack.last }

  func goBack() {
    guard let previous = backStack.popLast() else { return }
    forwardStack.append(currentDestination)
    currentDestination = previous
  }

  func goForward() {
    guard let next = forwardStack.popLast() else { return }
    backStack.append(currentDestination)
    currentDestination = next
  }
  var selectedLesson: Lesson = .pairing
  var addresses: [LocalAddress] = []
  var selectedAddressID: String? {
    didSet {
      if selectedAddressID != oldValue {
        pairingCode = nil
        pairingCancellation = Task { await receiver.cancelPairing() }
      }
    }
  }
  var isRefreshingAddresses = false
  var addressError: String?
  var isCheckingPlatform = false
  var identityCheck: IdentityCheck = .unchecked
  var listenerCheck: ListenerCheck = .unchecked
  var checkedAt: Date?
  @ObservationIgnored private let platform = PlatformService()
  @ObservationIgnored private let receiver: ReceiverCoordinator
  @ObservationIgnored private let pasteboard: NSPasteboard
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var clockTask: Task<Void, Never>?
  @ObservationIgnored private var pairingCancellation: Task<Void, Never>?
  private var resumeAfterSleep = false
  var receiverStatus: ReceiverStatus = .stopped
  var relayStatus: RelayStatus = .disabled
  private(set) var relayEnrollment: (deviceID: String, signingPublicKey: String)?
  var pairingCode: PairingCode?
  var pairingError: String?
  var isCreatingPairing = false
  var isAuthorizingIdentity = false
  var needsIdentityAccess: Bool {
    if case .identityAccessRequired = receiverStatus { return true }
    return false
  }
  var hasOutgoingFile = false
  var isQueueingFile = false
  var fileStatus: String?
  var observations: [LocalObservation] = []
  private(set) var clipboardUpdate: ClipboardUpdate?
  private var receiverIdentity: PublicIdentity?
  private var peerContact: PeerContact?
  var duplicateCount = 0
  var rejectedCount = 0
  var verifiedCount = 0
  var now: Date = .now
  var verifiedMessages: [LocalObservation] { observations.filter { $0.kind == .paired } }
  var comparisons: [LocalObservation] { observations.filter { $0.kind != .paired } }

  init(receiver: ReceiverCoordinator = ReceiverCoordinator(), pasteboard: NSPasteboard = .general) {
    self.receiver = receiver
    self.pasteboard = pasteboard
  }

  func beginSession() {
    guard eventTask == nil else { return }
    eventTask = Task { [weak self, receiver] in
      for await event in receiver.events {
        guard let self else { return }
        switch event {
        case .observation(let observation):
          observations.insert(observation, at: 0)
          observations = Array(observations.prefix(40))
          if observation.kind == .paired {
            verifiedCount += 1
            copyToClipboard(observation)
          }
        case .peerContact(let contact): peerContact = contact
        case .duplicate: duplicateCount += 1
        case .outgoingFileQueued(let name):
          hasOutgoingFile = true
          fileStatus = "\(name) is ready. On Android, open Receive file from Mac."
        case .outgoingFileCleared(let delivered):
          hasOutgoingFile = false
          fileStatus =
            delivered ? "File saved on Android." : "Queued file cleared after pairing changed."
        case .rejected: rejectedCount += 1
        case .storageFailed:
          rejectedCount += 1
          pairingCode = nil
          await receiver.stopAfterFailure()
          receiverStatus = .identityAccessRequired(
            "Keychain could not save verified state; authorize existing identity")
        case .networkChanged: await refreshAddresses()
        case .identity(let identity):
          if peerContact?.senderID != identity.senderID { peerContact = nil }
          receiverIdentity = identity
          identityCheck = .available(identity)
        case .pairingCleared(let revision):
          if let pairingCode, pairingCode.revision <= revision { self.pairingCode = nil }
        case .status(let status):
          receiverStatus = status
          if case .failed = status {
            pairingCode = nil
            await receiver.stopAfterFailure()
          }
        case .relayStatus(let status): relayStatus = status
        case .relayEnrollment(let deviceID, let signingPublicKey):
          relayEnrollment = (deviceID, signingPublicKey.base64EncodedString())
        }
      }
    }
    clockTask = Task { [weak self, receiver] in
      var ticks = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        now = .now
        ticks += 1
        if ticks % 5 == 0 { await refreshAddresses() }
        if let pairingCode, pairingCode.expiresAt <= now { self.pairingCode = nil }
        await receiver.tick()
      }
    }
    resumeReceiver()
  }

  func copyToClipboard(_ observation: LocalObservation) {
    guard let content = observation.clipboardContent else { return }
    pasteboard.clearContents()
    let succeeded: Bool
    switch content {
    case .text(let text):
      succeeded = pasteboard.setString(text, forType: .string)
    case .image(let data, let type):
      succeeded = pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
    }
    clipboardUpdate = ClipboardUpdate(date: .now, succeeded: succeeded)
  }

  func queueFile(at url: URL) async {
    guard !hasOutgoingFile, !isQueueingFile else { return }
    isQueueingFile = true
    defer { isQueueingFile = false }
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
      guard values.isRegularFile == true else {
        fileStatus = "Choose a regular file."
        return
      }
      let source = try FileHandle(forReadingFrom: url)
      defer { try? source.close() }
      var data = Data()
      while data.count <= PairedFile.maxBytes {
        let remaining = PairedFile.maxBytes + 1 - data.count
        guard let chunk = try source.read(upToCount: min(64 * 1024, remaining)),
          !chunk.isEmpty
        else { break }
        data.append(chunk)
      }
      guard data.count <= PairedFile.maxBytes else {
        fileStatus = "Choose a file up to 5 MiB."
        return
      }
      let file = try PairedFile(
        name: url.lastPathComponent,
        mime: values.contentType?.preferredMIMEType ?? "application/octet-stream",
        data: data)
      try await receiver.queueFile(file)
    } catch {
      fileStatus =
        "Couldn’t queue the file. Check that the receiver is running and your phone is paired."
    }
  }

  func cancelOutgoingFile() async {
    await receiver.cancelOutgoingFile()
    hasOutgoingFile = false
    fileStatus = "File removed from the send queue."
  }

  func resumeReceiver() {
    guard !isAuthorizingIdentity else { return }
    receiverStatus = .starting
    Task { await receiver.start() }
  }
  func pauseReceiver() {
    pairingCode = nil
    Task { await receiver.pause() }
  }
  func authorizeIdentity() async {
    guard !isAuthorizingIdentity else { return }
    isAuthorizingIdentity = true
    defer { isAuthorizingIdentity = false }
    await receiver.authorizeIdentity()
  }
  func createPairing() async {
    guard receiverStatus == .listening, let address = selectedAddress, !isCreatingPairing else {
      return
    }
    pairingError = nil
    pairingCode = nil
    isCreatingPairing = true
    defer { isCreatingPairing = false }
    await pairingCancellation?.value
    do {
      let code = try await receiver.createPairing(at: address)
      guard selectedAddress?.id == address.id, receiverStatus == .listening else {
        await receiver.cancelPairing()
        return
      }
      pairingCode = code
    } catch ReceiverCoordinator.PairingError.vpnAddressUnavailable {
      await refreshAddresses()
      pairingError = "Connect Tailscale on this Mac, then select its current VPN address."
    } catch { pairingError = "Could not create a QR. Check receiver and Keychain access." }
  }
  func cancelPairing() {
    pairingCode = nil
    Task { await receiver.cancelPairing() }
  }
  func sleep() async {
    resumeAfterSleep = receiverStatus == .listening || receiverStatus == .starting
    pairingCode = nil
    await receiver.pause()
  }
  func wake() async {
    await refreshAddresses()
    if resumeAfterSleep {
      resumeAfterSleep = false
      await receiver.start()
    }
  }
  func shutdown() async {
    pairingCode = nil
    clockTask?.cancel()
    await receiver.shutdown()
    eventTask?.cancel()
    observations.removeAll()
  }

  var selectedAddress: LocalAddress? { addresses.first { $0.id == selectedAddressID } }
  var savedIdentity: PublicIdentity? {
    // An asynchronous diagnostics check can be older than the receiver's pairing.
    if let receiverIdentity { return receiverIdentity }
    if case .available(let identity) = identityCheck { return identity }
    return nil
  }
  var pairedSenderID: String? { savedIdentity?.senderID }
  var lastContact: PeerContact? {
    guard let peerContact, peerContact.senderID == pairedSenderID else { return nil }
    return peerContact
  }

  func refreshAddresses() async {
    guard !isRefreshingAddresses else { return }
    isRefreshingAddresses = true
    defer { isRefreshingAddresses = false }
    do {
      addresses = try await platform.localAddresses()
      addressError = nil
      // No implicit first-interface choice: a VPN can also have a private IP.
      if !addresses.contains(where: { $0.id == selectedAddressID }) {
        selectedAddressID = nil
      }
    } catch {
      addresses = []
      selectedAddressID = nil
      addressError = "macOS could not list network interfaces. Try refreshing."
    }
  }

  func checkPlatform() async {
    guard !isCheckingPlatform, !isAuthorizingIdentity else { return }
    isCheckingPlatform = true
    defer { isCheckingPlatform = false }
    await refreshAddresses()
    identityCheck = await platform.checkLegacyIdentity()
    listenerCheck = await platform.checkLoopbackListener()
    checkedAt = .now
  }

  func showLesson(_ lesson: Lesson) {
    selectedLesson = lesson
    destination = .learn
  }
}
