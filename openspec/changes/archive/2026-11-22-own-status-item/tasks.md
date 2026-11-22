# Tasks

## 1. Own the menu-bar item

- [x] 1.1 Replace `MenuBarExtra` with an `NSStatusItem` and an `NSPopover` hosting `PopoverView`, opened, closed and toggled through `AppController`; verify with a scripted build that the popover shows, becomes key and closes
- [x] 1.2 Keep the app running when its last window closes and keep Manage Macs closed at launch; verify with the scripted build that no window is visible at launch and the app survives closing the popover
- [x] 1.3 Keep Manage Macs as a SwiftUI `Window` scene opened from the popover; verify with the scripted build that Command-comma opens it with its toolbar items and closes the popover
- [x] 1.4 Show the blocked-agent count beside the glyph; verify with a blocked agent that the menu bar shows the number and that it clears

## 2. Integration checks

- [x] 2.1 Run `openspec validate own-status-item --strict` and build the app; verify both succeed
- [ ] 2.2 In the installed build, click the menu-bar icon to open the popover, click elsewhere to close it, and confirm it looks right in light and dark mode
