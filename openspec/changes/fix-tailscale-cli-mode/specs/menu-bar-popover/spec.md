# Spec Delta

## ADDED Requirements

### Requirement: Tailscale Macs are listed however Hop was started
While Tailscale is running, Hop SHALL list the Tailscale Macs whether Hop was started from Finder, the Dock, Spotlight, at login or from a terminal.

#### Scenario: Started from Finder
- **WHEN** Tailscale is running and the user opens Hop from Finder
- **THEN** the Tailscale group lists the Macs on the tailnet

#### Scenario: Started at login
- **WHEN** Tailscale is running and Hop was started at login
- **THEN** the Tailscale group lists the Macs on the tailnet

### Requirement: An unreadable Tailscale status is reported as unreadable
When the Tailscale command answers with something Hop cannot read as a status, the Tailscale group SHALL say that Tailscale's status could not be read, with the control that opens Tailscale, and SHALL NOT say that Tailscale isn't running.

#### Scenario: Unexpected answer
- **WHEN** the Tailscale command prints text that is not a status
- **THEN** the Tailscale group reads "Couldn't read Tailscale's status" with the control to open Tailscale

#### Scenario: No answer
- **WHEN** the Tailscale command prints nothing
- **THEN** the Tailscale group reads "Tailscale isn't running" with the control to open Tailscale
