import AppKit
import SwiftUI

struct PairPhoneView: View {
  @Environment(AppModel.self) private var model
  @AppStorage("showExplanations") private var showExplanations = true
  @State private var confirmingReplacement = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(
          eyebrow: "A trusted connection", title: "Pair your phone",
          subtitle: "One QR. Two devices. A shared starting point for trust.")
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 18) {
            setupPanel.frame(minWidth: 270, idealWidth: 420, maxWidth: .infinity)
            qrPanel.frame(width: 260)
          }
          VStack(spacing: 18) {
            setupPanel
            qrPanel
          }
        }
        identityPanel
        DisclosureGroup("What exactly establishes trust?") {
          VStack(alignment: .leading, spacing: 12) {
            Text(
              "1. Mac generates its encryption/signing keys locally. The public pairing ID labels this attempt; a separate random temporary secret authenticates it."
            )
            Text(
              "2. The QR visually transfers public keys, address, pairing ID, expiry and secret to your phone."
            )
            Text(
              "3. You confirm on Android. It sends its signing public key, an HMAC proof and its signature over the full transcript. It does not send the QR secret."
            )
            Text(
              "4. Mac verifies both, saves Android's public signing key, then returns its own HMAC proof and signature. Android verifies using the scanned Mac key before pinning it."
            )
            Text(
              "HMAC uses the shared QR secret. Signatures use a private key to sign and its public key to verify. Changing a bound public key invalidates the original proof and signature."
            )
            Text(
              "A stolen, still-usable QR secret is a different threat: its holder can attempt a new valid handshake. Protect the displayed code. Replay counters protect later messages; they do not fix a compromised pairing channel."
            )
          }.font(Theme.font(11)).foregroundStyle(Theme.secondary).lineSpacing(4).padding(.top, 12)
        }.font(Theme.font(12)).foregroundStyle(Theme.text)
        if showExplanations {
          Explanation(
            title: "Scanning is the introduction. Pairing is the handshake.",
            text:
              "The QR carries public keys, a network address and a five-minute secret. Android must confirm and complete the authenticated handshake before either device trusts the other."
          )
          Button {
            model.showLesson(.pairing)
          } label: {
            Label("Walk through pairing", systemImage: "arrow.up.right")
          }.buttonStyle(.plain).font(Theme.font(11)).foregroundStyle(Theme.pink)
        }
      }
      .padding(30).frame(maxWidth: 1060).frame(maxWidth: .infinity)
    }
  }

  private var setupPanel: some View {
    @Bindable var model = model
    return Panel {
      VStack(alignment: .leading, spacing: 20) {
        step(
          "01", title: "Join the same network",
          text: "Connect this Mac to your phone's hotspot, or put both devices on the same Wi-Fi.")
        Divider().overlay(Theme.border)
        VStack(alignment: .leading, spacing: 11) {
          step(
            "02", title: "Choose this Mac's address",
            text: "Select the interface your phone can reach. VPN interfaces may also appear.")
          Picker("Network address", selection: $model.selectedAddressID) {
            Text("Select an interface…").tag(nil as String?)
            ForEach(model.addresses) { address in
              Text(address.label).tag(Optional(address.id))
            }
          }
          .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Mac network address")
          HStack {
            Text(model.selectedAddress.map { "\($0.host):8787" } ?? "Port 8787 · local network")
              .font(Theme.font(10, design: .monospaced)).foregroundStyle(Theme.muted)
              .textSelection(.enabled)
            Spacer()
            Button {
              Task { await model.refreshAddresses() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary)
            .disabled(model.isRefreshingAddresses).help("Refresh network addresses")
            .accessibilityLabel("Refresh network addresses")
          }
          if let error = model.addressError {
            Text(error).font(Theme.font(11)).foregroundStyle(.orange)
          } else if !model.addresses.contains(where: { !$0.isEmulator }) {
            Text(
              "No private IPv4 interface found. Connect to Wi-Fi or your phone's hotspot and refresh."
            )
            .font(Theme.font(11)).foregroundStyle(Theme.secondary)
          }
          if model.selectedAddress?.isEmulator == true {
            Text(
              "10.0.2.2 is for the Android emulator. A physical phone needs this Mac's private IPv4 address."
            )
            .font(Theme.font(11)).foregroundStyle(Theme.secondary)
          }
        }
        Divider().overlay(Theme.border)
        step(
          "03", title: "Scan and confirm on Android",
          text: "Open Pair with Mac on your phone. Review the fingerprint, then confirm pairing.")
      }
      .padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var qrPanel: some View {
    Panel {
      VStack(spacing: 15) {
        if let code = model.pairingCode, let image = NSImage(data: code.png) {
          StatusBadge(title: "Waiting for confirmation", symbol: "qrcode", accented: true)
          Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
            .frame(maxWidth: 280).padding(8).background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Pairing QR. Scan only from the intended phone.")
          Text("Expires in \(max(0, Int(code.expiresAt.timeIntervalSince(model.now)))) seconds")
            .font(Theme.font(12, weight: .medium)).foregroundStyle(Theme.text)
          Text(
            "Scan, review the fingerprint, then confirm on Android. Scanning alone does not pair."
          )
          .font(Theme.font(11)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
          DisclosureGroup("Trusted manual input") {
            Text(
              "This bundle includes a temporary secret. Enter it only on your own phone through a trusted channel."
            )
            .font(Theme.font(10)).foregroundStyle(Theme.secondary)
            Text(code.bundle).font(Theme.font(9, design: .monospaced)).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }.font(Theme.font(11)).foregroundStyle(Theme.secondary)
          Button("Discard QR") { model.cancelPairing() }.buttonStyle(SecondaryButtonStyle())
        } else {
          StatusBadge(
            title: model.savedIdentity?.senderID == nil ? "Pair a phone" : "Saved phone pairing",
            symbol: "qrcode")
          Image(systemName: "qrcode.viewfinder").font(Theme.font(34, weight: .ultraLight))
            .foregroundStyle(Theme.pink).padding(20)
          Text(
            model.receiverStatus == .listening
              ? "Ready for a trusted introduction" : model.receiverStatus.title
          )
          .font(Theme.font(13, weight: .medium)).foregroundStyle(Theme.text).multilineTextAlignment(
            .center)
          Text(
            model.receiverStatus == .listening
              ? "Choose the interface your phone can reach, then create a five-minute code."
              : "Start the receiver to create a pairing code. Your existing identity is preserved."
          )
          .font(Theme.font(11)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
          Button(model.isCreatingPairing ? "Creating…" : "Create pairing QR") {
            if model.savedIdentity?.senderID != nil {
              confirmingReplacement = true
            } else {
              Task { await model.createPairing() }
            }
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(
            model.receiverStatus != .listening || model.selectedAddress == nil
              || model.isCreatingPairing)
          if model.needsIdentityAccess {
            Button(
              model.isAuthorizingIdentity ? "Waiting for macOS…" : "Authorize existing identity…"
            ) {
              Task { await model.authorizeIdentity() }
            }.buttonStyle(SecondaryButtonStyle()).disabled(model.isAuthorizingIdentity)
            Text(
              "macOS may ask to let this locally signed app access the existing learning identity. No key is replaced or exported."
            )
            .font(Theme.font(10)).foregroundStyle(Theme.secondary)
          }
          if model.receiverStatus != .listening && model.receiverStatus != .starting {
            Button("Start receiver") { model.resumeReceiver() }.buttonStyle(SecondaryButtonStyle())
          }
          if let error = model.pairingError {
            Text(error).font(Theme.font(11)).foregroundStyle(.orange)
          }
          Label("Local QR · five-minute expiry", systemImage: "lock").font(Theme.font(9))
            .foregroundStyle(Theme.muted)
        }
      }
      .padding(23).frame(maxWidth: .infinity)
    }
    .confirmationDialog("Create a QR for another pairing?", isPresented: $confirmingReplacement) {
      Button("Create replacement QR") { Task { await model.createPairing() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Only a completed, verified handshake replaces the saved phone. Creating a QR alone does not revoke it."
      )
    }
  }

  private var identityPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label("This Mac's identity", systemImage: "key.horizontal")
            .font(Theme.font(12, weight: .semibold)).foregroundStyle(Theme.text)
          Spacer()
          Button {
            Task { await model.checkPlatform() }
          } label: {
            HStack(spacing: 7) {
              if model.isCheckingPlatform { ProgressView().controlSize(.mini) }
              Text(model.isCheckingPlatform ? "Checking…" : "Check readiness")
            }
          }
          .buttonStyle(SecondaryButtonStyle()).disabled(model.isCheckingPlatform)
        }
        Text(model.identityCheck.title).font(Theme.font(12)).foregroundStyle(Theme.text)
        Text(model.identityCheck.detail).font(Theme.font(11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let identity = model.savedIdentity {
          VStack(alignment: .leading, spacing: 8) {
            Text("PUBLIC FINGERPRINT").font(Theme.font(9, weight: .medium)).tracking(1)
              .foregroundStyle(Theme.muted)
            Text(identity.fingerprint).font(Theme.font(10, design: .monospaced))
              .foregroundStyle(Theme.secondary).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
            Text(
              identity.senderID == nil
                ? "No saved phone pairing" : "Saved phone pairing · reachability unknown"
            )
            .font(Theme.font(11)).foregroundStyle(Theme.secondary)
            if let counter = identity.highestCounter {
              Text("Saved replay high-water counter: \(counter)")
                .font(Theme.font(10, design: .monospaced)).foregroundStyle(Theme.muted)
            }
          }
        }
      }
      .padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func step(_ number: String, title: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number).font(Theme.font(10, weight: .medium, design: .monospaced))
        .foregroundStyle(Theme.pink).padding(.top, 2)
      VStack(alignment: .leading, spacing: 7) {
        Text(title).font(Theme.font(12, weight: .medium)).foregroundStyle(Theme.text)
        Text(text).font(Theme.font(11)).foregroundStyle(Theme.secondary).lineSpacing(4)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
