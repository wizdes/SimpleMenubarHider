#!/bin/bash
set -euo pipefail

for tool in xcrun codesign mkdir cp security grep dirname pwd; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 1; }
done
here="$(cd "$(dirname "$0")" && pwd)"
xcrun --find clang >/dev/null

out="$here/build"
app="$out/FixtureOne.app"
mkdir -p "$app/Contents/MacOS"
xcrun clang -fobjc-arc -Wall -Wextra -framework Foundation -framework AppKit -framework ApplicationServices -framework ImageIO "$here/smh-spike.m" -o "$out/smh-spike"
xcrun clang -fobjc-arc -Wall -Wextra -framework AppKit "$here/FixtureOne/main.m" -o "$app/Contents/MacOS/FixtureOne"
cp "$here/FixtureOne/Info.plist" "$app/Contents/Info.plist"

identity='Developer ID Application: Yi Li (8Q5V8XK85Y)'
if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$identity"; then
    identity='-'
    echo 'WARNING: Developer ID Application: Yi Li (8Q5V8XK85Y) missing; using ad-hoc signing' >&2
fi
codesign --force --options runtime --sign "$identity" "$out/smh-spike"
codesign --force --options runtime --sign "$identity" "$app"
echo "built $out/smh-spike and $app"
