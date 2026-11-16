import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MessagesView: View {
  @Environment(AppModel.self) private var model
  @State private var inspected: LocalObservation?
  @State private var choosingFile = false
  @State private var saveError = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 7) {
          Text("Clipboard")
            .font(Theme.font(29, weight: .semibold)).tracking(-0.8)
            .foregroundStyle(Theme.text)
          Text("Verified text and images from Android are copied to this Mac.")
            .font(Theme.font(12)).foregroundStyle(Theme.secondary)
        }
        clipboardStatus
        HStack {
          Button("Send file to Android…") { choosingFile = true }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(
              model.pairedSenderID == nil || model.receiverStatus != .listening
                || model.hasOutgoingFile || model.isQueueingFile)
          if model.hasOutgoingFile {
            Button("Cancel queued file") { Task { await model.cancelOutgoingFile() } }
              .buttonStyle(SecondaryButtonStyle())
          }
        }
        if let status = model.fileStatus {
          Text(status).font(Theme.font(12)).foregroundStyle(Theme.secondary)
        }
        Panel {
          VStack(alignment: .leading, spacing: 0) {
            Text("Recent items")
              .font(Theme.font(13, weight: .semibold)).foregroundStyle(Theme.text)
              .padding(17)
            Divider().overlay(Theme.border)
            if model.verifiedMessages.isEmpty {
              emptyState
            } else {
              LazyVStack(spacing: 0) {
                ForEach(model.verifiedMessages) { observation in
                  clipRow(observation)
                  Divider().overlay(Theme.border)
                }
              }
              Text("Recent items are kept until you quit Sparshur.")
                .font(Theme.font(10)).foregroundStyle(Theme.secondary).padding(15)
            }
          }
        }
      }
      .padding(28).frame(maxWidth: 870).frame(maxWidth: .infinity)
    }
    .sheet(item: $inspected) { MessageInspector(observation: $0) }
    .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url): Task { await model.queueFile(at: url) }
      case .failure: model.fileStatus = "Couldn’t open the chosen file."
      }
    }
    .alert("Couldn’t save the file", isPresented: $saveError) {
      Button("OK", role: .cancel) {}
    }
  }

  private func save(_ file: PairedFile) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = file.name
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do { try file.data.write(to: url, options: .atomic) } catch { saveError = true }
    }
  }

  private var clipboardStatus: some View {
    let update = model.clipboardUpdate
    let hasError = update?.succeeded == false
    let symbol = hasError ? "exclamationmark.circle" : update == nil ? "clipboard" : "checkmark"
    return Panel {
      HStack(spacing: 14) {
        Image(systemName: symbol)
          .font(Theme.font(16, weight: .semibold))
          .foregroundStyle(hasError ? .orange : update == nil ? Theme.secondary : Theme.success)
          .frame(width: 40, height: 40)
          .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(statusTitle)
            .font(Theme.font(13, weight: .semibold)).foregroundStyle(Theme.text)
          Text(statusDetail)
            .font(Theme.font(11)).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        if let latest = model.verifiedMessages.first(where: { $0.clipboardContent != nil }) {
          Button("Copy latest") { model.copyToClipboard(latest) }
            .buttonStyle(SecondaryButtonStyle())
        }
      }
      .padding(16)
    }
  }

  private var statusTitle: String {
    if let update = model.clipboardUpdate {
      return update.succeeded ? "Copied to clipboard" : "Clipboard write failed"
    }
    if model.receiverStatus != .listening { return model.receiverStatus.shortTitle }
    return model.pairedSenderID == nil ? "Pair a phone to receive clips" : "Ready for a clip"
  }

  private var statusDetail: String {
    if let update = model.clipboardUpdate {
      if !update.succeeded { return "Use Copy on a clip below to try again." }
      return "Last copied at \(update.date.formatted(date: .omitted, time: .shortened))."
    }
    if model.receiverStatus != .listening {
      return "Check the receiver in Devices before sending."
    }
    if let contact = model.lastContact {
      return "Android reached this Mac over \(contact.route.lowercased())."
    }
    return model.pairedSenderID == nil
      ? "Get a pairing code from Devices."
      : "Open Sparshur on Android and send what you copied."
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("No items received yet")
        .font(Theme.font(18, weight: .semibold)).foregroundStyle(Theme.text)
      Text(
        model.pairedSenderID == nil
          ? "Pair your Android phone to send text, images, and files."
          : "Send something from Sparshur on Android to see it here."
      )
      .font(Theme.font(12)).foregroundStyle(Theme.secondary)
      Button(model.pairedSenderID == nil ? "Open Devices" : "Check phone activity") {
        model.destination = .pairPhone
      }
      .buttonStyle(SecondaryButtonStyle())
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(24)
  }

  private func clipRow(_ observation: LocalObservation) -> some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Text(observation.file?.name ?? observation.plaintext ?? "")
          .font(Theme.font(13)).foregroundStyle(Theme.text)
          .lineLimit(4).textSelection(.enabled)
        Label(
          observation.receivedAt.formatted(date: .abbreviated, time: .shortened),
          systemImage: "checkmark.shield"
        )
        .font(Theme.font(10)).foregroundStyle(Theme.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if observation.clipboardContent != nil {
        Button("Copy", systemImage: "doc.on.doc") { model.copyToClipboard(observation) }
          .labelStyle(.titleAndIcon)
          .buttonStyle(SecondaryButtonStyle())
      }
      if let file = observation.file {
        Button("Save file…") { save(file) }.buttonStyle(SecondaryButtonStyle())
      } else {
        Button {
          inspected = observation
        } label: {
          Label("Inspect message", systemImage: "info.circle").labelStyle(.iconOnly)
        }
        .buttonStyle(SecondaryButtonStyle())
        .help("Inspect message")
      }
    }
    .padding(17)
  }
}

struct ObservationRow: View {
  let observation: LocalObservation
  let inspect: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(
          observation.kind == .paired
            ? "Paired sender verified"
            : observation.kind == .readable
              ? "Readable sample — sender unverified" : "Phone-only AES — Mac has no key"
        )
        .font(Theme.font(10, weight: .medium)).foregroundStyle(Theme.pink)
        Spacer()
        Text(observation.receivedAt.formatted(date: .omitted, time: .shortened)).font(
          Theme.font(10)
        ).foregroundStyle(Theme.muted)
      }
      Text(observation.plaintext ?? "Ciphertext stays unreadable on this Mac.")
        .font(Theme.font(14)).foregroundStyle(Theme.text).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Button("Inspect") { inspect() }.buttonStyle(SecondaryButtonStyle())
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
  }
}
