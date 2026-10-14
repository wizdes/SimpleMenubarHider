#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-debug}"
case "$configuration" in
  debug) configuration=Debug ;;
  release) configuration=Release ;;
  *) echo 'usage: scripts/install-app.sh [debug|release]' >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_app="$repo_root/build/DerivedData/Build/Products/$configuration/Simple Menubar Hider.app"
destination='/Applications/Simple Menubar Hider.app'
test -d "$source_app" || { echo "built app missing: $source_app" >&2; exit 1; }
test "$destination" = '/Applications/Simple Menubar Hider.app' || exit 1

running_pids() { pgrep -f '/Applications/Simple Menubar Hider.app/Contents/MacOS/Simple Menubar Hider' || true; }
osascript -e 'tell application id "dev.yili.smh" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  test -z "$(running_pids)" && break
  sleep 1
done
if test -n "$(running_pids)"; then
  running_pids | while read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
fi
if test -n "$(running_pids)"; then
  running_pids | while read -r pid; do kill -KILL "$pid" 2>/dev/null || true; done
fi
test -z "$(running_pids)" || { echo 'app did not quit' >&2; exit 1; }
if test -e "$destination"; then
  test -d "$destination" && test ! -L "$destination" || { echo 'refusing to replace non-app or symlink' >&2; exit 1; }
  rm -rf -- "$destination"
fi
cp -R "$source_app" "$destination"
echo "$destination"
