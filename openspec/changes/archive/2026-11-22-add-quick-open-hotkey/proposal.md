# Proposal

## Why

Reaching a Mac in Hop always starts with the mouse: find the menu-bar icon, click, find the row, point, click. For something used many times a day, a keyboard path is faster, and none of the comparable menu-bar launchers offer one (Shuttle only lists hotkeys on its roadmap).

## What Changes

- A global keyboard shortcut opens the Hop popover from any app, and closes it when pressed again. It is off by default and chosen from a short list in the Manage Macs window.
- With the popover open, typing filters the Mac list by name or address. The typed text is shown in the header; there is no search field at rest, so the quiet layout stays.
- Arrow keys move a highlight through the listed Macs. Return opens the highlighted Mac's detail view; Command-1, Command-2 and Command-3 run its first, second and third connection action.
- Escape clears the typed text, and closes the popover when there is none.

Proposed defaults not yet confirmed by the user:

- The shortcut is picked from presets (Control-Option-Space, Control-Option-H, Option-Command-H, Off), not recorded freely.
- Return opens the detail view, and the connection actions are on Command-1 to Command-3.
- Filtering covers Macs only, not workspaces.

Out of scope: a free-form shortcut recorder; searching Herdr workspaces; fuzzy matching.

## Capabilities

### New Capabilities

- `quick-open`: the global shortcut that opens the popover, and keyboard filtering, selection and actions inside it.

### Modified Capabilities

None.

## Impact

- `Hop.swift`: a hotkey registration (Carbon `RegisterEventHotKey`, which needs no Accessibility permission), `PopoverView` (key handling, filter, highlight), `MacRow` (highlight state), `ManagerView` (shortcut picker), a way to open the popover from code.
- Adds `import Carbon`; no third-party dependency.
- README and website: a short "Keyboard" section.
