# Proposal

## Why

Quit Hop sat inside the header's "More" menu, where it takes two clicks and is easy to miss. The user asked for it in the popover's main view. A first attempt, a lone "Quit Hop" label under a divider, looked like a leftover footer; of four designs explored (canvas: https://claude.ai/artifact/XWbUDRCFf7rMLjQRQaqFEh) the user chose the two-item line.

## What Changes

- The bottom of the Mac list shows one quiet line: "Manage Macs…" on the left and "Quit Hop" on the right, each with its keyboard shortcut shown beside it, in the same style as the key line that appears while typing.
- Both are removed from the "More" menu, so each is offered in one place.
- Command-comma and Command-Q are unchanged and keep working in the Mac list and in a Mac's detail view.
- The line is not shown in a Mac's detail view, and the key line takes its place while text is typed.

Out of scope: any other change to the "More" menu.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `menu-bar-popover`: Manage Macs and Quit Hop move from the "More" menu to visible controls at the bottom of the Mac list.

## Impact

- `Hop.swift`: `PopoverView` (a line under the Mac list, two items removed from the More menu).
- README: the sentence listing the More menu's items.
