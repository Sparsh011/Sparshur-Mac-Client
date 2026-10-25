import SwiftUI

enum Theme {
  static let fontScale: CGFloat = 1.2

  static func font(
    _ baseSize: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default
  ) -> Font {
    .system(size: baseSize * fontScale, weight: weight, design: design)
  }

  static let pink = Color(red: 247 / 255, green: 38 / 255, blue: 129 / 255)
  static let background = Color(red: 0.075, green: 0.075, blue: 0.085)
  static let sidebar = Color(red: 0.092, green: 0.092, blue: 0.105)
  static let surface = Color(red: 0.105, green: 0.105, blue: 0.12)
  static let raised = Color(red: 0.135, green: 0.135, blue: 0.15)
  static let border = Color.white.opacity(0.085)
  static let text = Color(red: 0.94, green: 0.94, blue: 0.96)
  static let secondary = Color(red: 0.65, green: 0.65, blue: 0.69)
  static let muted = Color(red: 0.49, green: 0.49, blue: 0.54)
}

struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.font(12, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 16).padding(.vertical, 10)
      .background(Theme.pink.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.3))
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .opacity(isEnabled ? 1 : 0.55)
      .contentShape(RoundedRectangle(cornerRadius: 7))
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.font(12, weight: .medium))
      .foregroundStyle(Theme.text)
      .padding(.horizontal, 14).padding(.vertical, 10)
      .background(configuration.isPressed ? Theme.raised : Theme.surface)
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
      .opacity(isEnabled ? 1 : 0.45)
  }
}

struct Panel<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    content
      .background(Theme.surface)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
  }
}

struct StatusBadge: View {
  let title: String
  var symbol = "circle"
  var accented = false
  var body: some View {
    Label(title, systemImage: symbol)
      .font(Theme.font(10, weight: .medium))
      .foregroundStyle(accented ? Theme.pink : Theme.secondary)
      .padding(.horizontal, 9).padding(.vertical, 5)
      .background(accented ? Theme.pink.opacity(0.1) : Theme.raised)
      .clipShape(Capsule())
      .fixedSize()
  }
}

struct PageHeader: View {
  let eyebrow: String
  let title: String
  let subtitle: String
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(eyebrow.uppercased())
        .font(Theme.font(10, weight: .semibold)).tracking(1.8)
        .foregroundStyle(Theme.pink)
      Text(title).font(Theme.font(29, weight: .semibold)).tracking(-0.8)
        .foregroundStyle(Theme.text)
      Text(subtitle).font(Theme.font(12)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct Explanation: View {
  let title: String
  let text: String
  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: "info.circle").foregroundStyle(Theme.pink).padding(.top, 1)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(Theme.font(12, weight: .medium)).foregroundStyle(Theme.text)
        Text(text).font(Theme.font(11)).foregroundStyle(Theme.secondary)
          .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.pink.opacity(0.045))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.pink.opacity(0.14)))
  }
}
