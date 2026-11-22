# quick-open Specification

## Purpose

Lets the user reach a Mac from the keyboard: a global shortcut opens the popover from any app, and typing, arrow keys and shortcuts inside it find a Mac and connect to it.

## Requirements

### Requirement: A global shortcut opens the popover
Hop SHALL offer a global keyboard shortcut that opens the popover from any app and closes it when pressed while it is open. The shortcut SHALL be off by default and SHALL be chosen in the Manage Macs window from Control-Option-Space, Control-Option-H, Option-Command-H and Off. The choice SHALL survive quitting and reopening Hop.

#### Scenario: Opening from another app
- **WHEN** the shortcut is set and the user presses it while another app is in front
- **THEN** the Hop popover opens and receives keyboard input

#### Scenario: Pressing it again
- **WHEN** the popover is open and the user presses the shortcut
- **THEN** the popover closes

#### Scenario: Default
- **WHEN** Hop runs for the first time
- **THEN** no global shortcut is set

### Requirement: A shortcut that is taken is reported
When the chosen shortcut cannot be registered because another app holds it, Hop SHALL say so in the Manage Macs window and SHALL leave the global shortcut off.

#### Scenario: Shortcut already in use
- **WHEN** the user chooses a shortcut that another app has registered
- **THEN** the Manage Macs window says the shortcut is unavailable and no global shortcut is set

### Requirement: Typing filters the Mac list
While the Mac list is showing, typing SHALL filter it to the Macs whose name or address contains the typed text, ignoring case, and the typed text SHALL be shown in the popover header. No search field SHALL be shown while nothing is typed. Escape SHALL clear the typed text, and SHALL close the popover when there is none. The typed text SHALL be cleared when the popover is reopened.

#### Scenario: Filtering
- **WHEN** the list shows "Studio", "MacBook Air" and "Office iMac" and the user types "mac"
- **THEN** the list shows "MacBook Air" and "Office iMac", and the header shows "mac"

#### Scenario: No match
- **WHEN** the user types text that matches no Mac
- **THEN** the list says no Macs match

#### Scenario: Clearing
- **WHEN** text is typed and the user presses Escape
- **THEN** the full list is shown again and the popover stays open

#### Scenario: Escape with nothing typed
- **WHEN** nothing is typed and the user presses Escape
- **THEN** the popover closes

### Requirement: Macs can be chosen and reached from the keyboard
While text is typed, the first listed Mac SHALL be highlighted. The Up and Down arrow keys SHALL move the highlight through the listed Macs. Return SHALL open the highlighted Mac's detail view. Command-1, Command-2 and Command-3 SHALL run the highlighted Mac's first, second and third connection action. The highlight SHALL be distinguishable without relying on color alone.

#### Scenario: Shortcut, letters, Return
- **WHEN** the user opens the popover, types "stu" and presses Return
- **THEN** the detail view of "Studio" is shown

#### Scenario: Connecting without the mouse
- **WHEN** "Studio" is highlighted and the user presses Command-2
- **THEN** an SSH session to "Studio" starts and the popover closes

#### Scenario: Moving the highlight
- **WHEN** two Macs are listed with the first highlighted and the user presses Down
- **THEN** the second Mac is highlighted

### Requirement: The keys are shown while typing
While text is typed, the popover SHALL show a line at its bottom naming the keys that act on the list: Return for details, Command-1, Command-2 and Command-3 with the names of the highlighted Mac's actions, and Escape to clear. The line SHALL NOT be shown while nothing is typed.

#### Scenario: Typing
- **WHEN** the user types "mac" and "MacBook Air" is highlighted
- **THEN** the bottom of the popover names Return, Command-1 Screen Share, Command-2 SSH, Command-3 Files and Escape

#### Scenario: Nothing typed
- **WHEN** nothing is typed
- **THEN** no key line is shown
