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
| `reveal` | none | Same as clicking SMH's icon. |
| `pause` / `resume` | none | Sets `paused` and sends `pauseToggled`. |
| `state` | none | Only replies. |
| `quit` | none | Releases hiding and quits. |

## Reply

- Name: `dev.yili.smh.debug.state`
- userInfo (strings): `id` (echo), `state` (`expanded`, `collapsed`, `revealing`, or `unavailable:<reason>`), `hidden` (comma-separated, sorted), `allowCount` (number of bundle ids in the active allow list, `0` when nothing is applied), `applied` (`yes` when an assertion is active).

SMH sends the reply after the command's actions have run, and after an apply has finished (its completion handler called), so a test may take a screenshot as soon as the reply arrives.
