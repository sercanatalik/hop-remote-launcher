# Tasks

## 1. File-sharing check

- [x] 1.1 Add a per-Mac file-sharing result to `Store`, probed on port 445 in `refresh` for saved Macs and in `refreshTailscale` for online Tailscale Macs, with a helper that is false only when a Mac is online and the probe failed; verify by build and by reading both probe sites

## 2. Popover

- [x] 2.1 Dim the Files button in `MacRow` and in `MacDetailView` when the helper is false, with a tooltip and accessible label saying File Sharing appears to be off, leaving the action unchanged; verify by build
- [x] 2.2 Add one sentence to the README and the website describing the dimmed Files button; verify both mention it

## 3. Integration checks

- [x] 3.1 Run `openspec validate dim-unavailable-files --strict` and build the app; verify both succeed
- [ ] 3.2 In the running app, confirm Files is dimmed on a Mac with File Sharing off and normal on one with it on
