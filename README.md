# Simple Menubar Hider (SMH)

A small macOS 27 menu bar app. You pick apps in a list, and SMH hides their menu bar icons. One click on SMH's icon shows them again for a few seconds.

SMH uses a private Apple framework (`MenuBarClientCore`), so any macOS update can break it. When that happens, SMH hides nothing and says so.

Status: in development. See `docs/plan.md`.

## Known limits

- SMH hides icons per app. If an app has two icons, both hide or both stay.
- The Focus icon (the moon) hides while hiding is on. macOS does not let SMH keep it.
- Icons from programs without a bundle id also hide while hiding is on.
- Icons from apps run from outside /Applications also hide while hiding is on.
- SMH pauses itself while Thaw, Ice, Bartender or Hidden Bar runs.
- SMH uses a private Apple framework. A macOS update can break it. When that happens, SMH hides nothing.
