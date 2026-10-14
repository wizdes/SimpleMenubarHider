#!/bin/bash
set -euo pipefail

# M2 done-test for Simple Menubar Hider: drives a Debug SMH build and the
# fixture apps through the debug channel (docs/debug-channel.md) and checks
# each step with the menubar-probe screenshot oracle.
#
# This script does not build or install SMH or the fixtures; they must
# already be in /Applications. It builds Tools/ if needed.
# It never leaves SMH holding an assertion: trap EXIT quits SMH (release
# first via `smhctl quit`, then TERM, then KILL) and quits the fixtures.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_BUILD="$ROOT/Tools/build"
PROBE="$TOOLS_BUILD/menubar-probe"
SMHCTL="$TOOLS_BUILD/smhctl"

RESULTS_DIR="$ROOT/build/e2e-results"
mkdir -p "$RESULTS_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_FILE="$RESULTS_DIR/e2e-$STAMP.txt"
: > "$RESULTS_FILE"

SMH_APP="/Applications/Simple Menubar Hider.app"
SMH_BID="dev.yili.smh"
SMH_PROC_PATTERN="Simple Menubar Hider.app/Contents/MacOS/"
ONE_BID="dev.yili.smh.fixture.one"
MANY_BID="dev.yili.smh.fixture.many"
WIDE_BID="dev.yili.smh.fixture.wide"
ONE_APP="/Applications/FixtureOne.app"
MANY_APP="/Applications/FixtureMany.app"
WIDE_APP="/Applications/FixtureWide.app"

# Fixture icon colors (see Fixtures/*/main.m).
MAGENTA="FF00FF" # FixtureOne: 1,0,1
CYAN="00FFFF"    # FixtureMany item 1: 0,1,1
YELLOW="FFFF00"  # FixtureMany item 2: 1,1,0
ORANGE="FF8000"  # FixtureMany item 3: 255,128,0
BLUE="0000FF"    # FixtureWide: 0,0,1

HIDE_ONE_MANY="$ONE_BID,$MANY_BID"

TOTAL=0
FAILED=0

log() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >> "$RESULTS_FILE"
}

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

check_pass() { # name ms
  TOTAL=$((TOTAL + 1))
  log "PASS $1 ($2 ms)"
}

check_fail() { # name ms detail
  TOTAL=$((TOTAL + 1))
  FAILED=$((FAILED + 1))
  log "FAIL $1 ($2 ms) :: $3"
}

# smh_field <reply-line> <key>: prints the value (may be empty).
smh_field() {
  local line="$1" key="$2" f
  for f in $line; do
    case "$f" in
      "$key="*) printf '%s' "${f#"$key="}"; return 0 ;;
    esac
  done
  return 1
}

smh_pids() {
  pgrep -f "$SMH_PROC_PATTERN" 2>/dev/null || true
}

quit_bid() { # bundle-id: polite quit, never fails
  osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 || true
}

# wait_gone <kind> <match> <timeout-s>: 0 when no process matches anymore.
wait_gone() {
  local kind="$1" match="$2" timeout_s="$3" i
  for i in $(seq 1 "$timeout_s"); do
    if [ "$kind" = "exact" ]; then
      pgrep -x "$match" >/dev/null 2>&1 || return 0
    else
      pgrep -f "$match" >/dev/null 2>&1 || return 0
    fi
    sleep 1 || true
  done
  if [ "$kind" = "exact" ]; then
    pgrep -x "$match" >/dev/null 2>&1 || return 0
  else
    pgrep -f "$match" >/dev/null 2>&1 || return 0
  fi
  return 1
}

# wait_smh_answers <timeout-s>: 0 once `smhctl state` gets a reply.
wait_smh_answers() {
  local timeout_s="$1" i reply
  for i in $(seq 1 "$timeout_s"); do
    if reply="$("$SMHCTL" state --timeout-ms 1000 2>/dev/null)"; then
      printf '%s' "$reply"
      return 0
    fi
    sleep 1 || true
  done
  return 1
}

