# Simple Menubar Hider

Simple Menubar Hider (SMH) lets you pick apps in a small popover and hides their menu bar icons. Left-click SMH's eye icon to show them for a few seconds. macOS 27 broke the method Bartender, Ice and Hidden Bar used to hide icons. Thaw works on macOS 27 but has many features; SMH does one thing.

## Requirements

macOS 27 or later. SMH is built and tested on Apple silicon.

## Install

1. Download the zip from [GitHub Releases](https://github.com/wizdes/SimpleMenubarHider/releases) and unzip it.
2. Move `Simple Menubar Hider.app` to `/Applications`. SMH will not hide icons when run from elsewhere.
3. Open the app. Right-click its eye icon in the menu bar.
4. Grant Accessibility access when asked. SMH needs it to list apps with menu bar icons. Hiding itself does not use Accessibility.

## Use

Right-click the eye icon to open the popover. Tick the apps to hide. The popover also has Hide Again After, Launch at Login, Pause Hiding and Quit Simple Menubar Hider. Left-click the eye icon to show hidden icons until the chosen delay ends.

## Known limits

- Hiding is per app. If an app has two menu bar icons, both hide or both stay.
- Hiding has been tested on macOS 27 only. Later macOS releases may change the private API.
- The Focus icon (the moon) hides while hiding is on. macOS does not let SMH keep it.
- Icons from programs without a bundle id also hide while hiding is on.
- Icons from apps run outside `/Applications` also hide while hiding is on.
- SMH pauses hiding while Thaw, Ice, Bartender or Hidden Bar runs.
- SMH uses a private Apple API. A macOS update can break it. If that happens, SMH hides nothing and shows a warning.

## How it works

macOS 27 draws the menu bar in one window owned by MenuBarAgent. SMH uses the private `MenuBarClientCore` assessment-mode allow list to show all running apps except the ones you chose to hide. If SMH quits or crashes, macOS shows every icon again. Apple can change this private API. See the [hiding flow](docs/hiding-flow.html).

## Build from source

Install Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), then run:

```sh
brew install xcodegen
scripts/build-app.sh release
scripts/install-app.sh release
```

Run unit tests with `scripts/unit-tests.sh`. The live suites are `scripts/e2e.sh` and `scripts/adversarial.sh`. They need a Debug build in `/Applications` (`scripts/build-app.sh debug`, then `scripts/install-app.sh debug`) and the fixture apps (`scripts/build-fixtures.sh`, then `scripts/install-fixtures.sh`). They drive the real menu bar, and they save and restore your settings.

## Credits

[stash](https://github.com/brentc22/stash) and [MenuBarHider](https://github.com/happy666End/MenuBarHider), both MIT, showed the allow-list approach. [Ice pull request 995](https://github.com/jordanbaird/Ice/pull/995) and [Thaw](https://github.com/thaw-app/Thaw) helped with macOS 27 research.

## License

MIT. See [LICENSE](LICENSE).
