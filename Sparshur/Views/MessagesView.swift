import SwiftUI

struct MessagesView: View {
  @Environment(AppModel.self) private var model
  @AppStorage("showExplanations") private var showExplanations = true
  @State private var inspected: LocalObservation?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(
          eyebrow: "Your local inbox", title: "Messages",
          subtitle: "Messages from your Android phone, verified on this Mac.")
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            SummaryCard(
              symbol: "iphone", title: "PAIRED PHONE", value: model.pairingSummary,
              detail: model.pairingDetail)
            SummaryCard(
              symbol: "antenna.radiowaves.left.and.right", title: "RECEIVER",
              value: model.receiverStatus == .listening ? "Listening" : "Not receiving",
              detail: "Local HTTP · port 8787")
            SummaryCard(
              symbol: "checkmark.shield", title: "VERIFIED MESSAGES",
              value: "\(model.verifiedCount)", detail: "Accepted in this session")
          }
          Panel {
            VStack(alignment: .leading, spacing: 10) {
              Text("Phone: \(model.pairingSummary)")
              Text(model.receiverStatus.title)
              Text("Verified messages: \(model.verifiedCount)")
            }.font(Theme.font(11)).foregroundStyle(Theme.secondary).frame(
              maxWidth: .infinity, alignment: .leading
            ).padding(17)
          }
        }
        Panel {
          VStack(spacing: 0) {
            HStack {
              Label("Inbox", systemImage: "tray").font(Theme.font(12, weight: .semibold))
              StatusBadge(title: "\(model.verifiedMessages.count) displayed")
              Spacer()
            }.padding(17).foregroundStyle(Theme.text)
            Divider().overlay(Theme.border)
            if model.verifiedMessages.isEmpty {
              VStack(spacing: 14) {
                DeviceIllustration()
                Text(
                  model.savedIdentity?.senderID == nil
                    ? "Your first message starts here"
                    : "Ready for a message from your paired phone"
                )
                .font(Theme.font(19, weight: .medium)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                Text(
                  model.receiverStatus == .listening
                    ? "Send a message from Android. Verified deliveries appear here."
                    : "Start the receiver to accept messages from your phone."
                )
                .font(Theme.font(12)).foregroundStyle(Theme.secondary).multilineTextAlignment(
                  .center)
                Button {
                  model.destination = .pairPhone
                } label: {
                  Label("Pair phone", systemImage: "qrcode")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("How does pairing work?") { model.showLesson(.pairing) }
                  .buttonStyle(.plain).font(Theme.font(11)).foregroundStyle(Theme.secondary)
              }.padding(30).frame(maxWidth: .infinity)
            } else {
              LazyVStack(spacing: 0) {
                ForEach(model.verifiedMessages) { observation in
                  ObservationRow(observation: observation) { inspected = observation }
                  Divider().overlay(Theme.border)
                }
              }
            }
            HStack {
              Label("Last 40 observations · memory only", systemImage: "clock.arrow.circlepath")
              Spacer()
              Text("\(model.duplicateCount) duplicates")
            }.font(Theme.font(10)).foregroundStyle(Theme.muted).padding(14)
          }
        }
        if model.receiverStatus != .listening {
          HStack {
            Text(model.receiverStatus.title).font(Theme.font(11)).foregroundStyle(Theme.secondary)
            Spacer()
            if model.needsIdentityAccess {
              Button("Authorize existing identity…") { Task { await model.authorizeIdentity() } }
                .buttonStyle(SecondaryButtonStyle()).disabled(model.isAuthorizingIdentity)
            } else {
              Button("Start receiver") { model.resumeReceiver() }.buttonStyle(
                SecondaryButtonStyle()
              ).disabled(model.receiverStatus == .starting)
            }
          }
        }
        if showExplanations {
          Explanation(
            title: "What gets verified?",
            text:
              "Sender signature → key unwrap → payload verification → saved replay state → signed receipt. Readable and phone-only samples appear separately in Learn."
          )
        }
      }.padding(30).frame(maxWidth: 1060).frame(maxWidth: .infinity)
    }.sheet(item: $inspected) { MessageInspector(observation: $0) }
  }
}

struct ObservationRow: View {
  let observation: LocalObservation
  let inspect: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(
          observation.kind == .paired
            ? "Paired sender verified"
            : observation.kind == .readable
              ? "Readable sample — sender unverified" : "Phone-only AES — Mac has no key"
        )
        .font(Theme.font(10, weight: .medium)).foregroundStyle(Theme.pink)
        Spacer()
        Text(observation.receivedAt.formatted(date: .omitted, time: .shortened)).font(
          Theme.font(10)
        ).foregroundStyle(Theme.muted)
      }
      Text(observation.plaintext ?? "Ciphertext stays unreadable on this Mac.")
        .font(Theme.font(14)).foregroundStyle(Theme.text).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Button("Inspect") { inspect() }.buttonStyle(SecondaryButtonStyle())
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SummaryCard: View {
  let symbol: String
  let title: String
  let value: String
  let detail: String
  var body: some View {
    Panel {
      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 7) {
          Image(systemName: symbol).font(Theme.font(12)).foregroundStyle(Theme.pink)
          Text(title).font(Theme.font(8, weight: .medium)).tracking(0.8)
            .foregroundStyle(Theme.secondary)
        }
        Text(value).font(Theme.font(17, weight: .medium)).foregroundStyle(Theme.text)
        Text(detail).font(Theme.font(10)).foregroundStyle(Theme.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading).padding(17)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

struct DeviceIllustration: View {
  var body: some View {
    HStack(spacing: 15) {
      ZStack {
        RoundedRectangle(cornerRadius: 9).fill(Theme.raised).frame(width: 43, height: 70)
        RoundedRectangle(cornerRadius: 9).stroke(Theme.secondary.opacity(0.45)).frame(
          width: 43, height: 70)
        VStack {
          Capsule().fill(Theme.muted).frame(width: 12, height: 2).padding(.top, 7)
          Spacer()
          Image(systemName: "bubble.left.fill").font(Theme.font(16)).foregroundStyle(Theme.pink)
          Spacer()
          Capsule().fill(Theme.muted).frame(width: 13, height: 2).padding(.bottom, 6)
        }.frame(width: 43, height: 70)
      }
      HStack(spacing: 5) {
        ForEach(0..<3) { _ in Circle().fill(Theme.pink.opacity(0.4)).frame(width: 3, height: 3) }
        Image(systemName: "lock.fill").font(Theme.font(10)).foregroundStyle(Theme.pink)
        ForEach(0..<3) { _ in Circle().fill(Theme.pink.opacity(0.4)).frame(width: 3, height: 3) }
      }
      VStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 6).fill(Theme.raised)
          .frame(width: 85, height: 55)
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.secondary.opacity(0.45)))
          .overlay(
            Image(systemName: "checkmark.shield").font(Theme.font(20)).foregroundStyle(
              Theme.pink))
        Rectangle().fill(Theme.secondary.opacity(0.4)).frame(width: 12, height: 8)
        Capsule().fill(Theme.secondary.opacity(0.4)).frame(width: 40, height: 2)
      }
    }
    .frame(height: 85)
    .accessibilityHidden(true)
  }
}
