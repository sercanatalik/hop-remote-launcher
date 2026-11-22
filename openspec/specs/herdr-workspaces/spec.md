# herdr-workspaces Specification

## Purpose

Lets a user reach, extend and create Herdr workspaces on their remote Macs from Hop, in both the Herdr desktop app and the Herdr terminal app, and see, mute or turn off the state of the coding agents running there.

## Requirements

### Requirement: Herdr features depend on Herdr being installed
Hop SHALL show Herdr workspace features only when the Herdr desktop app is installed, and the Herdr terminal action only when the Herdr terminal app is installed. Hop SHALL work as before when neither is installed.

#### Scenario: No Herdr installed
- **WHEN** neither the Herdr desktop app nor the Herdr terminal app is installed
- **THEN** nothing Herdr-related appears anywhere in Hop and no error is shown

#### Scenario: Only the terminal app installed
- **WHEN** the Herdr terminal app is installed and the Herdr desktop app is not
- **THEN** Macs offer "Open Herdr in Terminal" and show no Herdr workspaces

### Requirement: Macs are matched to Herdr machines
Hop SHALL treat a Mac as a Herdr machine when the host part of a Herdr machine's SSH target, ignoring any user name and letter case, equals the Mac's host, or when either of the two is the first label of the other. IP addresses SHALL match only when equal. Hop SHALL show Herdr workspaces only for Macs matched this way. The rule applies to saved Macs and Tailscale Macs alike.

#### Scenario: Tailscale Mac known to Herdr
- **WHEN** Herdr has a machine with target `sercan@studio.tail1234.ts.net` and Hop lists a Mac with host `studio.tail1234.ts.net`
- **THEN** that Mac shows a Herdr workspaces section

#### Scenario: Mac saved by its short name
- **WHEN** Herdr has a machine with target `sercan@studio.tail1234.ts.net` and Hop lists a Mac with host `Studio`
- **THEN** that Mac shows a Herdr workspaces section

#### Scenario: Mac not known to Herdr
- **WHEN** no Herdr machine's target matches a Mac's host
- **THEN** that Mac shows no Herdr workspaces section

### Requirement: Existing spaces are listed per Mac
A matched Mac SHALL list the Herdr spaces that live on its machine, by name, in the order Herdr reports them, both under its row in the Mac list and in its detail view. Spaces on this computer and on other machines SHALL NOT appear under that Mac.

#### Scenario: Mac with two spaces
- **WHEN** Herdr reports spaces `quant-works` and `trading-works` on a Mac's machine and one space on this computer
- **THEN** that Mac lists `quant-works` and `trading-works` and no other space

#### Scenario: Space information unavailable
- **WHEN** Hop cannot read the space list, for example because the Herdr desktop app is closed
- **THEN** the Mac lists no spaces and still offers "New Workspace"

### Requirement: Open an existing space
Each listed space SHALL offer an "Open" action that shows that space in the Herdr desktop app and brings the Herdr desktop app to the front.

#### Scenario: Opening a space
- **WHEN** the user chooses "Open" on the space `quant-works`
- **THEN** the Herdr desktop app comes to the front showing `quant-works`

### Requirement: Add a tab to an existing space
Each listed space SHALL offer a "New Tab" action that adds a tab with a new terminal to that space, starting in that space's own folder on its machine, shows it, and brings the Herdr desktop app to the front.

#### Scenario: Adding a tab
- **WHEN** the user chooses "New Tab" on a space whose folder is `/Users/sercan/code/app`
- **THEN** that space gains a tab whose terminal starts in `/Users/sercan/code/app` on the remote Mac, and the Herdr desktop app comes to the front showing it

### Requirement: Create a workspace in one click
A matched Mac SHALL offer "New Workspace", which creates a new Herdr space on that machine without asking for any input, named after the Mac as Hop displays it, starting in the remote user's home folder, and brings the Herdr desktop app to the front showing it. If the Herdr desktop app is not running, Hop SHALL start it first.

#### Scenario: New workspace on a Mac
- **WHEN** the user chooses "New Workspace" on the Mac named `Studio`
- **THEN** a new space named `Studio` exists on that Mac's machine and the Herdr desktop app is in front showing it, with no prompt shown

#### Scenario: Herdr desktop app not running
- **WHEN** the user chooses "New Workspace" while the Herdr desktop app is not running
- **THEN** Hop starts the Herdr desktop app and the new space is created once it is ready

### Requirement: Open Herdr in a terminal
When the Herdr terminal app is installed, every Mac with a host SHALL offer "Open Herdr in Terminal", which opens a terminal window attached to the Herdr terminal app on that Mac, connecting with the Mac's user name when one is set.

#### Scenario: Mac with a user name
- **WHEN** the user chooses "Open Herdr in Terminal" on a Mac with host `studio.local` and user `sercan`
- **THEN** a terminal window opens running the Herdr terminal app attached to `sercan@studio.local`

#### Scenario: Mac with no user name
- **WHEN** the user chooses "Open Herdr in Terminal" on a Mac with host `studio.local` and no user
- **THEN** a terminal window opens running the Herdr terminal app attached to `studio.local`

### Requirement: Agent status is shown per space
While agent status is on, each listed space SHALL show a summary counting its agents by state, in the order working, blocked, done, idle, omitting states with a count of zero. Terminals that run no agent SHALL NOT be counted. A space with no agents SHALL show its name alone. Each state SHALL be distinguishable without relying on color alone.

#### Scenario: Mixed states
- **WHEN** a space has one working agent, one done agent and one plain shell
- **THEN** the space shows "1 working, 1 done"

