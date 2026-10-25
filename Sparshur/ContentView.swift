import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    } detail: {
      Group {
        switch model.destination {
        case .messages: MessagesView()
        case .pairPhone: PairPhoneView()
        case .learn: LearnView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Theme.background)
      .navigationTitle("Sparshur — \(model.destination.title)")
      .toolbar {
        ToolbarItemGroup(placement: .navigation) {
          Button {
            model.goBack()
          } label: {
            Label("Back", systemImage: "chevron.left")
          }
          .help(
            model.previousDestination.map { "Back to \($0.title) (⌘[ or ⌘{)" } ?? "Back"
          )
          .keyboardShortcut(HistoryShortcuts.backWithShift)
          .disabled(!model.canGoBack)
          .accessibilityLabel("Back")
          Button {
            model.goForward()
          } label: {
            Label("Forward", systemImage: "chevron.right")
          }
          .help(model.nextDestination.map { "Forward to \($0.title) (⌘] or ⌘})" } ?? "Forward")
          .keyboardShortcut(HistoryShortcuts.forwardWithShift)
          .disabled(!model.canGoForward)
          .accessibilityLabel("Forward")
        }
        ToolbarItem(placement: .primaryAction) {
          StatusBadge(
            title: model.receiverStatus.shortTitle,
            symbol: model.receiverStatus == .listening
              ? "antenna.radiowaves.left.and.right" : "circle.dashed"
          )
          .labelStyle(.titleAndIcon)
          .help(model.receiverStatus.title)
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .font(Theme.font(13))
    .tint(Theme.pink)
    .preferredColorScheme(.dark)
    .task { await model.refreshAddresses() }
  }
}

#Preview {
  ContentView().environment(AppModel()).frame(width: 1100, height: 760)
}
