import SwiftUI

struct StatusMenu: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Text(model.receiverStatus.shortTitle)
    Button("Open Sparshur") { show(.messages) }
    Button("Pair phone") { show(.pairPhone) }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  private var observers: [NSObjectProtocol] = []
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationDidFinishLaunching(_ notification: Notification) {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in await self?.model?.sleep() }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in await self?.model?.wake() }
      })
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    Task {
      await model.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
