# menu-bar-popover Specification

## Purpose

Defines the popover Hop opens from the menu bar: how the user's Macs are listed with their status, how each Mac's connection actions are reached, and where the app-level actions live.

## Requirements

### Requirement: Hop opens a popover from the menu bar
Clicking the Hop icon in the menu bar SHALL open a popover anchored to the icon. The popover SHALL show a header with the number of Macs online out of the total, a Refresh Status control and a "More" menu, followed by the Mac list. The popover SHALL NOT have a footer.

#### Scenario: Opening Hop
- **WHEN** the user clicks the Hop icon while three of four Macs are online
- **THEN** a popover opens showing "3 of 4 online", the Refresh Status control, the "More" menu and the Mac list

### Requirement: Macs are listed in two groups
The popover SHALL list saved Macs under "My Macs" and discovered Tailscale Macs under "Tailscale", each row showing the Mac's name and whether it is online, offline or still being checked, with the word "Offline" on an offline Mac's row. The three reachability states SHALL be distinguishable without relying on color alone. The "My Macs" group SHALL be shown only when there is at least one saved Mac.

#### Scenario: Saved and Tailscale Macs
- **WHEN** the user has one saved Mac and two Macs discovered from Tailscale
- **THEN** the saved Mac appears under "My Macs" and the other two under "Tailscale"

#### Scenario: No saved Macs
- **WHEN** the user has no saved Macs and Tailscale Macs are listed
- **THEN** no "My Macs" group or heading is shown

#### Scenario: Nothing to list
- **WHEN** the user has no saved Macs and the Tailscale group is turned off
- **THEN** the popover says there are no Macs yet and offers a control that opens the Manage Macs window

#### Scenario: Tailscale not available
- **WHEN** Tailscale is not installed or not running
- **THEN** the "Tailscale" group shows a single button that opens or installs Tailscale, with the reason

### Requirement: Mac rows offer one-click connection actions
Each Mac row SHALL offer Screen Share, SSH and Files as one-click buttons, each with an accessible label naming the action and the Mac. The buttons SHALL be shown while the pointer is over the row or keyboard focus is on one of them, and SHALL otherwise be hidden. The three actions SHALL be available to assistive technology on every row whether or not the buttons are shown. On a Windows host's row, Remote Desktop SHALL take the place of Screen Share.

#### Scenario: Row at rest
- **WHEN** the pointer is not over a Mac's row and none of its buttons has keyboard focus
- **THEN** the row shows no Screen Share, SSH or Files buttons

#### Scenario: Screen Share from the list
- **WHEN** the user moves the pointer over a Mac's row and clicks the Screen Share button that appears
- **THEN** Screen Sharing opens to that Mac and the popover closes

#### Scenario: Assistive technology
- **WHEN** a VoiceOver user is on a Mac's row
- **THEN** Screen Share, SSH and Files are offered as actions for that Mac

#### Scenario: Pinning a Tailscale Mac
- **WHEN** the user looks at a Tailscale Mac's row
- **THEN** the row offers no "Add to My Macs" control, and the action is offered in that Mac's detail view

#### Scenario: Windows host row
- **WHEN** the user moves the pointer over a Windows host's row
- **THEN** Remote Desktop, SSH and Files buttons appear, and no Screen Share button

### Requirement: Each Mac has a detail view
Choosing a Mac's row SHALL show a detail view inside the popover for that Mac, with a control to return to the list. The detail view SHALL offer Screen Share, SSH, Files and Copy Address, SHALL offer Wake when the Mac has a MAC address, SHALL offer "Add to My Macs" when the Mac is a Tailscale Mac, and SHALL show the Mac's address. In a Windows host's detail view, Remote Desktop SHALL take the place of Screen Share.

#### Scenario: Opening and leaving the detail view
- **WHEN** the user chooses a Mac's row and then the back control
- **THEN** the popover shows that Mac's detail view and then returns to the Mac list

#### Scenario: Mac with a MAC address
- **WHEN** the user opens the detail view of a Mac that has a MAC address set
- **THEN** a Wake action is offered

