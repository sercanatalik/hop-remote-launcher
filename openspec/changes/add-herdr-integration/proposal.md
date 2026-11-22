# Proposal

## Why

Hop gets you onto a remote Mac by Screen Sharing, SSH or file sharing, but not into the Herdr workspaces where coding agents run on that Mac. Getting there today means opening Herdr, finding the machine and the right space by hand, and there is no way to see from the menu bar whether an agent on a remote Mac is waiting for you. Hop's text-only menu also cannot show that information well, so this change replaces it with a popover.

## What Changes

- **BREAKING (UI)**: The Hop menu-bar menu becomes a popover. Every existing action stays available; the layout, and how each action is reached, changes.
  - Each Mac is a row with its status, address and one-click Screen Share, SSH and Files buttons.
  - Choosing a Mac opens a detail view inside the popover with all of that Mac's actions.
- Macs that the Herdr desktop app knows as a machine show their **Herdr workspaces**, in the Mac list and in the detail view. Each workspace offers **Open** and **New Tab**.
- **New Workspace**: one click creates a new space on that Mac in the Herdr desktop app, named after the Mac, starting in the remote home folder, with no prompt.
- **Open Herdr in Terminal**: attaches the Herdr terminal app (`herdr --remote`) to that Mac in a terminal window.
- **Agent status**, on by default:
  - a count of blocked agents on the menu-bar icon;
  - a "waiting for you" banner at the top of the popover with a direct Open button;
  - a blocked count on the Mac row, and counts by state on each workspace;
  - in the Mac detail view, one line per agent with its tab, app and state.
- **Agent status can be muted for 8 hours or 1 week, or turned off.** A mute ends by itself; off stays off until turned back on. While muted or off, Hop shows no agent status anywhere; workspaces and their actions remain.
- The Manage Macs window shows a Mac's Herdr machine, workspaces and the same actions.
- Herdr features appear only when the relevant Herdr app is installed. Spaces on this computer are not shown.
- Not in scope: adding a Mac to Herdr as a machine from Hop, prompting for a workspace name or folder, closing or renaming spaces, sending prompts to agents, focusing a single agent, and system notifications.

## Capabilities

### New Capabilities

- `menu-bar-popover`: The popover Hop shows from the menu bar: the Mac list with status and quick actions, the per-Mac detail view, and the app-level actions.
- `herdr-workspaces`: Discovering Herdr machines, spaces and agent states for the Macs Hop lists; opening, extending and creating Herdr workspaces on them in the desktop app and the terminal app; and showing, muting and disabling agent status.

### Modified Capabilities

None. The project has no existing specs.

## Impact

- **Code**: `Hop.swift` only. The menu views (`HostMenu`, `MenuContent`) are replaced by popover views; model, store, actions and the Manage window gain Herdr support. Expect the file to grow from about 670 to roughly 1,100 lines.
- **External tools**: new optional runtime use of the Herdr desktop app CLI (`herdr-app`), herdr-core CLI (`hc`) and Herdr terminal app CLI (`herdr`), run as child processes the same way Hop runs the Tailscale CLI. None is required; no new build dependency.
- **User's Herdr state**: New Workspace and New Tab create spaces, tabs and remote terminals in the user's Herdr.
- **Settings**: one new saved preference, the agent status mode and mute expiry.
- **Permissions**: none new. Opening a terminal window uses a `.command` file rather than Apple Events.
- **Docs**: `README.md` "What it does" is rewritten for the popover and gains a Herdr section.
- **Design reference**: artboards B (Popover, Mac detail), Agent status language and Manage Macs window at https://claude.ai/artifact/EpboFoF4mYbJup1KZuJbAs.
- **Open risks**: whether the Herdr desktop CLI answers while the Herdr window is closed, and dismissing a window-style popover after an action; both are settled by the first tasks.
