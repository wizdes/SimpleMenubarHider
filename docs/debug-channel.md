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
| `scan` | none | Forces an Accessibility scan and replies when it finishes. |
| `reveal` | none | Same as clicking SMH's icon. |
| `pause` / `resume` | none | Sets `paused` and sends `pauseToggled`. |
| `state` | none | Only replies. |
| `quit` | none | Releases hiding and quits. |

## Reply

- Name: `dev.yili.smh.debug.state`
- userInfo (strings): `id` (echo), `state` (`expanded`, `collapsed`, `revealing`, or `unavailable:<reason>`), `hidden` (comma-separated, sorted), `allowCount` (number of bundle ids in the active allow list, `0` when nothing is applied), `applied` (`yes` when an assertion is active), `popover` (`open` or `closed`), and `trusted` (`yes` or `no`). A `scan` reply also has `found`: comma-separated sorted bundle ids, empty when none were found, or `untrusted` when Accessibility access is unavailable.

SMH sends the reply after the command's actions have run, and after an apply has finished (its completion handler called), so a test may take a screenshot as soon as the reply arrives.

The popover closes with a short animation, so a `closePopover` reply can still say `popover=open`. A test that needs `closed` sends `state` again after a moment.

## smhctl

`Tools/smhctl` sends one command and prints the reply on one line. It prints every reply field except `id`, as `key=value`, sorted by key:

```
$ smhctl scan
allowCount=0 applied=no found=com.example.app hidden= popover=closed state=expanded trusted=yes
```

`setHidden`, `setRevealSeconds` and `toggleApp` take an argument (`toggleApp` needs a bundle id). The other commands take none. Add `--timeout-ms N` to wait longer than 5000 ms; on timeout it prints `TIMEOUT` and exits 3.
