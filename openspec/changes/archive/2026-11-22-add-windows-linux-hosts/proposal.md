# Proposal

## Why

Hop only handles Macs. A Windows PC or a Linux machine on the same tailnet is hidden behind the "Only Macs" setting, and if shown it gets a Screen Share button that cannot work on Windows. Comparable tools (RDPMaster, RDP Manager) treat Windows and Linux as ordinary targets, and it is the clearest gap in Hop.

## What Changes

- Every host has a platform: Mac, Windows or Linux. Tailscale devices take it from Tailscale; a saved host's platform is chosen in the Manage Macs window and defaults to Mac.
- A Windows host offers **Remote Desktop** where a Mac offers Screen Share. It hands off to the remote desktop app installed on this Mac (Microsoft's Windows App), the same way Screen Share hands off to Screen Sharing. Hop does not contain an RDP client.
- When no app on this Mac can open Remote Desktop connections, the Remote Desktop control is dimmed and choosing it opens the page to get Windows App.
- With "Only Macs" off, the Tailscale group lists Windows and Linux computers. Phones, tablets and TVs are never listed.
- Screen Share, Remote Desktop and SSH are dimmed when the host is online but refuses that kind of connection, as Files already is.
- A non-Mac host's platform is named on its row and in its detail view.

Proposed defaults not yet confirmed by the user:

- Linux hosts keep Screen Share (VNC), dimmed when nothing answers, so every row has the same three controls.
- The app keeps saying "Macs" ("My Macs", "Manage Macs") even when the list holds other computers.

Out of scope: running Hop on Windows; a built-in RDP, VNC or SSH client; RD Gateway, saved passwords or per-connection RDP settings; renaming "Macs" in the interface; Herdr behavior.

## Capabilities

### New Capabilities

- `host-platforms`: what platform a host is, how Windows and Linux hosts are found and shown, the Remote Desktop action, and dimming of connection actions a host does not accept.

### Modified Capabilities

- `menu-bar-popover`: on a Windows host, Remote Desktop takes the place of Screen Share in the row and in the detail view.

## Impact

- `Hop.swift`: `RemoteMac` (a platform field, saved in `hosts.json`; old files load as Mac), `Store` (probes for ports 22, 5900 and 3389 kept per host, Tailscale filter), `Actions` (Remote Desktop hand-off), `MacRow`, `MacDetailView`, `ManagerView` (platform picker).
- Depends on an external app for Remote Desktop; nothing is bundled.
- README, website and the "Set up your remote Macs" table gain Windows and Linux rows.
