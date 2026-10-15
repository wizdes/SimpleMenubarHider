# Test log

Results for Simple Menubar Hider on macOS 27.0.1 (build 26A434), one Dell U2414H display at 1920 x 1080, Apple silicon. Times are measured by `Tools/menubar-probe` screenshots, which add about 190 ms each.

## Automated runs at commit 31ec3e2 (2026-10-14)

| Suite | Result |
| --- | --- |
| `scripts/unit-tests.sh` | 7 suite runs pass: SMHCore 42 tests; AdversarialRulesTests 27/27 (Release) and 27/27 (Debug); HidingEngineTests 15/15 (Release) and 20/20 (Debug); SMHMenuBarShimTests 23/23; PopoverRulesTests 85/85 |
| `scripts/e2e.sh` | 12/12 |
| `scripts/adversarial.sh` (full) | 18/18 |

Selected numbers from the full adversarial run:

- Case 8, flicker soak: FixtureFlicker ran 600 s while SMH hid FixtureOne. Mean SMH CPU 0.00% over 115 samples, 3 applies, FixtureOne hidden in every check.
- Case 15: 500 rapid reveals and 20 concurrent `setHidden` calls. SMH answered in 91 ms afterwards; memory 50592 KB before, 47952 KB after; the last requested list won.
- Case 16: a competing hider was seen in 430 ms; SMH paused and showed every icon; it resumed 86 ms after the competitor quit; a user pause held through it.
- Case 19: one injected apply failure re-hid after 2333 ms; three failures kept icons visible in all 28 checks and re-hid at 22374 ms (the 2 s, 5 s, 15 s backoff).
- Earlier runs: kill -9 restores icons in about 500 ms; a normal quit in about 540 ms; a newly launched menu bar app shows in about 800 ms while hiding is on.

## Manual checks

| Plan case | What | Result |
| --- | --- | --- |
| 17 | Click Wi-Fi and Control Center while hiding is on | Pass (user, 2026-10-14) |
| 17 | Click the clock, or press Fn+N, to open Notification Center while hiding is on | Not checked: the user said it does not matter to them. An M0 hand test passed for the clock click. |
| M3 | Left-click reveals hidden icons, which hide again after about 10 s | Pass (user, 2026-10-14) |
| 4 | Sleep and wake, screen lock, fast user switching | Not run yet; the user chose to do it later |
| 5 | Launch at Login, then restart the Mac three times | Not run yet; the user chose to do it later |
| 12 | Accessibility removed while running | Not run. By design SMH keeps hiding saved apps, because hiding does not use Accessibility; only the app list in the popover needs it. |
| 18 | Full-screen app, menu bar auto-hide, two displays, a notched MacBook | Not run: this Mac has one external display and no notch |

## Known limits found by testing

- Items from programs without a bundle id, and from apps run outside /Applications, also hide while hiding is on (cases 9a and 9b). This is how macOS treats the allow list. The README says so.
- Any hiding also hides the Focus icon.
