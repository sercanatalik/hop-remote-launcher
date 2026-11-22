# Tasks

## 1. Fix

- [x] 1.1 Run the Tailscale command with `TAILSCALE_BE_CLI=1` added to the environment; verify with a scratch build run under an empty environment (`env -i`) that the fetch returns the running state and the peers, where the unfixed code returns "not running"
- [x] 1.2 Report non-empty output that is not a status as "Couldn't read Tailscale's status" and keep "Tailscale isn't running" for empty output; verify both with a scratch test of the function that interprets the output

## 2. Integration checks

- [x] 2.1 Run `openspec validate fix-tailscale-cli-mode --strict` and build the app; verify both succeed
- [x] 2.2 Launch the installed build through Launch Services with an empty environment and confirm the Tailscale Macs are listed
