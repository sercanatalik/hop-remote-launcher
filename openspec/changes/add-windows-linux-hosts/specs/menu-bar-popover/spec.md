# Spec Delta

## MODIFIED Requirements

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
