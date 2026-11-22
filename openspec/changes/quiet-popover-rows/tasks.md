# Tasks

## 1. Header and app-level actions

- [x] 1.1 Replace the popover footer with a "More" menu in the list header (Manage Macs, agent status submenu, Open Screen Sharing, Hop on GitHub, Report an Issue, About Hop, Quit Hop) and remove the footer and its divider; verify `./build.sh` compiles and `PopoverView` has no `footer`
- [x] 1.2 Bind Command-comma and Command-Q to hidden buttons present in both the list and the detail view, keeping Command-R on Refresh; verify by build and by reading that the buttons sit outside the list/detail branch
- [x] 1.3 Show a `bell.slash` button in the header while agent status is muted or off (Herdr installed) that turns status on, and show the mute end time as a disabled line in the agent status menu; verify by build
- [x] 1.4 Update the README paragraph that describes the bottom of the panel to describe the header "More" menu; verify the README no longer mentions a bottom bar

## 2. Mac list

- [x] 2.1 Rework `MacRow`: single line with reach mark, name and chevron; Screen Share, SSH and Files revealed on hover or keyboard focus; trailing note ("Offline" or workspace count) at rest; named accessibility actions for the three actions; no blocked count and no "Add to My Macs"; verify by build
- [x] 2.2 Hide the "My Macs" heading when there are no saved Macs, and show a "No Macs yet" line with an "Add a Mac…" control when there are no saved Macs and the Tailscale group is off; verify by build and by reading the list branches against the spec scenarios
- [x] 2.3 Replace the inline Herdr block under a matched Mac with plain workspace lines (row opens the space, "+" adds a tab, agent summary on the right) and one "New workspace" line, with no "Herdr in Terminal"; verify by build
- [x] 2.4 Slim the blocked-agent banner to one line with a small Open button; verify by build and that the three-banner limit and "and N more" are unchanged

## 3. Detail view

- [x] 3.1 Replace the action tiles with one action row (Screen Share primary, SSH, Files) and a "More" menu holding Wake (only with a MAC address), Open Herdr in Terminal (only when available) and Add to My Macs (Tailscale Macs only), hiding the menu when it would be empty; verify by build
- [x] 3.2 Make pinning from the detail view switch the detail view to the saved Mac; verify by build and by reading that the returned id is assigned to the detail selection
- [x] 3.3 Rework the detail workspaces block: "Workspaces" heading with a small "New" control, compact workspace rows ("+" for a new tab, "Open"), per-agent lines unchanged, no explanatory caption; keep the Manage Macs window's workspace rows as they are; verify by build
- [x] 3.4 Move the address to the bottom of the detail view with a Copy Address button beside it; verify by build

## 4. Integration checks

- [x] 4.1 Run `openspec validate quiet-popover-rows --strict` and `./build.sh`; verify both succeed
- [ ] 4.2 Manual check in the running app: hover reveals the row actions, Tab with Full Keyboard Access reaches them, VoiceOver offers the three actions on a row, and Command-R, Command-comma and Command-Q work in the list and in a detail view
- [x] 4.3 Retake `docs/screenshots/` (popover, detail, muted; light and dark) and update the image alt text in `README.md` and `docs/index.html`; verify the images show the new layout
