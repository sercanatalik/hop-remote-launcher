# Design

## Context

`HopApp` declared a `MenuBarExtra` in `.window` style as its first scene and a `Window("Manage Macs")` as its second. `Popover.close` closed the popover by closing its window, because `MenuBarExtra` offers no call for it. The spike in `add-quick-open-hotkey` found no way to open it from code on macOS 27.2.

## Goals / Non-Goals

**Goals:**
- Open, close and toggle the popover from code.
- Keep `PopoverView` and `ManagerView` unchanged.

**Non-Goals:**
- Reproducing the arrowless look of the `MenuBarExtra` window.

## Decisions

1. **`NSStatusItem` plus `NSPopover`, hosted by an application delegate.** `AppController` creates the status item, hosts `PopoverView` in an `NSHostingController` with `sizingOptions = [.preferredContentSize]` so the popover follows the content's height, and uses `.transient` behavior so a click elsewhere closes it. A custom borderless panel would keep the old look but needs its own outside-click and placement handling.
2. **Keep the Manage Macs window as a SwiftUI `Window` scene.** Hosting it in an `NSWindow` would risk losing its SwiftUI toolbar on macOS 13, where scene bridging for hosting controllers does not exist. `openWindow(id:)` called from the popover's hosting controller was checked and opens the window with its toolbar.
3. **A never-inserted `MenuBarExtra` stays as the first scene.** With the `Window` as the only scene, SwiftUI would open Manage Macs at launch. Keeping a `MenuBarExtra` with `isInserted` false leaves the `Window` a secondary scene, which is not opened at launch.
4. **`applicationShouldTerminateAfterLastWindowClosed` returns false.** Without it the app quit, with exit status 0, the first time the popover closed.
5. **The blocked count is the status item's title.** The controller watches the store and sets the button title next to the glyph.

## Risks / Trade-offs

- [The popover now has an arrow and standard popover chrome] → Accepted; it is the system look for a status item popover.
- [`onAppear` may not fire each time a persistent popover is shown] → The controller refreshes the store and bumps a counter on every show; the list resets from that counter.
