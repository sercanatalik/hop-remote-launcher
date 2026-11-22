# Design

## Context

The popover is a SwiftUI `MenuBarExtra` in `.window` style, all in `Hop.swift`. `PopoverView` draws a header, a scrolling list or detail view, and a footer. `MacRow`, `HerdrBlock`, `WorkspaceRow` and `MacDetailView` draw the parts this change touches. `WorkspaceRow` is also used by the Manage Macs window, which is out of scope. See proposal.md for motivation and the canvas for the target look.

## Goals / Non-Goals

**Goals:**
- Fewer always-visible controls in the popover, with every existing action still reachable.
- Row actions stay reachable by keyboard and VoiceOver even though they are hidden at rest.

**Non-Goals:**
- No change to the Manage Macs window's layout.
- No change to Herdr fetching, matching, refresh or the agent status model.
- No custom colors or fonts: system styles only, so light and dark both follow the system.

## Decisions

1. **Reveal row actions with opacity, not by removing them.** The three icon buttons stay in the view tree and switch between opacity 0 and 1 on hover or when one has keyboard focus (`@FocusState`). Removing them would make the row jump in width and would give keyboard focus nothing to land on. The trailing note ("Offline", "3 workspaces") shares the same space and fades the other way.
2. **Accessibility actions on the row button.** The row's main button carries named accessibility actions for Screen Share, SSH and Files. This does not depend on whether a transparent button is exposed to VoiceOver, which is not something to rely on.
3. **Hidden buttons own the keyboard shortcuts.** Command-comma and Command-Q are bound to zero-size transparent buttons in the popover background, present in both the list and the detail view. Whether SwiftUI fires shortcuts of items inside a closed `Menu` is not guaranteed, and the detail header has no "More" menu. The menu items also declare the shortcuts so the hints show; firing twice is harmless for both actions. Command-R stays on the visible Refresh button.
4. **Mute end time lives in the agent status submenu.** With the footer strip gone, the submenu shows a disabled "Muted until …" line above the choices, and the header shows a `bell.slash` button that turns status back on. Alternative considered: keep a strip under the header; rejected because it re-adds the clutter this change removes.
5. **`WorkspaceRow` gains a compact mode instead of being replaced.** The Manage window keeps the two text buttons; the detail view passes a flag that swaps "New Tab" for a "+" icon button. The list under a Mac row uses a new, smaller `SpaceLine` whose whole row is the Open button.
6. **Pinning from the detail view follows the Mac.** `store.pin` returns the saved Mac's id; the detail view switches to it so the user is not dropped back to the list when the Tailscale entry disappears.

## Risks / Trade-offs

- [Hover-only actions are less discoverable] → The chevron and row click still lead to the detail view, where every action is visible. If it proves annoying, Screen Share can be made always visible without a spec restructure.
- [Keyboard focus may not reach a fully transparent button on some macOS versions] → Covered by the accessibility actions and the detail view; needs a manual check with Full Keyboard Access.
- [Website and README screenshots show the old layout] → Retake after the change; tracked as a manual task.
