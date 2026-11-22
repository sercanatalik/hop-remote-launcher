# Proposal

## Why

Hop offers Files on every Mac, even when that Mac has File Sharing turned off. The user only finds out from a Finder error after a slow connection attempt. Hop already checks each Mac's Screen Sharing and Remote Login ports, so it can check file sharing the same way and say so up front.

## What Changes

- Hop checks whether each online Mac accepts file-sharing connections (SMB, port 445) whenever it refreshes host status, for saved and Tailscale Macs alike.
- In the popover, the Files control is dimmed on a Mac that is online but does not accept file-sharing connections, in the Mac's row and in its detail view. Its tooltip and accessible label say that File Sharing appears to be off.
- A dimmed Files control still works when chosen, because the check can be out of date.
- Files is shown normally while the check has not finished, and on Macs that are offline or still being checked.

Out of scope: the Manage Macs window, and the same treatment for Screen Share and SSH.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `menu-bar-popover`: adds a requirement that Files is dimmed, with an explanation, when a Mac is online but not accepting file-sharing connections.

## Impact

- `Hop.swift`: `Store` (a file-sharing result per Mac, probed in `refresh` and `refreshTailscale`), `IconButton`, `MacRow`, `MacDetailView`.
- One more short TCP probe per online Mac on each refresh.
- README and website: one sentence each.
