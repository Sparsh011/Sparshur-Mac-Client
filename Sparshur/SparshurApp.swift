import SwiftUI

struct SparshurApp: App {
  // The App owns this reference; changing screens never creates a second model.
  @State private var model = AppModel()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Window("Sparshur", id: "main") {
      ContentView()
        .environment(model)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
          delegate.model = model
          model.beginSession()
        }
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
