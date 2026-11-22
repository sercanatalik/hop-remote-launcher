# Design

## Context

Hop is one Swift file (`Hop.swift`, 666 lines), unsandboxed, with no tests and no Xcode project. It already integrates one external tool: `Tailscale.fetch()` finds the CLI from a list of candidate paths, runs `status --json` as a child process off the main actor, and decodes the result. `Store` publishes the results; a 30-second timer and "Refresh Status" call `Store.refresh()`. Every per-Mac action is a URL scheme handed to `NSWorkspace`. The UI is `MenuBarExtra` with `.menuBarExtraStyle(.menu)`, a native menu of text items built by `HostMenu` and `MenuContent`.

Herdr ships two front ends with separate machine lists (observed on the developer's Mac, Herdr TUI 0.9.5 and herdr-core 0.1.21):

| | Desktop | Terminal |
| --- | --- | --- |
| App | `~/Applications/Herdr.app`, bundle id `dev.herdr.app` | `herdr` binary |
| CLI | `herdr-app` (the app's own executable), `hc` (herdr-core) | `herdr` |
| Machines | `hc machine ls --json` | `herdr machine list --json` |
| URL scheme | none | none |

Observed outputs this design relies on:

- `hc machine ls` returns `{"machines":[{"name","target","host","state",...}]}`. `target` is `user@host`, here a Tailscale DNS name.
- `herdr-app ls` returns `{"spaces":[{"id","name","folder","machine","tabs":[{"name","terminals":[{"status","app",...}]}]}]}`. `machine` is the `hc` machine name, or null for this computer. `status` is `working`, `blocked`, `done`, `idle` or null. Space ids are machine-prefixed and opaque.
- `herdr-app do <command>` takes `--arg value` pairs. `space.new` accepts `name`, `folder`, `machine`; `space.select` accepts `id`; `tab.new` accepts `space`, `folder`.

Visual reference: artboards "B · Popover refactor", "B · Mac detail", "Agent status language" and "Manage Macs window" at https://claude.ai/artifact/EpboFoF4mYbJup1KZuJbAs. Artboard A (native menu) is superseded.

## Goals / Non-Goals

**Goals:**

- Follow the Tailscale integration's shape so the Herdr code reads as a second instance of a known pattern.
- Keep the popover responsive whatever the Herdr tools do.
- Keep every action Hop has today reachable in the popover.
- Add no permission prompt and no build dependency.

**Non-Goals:**

- Talking to Herdr's sockets directly. The CLIs are the documented surface.
- Reconciling the terminal app's saved machines with Hop's Macs.
- Live updates between refreshes (event subscriptions) and system notifications.
- Splitting `Hop.swift` into several files.

## Decisions

### 1. Switch to a window-style popover

`MenuBarExtra` moves to `.menuBarExtraStyle(.window)`, available on macOS 13, Hop's minimum. `HostMenu` and `MenuContent` are replaced by SwiftUI views: `PopoverView` (header, banners, Mac list, footer), `MacRow`, `MacDetailView`, `WorkspaceRow`. Navigation between list and detail is a `@State` selected Mac id inside the popover, not a navigation stack, so the popover keeps one fixed width (400 pt) and a height capped with a scroll view.

*Alternative: keep the native menu and add submenus (artboard A).* Rejected by the user: a text menu cannot carry the banner, icon buttons or per-agent rows.

*Alternative: `NSPopover` on an `NSStatusItem`.* Rejected: it needs an AppKit app delegate and gives nothing the window style lacks.

### 2. Closing the popover

A window-style `MenuBarExtra` does not close after a button press. Actions that leave Hop close it by calling `close()` on the popover's window, captured with a small `NSViewRepresentable` accessor; actions that stay in Hop do not. Clicking the status item programmatically is not an option: its button has no target or action (SwiftUI tracks the mouse itself), which was confirmed while implementing. Most leaving actions also bring another app forward, which dismisses the popover by itself. Whether the icon reopens the popover with a single click after `close()` could not be tested without real mouse input and needs a manual check (task 1.5).

### 3. Keyboard shortcuts and the app-level actions

Refresh Status, Manage Macs and Quit keep `.keyboardShortcut` on their popover buttons, which works while the popover window is key. Open Screen Sharing, Hop on GitHub, Report an Issue and About Hop move into a "More" menu button in the footer, so the footer stays one row.

### 4. Reachability without color alone

Online is a filled green dot, offline a hollow grey ring, checking a dashed ring. This replaces the emoji dots, which a custom view no longer needs.

### 5. Drive Herdr through its CLIs as child processes

A `Herdr` enum mirrors `Tailscale`: candidate paths, a `fetch()` that returns a decoded snapshot, and action functions. Candidate paths:

- `herdr-app`: `~/Applications/Herdr.app/Contents/MacOS/Herdr`, `/Applications/Herdr.app/Contents/MacOS/Herdr`, `~/.local/bin/herdr-app`
- `hc`: `~/.local/bin/hc`, `/opt/homebrew/bin/hc`, `/usr/local/bin/hc`
- `herdr`: `/opt/homebrew/bin/herdr`, `/usr/local/bin/herdr`, `~/.local/bin/herdr`

A menu-bar app does not inherit the shell `PATH`, so paths are probed explicitly, as for Tailscale.

*Alternative: speak JSON to `~/.config/herdr-app/herdr-app.sock`.* Rejected: the desktop socket protocol is undocumented, and the CLI is what Herdr's own skill file tells callers to use.

### 6. One shared process runner with a timeout

`Tailscale.fetch()` blocks on `readDataToEndOfFile()` with no limit. Herdr calls can reach a remote machine, so a small shared helper runs a process, returns stdout and exit status, and terminates the process after a limit (3 s for reads, 10 s for actions). Tailscale's fetch is left as it is.

### 7. Match by the host part of the `hc` target

Strip `user@` from the machine's `target`, lowercase, and compare with the Mac's host: equal, or either one being the first DNS label of the other, so a Mac saved as `studio` matches a machine known as `studio.tail1234.ts.net` and the reverse. IP addresses only match when equal. The machine's `host` field is checked the same way as a second chance. The result is a `[RemoteMac.ID: machineName]` map rebuilt on each refresh.

*Alternative: an explicit "Herdr machine" field per Mac.* Deferred: it adds a saved field, and the automatic rule covers Tailscale names, which is how Herdr machines are added in practice.

### 8. One `herdr-app ls` call feeds spaces and agent status

Spaces are grouped by `machine`. Each space keeps its agents as `(tab name, app, status)` for terminals with a non-null status; counts and blocked totals are derived from that list. `Store` publishes `herdrSpaces: [machineName: [HerdrSpace]]`. The refresh runs from `Store.refresh()` and again shortly after each Herdr action.

The fetch runs whatever the agent status mode is, because the space list needs it. The mode only decides what is displayed.

### 9. Agent status mode

```
enum AgentStatusMode { on, mutedUntil(Date), off }
```

Stored in `UserDefaults` as a string (`on` / `muted` / `off`) plus a `Date` for the mute end. `Store` exposes one derived `showAgentStatus: Bool`, true when the mode is `on` or the mute end has passed; every status surface (icon count, banners, row counts, agent lines, Manage window) reads only that flag. Expiry is evaluated on read and on each refresh tick, and an expired mute is rewritten to `on`, so no separate timer is needed and expiry survives relaunch and sleep.

The control is a menu button in the popover footer, labelled with the current state ("Agent status: On", "Muted until Mon 09:00", "Off") and offering On, Mute for 8 hours, Mute for 1 week, Off. The same four choices appear in the Manage window toolbar. Durations are 8 × 3600 s and 7 × 86400 s from the moment of choosing.

*Alternative: mute hides only the icon count and banner, leaving counts in the list.* Rejected for now: "muted" and "off" would then differ in two ways (scope and expiry) and need explaining. One rule, "nothing shown", is simpler; this can be revisited.

### 10. Menu-bar icon count

The `MenuBarExtra` label becomes the Hop glyph followed by the blocked total as text when it is above zero and `showAgentStatus` is true. The glyph stays a template image so it follows the menu bar's appearance.

### 11. Banners

Banners are computed from the spaces with at least one blocked agent, in machine then Herdr order, capped at three with an "and N more" line. Open runs the same action as the workspace's Open.

### 12. Desktop actions

| Action | Command | Then |
| --- | --- | --- |
| Open | `herdr-app do space.select --id <id>` | activate `dev.herdr.app`, close popover |
| New Tab | `herdr-app do tab.new --space <id> --folder <space folder>` | activate, close popover |
| New Workspace | `herdr-app do space.new --name <Mac name> --machine <machine name>` | activate, close popover |

`--folder` is always passed for New Tab, even when empty (a space created in the home folder reports an empty folder), because Herdr's default is the focused terminal's folder, which may belong to another space or machine. New Workspace passes no folder, so Herdr starts it in the remote home. Duplicate names are allowed; Herdr identifies spaces by id. Arguments are passed as an argv array to `Process`, never through a shell.

### 13. Herdr window closed: launch, wait, then act

Whether `herdr-app ls` and `do` answer while the window is closed is untested; `ls` is documented as reading "the open window". Task 1.1 settles it. The design holds either way: before any action, if no running application has bundle id `dev.herdr.app`, Hop launches it and retries the command for up to 10 s. If `ls` fails while the window is closed, the space list is empty and New Workspace remains, as the spec requires.

### 14. Terminal app: a `.command` file, target from Hop's own fields

"Open Herdr in Terminal" writes an executable script to Hop's Application Support folder (`Hop/herdr-<host>.command`, the host reduced to letters, digits, dots and dashes; Tailscale Macs get a new id on every launch, so the id would leave a file behind each time) containing `exec <herdr path> --remote <user@host>` with the target single-quoted, and opens it with `NSWorkspace`. The file is overwritten on each use. The target is built from the Mac's `user` and `host`; Herdr documents `herdr --remote <target>` as a standalone attach that needs no saved machine.

*Alternative: AppleScript `do script`.* Rejected: it triggers an Automation prompt and hard-codes Terminal.app.

### 15. Manage window

The detail form for a matched Mac gains a Herdr section below the existing actions row: matched machine name and state, a workspace table (name, folder, agents, Open, New Tab), New Workspace and Open Herdr in Terminal. It reuses `WorkspaceRow` logic and `showAgentStatus`. The toolbar gains the agent status menu.

### 16. Stay in one file

All code stays in `Hop.swift`, with a new `// MARK: - Herdr` section after Tailscale and the menu section replaced by `// MARK: - Popover`. The file reaches about 1,560 lines, more than first estimated. Splitting it would need a change to `build.sh` and the README's "one Swift file" promise, which this change does not take on.

## Risks / Trade-offs

- [Rewriting the whole menu risks losing an existing action or shortcut] → The `menu-bar-popover` spec lists every current action; task 6.1 checks each against the old menu before the old views are deleted.
- [A window-style popover does not close by itself, and the workaround reaches for the hosting window] → Spike 1.5 first; if it is unreliable, fall back to leaving the popover open after actions, which is safe though less tidy.
- [Herdr CLI output or arguments change between versions] → Decode with optional fields; any decode failure means "no Herdr information"; failed actions beep.
- [`herdr-app ls` only answers with the window open] → Accepted: workspaces and status are empty while Herdr is closed.
- [A refresh every 30 s spawns two more processes] → Both are local; skipped when the binaries are absent; bounded by the timeout.
- [One-click New Workspace creates remote terminals with no confirmation] → Confirmed behaviour; the detail view states it under the button.
- [Muting hides a blocked agent the user would have wanted to see] → The footer always shows the muted state and its end time, with one click to turn status back on.
- [`.command` opens in whatever app handles that type] → Accepted for the first version.
- [The macOS 27 SDK in the Command Line Tools cannot compile SwiftUI's `@State` (its macro plugin is missing); this affects the unchanged file too] → Build locally with `SDKROOT` pointing at the 26.5 SDK, or with full Xcode. CI uses Xcode and is unaffected.
- [No test suite exists] → Matching, status rollup, banner selection and mute expiry are pure functions checked with a scratch script; the rest is verified against a real Herdr install.
- [The file grows by about two thirds] → Accepted to keep the single-file promise; sections are marked.

## Migration Plan

No data migration: `hosts.json` and the two Tailscale preferences are unchanged, and the new preference defaults to on. The popover replaces the menu in one release; rollback is reverting the commit.

## Open Questions

- Whether a muted state should still show counts inside the list (see decision 9). Deferred until the feature has been used.
