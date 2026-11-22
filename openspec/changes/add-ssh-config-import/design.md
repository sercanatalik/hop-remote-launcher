# Design

## Context

`Actions.ssh` opens `ssh://user@host`, which Terminal turns into `ssh user@host`. The same `host` string is used for `vnc://`, `smb://`, the TCP probes and Wake. An SSH configuration entry has an alias (`Host studio`) that only `ssh` understands, and a real address (`HostName 10.0.0.5`) that everything else needs. The Manage Macs sidebar already has a "From Tailscale" section with an add control. The development Mac has no `~/.ssh/config`.

## Goals / Non-Goals

**Goals:**
- SSH that honors the user's configuration; other actions that still work.

**Non-Goals:**
- Evaluating the configuration the way `ssh` does. Hop reads names, not behavior.

## Decisions

1. **Store both the address and the alias.** `RemoteMac` gains an optional `sshAlias` and `sshPort`. `host` is the entry's `HostName`, or the alias when there is none, so Screen Share, Files, probes and Wake keep working. SSH uses the alias. Storing only the alias was rejected because `vnc://alias` does not resolve; storing only the address was rejected because it loses the port, key and jump host.
2. **SSH by alias opens `ssh://<alias>`.** Terminal runs `ssh <alias>`, and `ssh` applies the whole entry. No user name is added, because the entry supplies it. If the alias is no longer in the file when the action runs, Hop falls back to the saved address and user.
3. **A small line parser, not `ssh -G`.** Hop reads `Host`, `HostName`, `User`, `Port` and `Include` (relative to `~/.ssh`, with `*` globs), and takes each name on a `Host` line that has no `*`, `?` or `!`. `ssh -G <alias>` would give exact values but costs one process per host and resolves things Hop does not need. `Match` blocks are ignored: lines after one are skipped until the next `Host`. Values follow `ssh`'s first-value-wins rule, so a default set above a host's block wins over the block; the parser's output was compared with `ssh -G` on a fixture file and agreed.
4. **Offered in Manage Macs only.** A live popover group would add a third section to a list this project just made quieter, and SSH configuration files often hold dozens of servers that are not Macs. Listing them where hosts are managed keeps the choice with the user.
5. **The file is read when the Manage Macs window opens and on Refresh**, not on the 30-second timer.

## Risks / Trade-offs

- [The parser disagrees with `ssh` on an unusual file] → It only decides which names to offer; the connection itself is made by `ssh` through the alias.
- [A host behind a jump host is unreachable directly, so it shows as offline and its other actions fail] → Accepted and documented; SSH still works because it goes through the alias.
- [No SSH configuration on the developer's Mac] → Verification needs a sample file; the parser is checked with a scratch script against fixtures.
