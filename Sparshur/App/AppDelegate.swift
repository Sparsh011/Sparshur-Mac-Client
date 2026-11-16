import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model: AppModel
  private var observers: [NSObjectProtocol] = []

  override convenience init() { self.init(model: AppModel()) }

  init(model: AppModel) {
    self.model = model
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    model.beginSession()

    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in await self?.model.sleep() }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in await self?.model.wake() }
      })
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await model.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    let center = NSWorkspace.shared.notificationCenter
    for observer in observers { center.removeObserver(observer) }
    observers.removeAll()
  }
}
