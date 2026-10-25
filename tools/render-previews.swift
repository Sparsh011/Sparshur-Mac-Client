// Render this project's own views into offscreen bitmaps for layout review.
// This does not inspect or control a running application or the desktop.
import AppKit
import SwiftUI

@main
@MainActor
struct RenderPreviews {
  static func main() throws {
    let output = URL(
      fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/sparshur-previews")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .darkAqua)

    var previews: [(String, AnyView, CGSize)] = []
    for (name, destination, size) in [
      ("messages", Destination.messages, CGSize(width: 1100, height: 760)),
      ("pair-phone", Destination.pairPhone, CGSize(width: 1100, height: 760)),
      ("learn", Destination.learn, CGSize(width: 1100, height: 900)),
      ("messages-compact", Destination.messages, CGSize(width: 720, height: 520)),
      ("pair-phone-compact", Destination.pairPhone, CGSize(width: 720, height: 700)),
    ] {
      let model = AppModel()
      model.destination = destination
      // No sample identities, messages, network addresses or QR secrets.
      previews.append((name, AnyView(ContentView().environment(model)), size))
    }
    previews.append(
      (
        "settings",
        AnyView(
          SettingsView().environment(AppModel()).preferredColorScheme(.dark).tint(Theme.pink)),
        CGSize(width: 600, height: 490)
      ))

    for (name, view, size) in previews {
      let hosting = NSHostingView(rootView: view)
      let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
      window.contentView = hosting
      hosting.frame = CGRect(origin: .zero, size: size)
      window.appearance = NSAppearance(named: .darkAqua)
      hosting.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.25))
      hosting.layoutSubtreeIfNeeded()
      guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw RenderError.noBitmap
      }
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw RenderError.noBitmap
      }
      try png.write(to: output.appendingPathComponent("\(name).png"))
      window.contentView = nil
    }
    print("Rendered \(previews.count) offscreen previews to \(output.path)")
  }

  private enum RenderError: Error { case noBitmap }
}