cleanup() {
  # Release hiding first, then escalate: quit, TERM, KILL.
  if [ -x "$SMHCTL" ]; then
    "$SMHCTL" quit --timeout-ms 2000 >/dev/null 2>&1 || true
    sleep 1 || true
  fi
  local pids
  pids="$(smh_pids)"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    sleep 1 || true
  fi
  pids="$(smh_pids)"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
  fi
  quit_bid "$ONE_BID"
  quit_bid "$MANY_BID"
  quit_bid "$WIDE_BID"
  sleep 1 || true
  local name
  for name in FixtureOne FixtureMany FixtureWide; do
    if pgrep -x "$name" >/dev/null 2>&1; then
      kill -TERM "$(pgrep -x "$name" 2>/dev/null || true)" 2>/dev/null || true
    fi
  done
  sleep 1 || true
  for name in FixtureOne FixtureMany FixtureWide; do
    if pgrep -x "$name" >/dev/null 2>&1; then
      kill -KILL "$(pgrep -x "$name" 2>/dev/null || true)" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------- step a ---
# Check every input before any side effect (except building Tools/).
step_a() {
  local t0 dt problems=0
  t0=$(now_ms)

  for tool in open osascript pgrep python3 PlistBuddy dirname date; do
    if ! command -v "$tool" >/dev/null 2>&1 && [ ! -x "/usr/libexec/$tool" ]; then
      log "MISSING tool: $tool"
      problems=$((problems + 1))
    fi
  done

  if [ ! -d "$SMH_APP" ]; then
    log "MISSING $SMH_APP (need a Debug build installed)"
    problems=$((problems + 1))
  else
    local plist="$SMH_APP/Contents/Info.plist" bid=""
    if [ -f "$plist" ]; then
      bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    fi
    if [ "$bid" != "$SMH_BID" ]; then
      log "WRONG bundle id in $SMH_APP: '$bid' (want $SMH_BID)"
      problems=$((problems + 1))
    fi
    if [ -z "$(find "$SMH_APP/Contents/MacOS/" -type f -exec grep -q "dev.yili.smh.debug.command" {} \; -print -quit 2>/dev/null)" ]; then
      log "NOT-A-DEBUG-BUILD: $SMH_APP has no debug channel (want a Debug build)"
      problems=$((problems + 1))
    fi
  fi
  if [ ! -d "$ONE_APP" ]; then log "MISSING $ONE_APP"; problems=$((problems + 1)); fi
  if [ ! -d "$MANY_APP" ]; then log "MISSING $MANY_APP"; problems=$((problems + 1)); fi
  if [ ! -d "$WIDE_APP" ]; then log "MISSING $WIDE_APP"; problems=$((problems + 1)); fi

  if [ ! -x "$PROBE" ] || [ ! -x "$SMHCTL" ]; then
    log "building Tools/..."
    if ! bash "$ROOT/Tools/build-tools.sh" >>"$RESULTS_FILE" 2>&1; then
      log "TOOLS BUILD FAILED (see $RESULTS_FILE)"
      problems=$((problems + 1))
    fi
  fi
  if [ ! -x "$PROBE" ]; then log "MISSING $PROBE"; problems=$((problems + 1)); fi
  if [ ! -x "$SMHCTL" ]; then log "MISSING $SMHCTL"; problems=$((problems + 1)); fi

  dt=$(( $(now_ms) - t0 ))
  if [ "$problems" -eq 0 ]; then
    check_pass "a prerequisites" "$dt"
    return 0
  fi
  check_fail "a prerequisites" "$dt" "$problems problem(s)"
  log "This script does not build or install SMH or the fixtures. To fix:"
  log "  1. Build the Debug SMH app and install it at: $SMH_APP"
  log "  2. bash scripts/build-fixtures.sh && bash scripts/install-fixtures.sh"
  log "  3. bash Tools/build-tools.sh"
  return 2
}

# --------------------------------------------------------------- step a2 ---
step_a2() {
  local t0 dt ok=1 pids="" reply="" rc=0
  t0=$(now_ms)
  pids="$(smh_pids)"
  if [ -n "$pids" ]; then
    reply="$("$SMHCTL" setHidden "" --timeout-ms 2000 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ] && { [ "$rc" -ne 3 ] || [ "$reply" != "TIMEOUT" ]; }; then
      ok=0
      log "  setHidden failed: $reply"
    fi
    "$SMHCTL" quit --timeout-ms 2000 >>"$RESULTS_FILE" 2>&1 || true
    if ! wait_gone pattern "$SMH_PROC_PATTERN" 5; then
      pids="$(smh_pids)"
      if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null || true
      fi
      if ! wait_gone pattern "$SMH_PROC_PATTERN" 5; then
        pids="$(smh_pids)"
        if [ -n "$pids" ]; then
          # shellcheck disable=SC2086
          kill -KILL $pids 2>/dev/null || true
        fi
        if ! wait_gone pattern "$SMH_PROC_PATTERN" 5; then ok=0; fi
      fi
    fi
  fi
  quit_bid "$ONE_BID"
  quit_bid "$MANY_BID"
  quit_bid "$WIDE_BID"
  if ! wait_gone exact FixtureOne 5; then ok=0; fi
  if ! wait_gone exact FixtureMany 5; then ok=0; fi
  if ! wait_gone exact FixtureWide 5; then ok=0; fi
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "a2 clean start" "$dt";
  else check_fail "a2 clean start" "$dt" "SMH or fixtures did not cleanly stop"; fi
}

# ---------------------------------------------------------------- step b ---
step_b() {
  local t0 dt ok=1
  t0=$(now_ms)
  if ! open -g -b "$ONE_BID" 2>>"$RESULTS_FILE"; then ok=0; fi
  if ! open -g -b "$MANY_BID" 2>>"$RESULTS_FILE"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    if ! "$PROBE" wait --color "$MAGENTA" --want visible --timeout-ms 15000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! "$PROBE" wait --color "$CYAN" --want visible --timeout-ms 15000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  fi
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "b fixtures launch visible" "$dt";
  else check_fail "b fixtures launch visible" "$dt" "magenta/cyan not VISIBLE"; fi
}

# ---------------------------------------------------------------- step c ---
step_c() {
  local t0 dt ok=1 reply=""
  t0=$(now_ms)
  if ! open -g -b "$SMH_BID" 2>>"$RESULTS_FILE"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    if reply="$(wait_smh_answers 10 2>>"$RESULTS_FILE")"; then
      log "  smh: $reply" >>"$RESULTS_FILE"
    else
      ok=0
    fi
  fi
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "c SMH answers" "$dt";
  else check_fail "c SMH answers" "$dt" "smhctl state got no reply within 10 s"; fi
}

# ---------------------------------------------------------------- step d ---
step_d() {
  local t0 dt ok=1 reply="" state=""
  t0=$(now_ms)
  if reply="$("$SMHCTL" setHidden "" --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
    state="$(smh_field "$reply" state || true)"
    if [ "$state" != "expanded" ]; then ok=0; fi
  else
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    if ! "$PROBE" wait --color "$MAGENTA" --want visible --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! "$PROBE" wait --color "$CYAN" --want visible --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  fi
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "d empty hidden set expands" "$dt";
  else check_fail "d empty hidden set expands" "$dt" "reply=[$reply]"; fi
}

# ---------------------------------------------------------------- step e ---
step_e() {
  local t0 dt ok=1 reply="" state="" applied=""
  t0=$(now_ms)
  if ! "$SMHCTL" setRevealSeconds 3 --timeout-ms 5000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    if reply="$("$SMHCTL" setHidden "$HIDE_ONE_MANY" --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
      state="$(smh_field "$reply" state || true)"
      applied="$(smh_field "$reply" applied || true)"
      if [ "$state" != "collapsed" ] || [ "$applied" != "yes" ]; then ok=0; fi
    else
      ok=0
    fi
  fi
  for color in "$MAGENTA" "$CYAN" "$YELLOW" "$ORANGE"; do
    if [ "$ok" -eq 1 ]; then
      if ! "$PROBE" wait --color "$color" --want hidden --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
    fi
  done
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "e hide one+many collapses" "$dt";
  else check_fail "e hide one+many collapses" "$dt" "reply=[$reply]"; fi
}

# ---------------------------------------------------------------- step f ---
step_f() {
  local t0 dt ok=1 reply="" state=""
  t0=$(now_ms)
  if reply="$("$SMHCTL" reveal --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
    state="$(smh_field "$reply" state || true)"
    if [ "$state" != "revealing" ]; then ok=0; fi
  else
    ok=0
  fi
  for color in "$MAGENTA" "$CYAN" "$YELLOW" "$ORANGE"; do
    if [ "$ok" -eq 1 ]; then
      if ! "$PROBE" wait --color "$color" --want visible --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
    fi
  done
  for color in "$MAGENTA" "$CYAN" "$YELLOW" "$ORANGE"; do
    if [ "$ok" -eq 1 ]; then
      if ! "$PROBE" wait --color "$color" --want hidden --timeout-ms 6000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
    fi
  done
  if [ "$ok" -eq 1 ]; then
    if reply="$("$SMHCTL" state --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
      state="$(smh_field "$reply" state || true)"
      if [ "$state" != "collapsed" ]; then ok=0; fi
    else
      ok=0
    fi
  fi
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "f reveal then re-hide" "$dt";
  else check_fail "f reveal then re-hide" "$dt" "reply=[$reply]"; fi
}

# ---------------------------------------------------------------- step g ---
step_g() {
  local t0 dt ok=1 reply="" state=""
  t0=$(now_ms)
  if reply="$("$SMHCTL" pause --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
    state="$(smh_field "$reply" state || true)"
    if [ "$state" != "expanded" ]; then ok=0; fi
  else
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    if ! "$PROBE" wait --color "$MAGENTA" --want visible --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if reply="$("$SMHCTL" resume --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
      state="$(smh_field "$reply" state || true)"
      if [ "$state" != "collapsed" ]; then ok=0; fi
    else
      ok=0
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! "$PROBE" wait --color "$MAGENTA" --want hidden --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  fi
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "g pause/resume" "$dt";
  else check_fail "g pause/resume" "$dt" "reply=[$reply]"; fi
}

# ---------------------------------------------------------------- step h ---
step_h() {
  local t0 dt ok=1 i rc
  t0=$(now_ms)
  quit_bid "$ONE_BID"
  if ! wait_gone exact FixtureOne 5; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    if ! open -g -b "$ONE_BID" 2>>"$RESULTS_FILE"; then ok=0; fi
  fi
  # Relaunched hidden app must stay HIDDEN for 3 s (6 x 0.5 s polls).
  if [ "$ok" -eq 1 ]; then
    sleep 1 || true
    for i in 1 2 3 4 5 6; do
      rc=0
      "$PROBE" visible --color "$MAGENTA" >>"$RESULTS_FILE" 2>&1 || rc=$?
      if [ "$rc" -ne 1 ]; then ok=0; break; fi
      sleep 0.5 || true
    done
  fi
  # A new, not-hidden app must show while collapsed.
  if [ "$ok" -eq 1 ]; then
    if ! open -g -b "$WIDE_BID" 2>>"$RESULTS_FILE"; then ok=0; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! "$PROBE" wait --color "$BLUE" --want visible --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  fi
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "h relaunch hidden/new app" "$dt";
  else check_fail "h relaunch hidden/new app" "$dt" "magenta leaked or blue never showed"; fi
}

# ---------------------------------------------------------------- step i ---
step_i() {
  local t0 dt ok=1 pids="" pid="" reply="" hidden=""
  t0=$(now_ms)
  pids="$(smh_pids)"
  if [ -z "$pids" ]; then
    ok=0
  else
    pid="$(printf '%s\n' "$pids" | head -n 1 || true)"
    # A kill never counts as success: the probe verdicts below decide.
    kill -TERM "$pid" 2>/dev/null || true
  fi
  for color in "$MAGENTA" "$CYAN" "$YELLOW" "$ORANGE" "$BLUE"; do
    if [ "$ok" -eq 1 ]; then
      if ! "$PROBE" wait --color "$color" --want visible --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
    fi
  done
  # Relaunch: the hidden set must be restored from settings.
  if [ "$ok" -eq 1 ]; then
    if ! open -g -b "$SMH_BID" 2>>"$RESULTS_FILE"; then ok=0; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if reply="$(wait_smh_answers 10 2>>"$RESULTS_FILE")"; then
      hidden="$(smh_field "$reply" hidden || true)"
      case ",$hidden," in
        *",$ONE_BID,"*) ;;
        *) ok=0 ;;
      esac
      case ",$hidden," in
        *",$MANY_BID,"*) ;;
        *) ok=0 ;;
      esac
    else
      ok=0
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! "$PROBE" wait --color "$MAGENTA" --want hidden --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  fi
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "i TERM restores, relaunch keeps set" "$dt";
  else check_fail "i TERM restores, relaunch keeps set" "$dt" "reply=[$reply]"; fi
}

