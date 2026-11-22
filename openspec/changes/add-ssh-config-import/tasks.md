# Tasks

## 1. Reading the SSH configuration

- [ ] 1.1 Add a parser that reads `~/.ssh/config` and its `Include` files and returns each non-wildcard `Host` name with its `HostName`, `User` and `Port`, skipping `Match` blocks, and returns nothing when the file is missing; verify with a scratch script against fixture files covering includes, wildcards, several names on one `Host` line and a missing file

## 2. Model and actions

- [ ] 2.1 Add an optional SSH alias and SSH port to `RemoteMac`, saved in `hosts.json` and absent in old files; verify the existing `hosts.json` loads unchanged and a round trip keeps both fields
- [ ] 2.2 Make the SSH action connect through the alias when the Mac has one and the alias is still in the configuration, and fall back to the saved address and user otherwise; verify both paths against a fixture entry with a custom port
- [ ] 2.3 Probe the entry's SSH port for such a Mac; verify with a host listening only on a custom port

## 3. Manage Macs window

- [ ] 3.1 Add the "From SSH config" section listing unsaved hosts with an add control, hidden when there is no configuration file, refreshed when the window opens and on Refresh; verify each `ssh-config-import` listing scenario
- [ ] 3.2 Fill in name, address, user, alias and port when a host is added; verify against the "Adding a host fills in its details" scenarios
- [ ] 3.3 Describe the import in the README and on the website, including that a host behind a jump host shows as offline; verify both mention it

## 4. Integration checks

- [ ] 4.1 Run `openspec validate add-ssh-config-import --strict` and build the app; verify both succeed
- [ ] 4.2 In the running app, add a host from a sample configuration and open an SSH session to it
