import Foundation
import SwiftUI

@main
struct AppEntry {
  @MainActor
  static func main() {
    #if DEBUG
      if let index = CommandLine.arguments.firstIndex(of: "--integration-reply-fd"),
        CommandLine.arguments.indices.contains(index + 1),
        let descriptor = Int32(CommandLine.arguments[index + 1])
      {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let memoryOnly = CommandLine.arguments.contains("--integration-memory")
        Task { await NativeIntegrationSession.run(replyFD: descriptor, memoryOnly: memoryOnly) }
        application.run()
        return
      }
    #endif
    if CommandLine.arguments.contains("--check-identity") {
      let application = NSApplication.shared
      application.setActivationPolicy(.prohibited)
      Task {
        let check = await PlatformService().checkLegacyIdentity()
        print(check.title)
        if case .available(let identity) = check {
          print("Public fingerprint: \(identity.fingerprint)")
          print("Replay high-water: \(identity.highestCounter ?? 0)")
          exit(0)
        }
        exit(2)
      }
      application.run()
    } else {
      SparshurApp.main()
    }
  }
}
