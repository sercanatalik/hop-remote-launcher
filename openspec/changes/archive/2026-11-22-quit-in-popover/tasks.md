# Tasks

## 1. Manage Macs and Quit in the popover

- [x] 1.1 Show "Manage Macs…" and "Quit Hop" with their shortcuts on one line at the bottom of the Mac list, remove both from the "More" menu, and keep Command-comma and Command-Q on their hidden buttons; verify with an offscreen render of the popover and by reading that the hidden shortcut buttons are untouched
- [x] 1.2 Update the README sentence that lists the More menu's items; verify it lists neither Manage Macs nor Quit Hop there

## 2. Integration checks

- [x] 2.1 Run `openspec validate quit-in-popover --strict` and build the app; verify both succeed
- [ ] 2.2 In the running app, confirm both controls show at the bottom of the Mac list, that Manage Macs opens the window and Quit Hop quits
