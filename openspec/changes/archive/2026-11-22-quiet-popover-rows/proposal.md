# Proposal

## Why

The popover has grown crowded: every Mac row carries four icon buttons, a chevron and sometimes a blocked badge; every Herdr workspace carries two text buttons; the same blocked agent is announced in three places; and the footer holds four competing text items. The list is hard to scan, which defeats a menu-bar tool meant for a quick glance and one click.

## What Changes

Direction "A · Quiet rows" from the design exploration (canvas: https://claude.ai/artifact/S36ZavdApms44Lnuok7sAX).

- Mac rows show the reachability mark, the name and a chevron at rest. Screen Share, SSH and Files appear on the row when it is hovered or has keyboard focus, and stay reachable by VoiceOver. They remain one click.
- **BREAKING** "Add to My Macs" moves off the Tailscale Mac's row into the Mac's detail view.
- **BREAKING** The "My Macs" group is hidden when there are no saved Macs, instead of reading "No saved Macs yet".
- **BREAKING** The footer is removed. Manage Macs, the agent status choice, Open Screen Sharing, Hop on GitHub, Report an Issue, About Hop and Quit Hop move into a single "More" menu in the header, next to Refresh Status. Command-R, Command-comma and Command-Q are unchanged.
- When agent status is muted or off, the header shows a muted indicator, since the footer's "Agent status" label is gone.
- Workspaces listed under a Mac row become plain rows: choosing the row opens the space, a small "+" button adds a tab, and one "New workspace" line follows the list. "Herdr in Terminal" is no longer offered under the row; it stays in the detail view.
- **BREAKING** A Mac's row no longer repeats its blocked count. The blocked state is shown by the banner and by the workspace line directly under the row. The menu-bar icon count is unchanged.
- The detail view is simplified: one action row with Screen Share as the primary action, SSH and Files beside it, and a "More" menu holding Wake, Open Herdr in Terminal and Add to My Macs. "New Workspace" becomes a small "New" control in the workspaces heading, its explanatory caption is removed, and the address sits at the bottom with a copy button. The detail view no longer shows the app-level footer.

Proposed defaults not yet confirmed by the user:

- Whether Screen Share should stay always visible on the row, with only SSH and Files revealed on hover.
- Dropping the per-Mac blocked count from the row.

Out of scope: the Manage Macs window, light-mode-specific styling decisions, any change to Herdr behavior or refresh logic.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `menu-bar-popover`: row actions are revealed on hover or focus; "Add to My Macs" moves to the detail view; the empty "My Macs" group is hidden; app-level actions move from a footer to a header menu; the detail view's action layout changes.
- `herdr-workspaces`: a Mac's row no longer shows its own blocked count; the workspaces listed under a row offer Open by choosing the row and New Tab by an icon button.

## Impact

- `Hop.swift`: `PopoverView` (header, footer removal, list sections), `MacRow`, `HerdrBlock`, `WorkspaceRow`, `MacDetailView`, `ActionTile`, `AgentStatusMenu`.
- `openspec/specs/menu-bar-popover/spec.md` and `openspec/specs/herdr-workspaces/spec.md` need delta specs.
- `docs/screenshots/` and the README/website images show the old layout and need retaking.
- No new dependencies, no data or settings migration.
