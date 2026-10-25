import SwiftUI

struct MessageInspector: View {
  let observation: LocalObservation
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Inspect delivery").font(Theme.font(20, weight: .medium))
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(Array(observation.stages.enumerated()), id: \.offset) { index, stage in
            Label("\(index + 1). \(stage)", systemImage: "checkmark.circle")
              .font(Theme.font(12)).foregroundStyle(Theme.secondary)
          }
          if observation.kind == .paired {
            Explanation(
              title: "What the receipt promises",
              text:
                "The sender and payload were authenticated and replay protection was saved. A receipt does not mean a human read this or that inbox history is durable."
            )
          }
          Text("ACTUAL WIRE ENVELOPE").font(Theme.font(10, weight: .medium)).foregroundStyle(
            Theme.muted)
          Text(String(data: observation.envelope, encoding: .utf8) ?? "Unavailable")
            .font(Theme.font(10, design: .monospaced)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }.padding(24).frame(minWidth: 600, idealWidth: 680, minHeight: 480, idealHeight: 600)
      .background(Theme.background).foregroundStyle(Theme.text).preferredColorScheme(.dark)
  }
}
