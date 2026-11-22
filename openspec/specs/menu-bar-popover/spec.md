# menu-bar-popover Specification

## Purpose

Defines the popover Hop opens from the menu bar: how the user's Macs are listed with their status, how each Mac's connection actions are reached, and where the app-level actions live.

## Requirements

### Requirement: Hop opens a popover from the menu bar
Clicking the Hop icon in the menu bar SHALL open a popover anchored to the icon. The popover SHALL show a header with the number of Macs online out of the total, the Mac list, and a footer with app-level actions.

#### Scenario: Opening Hop
- **WHEN** the user clicks the Hop icon while three of four Macs are online
- **THEN** a popover opens showing "3 of 4 online", the Mac list and the footer

### Requirement: Macs are listed in two groups
The popover SHALL list saved Macs under "My Macs" and discovered Tailscale Macs under "Tailscale", each row showing the Mac's name, its address or offline state, and whether it is online, offline or still being checked. The three reachability states SHALL be distinguishable without relying on color alone.

#### Scenario: Saved and Tailscale Macs
- **WHEN** the user has one saved Mac and two Macs discovered from Tailscale
- **THEN** the saved Mac appears under "My Macs" and the other two under "Tailscale"

#### Scenario: No saved Macs
- **WHEN** the user has no saved Macs
- **THEN** the "My Macs" group reads "No saved Macs yet"

#### Scenario: Tailscale not available
- **WHEN** Tailscale is not installed or not running
- **THEN** the "Tailscale" group shows a single button that opens or installs Tailscale, with the reason

### Requirement: Mac rows offer one-click connection actions
Each Mac row SHALL offer Screen Share, SSH and Files as one-click buttons, each with an accessible label naming the action and the Mac. A Tailscale Mac's row SHALL also offer "Add to My Macs".

#### Scenario: Screen Share from the list
- **WHEN** the user clicks the Screen Share button on a Mac's row
- **THEN** Screen Sharing opens to that Mac and the popover closes

#### Scenario: Pinning a Tailscale Mac
- **WHEN** the user clicks "Add to My Macs" on a Tailscale Mac
- **THEN** that Mac moves to "My Macs" and the popover stays open

### Requirement: Each Mac has a detail view
Choosing a Mac's row SHALL show a detail view inside the popover for that Mac, with a control to return to the list. The detail view SHALL offer Screen Share, SSH, Files and Copy Address, SHALL offer Wake when the Mac has a MAC address, and SHALL show the Mac's address.

#### Scenario: Opening and leaving the detail view
- **WHEN** the user chooses a Mac's row and then the back control
- **THEN** the popover shows that Mac's detail view and then returns to the Mac list

#### Scenario: Mac with a MAC address
- **WHEN** the user opens the detail view of a Mac that has a MAC address set
- **THEN** a Wake action is offered

#### Scenario: Mac without a MAC address
- **WHEN** the user opens the detail view of a Mac with no MAC address
- **THEN** no Wake action is shown

### Requirement: App-level actions remain available
The popover SHALL offer Refresh Status, Manage Macs, Open Screen Sharing, Hop on GitHub, Report an Issue, About Hop and Quit Hop. Refresh Status, Manage Macs and Quit Hop SHALL keep their keyboard shortcuts (Command-R, Command-comma, Command-Q) while the popover is open.

#### Scenario: Refreshing from the keyboard
- **WHEN** the popover is open and the user presses Command-R
- **THEN** Hop refreshes the status of every Mac

#### Scenario: Opening the Manage window
- **WHEN** the user chooses "Manage Macs…"
- **THEN** the Manage Macs window opens in front and the popover closes

### Requirement: The popover closes after launching something
The popover SHALL close after any action that opens another app or window, and SHALL stay open after actions that only change what the popover shows.

#### Scenario: Action that leaves Hop
- **WHEN** the user starts an SSH session from the popover
- **THEN** the popover closes

#### Scenario: Action that stays in Hop
- **WHEN** the user chooses Refresh Status or Copy Address
- **THEN** the popover stays open
