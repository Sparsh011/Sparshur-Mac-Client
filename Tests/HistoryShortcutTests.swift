import AppKit
import SwiftUI
import XCTest

@testable import SparshurPlatform

@MainActor
private final class ShortcutTarget: NSObject {
  var invocations = 0
  @objc func navigate(_ sender: Any?) { invocations += 1 }
}

final class HistoryShortcutTests: XCTestCase {
  @MainActor
  func testAppKitMatchesBracketsAndShiftedBraces() async throws {
    _ = NSApplication.shared
    for (shortcut, character, shift, keyCode) in [
      (HistoryShortcuts.back, "[", false, UInt16(33)),
      (HistoryShortcuts.forward, "]", false, UInt16(30)),
      (HistoryShortcuts.backWithShift, "{", true, UInt16(33)),
      (HistoryShortcuts.forwardWithShift, "}", true, UInt16(30)),
    ] {
      let target = ShortcutTarget()
      let menu = NSMenu(title: "Isolated shortcut test")
      menu.autoenablesItems = false
      let item = NSMenuItem(
        title: "Navigate", action: #selector(ShortcutTarget.navigate(_:)),
        keyEquivalent: String(shortcut.key.character))
      item.target = target
      item.keyEquivalentModifierMask = shortcut.modifiers.contains(.command) ? [.command] : []
      menu.addItem(item)
      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command],
          timestamp: 0, windowNumber: 0, context: nil, characters: character,
          charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
      XCTAssertTrue(menu.performKeyEquivalent(with: event), character)
      XCTAssertEqual(target.invocations, 1, character)
      item.isEnabled = false
      // AppKit may consume a disabled key equivalent, but must not run its action.
      _ = menu.performKeyEquivalent(with: event)
      XCTAssertEqual(target.invocations, 1, character)
    }
  }
}
