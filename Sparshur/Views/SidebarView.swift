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
        VStack(alignment: .leading, spacing: 3) {
          Text("sparshur").font(Theme.font(19, weight: .semibold)).tracking(-0.6)
            .foregroundStyle(Theme.text)
          Text("ANDROID ↔ MAC").font(Theme.font(8, weight: .medium)).tracking(1.5)
            .foregroundStyle(Theme.muted)
        }
      }
      .padding(.horizontal, 19).padding(.top, 22).padding(.bottom, 30)

      Text("WORKSPACE").font(Theme.font(9, weight: .semibold)).tracking(1.5)
        .foregroundStyle(Theme.muted).padding(.horizontal, 22).padding(.bottom, 8)

      List(selection: $model.destination) {
        ForEach(Destination.allCases) { destination in
          HStack(spacing: 11) {
            Image(systemName: destination.symbol).frame(width: 18)
            Text(destination.title)
            Spacer()
            if destination == .messages {
              Text("\(model.verifiedMessages.count)").font(Theme.font(10, design: .monospaced))
                .foregroundStyle(Theme.muted)
            }
          }
          .font(Theme.font(12, weight: model.destination == destination ? .medium : .regular))
          .padding(.vertical, 7)
          .foregroundStyle(model.destination == destination ? Theme.pink : Theme.secondary)
          .listRowBackground(
            model.destination == destination ? Theme.pink.opacity(0.09) : Color.clear
          )
          .tag(destination)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .padding(.horizontal, 8)
      .accessibilityLabel("Workspace navigation")

      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 7) {
          Image(systemName: "desktopcomputer").foregroundStyle(Theme.secondary)
          Text("This Mac").font(Theme.font(11, weight: .medium))
          Spacer()
          Text("LOCAL").font(Theme.font(8, weight: .semibold)).tracking(0.8)
            .foregroundStyle(Theme.muted)
        }
        HStack(spacing: 6) {
          Circle().stroke(Theme.muted, lineWidth: 1.5).frame(width: 5, height: 5)
          Text(model.receiverStatus.shortTitle).font(Theme.font(10)).foregroundStyle(
            Theme.secondary)
        }
      }
      .padding(13)
      .background(Theme.surface)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
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