#### Scenario: Mac without a MAC address
- **WHEN** the user opens the detail view of a Mac with no MAC address
- **THEN** no Wake action is shown

#### Scenario: Adding a Tailscale Mac from the detail view
- **WHEN** the user chooses "Add to My Macs" in a Tailscale Mac's detail view
- **THEN** that Mac moves to "My Macs", the popover stays open and the detail view shows the saved Mac

#### Scenario: Windows host detail view
- **WHEN** the user opens the detail view of a Windows host
- **THEN** Remote Desktop is offered as the primary action, with SSH, Files and Copy Address

### Requirement: App-level actions remain available
The popover SHALL offer Refresh Status in its header, and Open Screen Sharing, Hop on GitHub, Report an Issue and About Hop in the header's "More" menu. Manage Macs and Quit Hop SHALL be offered as visible controls at the bottom of the Mac list, each shown with its keyboard shortcut, and not inside a menu. Refresh Status, Manage Macs and Quit Hop SHALL keep their keyboard shortcuts (Command-R, Command-comma, Command-Q) while the popover is open, in the Mac list and in a Mac's detail view.

#### Scenario: Refreshing from the keyboard
- **WHEN** the popover is open and the user presses Command-R
- **THEN** Hop refreshes the status of every Mac

#### Scenario: Opening the Manage window
- **WHEN** the user chooses "Manage Macs…" at the bottom of the Mac list
- **THEN** the Manage Macs window opens in front and the popover closes

#### Scenario: Quitting from a detail view
- **WHEN** a Mac's detail view is showing and the user presses Command-Q
- **THEN** Hop quits

#### Scenario: Quitting from the Mac list
- **WHEN** the Mac list is showing and the user chooses "Quit Hop" at the bottom of the popover
- **THEN** Hop quits

### Requirement: The popover closes after launching something
The popover SHALL close after any action that opens another app or window, and SHALL stay open after actions that only change what the popover shows.

#### Scenario: Action that leaves Hop
- **WHEN** the user starts an SSH session from the popover
- **THEN** the popover closes

#### Scenario: Action that stays in Hop
- **WHEN** the user chooses Refresh Status or Copy Address
- **THEN** the popover stays open

### Requirement: Muted agent status is indicated in the header
While agent status is muted or off and the Herdr desktop app is installed, the popover header SHALL show a muted indicator that is distinguishable without relying on color, and choosing it SHALL turn agent status back on. No indicator SHALL be shown while agent status is on.

#### Scenario: Muted
- **WHEN** agent status is muted for 8 hours and the user opens the popover
- **THEN** the header shows the muted indicator

#### Scenario: Turning back on from the header
- **WHEN** the user chooses the muted indicator
- **THEN** agent status is on and the indicator disappears

#### Scenario: Agent status on
- **WHEN** agent status is on
- **THEN** the header shows no muted indicator

### Requirement: Files is dimmed when file sharing is unavailable
Hop SHALL check, whenever it refreshes host status, whether each online Mac accepts file-sharing connections. In the popover, the Files control of a Mac that is online but does not accept them SHALL be dimmed in the Mac's row and in its detail view, and its tooltip and accessible label SHALL say that File Sharing appears to be off. A dimmed Files control SHALL still attempt the connection when chosen. Files SHALL be shown normally before the check has finished and on Macs that are offline.

#### Scenario: File Sharing turned off
- **WHEN** a Mac is online, accepts Screen Sharing connections and refuses file-sharing connections
- **THEN** its Files control is dimmed and its tooltip says File Sharing appears to be off, while Screen Share and SSH are shown normally

#### Scenario: File Sharing turned on
- **WHEN** a Mac is online and accepts file-sharing connections
- **THEN** its Files control is shown normally

#### Scenario: Choosing a dimmed Files control
- **WHEN** the user chooses a dimmed Files control
- **THEN** Hop attempts the file-sharing connection and the popover closes

#### Scenario: Offline Mac
- **WHEN** a Mac is offline
- **THEN** its Files control is not dimmed

#### Scenario: File Sharing turned on later
- **WHEN** File Sharing is turned on for a Mac whose Files control is dimmed and the user chooses Refresh Status
- **THEN** the Files control is shown normally
