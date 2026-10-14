#!/bin/bash
set -euo pipefail

# Copy built fixture apps to /Applications.
# Quits any running copy first: copying over a running signed app makes
# macOS kill it mid-test. Never launches anything.

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/Fixtures/build"

run_or_echo() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

quit_running_copy() {
  local name="$1"
  local bundle_id="$2"
  local pid=""

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] osascript -e 'tell application id \"$bundle_id\" to quit' (then wait up to 5s, kill -TERM, kill -KILL \"$name\" if still running)"
    return 0
  fi

  if pgrep -x "$name" >/dev/null 2>&1; then
    pid="$(pgrep -x "$name" | head -n 1)"
  else
    return 0
  fi

  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true

  # Wait up to 5 s for the process to exit on its own.
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

install_app() {
  local name="$1"
  local bundle_id="$2"
  local src="$BUILD_DIR/$name.app"
  local dest="/Applications/$name.app"

  # Safety gate: only ever delete one of the known fixture app names.
  case "$name" in
    FixtureOne|FixtureMany|FixtureFlicker|FixtureWide|FixtureNoBundle)
      ;;
    *)
      echo "ERROR: refusing to delete unexpected app name: $name" >&2
      exit 1
      ;;
  esac

  quit_running_copy "$name" "$bundle_id"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] rm -rf $dest"
    echo "[dry-run] cp -R $src $dest"
  else
    rm -rf "$dest"
    cp -R "$src" "$dest"
    echo "Installed $dest (id $bundle_id)"
  fi
}

install_app "FixtureOne" "dev.yili.smh.fixture.one"
install_app "FixtureMany" "dev.yili.smh.fixture.many"
install_app "FixtureFlicker" "dev.yili.smh.fixture.flicker"
install_app "FixtureWide" "dev.yili.smh.fixture.wide"
