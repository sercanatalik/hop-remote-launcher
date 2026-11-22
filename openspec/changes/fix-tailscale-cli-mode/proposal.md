# Proposal

## Why

Hop shows "Tailscale isn't running" while Tailscale is running, whenever Hop was started from Finder, the Dock, Spotlight or at login. Hop reads the tailnet by running the Tailscale app's binary with `status --json`. That binary is both the GUI app and the command-line tool and picks its mode from the environment; with the bare environment of a normally launched app it tries to start as the GUI and prints "The Tailscale GUI failed to start" instead of the status. Hop only worked when started from a terminal. This affects the released 1.0.0 and 1.1.0.

## What Changes

- Hop runs the Tailscale command with `TAILSCALE_BE_CLI=1`, Tailscale's own switch for forcing command-line mode, so discovery works however Hop was started.
- When the Tailscale command answers with something Hop cannot read, the Tailscale group says the status could not be read, instead of claiming Tailscale isn't running. "Tailscale isn't running" is kept for the case where the command returns nothing.

Out of scope: any other change to Tailscale discovery; the App Store variant of Tailscale was not available to test.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `menu-bar-popover`: adds that Tailscale Macs are listed however Hop was started, and that an unreadable status is reported as unreadable.

## Impact

- `Hop.swift`: `Tailscale.fetch` (environment of the child process, and the message for unreadable output).
- No interface change beyond the wording of one message.
