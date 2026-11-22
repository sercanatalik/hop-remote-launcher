# Spec Delta

## MODIFIED Requirements

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
