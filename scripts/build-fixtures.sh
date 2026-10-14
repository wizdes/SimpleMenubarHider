#!/bin/bash
set -euo pipefail

# Build the SMH menu-bar fixture apps and the bundle-less executable.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$ROOT/Fixtures"
BUILD_DIR="$FIXTURES_DIR/build"
SIGN_IDENTITY="Developer ID Application: Yi Li (8Q5V8XK85Y)"

for tool in xcrun codesign security plutil; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found in PATH" >&2
    exit 1
  fi
done

mkdir -p "$BUILD_DIR"

USE_ADHOC=0
if security find-identity -v -p codesigning | grep -q "8Q5V8XK85Y"; then
  USE_ADHOC=0
else
  echo "WARNING: signing identity \"$SIGN_IDENTITY\" not found; falling back to ad-hoc signing"
  USE_ADHOC=1
fi

sign_artifact() {
  local target="$1"
  if [ "$USE_ADHOC" -eq 0 ]; then
    codesign --force --options runtime --sign "Developer ID Application: Yi Li (8Q5V8XK85Y)" "$target"
  else
    codesign --force --options runtime --sign "-" "$target"
  fi
}

build_app() {
  local name="$1"
  local bundle_id="$2"
  local src="$FIXTURES_DIR/$name/main.m"
  local plist="$FIXTURES_DIR/$name/Info.plist"
  local app="$BUILD_DIR/$name.app"
  local contents="$app/Contents"
  local macos="$contents/MacOS"

  plutil -lint "$plist" >/dev/null
  rm -rf "$app"
  mkdir -p "$macos"
  xcrun clang -fobjc-arc -Wall -Wextra -framework AppKit "$src" -o "$macos/$name"
  cp "$plist" "$contents/Info.plist"
  sign_artifact "$app"
  echo "Built $app (id $bundle_id)"
}

build_app "FixtureOne" "dev.yili.smh.fixture.one"
build_app "FixtureMany" "dev.yili.smh.fixture.many"
build_app "FixtureFlicker" "dev.yili.smh.fixture.flicker"
build_app "FixtureWide" "dev.yili.smh.fixture.wide"

# Bundle-less fixture: plain command-line executable, no .app wrapper.
xcrun clang -fobjc-arc -Wall -Wextra -framework AppKit "$FIXTURES_DIR/FixtureNoBundle/main.m" -o "$BUILD_DIR/fixture-nobundle"
sign_artifact "$BUILD_DIR/fixture-nobundle"
echo "Built $BUILD_DIR/fixture-nobundle (no bundle)"
