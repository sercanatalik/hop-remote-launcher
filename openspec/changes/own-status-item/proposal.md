# Proposal

## Why

The `add-quick-open-hotkey` spike showed that SwiftUI's `MenuBarExtra` cannot be opened from code: its button ignored `performClick`, synthetic mouse events and a direct `mouseDown`. A global shortcut needs to open the popover, so Hop has to own its menu-bar item.

## What Changes

- Hop creates its own menu-bar item (`NSStatusItem`) and shows the same popover content in an `NSPopover`, in place of `MenuBarExtra`.
- The popover can now be opened and closed from code, and is closed through its own API instead of by closing its window.
- The popover gains the standard pointer arrow under the menu-bar icon. Nothing else about its content changes.
- Hop explicitly stays running when its last window closes.

Out of scope: any change to what the popover or the Manage Macs window contain.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. The `menu-bar-popover` requirements (a popover anchored to the icon, its header, list and shortcuts) are unchanged, so this change sets `skip_specs: true`.

## Impact

- `Hop.swift`: a new `AppController` (application delegate) owning the status item and popover; `HopApp` keeps the Manage Macs `Window` scene and a never-inserted `MenuBarExtra` as its first scene; `Popover.close` and `QuickOpen.togglePopover` go through the controller.
- Adds `import Combine` to watch the store for the blocked-agent count.
