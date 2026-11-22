# Tasks

## 1. Spike: Remote Desktop hand-off

- [ ] 1.1 With Windows App installed and a Windows PC reachable, open `rdp://full%20address=s%3A<host>%3A3389` and record in a comment above the new action whether a session starts; if it does not, confirm that opening a generated `.rdp` file does, and note which path the implementation uses
- [ ] 1.2 Confirm `NSWorkspace.urlForApplication(toOpen:)` returns nil for `rdp://` with no client installed and the client's path with one installed; record both results in the same comment

## 2. Platform model

- [x] 2.1 Add a platform field to `RemoteMac` (mac, windows, linux), saved in `hosts.json` and read as mac when absent; verify by loading the existing `hosts.json` unchanged and by a round trip of a Windows host
- [x] 2.2 Map Tailscale's `OS` to a platform, skip devices that are not computers, and list Windows and Linux hosts when "Only Macs" is off; verify against the live tailnet that the Linux machine appears and the iOS devices do not
- [ ] 2.3 Carry the platform over when a Tailscale host is added to My Macs, and add a platform picker to the Manage Macs form; verify by pinning the Linux host and by changing a saved host to Windows and relaunching

## 3. Availability

- [x] 3.1 Replace the Files-only probe result with one per host and port (22, 445, 5900, 3389), probed on refresh for saved hosts and for online Tailscale hosts; verify by build and that Files dimming still behaves as the `menu-bar-popover` spec says
- [x] 3.2 Treat a saved host as online when any probed port answers; verify with a host that only has file sharing on

## 4. Actions and interface

- [ ] 4.1 Add the Remote Desktop action using the path chosen in 1.1, closing the popover; verify against a Windows PC
- [x] 4.2 Show Remote Desktop in place of Screen Share on Windows hosts in the row, the row's accessibility actions and the detail view; verify by build and with a saved host set to Windows
- [x] 4.3 Dim Screen Share, Remote Desktop and SSH under the same rule as Files, with tooltips and accessible labels; when nothing handles `rdp://`, dim Remote Desktop and open the Windows App page when chosen; verify the "no app installed" path on this Mac
- [x] 4.4 Name the platform on a non-Mac host's row and in its detail status line; verify with the Linux host
- [x] 4.5 Add Windows and Linux to the README, the website and the "Set up your remote Macs" table (Remote Desktop on Windows, OpenSSH, file sharing); verify both documents mention Remote Desktop

## 5. Integration checks

- [x] 5.1 Run `openspec validate add-windows-linux-hosts --strict` and build the app; verify both succeed
- [ ] 5.2 In the running app, walk the `host-platforms` scenarios that the available machines allow, and list the ones that could not be checked
