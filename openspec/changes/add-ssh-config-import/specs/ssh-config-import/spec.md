# Spec Delta

## Purpose

Lets the user bring the machines already listed in their SSH configuration into Hop without retyping them, and makes SSH to those machines honor that configuration.

## ADDED Requirements

### Requirement: Hosts in the SSH configuration are offered in Manage Macs
The Manage Macs window SHALL list the hosts named in the user's SSH configuration file and in the files it includes, under a "From SSH config" heading, each with a control to add it to My Macs. Names containing wildcards SHALL NOT be listed. Hosts already saved in My Macs SHALL NOT be listed. When there is no SSH configuration file, the heading SHALL NOT be shown.

#### Scenario: Hosts found
- **WHEN** the SSH configuration names "studio" and "*.internal" and neither is saved
- **THEN** the Manage Macs window lists "studio" under "From SSH config" and does not list "*.internal"

#### Scenario: Included files
- **WHEN** the SSH configuration includes another file that names "buildbox"
- **THEN** "buildbox" is listed

#### Scenario: Already saved
- **WHEN** "studio" from the SSH configuration has been added to My Macs
- **THEN** "studio" is no longer listed under "From SSH config"

#### Scenario: No SSH configuration
- **WHEN** the user has no SSH configuration file
- **THEN** no "From SSH config" heading is shown

### Requirement: Adding a host fills in its details
Adding a host from the SSH configuration SHALL save it to My Macs with the entry's name as its name, the entry's host name as its address, or the entry's name when it has no host name, and the entry's user as its user name when it has one.

#### Scenario: Entry with a host name and user
- **WHEN** the user adds the entry "studio" whose host name is "10.0.0.5" and whose user is "sercan"
- **THEN** My Macs gains a Mac named "studio" with address "10.0.0.5" and user name "sercan"

#### Scenario: Entry with no host name
- **WHEN** the user adds the entry "studio.local" which has no host name
- **THEN** the saved Mac's address is "studio.local"

### Requirement: SSH uses the configuration entry
SSH to a Mac added from the SSH configuration SHALL connect through that Mac's configuration entry, so that the port, key, jump host and other options written there apply. When the entry is no longer in the SSH configuration, SSH SHALL connect to the Mac's saved address with its saved user name.

#### Scenario: Entry with a custom port
- **WHEN** the user chooses SSH on a Mac added from an entry whose port is 2222
- **THEN** the SSH session connects on port 2222

#### Scenario: Entry removed later
- **WHEN** the entry has been deleted from the SSH configuration and the user chooses SSH
- **THEN** the SSH session connects to the saved address with the saved user name

### Requirement: The online check uses the entry's SSH port
For a Mac added from the SSH configuration, Hop SHALL check SSH on the port given in its entry when deciding whether the Mac is online.

#### Scenario: SSH on a custom port
- **WHEN** a Mac added from an entry with port 2222 accepts connections on port 2222 and not on port 22
- **THEN** the Mac is shown as online
