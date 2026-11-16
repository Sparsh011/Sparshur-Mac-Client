import SwiftUI

struct StatusMenu: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Text(model.receiverStatus.shortTitle)
    if model.pairedSenderID != nil {
      Text("Android phone paired")
      if let contact = model.lastContact {
        Text("Last contact · \(contact.date.formatted(date: .abbreviated, time: .shortened))")
      }
    }
    Button("Open Sparshur") { show(.messages) }
    Button("Devices") { show(.pairPhone) }
    Divider()
    if model.receiverStatus == .listening || model.receiverStatus == .starting {
      Button("Pause receiver") { model.pauseReceiver() }
    } else {
      Button("Resume receiver") { model.resumeReceiver() }
    }
    if model.needsIdentityAccess {
      Button("Authorize existing identity…") { Task { await model.authorizeIdentity() } }
        .disabled(model.isAuthorizingIdentity)
    }
    SettingsLink()
    Divider()
    Button("Quit Sparshur") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
  private func show(_ destination: Destination) {
    model.destination = destination
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}
