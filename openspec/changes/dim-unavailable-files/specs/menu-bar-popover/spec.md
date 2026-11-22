# Spec Delta

## ADDED Requirements

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
