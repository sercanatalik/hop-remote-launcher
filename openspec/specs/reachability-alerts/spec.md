# reachability-alerts Specification

## Purpose

Tells the user when a saved Mac goes offline or comes back without the popover being open, while avoiding false alarms, and shows how quickly a Mac responds.

## Requirements

### Requirement: Saved Macs going offline or coming back can be announced
Hop SHALL offer a setting, off by default, in the Manage Macs window that makes it post a macOS notification naming a saved Mac when that Mac goes offline, and another when it comes back online. Macs that are only listed from Tailscale SHALL NOT be announced. The setting SHALL survive quitting and reopening Hop.

#### Scenario: A saved Mac drops off
- **WHEN** the setting is on and a saved Mac that was online is found offline on two checks in a row
- **THEN** one notification says that Mac is offline

#### Scenario: It comes back
- **WHEN** a saved Mac that Hop announced as offline answers a check
- **THEN** one notification says that Mac is back online

#### Scenario: Setting off
- **WHEN** the setting is off and a saved Mac goes offline
- **THEN** no notification is posted

#### Scenario: Tailscale-only Mac
- **WHEN** the setting is on and a Mac listed only from Tailscale goes offline
- **THEN** no notification is posted

### Requirement: False alarms are avoided
Hop SHALL NOT announce a Mac as offline after a single failed check. Hop SHALL NOT announce anything while this computer has no network connection, on the first check after Hop starts, or on the first check after this computer wakes from sleep. A Mac that was already offline when Hop started SHALL NOT be announced as offline.

#### Scenario: One failed check
- **WHEN** a saved Mac fails one check and answers the next
- **THEN** no notification is posted

#### Scenario: This computer loses its network
- **WHEN** this computer has no network connection and every saved Mac fails its checks
- **THEN** no notification is posted

#### Scenario: Waking from sleep
- **WHEN** this computer wakes and the first check finds a saved Mac offline
- **THEN** no notification is posted for that check

### Requirement: Notification permission is handled
Turning the setting on SHALL ask for permission to post notifications when it has not been given. When permission is refused, the setting SHALL stay off and the Manage Macs window SHALL say that notifications are turned off for Hop in System Settings. It SHALL also offer a control that opens the notification settings in System Settings.

#### Scenario: Permission given
- **WHEN** the user turns the setting on and allows notifications
- **THEN** the setting is on

#### Scenario: Permission refused
- **WHEN** the user turns the setting on and refuses notifications
- **THEN** the setting is off and the window explains where to allow them

#### Scenario: Going to System Settings
- **WHEN** permission was refused and the user chooses "Open System Settings…"
- **THEN** System Settings opens at its notification settings

### Requirement: A Mac's response time is shown
The status line of a Mac's detail view SHALL show how long the most recent successful check took to reach that Mac, in milliseconds, when such a check has been made. It SHALL show no time for an offline Mac.

#### Scenario: Online Mac
- **WHEN** the user opens the detail view of a Mac whose last check answered in 12 milliseconds
- **THEN** the status line includes "12 ms"

#### Scenario: Offline Mac
- **WHEN** the user opens the detail view of an offline Mac
- **THEN** the status line shows no response time
