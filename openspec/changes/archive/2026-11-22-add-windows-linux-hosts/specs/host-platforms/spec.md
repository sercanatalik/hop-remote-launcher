# Spec Delta

## Purpose

Lets Hop list and reach computers that are not Macs: it records each host's platform, finds Windows and Linux computers on the tailnet, offers Remote Desktop for Windows hosts, and shows which connection actions a host does not accept.

## ADDED Requirements

### Requirement: Every host has a platform
Each host SHALL have a platform: Mac, Windows or Linux. A Tailscale host's platform SHALL be the one Tailscale reports. A saved host's platform SHALL default to Mac and SHALL be changeable in the Manage Macs window. A Tailscale host added to My Macs SHALL keep its platform.

#### Scenario: Windows PC on the tailnet
- **WHEN** Tailscale reports a device whose operating system is Windows
- **THEN** Hop treats that host as a Windows host

#### Scenario: Existing saved hosts
- **WHEN** Hop starts with a host list saved before platforms existed
- **THEN** every saved host is a Mac

#### Scenario: Changing a saved host's platform
- **WHEN** the user sets a saved host's platform to Windows in the Manage Macs window
- **THEN** that host is a Windows host from then on, including after Hop restarts

### Requirement: Tailscale lists other computers on request
While the "Only Macs" setting is off, the Tailscale group SHALL list Windows and Linux computers as well as Macs. While it is on, the group SHALL list only Macs. Devices that are not computers, such as phones, tablets and TVs, SHALL NOT be listed in either case.

#### Scenario: Only Macs off
- **WHEN** "Only Macs" is off and the tailnet has a Mac, a Linux machine and a phone
- **THEN** the Tailscale group lists the Mac and the Linux machine and not the phone

#### Scenario: Only Macs on
- **WHEN** "Only Macs" is on and the tailnet has a Mac and a Windows PC
- **THEN** the Tailscale group lists only the Mac

### Requirement: Windows hosts offer Remote Desktop
A Windows host SHALL offer a Remote Desktop action that opens a Remote Desktop connection to that host in the remote desktop app installed on this Mac, using the host's user name when one is set, and closes the popover. Hop SHALL NOT display the remote session itself.

#### Scenario: Connecting
- **WHEN** a remote desktop app is installed and the user chooses Remote Desktop on a Windows host
- **THEN** that app opens a connection to the host and the popover closes

#### Scenario: No remote desktop app installed
- **WHEN** no app on this Mac can open Remote Desktop connections
- **THEN** the Remote Desktop control is dimmed, its tooltip and accessible label say an app is needed, and choosing it opens the page to get Windows App

### Requirement: Connection actions a host refuses are dimmed
Hop SHALL check, whenever it refreshes host status, whether each online host accepts Screen Sharing, Remote Desktop and SSH connections. A Screen Share, Remote Desktop or SSH control SHALL be dimmed, with a tooltip and accessible label saying that service appears to be off, when its host is online and refuses that connection. A dimmed control SHALL still attempt the connection when chosen. Controls SHALL be shown normally before the check has finished and on offline hosts.

#### Scenario: SSH turned off
- **WHEN** a Windows host is online, accepts Remote Desktop connections and refuses SSH connections
- **THEN** its SSH control is dimmed and its Remote Desktop control is shown normally

#### Scenario: Linux host without screen sharing
- **WHEN** a Linux host is online and refuses Screen Sharing connections
- **THEN** its Screen Share control is dimmed

#### Scenario: Choosing a dimmed control
- **WHEN** the user chooses a dimmed SSH control
- **THEN** Hop attempts the SSH connection and the popover closes

#### Scenario: Offline host
- **WHEN** a host is offline
- **THEN** none of its controls are dimmed

### Requirement: Saved hosts are online when any service answers
A saved host SHALL be shown as online when it accepts at least one of Screen Sharing, Remote Desktop, SSH or file-sharing connections, and as offline when it accepts none.

#### Scenario: Windows PC with only Remote Desktop
- **WHEN** a saved Windows host accepts Remote Desktop connections and nothing else
- **THEN** it is shown as online

### Requirement: A non-Mac host's platform is named
A Windows or Linux host's platform SHALL be named in words on its row in the Mac list when the row has nothing else to say there, and in the status line of its detail view. A Mac's platform SHALL NOT be named.

#### Scenario: Windows host in the list
- **WHEN** an online Windows host with no Herdr workspaces is listed
- **THEN** its row reads "Windows" where an offline host's row reads "Offline"

#### Scenario: Detail view
- **WHEN** the user opens the detail view of an online Linux host found by Tailscale
- **THEN** the status line includes "Linux"
