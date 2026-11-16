import SwiftUI

struct SparshurApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  private var model: AppModel { delegate.model }

  var body: some Scene {
    Window("Sparshur", id: "main") {
      ContentView()
        .environment(model)
        .frame(minWidth: 720, minHeight: 520)
    }
    .defaultSize(width: 1100, height: 760)
    .windowToolbarStyle(.unified)
    .commands {
      CommandMenu("Navigate") {
        Button("Back") { model.goBack() }
          .keyboardShortcut(HistoryShortcuts.back)
          .disabled(!model.canGoBack)
        Button("Forward") { model.goForward() }
          .keyboardShortcut(HistoryShortcuts.forward)
          .disabled(!model.canGoForward)
        Divider()
        ForEach(Destination.allCases) { destination in
          Button(destination.title) { model.destination = destination }
            .keyboardShortcut(destination.shortcut, modifiers: .command)
        }
      }
    }

    Settings {
      SettingsView()
        .environment(model)
        .preferredColorScheme(.dark)
        .tint(Theme.pink)
    }
    MenuBarExtra("Sparshur", systemImage: "arrow.triangle.branch") {
      StatusMenu().environment(model)
    }
  }
}
