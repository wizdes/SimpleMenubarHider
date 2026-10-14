#!/bin/bash
set -euo pipefail

# Unit tests for Simple Menubar Hider (SMH). No app, no menu bar.
#
# What it does, in order:
#   1. Checks the tools and the package before it builds anything.
#   2. Runs `swift test` for Packages/SMHCore. That is one suite.
#   3. Finds every guarded test file under App/ and runs it. That is one
#      suite per file.
#   4. Prints "UNIT PASS n suites", or prints each failure and exits 1.
#
# A guarded test file is a Swift file whose first lines hold
# `#if SMH_<NAME>_TESTS`. The app build never sets that flag, so the app
# never sees the test code. The file's header comment holds the commands
# that build and run it, as lines that start with "//" and 3 or more
# spaces. A line that ends in "\" goes on into the next line. The commands
# use $DIR as their build folder and run from the repo root. This script
# runs those commands, so a new guarded file needs no change here.
#
# A guarded file fails loudly when its header has no commands, when no
# command passes its -D flag, when no command names the file, or when the
# last command does not run something from $DIR.
#
# Build output goes under build/unit-tests/ (build/ is git-ignored).
# SMHCore builds in build/unit-tests/smhcore-build, which stays so the next
# run is faster. Logs and the guarded files' builds go to
# build/unit-tests/run-<time>-<pid>/. That folder is deleted when every
# suite passes and kept when one fails, so the logs can be read.

usage() {
  echo "usage: scripts/unit-tests.sh" >&2
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/SMHCore"
UNIT_ROOT="$ROOT/build/unit-tests"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$UNIT_ROOT/run-$STAMP-$$"
RUN_DIR_MADE=0
ALL_PASSED=0

cleanup() {
  set +e
  # Delete only the exact run folder this script made, and only after a
  # full pass. On a failure the logs stay for reading.
  if [ "$RUN_DIR_MADE" -eq 1 ] && [ "$ALL_PASSED" -eq 1 ]; then
    case "$RUN_DIR" in
      "$UNIT_ROOT"/run-*) rm -rf "$RUN_DIR" ;;
      *) echo "REFUSING to delete unexpected path: $RUN_DIR" >&2 ;;
    esac
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------ prerequisites ---
problems=0
for tool in swift xcrun find sed grep head sort date; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "MISSING tool: $tool" >&2
    problems=$((problems + 1))
  fi
done
if command -v xcrun >/dev/null 2>&1; then
  rc=0
  xcrun --find swiftc >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "MISSING tool: swiftc (xcrun --find swiftc exit $rc)" >&2
    problems=$((problems + 1))
  fi
fi
if [ ! -f "$PACKAGE/Package.swift" ]; then
  echo "MISSING $PACKAGE/Package.swift" >&2
  problems=$((problems + 1))
fi
if [ ! -d "$ROOT/App" ]; then
  echo "MISSING folder $ROOT/App" >&2
  problems=$((problems + 1))
fi
# The header commands use $DIR without quotes, so a space in it would split.
case "$RUN_DIR" in
  *[[:space:]]*)
    echo "UNSUPPORTED: the build folder path has a space: $RUN_DIR" >&2
    problems=$((problems + 1))
    ;;
esac
if [ -e "$RUN_DIR" ]; then
  echo "IN THE WAY: $RUN_DIR already exists" >&2
  problems=$((problems + 1))
fi
if [ "$problems" -ne 0 ]; then
  echo "UNIT FAIL: $problems problem(s) before any test ran" >&2
  exit 2
fi

mkdir -p "$RUN_DIR"
RUN_DIR_MADE=1

SUITES=0
FAILED=0
FAIL_NAMES=""

suite_pass() { # name detail
  SUITES=$((SUITES + 1))
  echo "PASS $1 :: $2"
}

suite_fail() { # name detail
  SUITES=$((SUITES + 1))
  FAILED=$((FAILED + 1))
  FAIL_NAMES="$FAIL_NAMES $1"
  echo "FAIL $1 :: $2"
}

# tail_of <log>: the last lines of a log, indented, for a failure report.
tail_of() {
  tail -n 20 "$1" 2>/dev/null | sed 's/^/    /' || true
}

# ------------------------------------------------------------- SMHCore suite ---
CORE_LOG="$RUN_DIR/smhcore-swift-test.log"
rc=0
swift test --package-path "$PACKAGE" --scratch-path "$UNIT_ROOT/smhcore-build" >"$CORE_LOG" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  suite_pass "SMHCore swift test" "$(grep -E 'Executed|passed after|Test run with' "$CORE_LOG" | tail -n 1 || true)"
else
  suite_fail "SMHCore swift test" "exit $rc, log $CORE_LOG"
  tail_of "$CORE_LOG"
