# Spec Delta

## MODIFIED Requirements

### Requirement: Blocked agents are surfaced
While agent status is on, Hop SHALL show the total number of blocked agents on its menu-bar icon when that number is above zero. No other agent state SHALL appear on the icon. A Mac's own row SHALL NOT show agent status; the blocked state of its agents is shown by the banner and by the spaces listed under the row.

#### Scenario: One blocked agent
- **WHEN** one agent on one Mac is blocked
- **THEN** the menu-bar icon shows "1", that Mac's own row shows no blocked count, and the space holding the agent shows "1 blocked" under the row

#### Scenario: Nothing blocked
- **WHEN** every agent is working, done or idle
- **THEN** the menu-bar icon shows no count and no Mac row shows agent status

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
