#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-debug}"
case "$configuration" in
  debug) configuration=Debug ;;
  release) configuration=Release ;;
  *) echo 'usage: scripts/build-app.sh [debug|release]' >&2; exit 2 ;;
esac

for tool in xcodegen xcodebuild codesign; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
xcodegen generate
xcodebuild -project SimpleMenubarHider.xcodeproj -scheme SimpleMenubarHider \
  -configuration "$configuration" -derivedDataPath build/DerivedData build
app_path="$repo_root/build/DerivedData/Build/Products/$configuration/Simple Menubar Hider.app"
test -d "$app_path" || { echo "built app missing: $app_path" >&2; exit 1; }
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
[[ "$icon_name" == AppIcon && -f "$app_path/Contents/Resources/AppIcon.icns" && -f "$app_path/Contents/Resources/Assets.car" ]] || { echo "app icon missing from $app_path" >&2; exit 1; }
codesign --verify --deep --strict "$app_path"
echo "$app_path"