fi

# -------------------------------------------------------- guarded test files ---
# guard_flag <file>: prints SMH_<NAME>_TESTS when one of the first 5 lines
# is `#if SMH_<NAME>_TESTS`. Returns 1 when the file is not guarded.
guard_flag() {
  local line
  line="$(head -n 5 "$1" | grep -E '^#if[[:space:]]+SMH_[A-Z0-9_]+_TESTS[[:space:]]*$' | head -n 1 || true)"
  [ -n "$line" ] || return 1
  printf '%s' "$line" | sed -E 's/^#if[[:space:]]+//; s/[[:space:]]*$//'
}

# header_commands <file>: prints one full command per line, taken from the
# first block of "//" lines after the #if line. Only lines with 3 or more
# spaces after "//" count. A line that ends in "\" joins the next line.
header_commands() {
  local file="$1" line started=0 body pending=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$started" -eq 0 ]; then
      case "$line" in
        "#if "*) started=1 ;;
      esac
      continue
    fi
    case "$line" in
      "//"*) ;;
      *) break ;;
    esac
    case "$line" in
      "//   "*) ;;
      *)
        # A plain comment line ends any open command.
        if [ -n "$pending" ]; then printf '%s\n' "$pending"; pending=""; fi
        continue
        ;;
    esac
    body="${line#//}"
    body="$(printf '%s' "$body" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$body" in
      *"\\")
        pending="${pending:+$pending }${body%\\}"
        pending="$(printf '%s' "$pending" | sed -E 's/[[:space:]]+$//')"
        ;;
      *)
        printf '%s\n' "${pending:+$pending }$body"
        pending=""
        ;;
    esac
  done < "$file"
  if [ -n "$pending" ]; then printf '%s\n' "$pending"; fi
}

GUARDED=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if guard_flag "$f" >/dev/null; then GUARDED+=("$f"); fi
done < <(cd "$ROOT" && find App -type f -name '*.swift' | sort)

if [ "${#GUARDED[@]}" -eq 0 ]; then
  suite_fail "guarded test files" "no file under App/ starts with #if SMH_*_TESTS"
fi

for rel in ${GUARDED[@]+"${GUARDED[@]}"}; do
  flag="$(guard_flag "$ROOT/$rel")"
  name="$(basename "$rel" .swift)"
  dir="$RUN_DIR/$name"
  log_file="$RUN_DIR/$name.log"
  cmds=()
  while IFS= read -r c; do
    [ -n "$c" ] && cmds+=("$c")
  done < <(header_commands "$ROOT/$rel")

  # Check the header before running anything from it.
  problem=""
  if [ "${#cmds[@]}" -eq 0 ]; then
    problem="no runnable command in its header (want lines that start with '//   ')"
  else
    joined="$(printf '%s\n' "${cmds[@]}")"
    last="${cmds[${#cmds[@]}-1]}"
    if ! printf '%s' "$joined" | grep -qE -- "-D[[:space:]]*$flag([[:space:]]|$)"; then
      problem="no header command passes -D $flag"
    elif ! printf '%s' "$joined" | grep -qF -- "$rel"; then
      problem="no header command names $rel"
    else
      case "$last" in
        *'$DIR/'*|*'${DIR}/'*) ;;
        *) problem="the last header command does not run anything from \$DIR: $last" ;;
      esac
    fi
  fi
  if [ -n "$problem" ]; then
    suite_fail "$rel" "$problem"
    continue
  fi

  mkdir -p "$dir"
  : > "$log_file"
  ok=1
  out=""
  for c in "${cmds[@]}"; do
    printf '$ %s\n' "$c" >> "$log_file"
    rc=0
    (cd "$ROOT" && DIR="$dir" bash -c "set -euo pipefail; $c") >>"$log_file" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      ok=0
      out="exit $rc from: $c"
      break
    fi
  done
  if [ "$ok" -eq 1 ]; then
    suite_pass "$rel" "$(tail -n 1 "$log_file" || true)"
  else
    suite_fail "$rel" "$out (log $log_file)"
    tail_of "$log_file"
  fi
done

# ------------------------------------------------------------------- result ---
if [ "$FAILED" -eq 0 ] && [ "$SUITES" -gt 0 ]; then
  ALL_PASSED=1
  echo "UNIT PASS $SUITES suites"
  exit 0
fi
echo "UNIT FAIL $FAILED/$SUITES suites:$FAIL_NAMES (logs in $RUN_DIR)"
exit 1
