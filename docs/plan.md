# Plan: Simple Menubar Hider (SMH) for macOS 27

## Context

The user wants a small Mac app that hides chosen apps' menu bar icons. Thaw works on macOS 27 but has too many features. This Mac runs macOS 27.0.1 (build 26A434) with Xcode 27.0.

**What macOS 27 broke (research, 2026-10-14):**
- Before macOS 27, every menu bar icon was its own small window. Bartender, Ice, Hidden Bar and Dozer found those windows and moved them off screen.
- macOS 27 draws the whole menu bar as one window, owned by a new process called `MenuBarAgent`. There are no per-icon windows left to move, capture or click. Every hider broke on beta 1.
- `MenuBarAgent` drops any status item wider than half the display. The old "very wide divider" trick (Dozer, Hidden Bar) now makes the divider vanish instead of pushing icons away.
- Apple added an overflow arrow (`«`) that holds icons that do not fit. The user cannot choose what goes there.
- Apple has no public API for managing other apps' icons.

**What still works (open-source fixes):**
1. **App list ("assessment mode" allowlist).** macOS 27 keeps the exam-mode feature that strips the menu bar bare. The private framework `MenuBarClientCore` has `MBAssessmentModeConfiguration` and `MBAssessmentModeAssertion`. An app sends a list of bundle IDs that may draw icons. `MenuBarAgent` hides the rest. Releasing the assertion brings everything back. Used by Stash and MenuBarHider. Needs no special entitlement, but needs no sandbox. Known traps: it blocks Notification Center (clicking the clock) while active; passing an `NSSet` where an `NSArray` is expected throws; a system-items range of `0...63` silently hides Screen Mirroring; Apple's own extras share one bundle ID.
2. **Wide divider into the overflow.** A divider sized just under half the display pushes icons into Apple's `«` overflow. Public API only, but hides by position, not by app, and reflows when the front app's menu changes width. Used by IceMelt and Hidden Bar 1.11.1.

I confirmed `MenuBarClientCore.framework` and `MenuBarAgent` exist on this Mac. A Developer ID certificate ("Developer ID Application: Yi Li (8Q5V8XK85Y)") is installed, and `xcodegen` is on PATH.

