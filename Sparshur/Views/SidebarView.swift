import SwiftUI

struct SidebarView: View {
  @Environment(AppModel.self) private var model
  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "arrow.triangle.branch")
          .font(Theme.font(19, weight: .semibold))
          .foregroundStyle(Theme.pink)
          .frame(width: 34, height: 34)
          .background(Theme.pink.opacity(0.10))
          .clipShape(RoundedRectangle(cornerRadius: 9))
        Text("Sparshur").font(Theme.font(18, weight: .semibold)).tracking(-0.6)
          .foregroundStyle(Theme.text)
      }
      .padding(.horizontal, 19).padding(.top, 22).padding(.bottom, 20)

      List(selection: $model.destination) {
        ForEach(Destination.allCases) { destination in
          HStack(spacing: 11) {
            Image(systemName: destination.symbol).frame(width: 18)
            Text(destination.title)
            Spacer()
          }
          .font(Theme.font(12, weight: model.destination == destination ? .medium : .regular))
          .padding(.vertical, 7)
          .foregroundStyle(model.destination == destination ? Theme.pink : Theme.secondary)
          .tag(destination)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .padding(.horizontal, 8)
      .accessibilityLabel("Workspace navigation")

      Button {
        model.destination = .pairPhone
      } label: {
        HStack(spacing: 9) {
          Image(systemName: "iphone").foregroundStyle(Theme.pink)
          VStack(alignment: .leading, spacing: 4) {
            Text(model.pairedSenderID == nil ? "Pair an Android phone" : "Android phone")
              .font(Theme.font(11, weight: .semibold)).foregroundStyle(Theme.text)
            if model.pairedSenderID != nil {
              Text("Paired").font(Theme.font(10)).foregroundStyle(Theme.secondary)
            }
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(Theme.font(9)).foregroundStyle(Theme.muted)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 15).padding(.bottom, 15)

      Divider().overlay(Theme.border)
      SettingsLink {
        HStack(spacing: 10) {
          Image(systemName: "gearshape")
          Text("Settings")
          Spacer()
          Text("⌘,").foregroundStyle(Theme.muted)
        }
        .font(Theme.font(11)).foregroundStyle(Theme.secondary)
        .padding(.horizontal, 22).padding(.vertical, 17)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .background(Theme.sidebar)
  }
}
