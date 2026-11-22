# Design

## Context

The popover is a SwiftUI `MenuBarExtra` in `.window` style. SwiftUI gives no API to open it from code, and Hop closes it by closing its window directly (`Popover.close`). The popover already has hidden buttons that own Command-comma and Command-Q, and Command-R on Refresh.

## Goals / Non-Goals

**Goals:**
- A shortcut that works with no permission prompt.
- Keyboard filtering with no always-visible search field.

**Non-Goals:**
- Replacing `MenuBarExtra` unless the spike shows it cannot be opened from code.

## Decisions

1. **Carbon `RegisterEventHotKey` for the global shortcut.** It needs no Accessibility permission, unlike an `NSEvent` global monitor, and no dependency. Registration failure is reported by the call, which is how Hop learns the shortcut is taken.
2. **Open the popover by clicking the status item's button.** The status bar button is found through the app's windows and sent `performClick`. This is the known way to toggle a `MenuBarExtra`, but it relies on private view structure, so it is the first task. Fallback: replace `MenuBarExtra` with an `NSStatusItem` and an `NSPopover` hosting the same `PopoverView`; that would also give Hop a real way to close the popover.
3. **Presets, not a recorder.** A free-form recorder is a sizeable control to write without a dependency. Three presets plus Off cover the need; a recorder can come later without changing the spec's shape.
4. **Typing is captured at the popover level.** A key handler on the popover collects printable characters into a query held in `PopoverView`, shown in the header in place of the online count. Returning to the list from a detail view, and reopening the popover, clear it.
5. **The highlight is the first match by default**, so shortcut, a few letters, Return is the whole path. Command-1 to Command-3 map to the row's actions in the order they are drawn.

## Spike outcome

The spike (task 1.1) failed on macOS 27.2: the `MenuBarExtra` button ignored `performClick`, synthetic mouse events and a direct `mouseDown`. The fallback in decision 2 was taken as its own change, `own-status-item`, and this change builds on it: the shortcut calls `AppController.togglePopover`.

## Risks / Trade-offs

- [Opening `MenuBarExtra` from code may break in a macOS update] → Spike first; the `NSStatusItem` fallback is specified.
- [A preset may collide with another app] → Registration failure is surfaced in Manage Macs and the setting falls back to Off.
- [Key handling in a non-activating status window can miss keys until the window is key] → Covered by the spike; the popover must become key when opened by the shortcut.
