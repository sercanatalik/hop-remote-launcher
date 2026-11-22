# Tasks

## 1. Spikes: confirm external behaviour

- [x] 1.1 With the Herdr desktop window closed and then with the app quit, run `herdr-app ls` and `herdr-app status`; record exit codes and output in a comment block at the top of the new Herdr section, and confirm design decision 13 (launch, wait, retry) covers what is observed
- [x] 1.2 Run `herdr-app do space.select --id <an existing space id>` and confirm the space is shown; record the success output and the output for an unknown id
- [x] 1.3 Confirm `herdr --remote <user@host>` attaches to a Mac that is not in `herdr machine list`; if it requires prior setup, stop and raise it before continuing, since it changes design decision 14
- [x] 1.4 Time `hc machine ls --json` with one machine unreachable and confirm it returns within the 3 s read limit or is cut off by it
- [x] 1.5 In a throwaway build, switch `MenuBarExtra` to `.window` style with one button that closes the popover through its hosting window; confirm it closes and reopens cleanly, and that `.keyboardShortcut("r")` fires while the popover is key; if closing is unreliable, record the fallback from the design's risks

## 2. Herdr discovery

- [x] 2.1 Add a `// MARK: - Herdr` section to `Hop.swift` with candidate paths for `herdr-app`, `hc` and `herdr`, and path lookup; verify by building with `./build.sh` and logging the three resolved paths once at launch
- [x] 2.2 Add a shared process runner that returns stdout and exit status and terminates the child after a time limit; verify by running `/bin/sleep 5` with a 1 s limit and seeing it return in about 1 s
- [x] 2.3 Add Decodable models and a fetch for `hc machine ls --json` and `herdr-app ls`, keeping each agent's tab name, app and status, with all fields optional and decode failure yielding an empty result; verify against the live output on this Mac and against an empty string
- [x] 2.4 Add the matching function (host part of `target`, case-insensitive, full host or first label, `host` field as second chance) as a pure function; verify with a scratch script covering `user@studio.tail1234.ts.net` vs `studio.tail1234.ts.net`, vs `Studio`, and a non-match
- [x] 2.5 Add the status rollup (counts in the order working, blocked, done, idle; zero counts and null status omitted; blocked total per machine and overall) and banner selection (spaces with a blocked agent, first three, remainder count) as pure functions; verify with the scratch script for mixed states, no agents, and five blocked spaces

## 3. Store and agent status mode

- [x] 3.1 Add published Herdr state to `Store` (installed flags, Mac-to-machine map, spaces per machine) and refresh it from `Store.refresh()`; verify by adding a space in Herdr, refreshing and seeing the new state logged
- [x] 3.2 Skip all Herdr work when the binaries are absent; verify by temporarily pointing the candidate paths at non-existent files and confirming no child process is spawned
- [x] 3.3 Add the agent status mode (on, muted until a date, off) saved in `UserDefaults`, defaulting to on, with a derived `showAgentStatus` that treats an expired mute as on and rewrites it; verify with the scratch script for each mode and for a mute end one second in the past
- [x] 3.4 Verify mute persistence by muting for 8 hours, quitting and relaunching Hop, and confirming the same end time is shown; then set the saved end time into the past by hand and confirm status returns at the next refresh

## 4. Herdr actions

- [x] 4.1 Add a helper that ensures the Herdr desktop app is running (launching `dev.herdr.app` if needed), retries a `herdr-app do` command for up to 10 s, activates the app on success and beeps on failure; verify with Herdr quit and with Herdr running
- [x] 4.2 Add Open (`space.select --id`), New Tab (`tab.new --space --folder`) and New Workspace (`space.new --name --machine`) actions, passing arguments as argv; verify each against the remote Mac, including a Mac name containing a space
- [x] 4.3 Refresh Herdr state shortly after each action; verify a workspace created from Hop is listed the next time the popover opens
- [x] 4.4 Add "Open Herdr in Terminal", writing an executable `.command` file in Hop's Application Support folder and opening it; verify with and without a user name, that repeated use leaves one file per Mac, and that a host containing a space and a single quote cannot inject a command

## 5. Popover

- [x] 5.1 Replace the `.menu` style with `.window` and add `PopoverView` with header (online count, refresh), scrollable Mac list in "My Macs" and "Tailscale" groups, and footer; verify the empty, Tailscale-not-installed and Tailscale-not-running states each render as the `menu-bar-popover` spec describes
- [x] 5.2 Add `MacRow` with the three reachability marks (filled dot, hollow ring, dashed ring), name, address, and Screen Share, SSH and Files icon buttons with accessibility labels, plus "Add to My Macs" on Tailscale rows; verify each button with VoiceOver reading its label and the right app opening
- [x] 5.3 Add `MacDetailView` with back control, action grid (Screen Share, SSH, Files, Copy Address, and Wake only when a MAC address is set) and the address; verify navigation both ways and Wake appearing only for a Mac with a MAC address
- [x] 5.4 Add the footer: Manage Macs, a "More" menu (Open Screen Sharing, Hop on GitHub, Report an Issue, About Hop) and Quit, with Command-R, Command-comma and Command-Q working while the popover is open; verify each shortcut and each menu item
- [x] 5.5 Close the popover after actions that leave Hop and keep it open for Refresh, Copy Address and Add to My Macs; verify against the scenarios in the `menu-bar-popover` spec

## 6. Herdr in the popover

- [x] 6.1 Before deleting `HostMenu` and `MenuContent`, check every action and label they offered against the new popover and the `menu-bar-popover` spec; list any gap and close it, then delete the old views and confirm the build has no unused code warnings
- [x] 6.2 Add `WorkspaceRow` (name, status summary, Open, New Tab) under matched Macs in the list, with New Workspace and Open Herdr in Terminal; verify an unmatched Mac shows no workspaces and that a Mac with only the terminal app installed shows only the terminal action
- [x] 6.3 In `MacDetailView`, list each workspace with its folder and one line per agent (tab, app, state), each state with its own shape, and the note under New Workspace that it creates a space with no prompt; verify against a workspace with a blocked and a working agent
- [x] 6.4 Add the blocked count to the Mac row and to the menu-bar icon label, and the banners at the top of the popover with their Open action; verify with one blocked agent, with none, and with more than three blocked spaces
- [x] 6.5 Add the agent status menu to the footer (On, Mute for 8 hours, Mute for 1 week, Off) showing the current state and the mute end time; verify every status surface disappears while muted or off, that workspaces and actions remain, and that choosing On during a mute restores status immediately

## 7. Manage window

- [x] 7.1 Add the Herdr section to the detail form of a matched Mac: machine name and state, workspace table with Open and New Tab, New Workspace and Open Herdr in Terminal; verify it is absent for an unmatched Mac
- [x] 7.2 Add the agent status menu to the Manage window toolbar, bound to the same setting; verify changing it in the window changes the popover and the reverse

## 8. Documentation and integration check

- [x] 8.1 Rewrite the README "What it does" section for the popover and add a Herdr section covering workspaces, New Workspace creating a space with no prompt, agent status and how to mute or turn it off; verify the text matches the built app
- [x] 8.2 Run through every scenario in `specs/menu-bar-popover/spec.md` and `specs/herdr-workspaces/spec.md` against the built app, including Herdr not installed (binaries renamed away temporarily) and Herdr not answering
- [x] 8.3 Run `UNIVERSAL=1 ./build.sh` and confirm it compiles with no new warnings, matching what CI builds
