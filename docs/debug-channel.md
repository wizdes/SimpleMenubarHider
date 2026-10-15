# Debug control channel (Debug builds only)

End-to-end tests drive SMH through macOS distributed notifications. The channel exists only when SMH is built with the Debug configuration (`#if DEBUG`). Release builds never register it, because any local process can post a distributed notification.

## Command

- Name: `dev.yili.smh.debug.command`
- Object: `nil`
- userInfo (all values are strings):
  - `id`: a unique id chosen by the sender, echoed in the reply.
  - `cmd`: one of the commands below.
  - `arg`: the argument, when the command takes one.

| cmd | arg | What SMH does |
| --- | --- | --- |
| `setHidden` | comma-separated bundle ids, or empty | Replaces the hidden set, saves it, sends `hiddenSetChanged`. |
| `setRevealSeconds` | number of seconds | Sets the reveal delay (clamped to 3...120, the same as Settings). |
| `openPopover` / `closePopover` | none | Opens or closes the settings popover. |
| `toggleApp` | one bundle id | Uses the same toggle action as an app row, saves the hidden set, and sends `hiddenSetChanged`. |
| `scan` | none | Forces an Accessibility scan and replies when it finishes. If a newer scan starts first, the reply waits for the newest one, and only its result counts. |
| `reveal` | none | Same as clicking SMH's icon. |
| `pause` / `resume` | none | Sets the user's `paused` setting and sends `pauseToggled`. While a competing hider runs, SMH stays paused after `resume`. |
| `failNextApplies` | a whole number N (0 or more) | The next N applies fail with a normal error (`debug: injected apply failure`) before they reach the shim. Any apply counts, also one for an unchanged list and a retry. So `failNextApplies 1` then `setHidden` with the same set gives `state=unavailable:Hiding failed: debug: injected apply failure` and `applied=no`, and the 2 s retry hides again. `0` stops the failures. |
| `state` | none | Only replies. |
| `quit` | none | Releases hiding and quits. |

## Reply

- Name: `dev.yili.smh.debug.state`
- userInfo (strings): `id` (echo), `state` (`expanded`, `collapsed`, `revealing`, or `unavailable:<reason>`), `hidden` (comma-separated, sorted), `allowCount` (number of bundle ids in the active allow list, `0` when nothing is applied), `applied` (`yes` when an assertion is active), `applyCount` (successful assertion applies since launch; a skipped no-op does not count), `conflict` (comma-separated sorted bundle ids of running competing hiders, empty when none; while it is not empty, SMH pauses itself, so `state` is `expanded`, and it hides again when the competitor quits unless the user paused), `settingsNote` (the corrupt settings reason on a launch that found them unreadable, empty otherwise; the unreadable bytes are copied to `~/Library/Application Support/Simple Menubar Hider/settings-corrupt-<UTC>.json` first, then replaced with defaults; when that copy fails, the stored bytes are left as they are, SMH runs on defaults in memory, and it saves only after the user changes a setting), `popover` (`open` or `closed`), and `trusted` (`yes` or `no`). A `scan` reply also has `found`: comma-separated sorted bundle ids, empty when none were found, or `untrusted` when Accessibility access is unavailable.

The test fixture `dev.yili.smh.fixture.competitor` counts as a competing hider only in Debug builds.

In Debug builds, launch with `SMH_DEBUG_FORCE_SHIM_MISSING=1` to test the unavailable state without applying an assertion. For example: `open -g -n --env SMH_DEBUG_FORCE_SHIM_MISSING=1 -a "/Applications/Simple Menubar Hider.app"`. Release builds have no code or string for this flag.

SMH sends the reply after the command's actions have run, and after an apply has finished (its completion handler called), so a test may take a screenshot as soon as the reply arrives.

The popover closes with a short animation, so a `closePopover` reply can still say `popover=open`. A test that needs `closed` sends `state` again after a moment.

## smhctl

`Tools/smhctl` sends one command and prints the reply on one line. It prints every reply field except `id`, as `key=value`, sorted by key:

```
$ smhctl scan
allowCount=0 applied=no applyCount=0 conflict= found=com.example.app hidden= popover=closed settingsNote= state=expanded trusted=yes
```

`setHidden`, `setRevealSeconds` and `toggleApp` take an argument (`toggleApp` needs a bundle id). The other commands take none. Add `--timeout-ms N` to wait longer than 5000 ms; on timeout it prints `TIMEOUT` and exits 3.

`smhctl` does not send `failNextApplies` yet. `scripts/adversarial.sh` posts it with `osascript` (function `smh_post`) and then reads the state with `smhctl state`.
