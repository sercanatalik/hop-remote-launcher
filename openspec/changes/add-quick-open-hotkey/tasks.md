# Tasks

## 1. Spike: opening the popover from code

- [x] 1.1 In a throwaway build, find the status item's button and toggle the `MenuBarExtra` popover with `performClick`; confirm it opens from another app, becomes key and receives key presses; record the result in a comment above the new code, and if it is unreliable, record the decision to move to `NSStatusItem` plus `NSPopover` and stop to update the task list

## 2. Global shortcut

- [ ] 2.1 Register a global shortcut with Carbon `RegisterEventHotKey` that toggles the popover, re-registering when the setting changes; verify from another app with each preset
- [ ] 2.2 Save the choice in `UserDefaults` (default Off) and add the picker to the Manage Macs window; verify the choice survives a relaunch
- [ ] 2.3 Report a failed registration in the Manage Macs window and fall back to Off; verify by choosing a shortcut held by another app
- [x] 2.4 Describe the shortcut and where to set it in the README and on the website; verify both mention it

## 3. Keyboard in the popover

- [x] 3.1 Collect typed text at the popover level, filter the Mac list by name or address ignoring case, show the text in the header and a "no Macs match" line; clear it on reopen and on Escape; verify each `quick-open` filtering scenario
- [ ] 3.2 Highlight the first listed Mac while text is typed, move the highlight with Up and Down, and mark it with a shape or outline as well as a tint; verify by keyboard and with Increase Contrast on
- [ ] 3.3 Open the highlighted Mac's detail view on Return and run its actions on Command-1 to Command-3, without disturbing Command-R, Command-comma and Command-Q; verify each shortcut
- [ ] 3.4 Show the key line at the bottom of the popover while text is typed, naming Return, Command-1 to Command-3 with the highlighted Mac's actions, and Escape; verify it is absent with nothing typed
- [x] 3.5 Document the popover keys in the README; verify the keys listed match the build

## 4. Integration checks

- [x] 4.1 Run `openspec validate add-quick-open-hotkey --strict` and build the app; verify both succeed
- [ ] 4.2 In the running app, go from another app to an SSH session using only the keyboard
