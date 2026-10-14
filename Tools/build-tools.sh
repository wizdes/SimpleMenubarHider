#!/bin/bash
set -euo pipefail

# Build the SMH end-to-end test tools into Tools/build/.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/Tools/build"

for tool in xcrun clang swiftc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found in PATH" >&2
    exit 1
  fi
done

mkdir -p "$BUILD_DIR"

xcrun clang -fobjc-arc -Wall -Wextra -O2 \
  -framework AppKit -framework Foundation -framework ImageIO \
  "$ROOT/Tools/menubar-probe/main.m" -o "$BUILD_DIR/menubar-probe"
echo "Built $BUILD_DIR/menubar-probe"

xcrun swiftc -O "$ROOT/Tools/smhctl/main.swift" -o "$BUILD_DIR/smhctl"
echo "Built $BUILD_DIR/smhctl"
