# Tasks

## 1. Response time

- [x] 1.1 Make the TCP probe report how long the connect took, and keep the latest successful time per Mac in `Store`; verify by logging it for a reachable and an unreachable host
- [x] 1.2 Show the time in the detail view's status line for online Macs only; verify against the `reachability-alerts` response-time scenarios

## 2. Transitions

- [x] 2.1 Track the last reported state and consecutive misses per saved Mac, report offline after two misses and back after one answer, and never report a Mac that was offline at launch; verify with a scratch script driving the state function through each scenario
- [ ] 2.2 Skip counting while `NWPathMonitor` reports no network path, and on the first refresh after launch and after wake; verify by turning Wi-Fi off and by sleeping and waking the Mac

## 3. Notifications and setting

- [ ] 3.1 Add the setting to the Manage Macs window, saved in `UserDefaults` and off by default, requesting notification permission when turned on and turning itself off with an explanation and an "Open System Settings…" button when refused; verify both permission answers
- [ ] 3.2 Post one notification per transition naming the Mac; verify by turning Remote Login and Screen Sharing off and on again on a saved Mac
- [x] 3.3 Describe the setting in the README and on the website; verify both mention it

## 4. Integration checks

- [x] 4.1 Run `openspec validate add-reachability-alerts --strict` and build the app; verify both succeed
- [ ] 4.2 In the installed build, confirm notifications appear under Hop's name and that none is posted when this Mac's own network drops
