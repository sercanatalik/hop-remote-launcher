# Design

## Context

`Store.refresh` runs every 30 seconds and when the popover opens. Saved Macs are probed over TCP by `Probe.tcp`, which returns only true or false; Tailscale Macs take their online state from Tailscale. Hop already imports `Network`. The app is ad-hoc signed with a bundle identifier, which is enough for `UNUserNotificationCenter`.

## Goals / Non-Goals

**Goals:**
- No notification the user would call a false alarm.

**Non-Goals:**
- Sub-30-second detection.

## Decisions

1. **Two misses before "offline", one hit before "back".** With a 30-second cycle a Mac is reported offline about a minute after it drops. A single failed TCP connect is too common on Wi-Fi to report.
2. **Stay silent when the fault is local.** An `NWPathMonitor` tells Hop whether this computer has a network path; while it has none, misses are not counted. The first refresh after launch and after `NSWorkspace.didWakeNotification` only records state and never notifies. SwitchBored solves the same problem by pinging a reference server; the path monitor needs no outside host.
3. **Only transitions notify.** Hop keeps the last reported state per saved Mac in memory. A Mac that is offline when Hop starts is not announced; it is announced when it comes back only if Hop saw it go.
4. **Latency is the TCP connect time of the probe that succeeded.** No ICMP, which would need a different API and can be blocked. It is shown only where a probe ran, so a Tailscale Mac shows it once file-sharing or another probe has answered.
5. **Permission is requested when the setting is turned on**, not at launch. A refusal turns the toggle back off and shows a line pointing to System Settings.

## Risks / Trade-offs

- [A Mac that sleeps on a schedule produces an alert every night] → The setting is global and off by default; per-Mac switches are the follow-up if this bites.
- [Notifications from an ad-hoc signed app may be attributed oddly after a rebuild] → Check in the installed build as the last task.
