# Design

## Context

Hop launches everything through URL hand-offs (`vnc://`, `ssh://`, `smb://`) and has no protocol code. `RemoteMac` has no notion of platform. `Tailscale.fetch` already returns each peer's `OS`; `Store.refreshTailscale` drops everything that is not `macOS` when "Only Macs" is on, and lists every peer, phones included, when it is off. On the development Mac there is no Windows App, nothing registered for `rdp://`, and no Windows peer on the tailnet.

## Goals / Non-Goals

**Goals:**
- Remote Desktop as a hand-off, with no RDP code in Hop.
- One row layout for every platform: three controls, dimmed when unavailable.

**Non-Goals:**
- Storing credentials or RDP settings.
- Detecting a saved host's platform by probing.

## Decisions

1. **Platform is a stored field, not inferred.** `RemoteMac.platform` is `mac`, `windows` or `linux`, absent in old `hosts.json` files and read as `mac`. Tailscale's `OS` string maps to it (`macOS`, `windows`, `linux`); anything else (iOS, android, tvOS) is not a computer and is skipped. Guessing from open ports was rejected: a Mac with Screen Sharing off and a Linux box look the same.
2. **Remote Desktop opens an `rdp://` URL.** The URL is `rdp://full%20address=s%3A<host>%3A3389`, with the colons percent-encoded, opened with `NSWorkspace`. Microsoft documents this scheme for its Mac client, but reports for the current Windows App are mixed, so the first task is a spike. Fallback if the URL is ignored: write a `.rdp` file (`full address:s:<host>`, plus `username:s:<user>` when set) into Hop's Application Support folder and open that, as Hop already does with `.command` files for Herdr.
3. **"Can this Mac do Remote Desktop" is asked of Launch Services.** `NSWorkspace.urlForApplication(toOpen:)` on an `rdp://` URL says whether any app handles it. No app name is hard-coded, so a third-party client that registers the scheme also works.
4. **One availability rule for every action.** `Store` keeps the last probe result per host and port (22, 445, 5900, 3389). A control is dimmed when the host is online and its port refused. This replaces the Files-only dictionary added by `dim-unavailable-files` with a per-port one; the Files behavior does not change.
5. **Saved hosts count as online when any probed port answers**, so a Windows PC with only Remote Desktop on is not shown as offline.

## Risks / Trade-offs

- [The `rdp://` hand-off may not start a session in Windows App] → Spike first; the `.rdp` file fallback is specified above.
- [No Windows PC on the developer's tailnet to test against] → The spike and the final check need one; until then only the dimmed and "no app installed" paths can be verified.
- [Four probes per host on every refresh instead of three] → Probes are short TCP connects run in parallel; Tailscale hosts are probed only when Tailscale says they are online.
- ["Macs" wording is wrong for a Windows PC] → Accepted for now; renaming is a separate, larger text change.
