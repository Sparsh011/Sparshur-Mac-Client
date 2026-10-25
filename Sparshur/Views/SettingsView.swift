import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @AppStorage("showExplanations") private var showExplanations = true
  @AppStorage("showComparison") private var showComparison = true
  @State private var selectedTab: SettingsTab = .general

  private enum SettingsTab: String, CaseIterable {
    case general = "General"
    case diagnostics = "Diagnostics"
    var symbol: String { self == .general ? "slider.horizontal.3" : "stethoscope" }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        ForEach(SettingsTab.allCases, id: \.self) { tab in
          Button {
            selectedTab = tab
          } label: {
            Label(tab.rawValue, systemImage: tab.symbol)
              .font(Theme.font(12, weight: .medium))
              .foregroundStyle(selectedTab == tab ? Theme.pink : Theme.secondary)
              .padding(.horizontal, 15).padding(.vertical, 12)
              .background(selectedTab == tab ? Theme.pink.opacity(0.09) : Color.clear)
              .clipShape(RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
        }
        Spacer()
      }.padding(15)
      Divider().overlay(Theme.border)
      if selectedTab == .general {
        Form {
          Section("Learning") {
            Toggle("Show short explanations", isOn: $showExplanations)
            Toggle("Show the original comparison lesson", isOn: $showComparison)
          }
          Section("Appearance") {
            LabeledContent("Theme", value: "Dark")
            LabeledContent("Primary colour") {
              HStack(spacing: 7) {
                Circle().fill(Theme.pink).frame(width: 9, height: 9)
                Text("#F72681").font(Theme.font(13, design: .monospaced))
              }
            }
          }
          Section("History") {
            Text(
              "The inbox keeps up to 40 observations in memory. Quitting clears their contents; pairing and replay state belong in Keychain."
            )
            .font(Theme.font(11)).foregroundStyle(Theme.secondary)
            Text(
              "Message contents are not persisted. Pause from the menu bar to stop incoming requests."
            )
            .font(Theme.font(11)).foregroundStyle(Theme.muted)
          }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            HStack {
              VStack(alignment: .leading, spacing: 6) {
                Text("Local readiness").font(Theme.font(18, weight: .semibold))
                Text("Read-only identity check and a temporary loopback socket.")
                  .font(Theme.font(11)).foregroundStyle(Theme.secondary)
              }
              Spacer()
              Button(model.isCheckingPlatform ? "Checking…" : "Run checks") {
                Task { await model.checkPlatform() }
              }
              .buttonStyle(SecondaryButtonStyle()).disabled(model.isCheckingPlatform)
            }
            Panel {
              VStack(alignment: .leading, spacing: 17) {
                diagnostic(
                  title: "Existing Keychain identity", value: model.identityCheck.title,
                  detail: model.identityCheck.detail)
                Divider().overlay(Theme.border)
                diagnostic(
                  title: "Incoming socket", value: model.listenerCheck.title,
                  detail: model.listenerCheck.detail)
                Divider().overlay(Theme.border)
                diagnostic(
                  title: "Lab receiver", value: model.receiverStatus.title,
                  detail:
                    "Native HTTP on port 8787. A listening socket does not mean your phone is online. Real phone reachability must be checked separately."
                )
                Divider().overlay(Theme.border)
                diagnostic(
                  title: "Mac mini relay", value: model.relayStatus.title,
                  detail:
                    "Outbound TLS WebSocket. Configure SPARSHUR_RELAY_URL and SPARSHUR_RELAY_ID in the launch environment. Bidirectional encrypted messaging requires the relay pairing upgrade."
                )
              }.padding(18)
            }
            if let checkedAt = model.checkedAt {
              Text("Last checked \(checkedAt.formatted(date: .omitted, time: .standard))")
                .font(Theme.font(10)).foregroundStyle(Theme.muted)
            }
            Text(
              "Sparshur \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") · macOS 14+"
            )
            .font(Theme.font(10)).foregroundStyle(Theme.muted)
          }.padding(24)
        }
        .background(Theme.background)
      }
    }
    .frame(width: 600, height: 490)
    .font(Theme.font(13))
    .background(Theme.background)
  }

  private func diagnostic(title: String, value: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased()).font(Theme.font(9, weight: .medium)).tracking(1).foregroundStyle(
        Theme.muted)
      Text(value).font(Theme.font(12, weight: .medium)).foregroundStyle(Theme.text)
      Text(detail).font(Theme.font(11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
