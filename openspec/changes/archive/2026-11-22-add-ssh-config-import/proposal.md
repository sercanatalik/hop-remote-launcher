# Proposal

## Why

Many people already keep their machines in `~/.ssh/config`. Today each one has to be typed into Hop again, and Hop then connects with a plain `ssh://` address that ignores the port, key and jump host written in that file. Shuttle, the best-known SSH menu for the Mac, builds its whole list from this file.

## What Changes

- The Manage Macs window lists the hosts found in the user's SSH configuration that are not already saved, next to the hosts found by Tailscale, each with a control to add it to My Macs.
- Adding one fills in its name, address and user name from the file.
- SSH to a Mac added this way connects through its SSH configuration entry, so the port, key and jump host in the file apply.
- The online check for such a Mac uses the SSH port from the file.
- Nothing appears when there is no SSH configuration file.

Proposed defaults not yet confirmed by the user:

- Hosts from the file are offered in the Manage Macs window only, not listed live in the popover the way Tailscale Macs are.
- Adding a host copies it. Later edits to the file change how SSH connects, but not the saved name or address.

Out of scope: editing the SSH configuration; a live "SSH config" group in the popover; `Match` blocks; importing keys or passwords.

## Capabilities

### New Capabilities

- `ssh-config-import`: finding hosts in the user's SSH configuration, adding them to My Macs, and connecting to them through their configuration entry.

### Modified Capabilities

None.

## Impact

- `Hop.swift`: a small parser for `~/.ssh/config` and the files it includes, `RemoteMac` (an optional SSH alias and SSH port, saved in `hosts.json`), `Actions.ssh`, the online probe, `ManagerView` (a "From SSH config" section).
- Reads `~/.ssh/config`; never writes it. Hop is not sandboxed, so no permission is involved.
- README and website: one short paragraph.
