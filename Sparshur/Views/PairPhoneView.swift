import AppKit
import SwiftUI

struct PairPhoneView: View {
  @Environment(AppModel.self) private var model
  @AppStorage("showExplanations") private var showExplanations = true
  @State private var showsPairingSetup = false
  @State private var confirmingReplacement = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 7) {
          Text("Devices")
            .font(Theme.font(29, weight: .semibold)).tracking(-0.8)
            .foregroundStyle(Theme.text)
          Text("Manage your Android pairing and check the last verified contact.")
            .font(Theme.font(12)).foregroundStyle(Theme.secondary)
        }
        devicesPanel
        receiverPanel
        if model.pairedSenderID == nil || showsPairingSetup || model.pairingCode != nil {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
              setupPanel.frame(minWidth: 260, maxWidth: .infinity)
              qrPanel.frame(width: 260)
            }
            VStack(spacing: 14) {
              setupPanel
              qrPanel
            }
          }
        }
        DisclosureGroup("Mac identity and diagnostics") {
          identityPanel.padding(.top, 10)
        }
        .font(Theme.font(12, weight: .medium)).foregroundStyle(Theme.secondary)
        if showExplanations {
          Button("Learn how pairing works") { model.showLesson(.pairing) }
            .buttonStyle(.plain).font(Theme.font(11)).foregroundStyle(Theme.pink)
        }
      }
      .padding(28).frame(maxWidth: 870).frame(maxWidth: .infinity)
    }
  }

  private var devicesPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Paired devices").font(Theme.font(13, weight: .semibold))
          Spacer()
          if model.pairedSenderID != nil && model.pairingCode == nil {
            Button(showsPairingSetup ? "Hide setup" : "Replace pairing") {
              showsPairingSetup.toggle()
            }
            .buttonStyle(.plain).font(Theme.font(11, weight: .medium))
            .foregroundStyle(Theme.pink)
          }
        }
        .foregroundStyle(Theme.text).padding(16)
        Divider().overlay(Theme.border)
        if let sender = model.pairedSenderID {
          HStack(alignment: .top, spacing: 13) {
            Image(systemName: "iphone")
              .font(Theme.font(17)).foregroundStyle(Theme.pink)
              .frame(width: 42, height: 42)
              .background(Theme.pink.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
              Text("Android phone").font(Theme.font(14, weight: .semibold))
                .foregroundStyle(Theme.text)
              if let contact = model.lastContact {
                Text("Last verified contact · \(contact.route)")
                  .font(Theme.font(11)).foregroundStyle(Theme.secondary)
                Text(contact.date.formatted(date: .abbreviated, time: .shortened))
                  .font(Theme.font(11)).foregroundStyle(Theme.secondary)
              } else {
                Text("No verified contact this session")
                  .font(Theme.font(11)).foregroundStyle(Theme.secondary)
              }
              Text("Device ID · \(sender)")
                .font(Theme.font(9, design: .monospaced)).foregroundStyle(Theme.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .help(sender)
            }
            Spacer(minLength: 8)
            StatusBadge(title: "Paired", symbol: "checkmark.shield", accented: true)
          }
          .padding(16)
        } else {
          Text(emptyDeviceLabel)
            .font(Theme.font(12)).foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
      }
    }
  }

  private var emptyDeviceLabel: String {
    if model.savedIdentity != nil { return "No phone paired." }
    if model.needsIdentityAccess { return "Authorize Keychain access to view the saved pairing." }
    if model.receiverStatus == .starting { return "Checking for a saved phone…" }
    return "Start the receiver to load the saved pairing."
  }

  private var receiverPanel: some View {
    let isListening = model.receiverStatus == .listening
    return Panel {
      HStack(spacing: 13) {
        Image(systemName: "desktopcomputer")
          .font(Theme.font(17)).foregroundStyle(isListening ? Theme.success : Theme.secondary)
          .frame(width: 42, height: 42)
          .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          Text("This Mac").font(Theme.font(13, weight: .semibold)).foregroundStyle(Theme.text)
          Text(isListening ? "Listening for transfers on port 8787" : model.receiverStatus.title)
            .font(Theme.font(11)).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        if model.needsIdentityAccess {
          Button("Authorize identity…") { Task { await model.authorizeIdentity() } }
            .buttonStyle(SecondaryButtonStyle()).disabled(model.isAuthorizingIdentity)
        } else if isListening {
          Button("Pause") { model.pauseReceiver() }.buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel("Pause receiver")
        } else {
          Button("Start receiver") { model.resumeReceiver() }.buttonStyle(SecondaryButtonStyle())
            .disabled(model.receiverStatus == .starting)
        }
      }
      .padding(16)
    }
  }

  private var setupPanel: some View {
    @Bindable var model = model
    return Panel {
      VStack(alignment: .leading, spacing: 12) {
        Text(model.pairedSenderID == nil ? "Pair a phone" : "Replace the paired phone")
          .font(Theme.font(14, weight: .semibold)).foregroundStyle(Theme.text)
        Text("Choose Wi-Fi, a hotspot, or Private VPN for Tailscale.")
          .font(Theme.font(11)).foregroundStyle(Theme.secondary)
        HStack(spacing: 8) {
          Picker("Mac network address", selection: $model.selectedAddressID) {
            Text("Select an address…").tag(nil as String?)
            ForEach(model.addresses) { address in
              Text(address.label).tag(Optional(address.id))
            }
          }
          .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
          Button {
            Task { await model.refreshAddresses() }
          } label: {
            Label("Refresh network addresses", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
          }
          .disabled(model.isRefreshingAddresses).help("Refresh network addresses")
        }
        if let address = model.selectedAddress {
          Text("\(address.host):8787")
            .font(Theme.font(10, design: .monospaced)).foregroundStyle(Theme.secondary)
            .textSelection(.enabled)
          if address.isPrivateVPN {
            Text("Connect Android to the same Tailscale network.")
              .font(Theme.font(11)).foregroundStyle(Theme.secondary)
          } else if address.isEmulator {
            Text("This address works with the Android emulator.")
              .font(Theme.font(11)).foregroundStyle(Theme.secondary)
          }
        }
        if let error = model.addressError {
          Text(error).font(Theme.font(11)).foregroundStyle(.orange)
        } else if !model.addresses.contains(where: { !$0.isEmulator }) {
          Text("Connect this Mac, then refresh to find its network address.")
            .font(Theme.font(11)).foregroundStyle(Theme.secondary)
        }
        Divider().overlay(Theme.border)
        Text("On Android, open Pair with Mac, scan the code, and confirm the fingerprint.")
          .font(Theme.font(11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(18).frame(maxWidth: .infinity, alignment: .leading)
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
          if let error = model.pairingError {
            Text(error).font(Theme.font(11)).foregroundStyle(.orange)
          }
          Label("QR expires after five minutes", systemImage: "lock").font(Theme.font(9))
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

}
