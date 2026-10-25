import SwiftUI

struct LearnView: View {
  @Environment(AppModel.self) private var model
  @AppStorage("showComparison") private var showComparison = true
  @State private var inspected: LocalObservation?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(
          eyebrow: "Build it. Understand it.", title: "A little context goes a long way",
          subtitle: "Small lessons, real code and one thing to try. Go at your own pace.")
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(Lesson.allCases) { lesson in
              Button {
                model.selectedLesson = lesson
              } label: {
                HStack(spacing: 7) {
                  Text(String(format: "%02d", lesson.number))
                    .font(Theme.font(10, design: .monospaced))
                  Text(lesson.title).font(Theme.font(11))
                }
                .foregroundStyle(model.selectedLesson == lesson ? Theme.pink : Theme.secondary)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(
                  model.selectedLesson == lesson ? Theme.pink.opacity(0.1) : Theme.surface
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                  RoundedRectangle(cornerRadius: 7).stroke(
                    model.selectedLesson == lesson ? Theme.pink.opacity(0.3) : Theme.border))
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(model.selectedLesson == lesson ? .isSelected : [])
            }
          }.padding(.vertical, 2)
        }
        .scrollIndicators(.automatic)

        HStack {
          Button {
            selectAdjacentLesson(-1)
          } label: {
            Label("Previous", systemImage: "chevron.left")
          }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(model.selectedLesson == Lesson.allCases.first)
          Spacer()
          Text("\(model.selectedLesson.number) of \(Lesson.allCases.count)")
            .font(Theme.font(10, design: .monospaced)).foregroundStyle(Theme.muted)
          Spacer()
          Button {
            selectAdjacentLesson(1)
          } label: {
            Label("Next lesson", systemImage: "chevron.right")
          }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(model.selectedLesson == Lesson.allCases.last)
        }

        Panel {
          VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
              Image(systemName: model.selectedLesson.symbol)
                .font(Theme.font(20)).foregroundStyle(Theme.pink)
                .frame(width: 42, height: 42).background(Theme.pink.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
              VStack(alignment: .leading, spacing: 5) {
                Text("LESSON \(String(format: "%02d", model.selectedLesson.number)) / 09")
                  .font(Theme.font(9, weight: .medium)).tracking(1.2).foregroundStyle(
                    Theme.muted)
                Text(model.selectedLesson.title).font(Theme.font(20, weight: .medium))
                  .foregroundStyle(Theme.text)
              }
            }
            Text(model.selectedLesson.summary).font(Theme.font(14))
              .foregroundStyle(Theme.secondary).lineSpacing(5)
              .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.border)
            Text("WHAT HAPPENS").font(Theme.font(9, weight: .semibold)).tracking(1.2)
              .foregroundStyle(Theme.muted)
            ForEach(Array(model.selectedLesson.steps.enumerated()), id: \.offset) { index, step in
              HStack(alignment: .top, spacing: 14) {
                Text(String(format: "%02d", index + 1))
                  .font(Theme.font(10, design: .monospaced)).foregroundStyle(Theme.pink)
                  .padding(.top, 3)
                Text(step).font(Theme.font(12)).foregroundStyle(Theme.secondary).lineSpacing(5)
                  .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
              }
            }
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 9) {
              Label("WHERE IN CODE", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(Theme.font(9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
              Text(model.selectedLesson.code).font(Theme.font(10, design: .monospaced))
                .foregroundStyle(Theme.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        Explanation(title: "Try this", text: model.selectedLesson.exercise)
        if showComparison {
          comparison
          if !model.comparisons.isEmpty {
            Text("Received comparison samples").font(Theme.font(14, weight: .medium))
              .foregroundStyle(Theme.text)
          }
          ForEach(model.comparisons) { observation in
            Panel { ObservationRow(observation: observation) { inspected = observation } }
          }
        }
      }
      .padding(30).frame(maxWidth: 1060).frame(maxWidth: .infinity)
    }.sheet(item: $inspected) { MessageInspector(observation: $0) }
  }

  private func selectAdjacentLesson(_ offset: Int) {
    let next = model.selectedLesson.number - 1 + offset
    guard Lesson.allCases.indices.contains(next) else { return }
    model.selectedLesson = Lesson.allCases[next]
  }

  private var comparison: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 14) {
        Text("Conceptual comparison · these are explanations, not received messages.")
          .font(Theme.font(10)).foregroundStyle(Theme.muted)
        comparisonRow(
          title: "Readable sample",
          text: "Sender unverified. The text is readable in transit and on the Mac.",
          symbol: "text.alignleft")
        comparisonRow(
          title: "Phone-only AES",
          text: "Encrypted with Android's own Keystore key. The Mac cannot decrypt it.",
          symbol: "iphone.gen3.radiowaves.left.and.right")
        comparisonRow(
          title: "Paired encryption",
          text:
            "Only the intended Mac can unwrap the message key. Sender and payload are verified before display.",
          symbol: "lock.shield")
      }.padding(.top, 16)
    } label: {
      Text("Three paths, three different guarantees")
        .font(Theme.font(12, weight: .medium)).foregroundStyle(Theme.text)
    }
    .padding(18).background(Theme.surface)
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
  }

  private func comparisonRow(title: String, text: String, symbol: String)
    -> some View
  {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).frame(width: 18).foregroundStyle(Theme.pink)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(Theme.font(12, weight: .medium)).foregroundStyle(Theme.text)
        Text(text).font(Theme.font(11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