#### Scenario: No agents
- **WHEN** a space contains only plain shells
- **THEN** the space shows its name with no status summary

### Requirement: Agents are listed in the Mac detail view
While agent status is on, a Mac's detail view SHALL list, under each space, one line per agent showing its tab, the agent app and its state.

#### Scenario: Space with two agents
- **WHEN** the user opens the detail view of a Mac whose space `quant-works` has a blocked `claude-code` agent in tab 1 and a working one in tab 2
- **THEN** `quant-works` shows two lines, "Tab 1 · claude-code · Blocked" and "Tab 2 · claude-code · Working"

### Requirement: Blocked agents are surfaced
While agent status is on, Hop SHALL show the total number of blocked agents on its menu-bar icon when that number is above zero. No other agent state SHALL appear on the icon. A Mac's own row SHALL NOT show agent status; the blocked state of its agents is shown by the banner and by the spaces listed under the row.

#### Scenario: One blocked agent
- **WHEN** one agent on one Mac is blocked
- **THEN** the menu-bar icon shows "1", that Mac's own row shows no blocked count, and the space holding the agent shows "1 blocked" under the row

#### Scenario: Nothing blocked
- **WHEN** every agent is working, done or idle
- **THEN** the menu-bar icon shows no count and no Mac row shows agent status

### Requirement: A banner points to blocked agents
While agent status is on and at least one agent is blocked, the top of the popover SHALL show a banner for each space that has a blocked agent, naming the space and its Mac, with an "Open" action that opens that space. At most three banners SHALL be shown; further spaces SHALL be summarized as a count.

#### Scenario: One space waiting
- **WHEN** a `claude-code` agent in `quant-works` on `Studio` is blocked
- **THEN** the popover shows a banner naming `quant-works` on `Studio`, and its "Open" action opens that space in the Herdr desktop app

#### Scenario: Five spaces waiting
- **WHEN** five spaces each have a blocked agent
- **THEN** three banners are shown followed by "and 2 more"

### Requirement: Agent status can be muted or turned off
Hop SHALL offer four agent status choices: On, Mute for 8 hours, Mute for 1 week, and Off. On SHALL be the default. While muted or off, Hop SHALL show no agent status anywhere: no icon count, no banner, no per-space summary and no per-agent lines. Workspaces and their actions SHALL remain. The choice SHALL be offered in the popover's "More" menu and in the Manage Macs window.

#### Scenario: Default
- **WHEN** Hop runs for the first time
- **THEN** agent status is on

#### Scenario: Muting
- **WHEN** an agent is blocked and the user chooses "Mute for 8 hours"
- **THEN** the icon count, the banner and all agent status disappear, and the workspaces are still listed with Open and New Tab

#### Scenario: Turning off
- **WHEN** the user chooses "Off"
- **THEN** no agent status is shown until the user chooses "On"

### Requirement: A mute ends by itself
A mute SHALL end at the chosen time after it was set, after which agent status SHALL be on again without user action. The mute and its end time SHALL survive quitting and reopening Hop. While muted, the agent status choices SHALL show when the mute ends and offer to turn agent status back on immediately.

#### Scenario: Mute expires
- **WHEN** the user mutes for 8 hours and 8 hours pass
- **THEN** agent status is shown again at the next refresh

#### Scenario: Hop restarted during a mute
- **WHEN** the user mutes for 1 week and restarts Hop the next day
- **THEN** agent status is still muted, with the same end time

#### Scenario: Ending a mute early
- **WHEN** agent status is muted and the user chooses "On"
- **THEN** agent status is shown again immediately

#### Scenario: Seeing when a mute ends
- **WHEN** agent status is muted and the user opens the agent status choices
- **THEN** the time the mute ends is shown

### Requirement: Herdr information refreshes with host status
Hop SHALL refresh Herdr machines, spaces and agent states whenever it refreshes host status: on its periodic refresh and on Refresh Status. After any Hop action that changes Herdr spaces or tabs, Hop SHALL refresh that information again.

#### Scenario: Manual refresh
- **WHEN** an agent becomes blocked and the user chooses Refresh Status
- **THEN** the popover and the menu-bar icon show the blocked agent

#### Scenario: After creating a workspace
- **WHEN** the user creates a workspace from Hop and reopens the popover
- **THEN** the new space is listed under that Mac

### Requirement: Herdr is available in the Manage Macs window
For a matched Mac, the Manage Macs window SHALL show the Herdr machine it matched, its spaces with Open and New Tab, New Workspace, and Open Herdr in Terminal, and SHALL show agent status under the same rules as the popover.

#### Scenario: Matched Mac selected
- **WHEN** the user selects a matched Mac in the Manage Macs window
- **THEN** the window shows its Herdr machine name, its spaces and the Herdr actions

#### Scenario: Unmatched Mac selected
- **WHEN** the user selects a Mac that is not a Herdr machine
- **THEN** the window shows no Herdr workspaces for it

### Requirement: Herdr failures do not disturb Hop
When a Herdr action fails, Hop SHALL signal the failure with the system alert sound and SHALL leave the popover and all non-Herdr actions working. A Herdr tool that is slow or does not answer SHALL NOT delay the popover opening.

#### Scenario: Action fails
- **WHEN** the user chooses "Open" on a space that no longer exists
- **THEN** Hop plays the alert sound and the popover remains usable

#### Scenario: Herdr does not answer
- **WHEN** a Herdr tool does not answer within Hop's time limit during a refresh
- **THEN** the popover opens normally, showing Herdr information from the last successful refresh or none
