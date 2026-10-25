import SwiftUI

enum HistoryShortcuts {
  static let back = KeyboardShortcut("[", modifiers: .command)
  static let forward = KeyboardShortcut("]", modifiers: .command)

  // AppKit key equivalents use the resulting punctuation character. Shift-[
  // produces "{"; registering "[" plus an explicit Shift mask does not match it.
  static let backWithShift = KeyboardShortcut("{", modifiers: .command)
  static let forwardWithShift = KeyboardShortcut("}", modifiers: .command)
}