**User decisions (2026-10-14):**
- Hide method: the app list (method 1).
- Reveal: one click puts hidden icons back in the bar; they hide again after a delay.
- Extras in version 1: launch at login, auto-update.
- Audience: public on GitHub with a Homebrew cask. The App Store was dropped, because a sandboxed build cannot use the hiding method (Hidden Bar's App Store build hides nothing on macOS 27).

**Sources:** [Stash](https://github.com/brentc22/stash), [MenuBarHider](https://github.com/happy666End/MenuBarHider), [IceMelt PR #46](https://github.com/pnikolaidis/icemelt/pull/46), [Thaw issue #687](https://github.com/thaw-app/Thaw/issues/687), [Thaw discussion #737](https://github.com/thaw-app/Thaw/discussions/737), [Hidden Bar #360](https://github.com/dwarvesf/hidden/issues/360), [Macworld](https://macworld.info/article/why-macos-27-broke-mac-utilities/), [BTT forum](https://community.folivora.ai/t/macos-27-golden-gate-menu-bar-management-broken-solutions-ice-thaw-bartender-barbee-etc/47232). These are third-party reports, not Apple docs. Milestone 0 checks each claim on this Mac before anything is built on it.

**Research gap:** I did not run the `research-sources` skill (Reddit and X) or an Astra investigator, because plan mode allows read-only work. Milestone 0 starts with that pass.

## Tier and setup

- **Tier 3.** It is a new project that uses a private Apple framework and controls a system process. A bug can hide icons the user needs or block Notification Center.
- Name: **Simple Menubar Hider (SMH)**, set by the user. Repo: `/Users/yili/work/Projects/SimpleMenubarHider`, its own Git repo, work in a worktree per CLAUDE.md.
- Stack (from the fall 2026 stack note): Swift 6, SwiftUI for the settings window, AppKit `NSStatusItem` for the icon, XcodeGen `project.yml`, Swift Testing. Minimum macOS 27.0.
- Builders: Codex Sol first (Tier 3), through `prepare_task.py` and `runner.py`. Root reviews every build.
- Planning uses the `greenfield-plan` skill at build start for the dependency graph and milestone checks.

## How it works

```
 Settings window ──writes──► hidden set (UserDefaults: bundle IDs)
                                   │
 NSWorkspace launch/quit ──────────┤
 Accessibility scan (AXExtrasMenuBar) ─► "apps with icons" list
                                   ▼
                           SMHCore (pure Swift)
                 allowed = apps with icons − hidden + SMH itself
                                   │
                                   ▼
                    MenuBarShim (Objective-C, dlopen)
              MBAssessmentModeConfiguration / Assertion
                                   │
                                   ▼
                            MenuBarAgent (Apple)
                      draws only the allowed apps' icons
```

Parts:
1. **SMHCore** (Swift package, no AppKit). Holds the hidden set, works out the allowed list, and runs the state machine: `expanded`, `collapsed`, `revealing` (timer running), `unavailable`. All logic lives here so unit tests cover it.
2. **MenuBarShim** (Objective-C). Loads `MenuBarClientCore` with `dlopen` and finds the classes at run time. It exposes `isAvailable`, `apply(allowedBundleIDs, systemItems)` and `release()`. Any missing class, missing selector or thrown exception returns an error. It never crashes and never hides on error.
3. **Scanner.** Lists running apps with `NSWorkspace`. Uses Accessibility (`AXExtrasMenuBar`) to find which apps own an icon. Finds the clock's position for the Notification Center workaround.
4. **App shell.** SMH's own status item: click to reveal, right-click for a small menu (Settings, Pause hiding, Quit). Settings window with one list of apps and a checkbox each. Launch at login through `SMAppService`. Sparkle for updates.

Safety rules:
- SMH never hides itself, the clock or Control Center.
- If the shim is unavailable, SMH shows a warning badge and hides nothing.
- Quitting or crashing must bring every icon back. Milestone 0 proves this.
- SMH refuses to hide when it is not running from `/Applications` (macOS will not draw its icon there).
- The app is signed with the Developer ID every build, so the Accessibility grant survives rebuilds. Ad-hoc signing resets that grant each time.

## M0 results (2026-10-14) and plan changes

M0 passed on macOS 27.0.1 (26A434): 20/20 hide and restore cycles, kill -9 recovery in 552 ms. Details are in the spike scripts and `spike/results/` (not committed).
1. An app launched while hiding is on stays hidden, because it is not on the allow list. SMH reapplies the list on every app launch, turning on the new assertion before dropping the old one (two assertions combine, so nothing flashes).
2. With system items 0...255 allowed, clicks on the clock, Wi-Fi and Control Center still worked (user test). There is no click bridge and no `liftedForClock` state in version 1. M4 test 17 keeps checking it.
3. `invalidate` without quitting restores icons at once. No helper process.
4. Restarting `MenuBarAgent` does not drop the assertion.
5. End-to-end tests read a screenshot of the menu bar for a solid magenta fixture icon. MenuBarAgent's log count is not usable.
6. Any assertion hides the Focus icon. The README must say so.

## Not in this version

Per-icon hiding inside one app, reordering icons, a drop-down panel of hidden icons, a global hotkey, show on hover, profiles, spacing control, macOS 26 or earlier, the Mac App Store, the wide-divider backup method, separate rules per display.

## Milestones

Each one has a done-test and a time budget. When a milestone runs 50% over budget, I send a note and cut back to the done-test.

### M0. Prove the private API on this Mac (budget: 1 day). Go or no-go gate.
- Run `research-sources` (Reddit, X) and one Astra investigator on "macOS 27 MBAssessmentModeAssertion, 27.1 beta changes".
- Write a throwaway command-line spike that lists the classes' methods through the Objective-C runtime, then hides one test app's icon and releases it.
- Measure and write down: what happens on `kill -9` of the spike; whether Notification Center is blocked and whether allowing the clock's system item fixes it; the safe system-items range; what happens to icons from apps without a bundle ID or outside `/Applications`; what happens to an app that launches while the list is active; how `killall MenuBarAgent` affects the assertion; two displays.
- **Done-test:** a script hides and restores a fixture app's icon 20 times in a row, checked through the Accessibility tree of `MenuBarAgent`, and `kill -9` restores all icons within 2 s. If this fails, I stop and bring the user the wide-divider option instead.

### M1. Core logic and test fixtures (budget: 1 day)
- `SMHCore` package with the allowed-list math, the state machine and the stored settings.
- Fixture apps, built in the repo, used by all later tests:
  - `FixtureOne`: one status item.
  - `FixtureMany`: three status items.
  - `FixtureFlicker`: adds and removes its item every second.
  - `FixtureWide`: a very wide item.
  - `FixtureNoBundle`: a bare executable that makes a status item.
- **Done-test:** `swift test` passes, with tests for every state change and every allowed-list edge case (empty set, hide everything, hide SMH itself, duplicate IDs, unknown IDs).

### M2. Hiding engine and menu bar icon (budget: 1.5 days)
- `MenuBarShim`, the scanner, SMH's status item, click to reveal, re-hide timer (default 10 s, paused while a menu is open).
- Recompute and reapply the list when an app launches or quits, after wake, after a display change, and when `MenuBarAgent` restarts.
- Notification Center workaround: lift the list while the pointer is over the clock, reapply 0.5 s after it leaves (pending M0 results).
- A debug-only control channel (a distributed notification) so tests can say "hide X", "reveal", "collapse" and read back the state.
- **Done-test:** the E2E script hides `FixtureOne` and `FixtureMany`, reveals, waits for re-hide, and confirms each step through the Accessibility tree and a screenshot.

### M3. Settings window and first run (budget: 1 day)
- Three rendered mockups of the settings window first, critiqued by Astra and a fresh reviewer. The user picks one.
- First run: explain the Accessibility permission, open the right System Settings pane, and detect the grant without a restart.
- List of apps that have menu bar icons, each with its icon, name and a checkbox. Apps that are not running but are already hidden stay in the list.
- Launch at login toggle.
- **Done-test:** a UI test checks a box and the icon disappears; unchecks it and the icon returns; the choice survives a SMH restart.

### M4. Adversarial and end-to-end testing (budget: 1.5 days)
Every case below is a scripted test that runs headless from the shell, unless marked manual.

Crash and lifecycle:
1. `kill -9` SMH while collapsed: all icons back within 2 s.
2. Quit SMH normally while collapsed: all icons back.
3. `killall MenuBarAgent` and `killall ControlCenter` while collapsed: SMH reapplies the list within 3 s.
4. Sleep and wake, screen lock, fast user switching (manual): state is correct afterwards.
5. Launch at login: SMH starts before or after `MenuBarAgent` and still hides correctly (manual reboot, three times).

Apps coming and going:
6. A hidden app quits and relaunches while collapsed: it stays hidden.
7. A new, not-hidden app launches while collapsed: its icon shows. Measure the flicker time.
8. `FixtureFlicker` runs for 10 minutes: SMH's CPU stays under 1% and the list is not reapplied on every flicker.
9. `FixtureNoBundle` and an app run from `~/Downloads`: behavior matches what M0 found, and the settings window warns about them.

Bad input and bad state:
10. Hide every app: SMH's own icon, the clock and Control Center stay.
11. Corrupt or empty preferences file: SMH starts with nothing hidden and logs the problem.
12. Accessibility permission revoked while running: SMH stops hiding, restores icons and shows the warning.
13. Shim forced unavailable (test flag that renames the class lookup): no hiding, warning badge, no crash.
14. SMH launched from outside `/Applications`: it refuses to hide and says why.
15. Toggle reveal and collapse 500 times quickly: no stuck state, memory stays flat.

Other menu bar tools and system features:
16. Thaw or Bartender running at the same time: SMH detects it and warns. No fight over the list.
17. Clicking the clock while collapsed opens Notification Center. Control Center, Spotlight and Siri still open.
18. Full-screen app, menu bar auto-hide, two displays, a notched MacBook (manual where hardware is needed).

- **Done-test:** all scripted cases pass in one run with zero skips and zero retries. The manual cases are written up with results.
- Fresh independent review: Astra (high) through the runner plus a native Opus reviewer, 900 s deadline. Root checks each finding.
- Diagram of the hiding flow (sequence type) with the `diagram-design` skill, saved as `docs/hiding-flow.html` in the repo.

### M5. Public release (budget: 1 day). Needs the user's OK before the first publish.
- Sparkle 2 with an EdDSA key (stored in `~/keys`, name only in the repo), appcast on GitHub Releases.
- Build, sign with Developer ID, notarize, staple, DMG.
- Public GitHub repo, README that says plainly it uses a private Apple API and can break on any update, GPL or MIT license (choice to check).
- Homebrew cask in a personal tap (`yili/homebrew-tap`).
- Launch check: on launch, if the shim is unavailable, show a clear message that points to the GitHub issue page.
- **Done-test:** a clean user account installs through `brew install --cask`, gets the update prompt from a test 0.0.2 release, and hides `FixtureOne`.
- Asking first: creating the public repo, publishing the release and the cask are new public targets, so I ask before each.

## Verification summary

- `swift test` for `SMHCore` (unit).
- `agent-config/claude/bin/quiet-run -- ./scripts/e2e.sh` builds SMH and the fixtures, installs to `/Applications`, and runs the M2 to M4 scripted cases. The oracle is the Accessibility tree of `MenuBarAgent`; a `screencapture` of the menu bar is the second check, and I look at the screenshots myself.
- Manual checklist for reboot, sleep, displays and notch hardware, with results written into `docs/test-log.md`.
- After each macOS 27.x update: rerun the M0 spike script as a canary.

## Choices to check

- License (MIT or GPL).
- Default re-hide delay of 10 s.
- Homebrew tap name.
