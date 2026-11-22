# Proposal

## Why

Hop checks every Mac every 30 seconds but only shows the result when the popover is open. A user who relies on a Mac being up, such as one running coding agents, finds out it dropped off only by looking. SwitchBored, the closest comparable app, notifies when a machine becomes unreachable and shows latency.

## What Changes

- Hop can post a macOS notification when a saved Mac goes offline, and another when it comes back. This is one setting in the Manage Macs window, off by default.
- A Mac must fail two checks in a row before it is reported offline, and nothing is reported while this computer itself has no network or has just woken or launched.
- Turning the setting on asks for notification permission; if it is refused, the setting stays off and says why.
- A Mac's detail view shows how long the last check took to reach it, in milliseconds.

Proposed defaults not yet confirmed by the user:

- Alerts cover saved Macs only, not Tailscale Macs that were never added to My Macs, because laptops on a tailnet come and go all day.
- One setting for all saved Macs, not a switch per Mac.

Out of scope: alerts for Herdr agents; per-Mac switches; a latency history or graph; ICMP ping.

## Capabilities

### New Capabilities

- `reachability-alerts`: notifications when a saved Mac goes offline or comes back, the rules that prevent false alarms, and the response time shown for a Mac.

### Modified Capabilities

None.

## Impact

- `Hop.swift`: `Probe` (returns the connect time), `Store` (previous state and miss count per Mac, network path monitor, wake observer, the setting), `ManagerView` (toggle), `PopoverView` (detail status line).
- Adds `import UserNotifications`; no third-party dependency.
- README and website: one short paragraph.