# ---------------------------------------------------------------- step j ---
step_j() {
  local t0 dt ok=1 pids="" pid=""
  t0=$(now_ms)
  pids="$(smh_pids)"
  if [ -z "$pids" ]; then
    ok=0
  else
    pid="$(printf '%s\n' "$pids" | head -n 1 || true)"
    kill -KILL "$pid" 2>/dev/null || true
  fi
  if ! "$PROBE" wait --color "$MAGENTA" --want visible --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "j KILL restores icons" "$dt";
  else check_fail "j KILL restores icons" "$dt" "magenta not VISIBLE after KILL"; fi
}

# ---------------------------------------------------------------- step k ---
step_k() {
  local t0 dt ok=1 reply="" state=""
  t0=$(now_ms)
  if ! open -g -b "$SMH_BID" 2>>"$RESULTS_FILE"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    if ! wait_smh_answers 10 >>"$RESULTS_FILE" 2>&1; then ok=0; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if reply="$("$SMHCTL" setHidden "" --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
      state="$(smh_field "$reply" state || true)"
      if [ "$state" != "expanded" ]; then ok=0; fi
    else
      ok=0
    fi
  fi
  # Quit SMH for real: ask, then TERM, then KILL. Never leave it holding
  # an assertion.
  if [ "$ok" -eq 1 ]; then
    "$SMHCTL" quit --timeout-ms 5000 >>"$RESULTS_FILE" 2>&1 || true
    if ! wait_gone pattern "$SMH_PROC_PATTERN" 5; then
      local pids
      pids="$(smh_pids)"
      if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null || true
      fi
      if ! wait_gone pattern "$SMH_PROC_PATTERN" 5; then
        pids="$(smh_pids)"
        if [ -n "$pids" ]; then
          # shellcheck disable=SC2086
          kill -KILL $pids 2>/dev/null || true
        fi
        if ! wait_gone pattern "$SMH_PROC_PATTERN" 5; then ok=0; fi
      fi
    fi
  fi
  quit_bid "$ONE_BID"
  quit_bid "$MANY_BID"
  quit_bid "$WIDE_BID"
  if ! wait_gone exact FixtureOne 5; then ok=0; fi
  if ! wait_gone exact FixtureMany 5; then ok=0; fi
  if ! wait_gone exact FixtureWide 5; then ok=0; fi
  dt=$(( $(now_ms) - t0 ))
  if [ "$ok" -eq 1 ]; then check_pass "k reset and quit all" "$dt";
  else check_fail "k reset and quit all" "$dt" "reply=[$reply]"; fi
}

main() {
  log "E2E start $(date -u +%Y-%m-%dT%H:%M:%SZ) results=$RESULTS_FILE"
  if ! step_a; then
    log "E2E FAIL $FAILED/$TOTAL"
    return 2
  fi
  step_a2
  step_b
  step_c
  step_d
  step_e
  step_f
  step_g
  step_h
  step_i
  step_j
  step_k
  if [ "$FAILED" -eq 0 ]; then
    log "E2E PASS $TOTAL/$TOTAL"
  else
    log "E2E FAIL $FAILED/$TOTAL"
    exit 1
  fi
}

main "$@"
