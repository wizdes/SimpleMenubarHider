#!/bin/bash
set -euo pipefail

# M4 adversarial test script for Simple Menubar Hider (SMH).
#
# What it does, in order:
#   1. Checks every input (tools, installed apps, free paths in ~/Downloads)
#      before it changes anything.
#   2. Saves a copy of SMH's settings, then does the same clean start as
#      scripts/e2e.sh.
#   3. Runs the M4 cases from docs/plan.md that a script can run. Each case
#      prints PASS or FAIL with its time in ms.
#   4. Prints the MANUAL list, then "ADV PASS n/n" or "ADV FAIL k/n".
#
# Usage: scripts/adversarial.sh [--quick]
#   --quick runs case 8 for 60 s instead of 600 s and case 15 with 50 reveal
#   calls instead of 500. Case 15 always sends 20 concurrent setHidden calls.
#
# This script does not build or install SMH or the fixtures. They must
# already be in /Applications. It builds Tools/ if needed.
#
# It touches only SMH, the fixtures, MenuBarAgent and ControlCenter.
# The trap on EXIT releases SMH (setHidden "" then quit, then TERM, then
# KILL), quits the fixtures, deletes only the copies this script made, and
# puts SMH's saved settings back.

usage() {
  echo "usage: scripts/adversarial.sh [--quick]" >&2
}

QUICK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

if [ "$QUICK" -eq 1 ]; then
  FLICKER_SECONDS=60
  REVEAL_CALLS=50
else
  FLICKER_SECONDS=600
  REVEAL_CALLS=500
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_BUILD="$ROOT/Tools/build"
PROBE="$TOOLS_BUILD/menubar-probe"
SMHCTL="$TOOLS_BUILD/smhctl"

RESULTS_DIR="$ROOT/build/e2e-results"
mkdir -p "$RESULTS_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_FILE="$RESULTS_DIR/adv-$STAMP.txt"
: > "$RESULTS_FILE"
PREFS_BACKUP="$RESULTS_DIR/adv-$STAMP-prefs.plist"

SMH_APP="/Applications/Simple Menubar Hider.app"
SMH_BID="dev.yili.smh"
SMH_PROC_PATTERN="Simple Menubar Hider.app/Contents/MacOS/"
# SMH saves its settings as JSON data under this key in this domain
# (Packages/SMHCore/Sources/SMHCore/Settings.swift, App/Engine/AppController.swift).
PREFS_DOMAIN="dev.yili.smh"
PREFS_KEY="SMHCore.settings"

ONE_BID="dev.yili.smh.fixture.one"
MANY_BID="dev.yili.smh.fixture.many"
WIDE_BID="dev.yili.smh.fixture.wide"
FLICKER_BID="dev.yili.smh.fixture.flicker"
COMPETITOR_BID="dev.yili.smh.fixture.competitor"
ONE_APP="/Applications/FixtureOne.app"
MANY_APP="/Applications/FixtureMany.app"
WIDE_APP="/Applications/FixtureWide.app"
FLICKER_APP="/Applications/FixtureFlicker.app"
COMPETITOR_APP="/Applications/FixtureCompetitor.app"
NOBUNDLE_BIN="$ROOT/Fixtures/build/fixture-nobundle"

# Copies this script makes, and deletes again, in ~/Downloads.
DOWNLOADS_DIR="$HOME/Downloads"
WIDE_COPY="$DOWNLOADS_DIR/SMHDownloadsTest.app"
WIDE_COPY_PATTERN="SMHDownloadsTest.app/Contents/MacOS/"
SMH_COPY="$DOWNLOADS_DIR/SMHOutsideTest.app"
SMH_COPY_PATTERN="SMHOutsideTest.app/Contents/MacOS/"
WIDE_COPY_MADE=0
SMH_COPY_MADE=0
NOBUNDLE_PID=""
PREFS_SAVED=0     # 1: domain exported to PREFS_BACKUP; 2: domain did not exist
PREFS_TOUCHED=0   # 1 once the script may have changed SMH's settings

# Fixture icon colors (see Fixtures/*/main.m).
MAGENTA="FF00FF" # FixtureOne
CYAN="00FFFF"    # FixtureMany item 1
BLUE="0000FF"    # FixtureWide
GREEN="00FF00"   # FixtureFlicker
RED="FF0000"     # fixture-nobundle
PURPLE="8000FF"  # FixtureCompetitor

ALL_FIXTURE_IDS="$ONE_BID,$MANY_BID,$WIDE_BID,$FLICKER_BID,$COMPETITOR_BID"

# Every key smhctl can print. smh_field uses this list to find where one
# value ends, because some values (state, settingsNote) contain spaces.
REPLY_KEYS="allowCount applied applyCount conflict found hidden popover settingsNote state trusted"

TOTAL=0
FAILED=0

log() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >> "$RESULTS_FILE"
}

note() { # only to the results file
  printf '%s\n' "$*" >> "$RESULTS_FILE"
}

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

check_pass() { # name ms [detail]
  TOTAL=$((TOTAL + 1))
  if [ -n "${3:-}" ]; then log "PASS $1 ($2 ms) :: $3"; else log "PASS $1 ($2 ms)"; fi
}

check_fail() { # name ms detail
  TOTAL=$((TOTAL + 1))
  FAILED=$((FAILED + 1))
  log "FAIL $1 ($2 ms) :: $3"
}

finish_case() { # ok name t0 pass-detail fail-detail
  local dt
  dt=$(( $(now_ms) - $3 ))
  if [ "$1" -eq 1 ]; then check_pass "$2" "$dt" "$4"; else check_fail "$2" "$dt" "$5"; fi
}

# smh_field <reply-line> <key>: prints the value, which may hold spaces or be
# empty. Returns 1 when the key is not in the reply.
smh_field() {
  local line=" $1" key="$2" rest k
  case "$line" in
    *" $key="*) ;;
    *) return 1 ;;
  esac
  rest="${line#*" $key="}"
  for k in $REPLY_KEYS; do
    rest="${rest%%" $k="*}"
  done
  printf '%s' "$rest"
}

smh_pids() {
  pgrep -f "$SMH_PROC_PATTERN" 2>/dev/null || true
}

first_smh_pid() {
  smh_pids | head -n 1 || true
}

quit_bid() { # bundle-id: polite quit, never fails
  osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 || true
}

# wait_gone <kind> <match> <timeout-s>: 0 when no process matches anymore.
wait_gone() {
  local kind="$1" match="$2" timeout_s="$3" i
  for i in $(seq 0 "$timeout_s"); do
    if [ "$kind" = "exact" ]; then
      pgrep -x "$match" >/dev/null 2>&1 || return 0
    else
      pgrep -f "$match" >/dev/null 2>&1 || return 0
    fi
    if [ "$i" -lt "$timeout_s" ]; then sleep 1 || true; fi
  done
  return 1
}

# term_then_kill <kind> <match>: TERM, wait, KILL, wait. 0 when gone.
term_then_kill() {
  local kind="$1" match="$2" pids=""
  if [ "$kind" = "exact" ]; then pids="$(pgrep -x "$match" 2>/dev/null || true)";
  else pids="$(pgrep -f "$match" 2>/dev/null || true)"; fi
  [ -z "$pids" ] && return 0
  note "  TERM $match ($pids)"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  wait_gone "$kind" "$match" 3 && return 0
  if [ "$kind" = "exact" ]; then pids="$(pgrep -x "$match" 2>/dev/null || true)";
  else pids="$(pgrep -f "$match" 2>/dev/null || true)"; fi
  if [ -n "$pids" ]; then
    note "  KILL $match ($pids)"
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
  fi
  wait_gone "$kind" "$match" 3
}

# wait_smh_answers <timeout-s>: prints the reply once `smhctl state` answers.
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

# stop_smh_pattern <pattern>: ask SMH to release and quit, then TERM, then
# KILL. 0 when no process matches anymore. A kill here is only cleanup;
# the cases decide pass or fail with the probe.
stop_smh_pattern() {
  local pattern="$1"
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    "$SMHCTL" quit --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1 || true
    if wait_gone pattern "$pattern" 5; then return 0; fi
    note "  SMH ($pattern) did not quit on request; escalating"
    term_then_kill pattern "$pattern"
    return $?
  fi
  return 0
}

stop_smh() { stop_smh_pattern "$SMH_PROC_PATTERN"; }

# start_smh [env-assignment]: launch the installed SMH and wait for a reply.
start_smh() {
  local rc=0
  if [ -n "${1:-}" ]; then
    open -g -n --env "$1" -a "$SMH_APP" 2>>"$RESULTS_FILE" || rc=$?
  else
    open -g -a "$SMH_APP" 2>>"$RESULTS_FILE" || rc=$?
  fi
  [ "$rc" -eq 0 ] || return 1
  wait_smh_answers 10 >/dev/null
}

# probe_wait <color> <visible|hidden> <timeout-ms>: prints the probe line.
probe_wait() {
  local out="" rc=0
  out="$("$PROBE" wait --color "$1" --want "$2" --timeout-ms "$3" 2>&1)" || rc=$?
  note "  probe wait $1 $2: $out (rc $rc)"
  printf '%s' "$out"
  return "$rc"
}

# probe_now <color>: prints VISIBLE, HIDDEN or ERROR.
probe_now() {
  local rc=0
  "$PROBE" visible --color "$1" >>"$RESULTS_FILE" 2>&1 || rc=$?
  case "$rc" in
    0) printf 'VISIBLE' ;;
    1) printf 'HIDDEN' ;;
    *) printf 'ERROR' ;;
  esac
}

# hold_hidden <color> <seconds>: 0 when every 0.5 s check says HIDDEN.
hold_hidden() {
  local polls=$(( $2 * 2 )) i
  for i in $(seq 1 "$polls"); do
    if [ "$(probe_now "$1")" != "HIDDEN" ]; then return 1; fi
    sleep 0.5 || true
  done
  return 0
}

# smh_state_reply: prints one `state` reply, or returns 1 when SMH did not answer.
smh_state_reply() {
  "$SMHCTL" state --timeout-ms 1000 2>/dev/null
}

# apply_count_now: prints SMH's applyCount, or returns 1.
apply_count_now() {
  local reply="" count=""
  reply="$(smh_state_reply)" || return 1
  count="$(smh_field "$reply" applyCount || true)"
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$count"
}

# wait_apply_count_above <base> <timeout-ms>: 0 once applyCount > base.
# Prints what it saw either way.
wait_apply_count_above() {
  local base="$1" timeout_ms="$2" start count=""
  start=$(now_ms)
  while :; do
    count="$(apply_count_now || true)"
    if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt "$base" ]; then
      printf 'applyCount %s -> %s after %s ms' "$base" "$count" "$(( $(now_ms) - start ))"
      return 0
    fi
    if [ $(( $(now_ms) - start )) -ge "$timeout_ms" ]; then
      printf 'applyCount stayed %s (was %s before)' "${count:-<no reply>}" "$base"
      return 1
    fi
    sleep 0.2 || true
  done
}

# wait_smh_state <state-prefix> <yes|no|any> <timeout-ms>: polls `state` until
# the state starts with the prefix and applied matches. Prints the ms it took,
# or the last state and applied it saw.
wait_smh_state() {
  local want_state="$1" want_applied="$2" timeout_ms="$3" start reply="" state="" applied=""
  start=$(now_ms)
  while :; do
    if reply="$(smh_state_reply)"; then
      state="$(smh_field "$reply" state || true)"
      applied="$(smh_field "$reply" applied || true)"
      case "$state" in
        "$want_state"*)
          if [ "$want_applied" = "any" ] || [ "$applied" = "$want_applied" ]; then
            printf '%s' "$(( $(now_ms) - start ))"
            return 0
          fi
          ;;
      esac
    fi
    if [ $(( $(now_ms) - start )) -ge "$timeout_ms" ]; then
      printf 'state=[%s] applied=[%s]' "$state" "$applied"
      return 1
    fi
    sleep 0.2 || true
  done
}

# smh_post <cmd> [arg]: posts one debug command and does not wait for the
# reply. smhctl does not know failNextApplies, so this posts it the same way
# smhctl does (docs/debug-channel.md), through osascript. A later
# `smhctl state` shows its effect.
smh_post() {
  osascript -l JavaScript - "dev.yili.smh.debug.command" "adv-$$-$(now_ms)" "$@" >>"$RESULTS_FILE" 2>&1 <<'JXA'
ObjC.import("Foundation");
function run(argv) {
  var info = $.NSMutableDictionary.alloc.init;
  info.setObjectForKey(argv[1], "id");
  info.setObjectForKey(argv[2], "cmd");
  if (argv.length > 3) info.setObjectForKey(argv[3], "arg");
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(argv[0], undefined, info, true);
  return "";
}
JXA
}

# fail_next_applies <n>: posts failNextApplies, then waits until SMH answers
# a `state`, so the command has arrived before the caller goes on.
fail_next_applies() {
  smh_post failNextApplies "$1" || return 1
  sleep 0.3 || true
  smh_state_reply >/dev/null
}

launch_app() { # app-path
  open -g -a "$1" 2>>"$RESULTS_FILE"
}

# ensure_collapsed: SMH running, hiding FixtureOne only, FixtureOne running
# and HIDDEN. Prints the last reply.
ensure_collapsed() {
  local reply="" state="" applied=""
  if ! pgrep -x FixtureOne >/dev/null 2>&1; then
    launch_app "$ONE_APP" || return 1
    probe_wait "$MAGENTA" visible 15000 >/dev/null || true
  fi
  if [ -z "$(smh_pids)" ]; then
    start_smh || return 1
  fi
  PREFS_TOUCHED=1
  "$SMHCTL" setRevealSeconds 3 --timeout-ms 5000 >>"$RESULTS_FILE" 2>&1 || return 1
  reply="$("$SMHCTL" setHidden "$ONE_BID" --timeout-ms 5000 2>>"$RESULTS_FILE")" || return 1
  note "  ensure_collapsed: $reply"
  state="$(smh_field "$reply" state || true)"
  applied="$(smh_field "$reply" applied || true)"
  if [ "$state" != "collapsed" ] || [ "$applied" != "yes" ]; then return 1; fi
  probe_wait "$MAGENTA" hidden 3000 >/dev/null || return 1
  printf '%s' "$reply"
}

save_prefs() {
  local rc=0
  defaults export "$PREFS_DOMAIN" "$PREFS_BACKUP" >>"$RESULTS_FILE" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$PREFS_BACKUP" ]; then
    PREFS_SAVED=1
    note "saved $PREFS_DOMAIN settings to $PREFS_BACKUP"
  else
    PREFS_SAVED=2
    note "no $PREFS_DOMAIN settings to save (export rc $rc)"
  fi
}

restore_prefs() {
  [ "$PREFS_TOUCHED" -eq 1 ] || return 0
  if [ "$PREFS_SAVED" -eq 1 ]; then
    if defaults import "$PREFS_DOMAIN" "$PREFS_BACKUP" >>"$RESULTS_FILE" 2>&1; then
      log "restored $PREFS_DOMAIN settings from $PREFS_BACKUP"
    else
      log "WARNING: could not restore $PREFS_DOMAIN settings; the saved copy is $PREFS_BACKUP"
    fi
  elif [ "$PREFS_SAVED" -eq 2 ]; then
    # There were no settings before the run; remove the key this run wrote.
    defaults delete "$PREFS_DOMAIN" "$PREFS_KEY" >>"$RESULTS_FILE" 2>&1 || true
    log "removed $PREFS_DOMAIN $PREFS_KEY (it did not exist before the run)"
  fi
}

# remove_copy <path> <made-flag>: deletes a copy only when this script made
# it and the path is one of the two exact copy paths.
remove_copy() {
  local path="$1" made="$2"
  [ "$made" -eq 1 ] || return 0
  case "$path" in
    "$WIDE_COPY"|"$SMH_COPY") ;;
    *) log "REFUSING to delete unexpected path: $path"; return 1 ;;
  esac
  if [ -d "$path" ]; then
    rm -rf "$path"
    note "  deleted $path"
  fi
  [ ! -e "$path" ]
}

stop_nobundle() {
  [ -n "$NOBUNDLE_PID" ] || return 0
  if kill -0 "$NOBUNDLE_PID" 2>/dev/null; then
    kill -TERM "$NOBUNDLE_PID" 2>/dev/null || true
    sleep 1 || true
  fi
  if kill -0 "$NOBUNDLE_PID" 2>/dev/null; then
    kill -KILL "$NOBUNDLE_PID" 2>/dev/null || true
    sleep 0.5 || true
  fi
  if kill -0 "$NOBUNDLE_PID" 2>/dev/null; then return 1; fi
  wait "$NOBUNDLE_PID" 2>/dev/null || true
  NOBUNDLE_PID=""
  return 0
}

cleanup() {
  set +e
  # Release hiding first, then quit; escalate only if needed.
  if [ -x "$SMHCTL" ] && { [ -n "$(smh_pids)" ] || pgrep -f "$SMH_COPY_PATTERN" >/dev/null 2>&1; }; then
    "$SMHCTL" setHidden "" --timeout-ms 2000 >/dev/null 2>&1 || true
    "$SMHCTL" quit --timeout-ms 2000 >/dev/null 2>&1 || true
    sleep 1 || true
  fi
  term_then_kill pattern "$SMH_PROC_PATTERN" || true
  term_then_kill pattern "$SMH_COPY_PATTERN" || true
  stop_nobundle || true
  local bid name
  for bid in "$ONE_BID" "$MANY_BID" "$WIDE_BID" "$FLICKER_BID" "$COMPETITOR_BID"; do
    quit_bid "$bid"
  done
  sleep 1 || true
  for name in FixtureOne FixtureMany FixtureWide FixtureFlicker FixtureCompetitor; do
    term_then_kill exact "$name" || true
  done
  term_then_kill pattern "$WIDE_COPY_PATTERN" || true
  remove_copy "$WIDE_COPY" "$WIDE_COPY_MADE" || true
  remove_copy "$SMH_COPY" "$SMH_COPY_MADE" || true
  restore_prefs || true
}
trap cleanup EXIT

# ------------------------------------------------------------ prerequisites ---
# Check every input before any side effect (except building Tools/).
step_prereq() {
  local t0 dt problems=0 tool app
  t0=$(now_ms)

  for tool in open osascript pgrep killall ps defaults python3 awk seq cp find grep; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log "MISSING tool: $tool"
      problems=$((problems + 1))
    fi
  done
  if [ ! -x /usr/libexec/PlistBuddy ]; then log "MISSING tool: /usr/libexec/PlistBuddy"; problems=$((problems + 1)); fi

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
    if [ -z "$(find "$SMH_APP/Contents/MacOS/" -type f -exec grep -q "SMH_DEBUG_FORCE_SHIM_MISSING" {} \; -print -quit 2>/dev/null)" ]; then
      log "OLD-BUILD: $SMH_APP does not read SMH_DEBUG_FORCE_SHIM_MISSING (case 13 needs it)"
      problems=$((problems + 1))
    fi
  fi
  for app in "$ONE_APP" "$MANY_APP" "$WIDE_APP" "$FLICKER_APP" "$COMPETITOR_APP"; do
    if [ ! -d "$app" ]; then log "MISSING $app"; problems=$((problems + 1)); fi
  done
  if [ ! -x "$NOBUNDLE_BIN" ]; then log "MISSING $NOBUNDLE_BIN"; problems=$((problems + 1)); fi

  if [ ! -d "$DOWNLOADS_DIR" ]; then
    log "MISSING folder $DOWNLOADS_DIR"
    problems=$((problems + 1))
  fi
  # The copies must not exist yet: this script deletes only what it made.
  if [ -e "$WIDE_COPY" ]; then log "IN THE WAY: $WIDE_COPY already exists; move it away first"; problems=$((problems + 1)); fi
  if [ -e "$SMH_COPY" ]; then log "IN THE WAY: $SMH_COPY already exists; move it away first"; problems=$((problems + 1)); fi
  if pgrep -f "$WIDE_COPY_PATTERN" >/dev/null 2>&1 || pgrep -f "$SMH_COPY_PATTERN" >/dev/null 2>&1; then
    log "IN THE WAY: a copy from an earlier run is still running"
    problems=$((problems + 1))
  fi
  if ! pgrep -x MenuBarAgent >/dev/null 2>&1; then
    log "MenuBarAgent is not running (case 3 needs it)"
    problems=$((problems + 1))
  fi

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
    check_pass "prerequisites" "$dt"
    return 0
  fi
  check_fail "prerequisites" "$dt" "$problems problem(s)"
  log "This script does not build or install SMH or the fixtures. To fix:"
  log "  1. Build the Debug SMH app and install it at: $SMH_APP"
  log "  2. bash scripts/build-fixtures.sh && bash scripts/install-fixtures.sh"
  log "  3. bash Tools/build-tools.sh"
  return 2
}

# --------------------------------------------------------------- clean start ---
# Same as scripts/e2e.sh step a2: release and quit SMH, quit the fixtures.
step_clean_start() {
  local t0 ok=1 reply="" rc=0 name
  t0=$(now_ms)
  if [ -n "$(smh_pids)" ]; then
    PREFS_TOUCHED=1
    reply="$("$SMHCTL" setHidden "" --timeout-ms 2000 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ] && { [ "$rc" -ne 3 ] || [ "$reply" != "TIMEOUT" ]; }; then
      ok=0
      log "  setHidden failed: $reply"
    fi
    if ! stop_smh; then ok=0; fi
  fi
  quit_bid "$ONE_BID"
  quit_bid "$MANY_BID"
  quit_bid "$WIDE_BID"
  quit_bid "$FLICKER_BID"
  quit_bid "$COMPETITOR_BID"
  for name in FixtureOne FixtureMany FixtureWide FixtureFlicker FixtureCompetitor; do
    if ! wait_gone exact "$name" 5; then ok=0; fi
  done
  finish_case "$ok" "clean start" "$t0" "" "SMH or fixtures did not cleanly stop"
}

# -------------------------------------------------------------------- case 1 ---
case_1() {
  local t0 ok=1 pid="" out="" detail=""
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    pid="$(first_smh_pid)"
    if [ -z "$pid" ]; then ok=0; detail="no SMH process"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    t0=$(now_ms)
    # A kill never counts as success: the probe verdict decides.
    kill -KILL "$pid" 2>/dev/null || true
    if ! out="$(probe_wait "$MAGENTA" visible 2000)"; then ok=0; detail="magenta not VISIBLE within 2 s ($out)"; fi
  fi
  wait_gone pattern "$SMH_PROC_PATTERN" 3 || true
  finish_case "$ok" "1 kill -9 restores within 2 s" "$t0" "$out" "$detail"
}

# -------------------------------------------------------------------- case 2 ---
case_2() {
  local t0 ok=1 out="" detail="" rc=0
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    t0=$(now_ms)
    # SMH may exit before its reply arrives, so the probe decides, not rc.
    "$SMHCTL" quit --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1 || rc=$?
    note "  smhctl quit rc $rc"
  fi
  if [ "$ok" -eq 1 ]; then
    if ! out="$(probe_wait "$MAGENTA" visible 2000)"; then ok=0; detail="magenta not VISIBLE within 2 s ($out)"; fi
  fi
  if ! wait_gone pattern "$SMH_PROC_PATTERN" 5; then
    if [ "$ok" -eq 1 ]; then ok=0; detail="SMH still running 5 s after quit"; fi
    stop_smh || true
  fi
  finish_case "$ok" "2 quit restores within 2 s" "$t0" "$out" "$detail"
}

# -------------------------------------------------------------------- case 3 ---
# kill_system_agent <process-name> [check-apply]: kill it, wait for a new pid,
# then the hidden fixture must be HIDDEN within 3 s and stay HIDDEN for 3 s.
# With check-apply, SMH's applyCount must also rise within 3 s after the new
# pid appears, which shows SMH forced an apply after the restart.
kill_system_agent() {
  local name="$1" check_apply="${2:-}" old="" new="" i rc=0 out="" base="" seen_ms="" left_ms=3000 apply_msg=""
  old="$(pgrep -x "$name" 2>/dev/null | head -n 1 || true)"
  if [ -n "$check_apply" ]; then
    if ! base="$(apply_count_now)"; then printf 'no applyCount from SMH before killing %s' "$name"; return 1; fi
  fi
  killall "$name" >>"$RESULTS_FILE" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then printf 'killall %s rc %s' "$name" "$rc"; return 1; fi
  for i in $(seq 1 100); do
    new="$(pgrep -x "$name" 2>/dev/null | head -n 1 || true)"
    if [ -n "$new" ] && [ "$new" != "$old" ]; then break; fi
    new=""
    sleep 0.1 || true
  done
  if [ -z "$new" ]; then printf '%s did not restart within 10 s' "$name"; return 1; fi
  seen_ms=$(now_ms)
  note "  $name restarted: $old -> $new"
  if [ -n "$check_apply" ]; then
    if ! apply_msg="$(wait_apply_count_above "$base" 3000)"; then
      printf 'no forced apply within 3 s after %s restart: %s' "$name" "$apply_msg"; return 1
    fi
    note "  $apply_msg"
    # The HIDDEN check keeps its 3 s limit from the moment the new pid appeared.
    left_ms=$(( 3000 - ($(now_ms) - seen_ms) ))
    if [ "$left_ms" -lt 1 ]; then left_ms=1; fi
  fi
  if ! out="$(probe_wait "$MAGENTA" hidden "$left_ms")"; then
    printf 'magenta not HIDDEN within 3 s after %s restart (%s)' "$name" "$out"; return 1
  fi
  if ! hold_hidden "$MAGENTA" 3; then
    printf 'magenta came back within 3 s after %s restart' "$name"; return 1
  fi
  printf '%s restart: %s%s' "$name" "$out" "${apply_msg:+; $apply_msg}"
}

case_3() {
  local t0 ok=1 detail="" msg="" pass=""
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    if msg="$(kill_system_agent MenuBarAgent check-apply)"; then pass="$msg"; else ok=0; detail="$msg"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if msg="$(kill_system_agent ControlCenter)"; then pass="$pass; $msg"; else ok=0; detail="$msg"; fi
  fi
  if [ -z "$(smh_pids)" ]; then ok=0; detail="SMH died; $detail"; fi
  finish_case "$ok" "3 MenuBarAgent and ControlCenter restarts" "$t0" "$pass" "$detail"
}

# -------------------------------------------------------------------- case 6 ---
case_6() {
  local t0 ok=1 detail=""
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    quit_bid "$ONE_BID"
    if ! wait_gone exact FixtureOne 5; then ok=0; detail="FixtureOne did not quit"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! launch_app "$ONE_APP"; then ok=0; detail="relaunch failed"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    sleep 1 || true
    if ! pgrep -x FixtureOne >/dev/null 2>&1; then ok=0; detail="FixtureOne not running after relaunch"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! hold_hidden "$MAGENTA" 3; then ok=0; detail="relaunched magenta showed while collapsed"; fi
  fi
  finish_case "$ok" "6 hidden app relaunch stays hidden" "$t0" "" "$detail"
}

# -------------------------------------------------------------------- case 7 ---
case_7() {
  local t0 ok=1 detail="" out="" ms=""
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    t0=$(now_ms)
    if ! launch_app "$WIDE_APP"; then ok=0; detail="FixtureWide launch failed"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if out="$(probe_wait "$BLUE" visible 5000)"; then
      ms=$(( $(now_ms) - t0 ))
    else
      ok=0; detail="blue never VISIBLE within 5 s ($out)"
    fi
  fi
  if [ "$ok" -eq 1 ] && [ "$(probe_now "$MAGENTA")" != "HIDDEN" ]; then
    ok=0; detail="magenta showed when FixtureWide launched"
  fi
  quit_bid "$WIDE_BID"
  wait_gone exact FixtureWide 5 || term_then_kill exact FixtureWide || true
  finish_case "$ok" "7 new app shows while collapsed" "$t0" "launch to VISIBLE ${ms} ms (probe $out)" "$detail"
}

# -------------------------------------------------------------------- case 8 ---
case_8() {
  local t0 ok=1 detail="" reply="" a0="" a1="" pid="" cpu="" samples="" n=0
  local start_s now_s elapsed=0 leaks=0 mean="" per_min="" applies=0 too_many=""
  t0=$(now_ms)
  if ! reply="$(ensure_collapsed)"; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    a0="$(smh_field "$reply" applyCount || true)"
    pid="$(first_smh_pid)"
    case "$a0" in
      ''|*[!0-9]*) ok=0; detail="reply has no numeric applyCount: [$reply]" ;;
    esac
    if [ -z "$pid" ]; then ok=0; detail="no SMH process"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! launch_app "$FLICKER_APP"; then ok=0; detail="FixtureFlicker launch failed"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    log "  case 8 runs FixtureFlicker for $FLICKER_SECONDS s"
    start_s=$(( $(now_ms) / 1000 ))
    while :; do
      sleep 5 || true
      now_s=$(( $(now_ms) / 1000 ))
      elapsed=$(( now_s - start_s ))
      if ! kill -0 "$pid" 2>/dev/null; then ok=0; detail="SMH (pid $pid) died after ${elapsed} s"; break; fi
      cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
      if [ -n "$cpu" ]; then samples="$samples $cpu"; n=$((n + 1)); fi
      if [ "$(probe_now "$MAGENTA")" != "HIDDEN" ]; then leaks=$((leaks + 1)); fi
      if [ "$elapsed" -ge "$FLICKER_SECONDS" ]; then break; fi
    done
  fi
  if [ "$ok" -eq 1 ]; then
    if reply="$("$SMHCTL" state --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
      a1="$(smh_field "$reply" applyCount || true)"
      case "$a1" in
        ''|*[!0-9]*) ok=0; detail="reply has no numeric applyCount: [$reply]" ;;
      esac
    else
      ok=0; detail="no state reply after the flicker run"
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    if [ "$n" -eq 0 ]; then ok=0; detail="no CPU samples"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    note "  cpu samples:$samples"
    mean="$(printf '%s\n' $samples | awk '{s+=$1} END {printf "%.2f", s/NR}')"
    applies=$(( a1 - a0 ))
    per_min="$(awk -v a="$applies" -v e="$elapsed" 'BEGIN {printf "%.1f", a*60/e}')"
    # At most one apply per 0.3 s debounce window on average.
    too_many="$(awk -v a="$applies" -v e="$elapsed" 'BEGIN {print (a*0.3 > e) ? 1 : 0}')"
    if awk -v m="$mean" 'BEGIN {exit !(m >= 1.0)}'; then ok=0; detail="mean CPU ${mean}% is not under 1.0%"; fi
    if [ "$too_many" = "1" ]; then ok=0; detail="${detail:+$detail; }$applies applies in ${elapsed} s is more than one per 0.3 s"; fi
    if [ "$leaks" -gt 0 ]; then ok=0; detail="${detail:+$detail; }magenta VISIBLE in $leaks of $n checks"; fi
  fi
  quit_bid "$FLICKER_BID"
  wait_gone exact FixtureFlicker 5 || term_then_kill exact FixtureFlicker || true
  finish_case "$ok" "8 flicker ${FLICKER_SECONDS} s" "$t0" \
    "mean CPU ${mean}% over $n samples, $applies applies (${per_min}/min), magenta HIDDEN in all checks" "$detail"
}

# ------------------------------------------------------------------- case 9a ---
case_9a() {
  local t0 ok=1 detail="" seen="" i
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    "$NOBUNDLE_BIN" >>"$RESULTS_FILE" 2>&1 &
    NOBUNDLE_PID=$!
    # Give its status item time to appear, then record what the probe sees.
    for i in 1 2 3 4 5 6; do
      sleep 0.5 || true
      seen="$(probe_now "$RED")"
      [ "$seen" = "VISIBLE" ] && break
    done
    if ! kill -0 "$NOBUNDLE_PID" 2>/dev/null; then ok=0; detail="fixture-nobundle exited early"; fi
    if [ -z "$(smh_pids)" ]; then ok=0; detail="SMH crashed"; fi
    if ! "$SMHCTL" state --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1; then ok=0; detail="${detail:+$detail; }SMH stopped answering"; fi
  fi
  if ! stop_nobundle; then ok=0; detail="${detail:+$detail; }fixture-nobundle would not stop"; fi
  finish_case "$ok" "9a bundle-less item (report)" "$t0" "red item is $seen while collapsed" "$detail"
}

# ------------------------------------------------------------------- case 9b ---
case_9b() {
  local t0 ok=1 detail="" seen="" i
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ] && pgrep -x FixtureWide >/dev/null 2>&1; then
    quit_bid "$WIDE_BID"
    if ! wait_gone exact FixtureWide 5; then ok=0; detail="installed FixtureWide still running"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if [ -e "$WIDE_COPY" ]; then
      ok=0; detail="$WIDE_COPY appeared during the run; not touching it"
    elif cp -R "$WIDE_APP" "$WIDE_COPY" 2>>"$RESULTS_FILE"; then
      WIDE_COPY_MADE=1
    else
      WIDE_COPY_MADE=1 # a partial copy may exist; cleanup removes it
      ok=0; detail="copy to $WIDE_COPY failed"
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! open -g -n "$WIDE_COPY" 2>>"$RESULTS_FILE"; then ok=0; detail="launch from Downloads failed"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    for i in $(seq 1 10); do
      sleep 0.5 || true
      seen="$(probe_now "$BLUE")"
      [ "$seen" = "VISIBLE" ] && break
    done
    if ! pgrep -f "$WIDE_COPY_PATTERN" >/dev/null 2>&1; then ok=0; detail="Downloads copy is not running"; fi
    if [ -z "$(smh_pids)" ]; then ok=0; detail="${detail:+$detail; }SMH crashed"; fi
  fi
  quit_bid "$WIDE_BID"
  if ! wait_gone pattern "$WIDE_COPY_PATTERN" 5; then term_then_kill pattern "$WIDE_COPY_PATTERN" || true; fi
  if pgrep -f "$WIDE_COPY_PATTERN" >/dev/null 2>&1; then
    ok=0; detail="${detail:+$detail; }Downloads copy would not stop"
  elif ! remove_copy "$WIDE_COPY" "$WIDE_COPY_MADE"; then
    ok=0; detail="${detail:+$detail; }could not delete $WIDE_COPY"
  else
    WIDE_COPY_MADE=0
  fi
  finish_case "$ok" "9b app run from ~/Downloads (report)" "$t0" "blue item is $seen while collapsed" "$detail"
}

# wait_popover <open|closed> <timeout-s>: polls `state` until popover=<want>.
# 0 when seen. Prints the last reply.
wait_popover() {
  local want="$1" timeout_s="$2" i reply="" rc
  for i in $(seq 0 "$timeout_s"); do
    rc=0
    reply="$("$SMHCTL" state --timeout-ms 2000 2>>"$RESULTS_FILE")" || rc=$?
    if [ "$rc" -eq 0 ] && [ "$(smh_field "$reply" popover || true)" = "$want" ]; then
      printf '%s' "$reply"
      return 0
    fi
    if [ "$i" -lt "$timeout_s" ]; then sleep 1 || true; fi
  done
  printf '%s' "$reply"
  return 1
}

# ------------------------------------------------------------------- case 10 ---
# Hiding every app, SMH included, must keep SMH working, and SMH's own
# status item must still exist. The popover opens anchored to that item,
# so popover=open proves the item is still there.
case_10() {
  local t0 ok=1 detail="" reply="" state="" allow="" pop="" rc=0
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    if ! reply="$("$SMHCTL" setHidden "$ALL_FIXTURE_IDS,$SMH_BID" --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
      ok=0; detail="setHidden got no reply"
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    sleep 1 || true
    if reply="$("$SMHCTL" state --timeout-ms 3000 2>>"$RESULTS_FILE")"; then
      state="$(smh_field "$reply" state || true)"
      allow="$(smh_field "$reply" allowCount || true)"
      if [ "$state" != "collapsed" ]; then ok=0; detail="state=$state"; fi
      case "$allow" in
        ''|*[!0-9]*) ok=0; detail="${detail:+$detail; }allowCount=[$allow]" ;;
        0) ok=0; detail="${detail:+$detail; }allowCount=0" ;;
      esac
    else
      ok=0; detail="SMH stopped answering after hiding every fixture and itself"
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    rc=0
    reply="$("$SMHCTL" openPopover --timeout-ms 3000 2>>"$RESULTS_FILE")" || rc=$?
    note "  openPopover: $reply (rc $rc)"
    pop="$(smh_field "$reply" popover || true)"
    if [ "$rc" -ne 0 ]; then
      ok=0; detail="openPopover got no reply (rc $rc)"
    elif [ "$pop" != "open" ]; then
      # The reply can come before the popover is shown; ask again for 2 s.
      if reply="$(wait_popover open 2)"; then
        pop="open"
      else
        ok=0; detail="SMH's own icon is gone: popover=[$pop] after openPopover"
      fi
    fi
  fi
  if [ "$pop" = "open" ]; then
    # Close it again so later cases start with the popover closed.
    rc=0
    "$SMHCTL" closePopover --timeout-ms 3000 >>"$RESULTS_FILE" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      ok=0; detail="${detail:+$detail; }closePopover got no reply (rc $rc)"
    elif ! wait_popover closed 3 >/dev/null; then
      ok=0; detail="${detail:+$detail; }popover still open 3 s after closePopover"
    fi
  fi
  finish_case "$ok" "10 hide everything keeps SMH working" "$t0" "state=$state allowCount=$allow popover opened and closed" "$detail reply=[$reply]"
}

# ------------------------------------------------------------------- case 11 ---
case_11() {
  local t0 ok=1 detail="" reply="" state="" hidden="" settings_note="" rc=0
  t0=$(now_ms)
  if ! stop_smh; then ok=0; detail="SMH would not quit"; fi
  if [ "$ok" -eq 1 ]; then
    PREFS_TOUCHED=1
    defaults write "$PREFS_DOMAIN" "$PREFS_KEY" -data deadbeef >>"$RESULTS_FILE" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then ok=0; detail="defaults write rc $rc"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! start_smh; then ok=0; detail="SMH did not answer after corrupt settings"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if reply="$("$SMHCTL" state --timeout-ms 3000 2>>"$RESULTS_FILE")"; then
      note "  first launch: $reply"
      state="$(smh_field "$reply" state || true)"
      hidden="$(smh_field "$reply" hidden || true)"
      settings_note="$(smh_field "$reply" settingsNote || true)"
      if [ "$state" != "expanded" ]; then ok=0; detail="state=$state"; fi
      if [ -n "$hidden" ]; then ok=0; detail="${detail:+$detail; }hidden=$hidden"; fi
      if [ -z "$settings_note" ]; then ok=0; detail="${detail:+$detail; }settingsNote empty on first launch"; fi
    else
      ok=0; detail="no state reply"
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! stop_smh; then ok=0; detail="SMH would not quit before relaunch"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! start_smh; then ok=0; detail="SMH did not answer on relaunch"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if reply="$("$SMHCTL" state --timeout-ms 3000 2>>"$RESULTS_FILE")"; then
      note "  relaunch: $reply"
      if ! smh_field "$reply" settingsNote >/dev/null; then
        ok=0; detail="reply has no settingsNote field"
      elif [ -n "$(smh_field "$reply" settingsNote || true)" ]; then
        ok=0; detail="settingsNote still set on relaunch: $(smh_field "$reply" settingsNote || true)"
      fi
    else
      ok=0; detail="no state reply on relaunch"
    fi
  fi
  finish_case "$ok" "11 corrupt settings" "$t0" "note was: $settings_note" "$detail"
}

# ------------------------------------------------------------------- case 13 ---
case_13() {
  local t0 ok=1 detail="" reply="" state="" applied="" seen=""
  t0=$(now_ms)
  # Make sure the saved hidden set names FixtureOne, so a working SMH would hide it.
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    if ! stop_smh; then ok=0; detail="SMH would not quit"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! probe_wait "$MAGENTA" visible 3000 >/dev/null; then ok=0; detail="magenta not VISIBLE after quit"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! start_smh "SMH_DEBUG_FORCE_SHIM_MISSING=1"; then ok=0; detail="SMH did not answer with the shim forced missing"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    sleep 1 || true
    if reply="$("$SMHCTL" state --timeout-ms 3000 2>>"$RESULTS_FILE")"; then
      note "  shim missing: $reply"
      state="$(smh_field "$reply" state || true)"
      applied="$(smh_field "$reply" applied || true)"
      case "$state" in
        unavailable:*) ;;
        *) ok=0; detail="state=$state" ;;
      esac
      if [ "$applied" != "no" ]; then ok=0; detail="${detail:+$detail; }applied=$applied"; fi
    else
      ok=0; detail="no state reply"
    fi
    seen="$(probe_now "$MAGENTA")"
    if [ "$seen" != "VISIBLE" ]; then ok=0; detail="${detail:+$detail; }magenta is $seen"; fi
  fi
  if ! stop_smh; then ok=0; detail="${detail:+$detail; }SMH would not quit afterwards"; fi
  finish_case "$ok" "13 shim forced missing" "$t0" "state=$state" "$detail"
}

# ------------------------------------------------------------------- case 14 ---
case_14() {
  local t0 ok=1 detail="" reply="" state="" applied="" seen="" exe=""
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    if ! stop_smh; then ok=0; detail="installed SMH would not quit"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if [ -e "$SMH_COPY" ]; then
      ok=0; detail="$SMH_COPY appeared during the run; not touching it"
    elif cp -R "$SMH_APP" "$SMH_COPY" 2>>"$RESULTS_FILE"; then
      SMH_COPY_MADE=1
    else
      SMH_COPY_MADE=1 # a partial copy may exist; cleanup removes it
      ok=0; detail="copy to $SMH_COPY failed"
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SMH_COPY/Contents/Info.plist" 2>/dev/null || true)"
    note "  copy executable: $SMH_COPY/Contents/MacOS/$exe"
    if ! open -g -n "$SMH_COPY" 2>>"$RESULTS_FILE"; then ok=0; detail="launch of the copy failed"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if reply="$(wait_smh_answers 10)"; then
      sleep 1 || true
      if ! reply="$("$SMHCTL" state --timeout-ms 3000 2>>"$RESULTS_FILE")"; then
        ok=0; detail="the copy stopped answering"
      fi
      note "  outside copy: $reply"
      state="$(smh_field "$reply" state || true)"
      applied="$(smh_field "$reply" applied || true)"
      case "$state" in
        unavailable:*Applications*) ;;
        *) ok=0; detail="state=$state" ;;
      esac
      if [ "$applied" != "no" ]; then ok=0; detail="${detail:+$detail; }applied=$applied"; fi
      if ! pgrep -f "$SMH_COPY_PATTERN" >/dev/null 2>&1; then ok=0; detail="${detail:+$detail; }the answering SMH is not the copy"; fi
      seen="$(probe_now "$MAGENTA")"
      if [ "$seen" != "VISIBLE" ]; then ok=0; detail="${detail:+$detail; }magenta is $seen"; fi
    else
      ok=0; detail="the copy did not answer"
    fi
  fi
  if ! stop_smh_pattern "$SMH_COPY_PATTERN"; then
    ok=0; detail="${detail:+$detail; }the copy would not quit"
  elif ! remove_copy "$SMH_COPY" "$SMH_COPY_MADE"; then
    ok=0; detail="${detail:+$detail; }could not delete $SMH_COPY"
  else
    SMH_COPY_MADE=0
  fi
  finish_case "$ok" "14 launched outside /Applications" "$t0" "state=$state" "$detail"
}

# ------------------------------------------------------------------- case 15 ---
# Part 2 of case 15 sends 20 setHidden calls at once, half "FixtureOne"
# and half "FixtureOne+FixtureMany", then one last "FixtureOne" call. Each
# new call can arrive while an older apply is still running, so SMH has to
# drop the older one. The last requested list must win: magenta HIDDEN,
# cyan VISIBLE.
SETHIDDEN_BURST=20

case_15() {
  local t0 ok=1 detail="" reply="" state="" pid="" rss0="" rss1="" i rc misses=0 drss=0 t1 answer_ms=""
  local list="" bpid="" bpids="" bmisses=0 hidden="" cyan="" magenta=""
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  if [ "$ok" -eq 1 ]; then
    pid="$(first_smh_pid)"
    rss0="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "$rss0" in ''|*[!0-9]*) ok=0; detail="could not read RSS before" ;; esac
  fi
  if [ "$ok" -eq 1 ]; then
    for i in $(seq 1 "$REVEAL_CALLS"); do
      rc=0
      "$SMHCTL" reveal --timeout-ms 2000 >/dev/null 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then misses=$((misses + 1)); fi
    done
    note "  $REVEAL_CALLS reveal calls, $misses without a reply"
    if [ "$misses" -gt 0 ]; then ok=0; detail="$misses of $REVEAL_CALLS reveal calls got no reply within 2 s"; fi
    t1=$(now_ms)
    if reply="$("$SMHCTL" state --timeout-ms 2000 2>>"$RESULTS_FILE")"; then
      answer_ms=$(( $(now_ms) - t1 ))
      state="$(smh_field "$reply" state || true)"
      case "$state" in
        collapsed|revealing) ;;
        *) ok=0; detail="${detail:+$detail; }final state=$state" ;;
      esac
    else
      ok=0; detail="${detail:+$detail; }state did not answer within 2 s"
    fi
    if ! kill -0 "$pid" 2>/dev/null; then ok=0; detail="${detail:+$detail; }SMH (pid $pid) died"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    rss1="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "$rss1" in
      ''|*[!0-9]*) ok=0; detail="could not read RSS after" ;;
      *)
        drss=$(( rss1 - rss0 ))
        if [ "$drss" -lt 0 ]; then drss=$(( -drss )); fi
        if [ "$drss" -ge 20480 ]; then ok=0; detail="RSS changed by ${drss} KB (${rss0} -> ${rss1})"; fi
        ;;
    esac
  fi
  # Part 2: concurrent setHidden calls; the final requested list wins.
  if [ "$ok" -eq 1 ]; then
    if ! pgrep -x FixtureMany >/dev/null 2>&1; then
      if ! launch_app "$MANY_APP"; then ok=0; detail="could not launch FixtureMany"; fi
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! probe_wait "$CYAN" visible 15000 >/dev/null; then ok=0; detail="cyan never VISIBLE before the burst"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    bpids=""
    for i in $(seq 1 "$SETHIDDEN_BURST"); do
      if [ $(( i % 2 )) -eq 1 ]; then list="$ONE_BID"; else list="$ONE_BID,$MANY_BID"; fi
      "$SMHCTL" setHidden "$list" --timeout-ms 5000 >>"$RESULTS_FILE" 2>&1 &
      bpids="$bpids $!"
    done
    for bpid in $bpids; do
      rc=0
      wait "$bpid" || rc=$?
      if [ "$rc" -ne 0 ]; then bmisses=$((bmisses + 1)); fi
    done
    note "  $SETHIDDEN_BURST concurrent setHidden calls, $bmisses without a reply"
    if [ "$bmisses" -gt 0 ]; then ok=0; detail="$bmisses of $SETHIDDEN_BURST concurrent setHidden calls got no reply within 5 s"; fi
    # The FixtureOne-only call goes last, after every burst call has answered.
    rc=0
    reply="$("$SMHCTL" setHidden "$ONE_BID" --timeout-ms 5000 2>>"$RESULTS_FILE")" || rc=$?
    note "  final setHidden: $reply (rc $rc)"
    if [ "$rc" -ne 0 ]; then ok=0; detail="${detail:+$detail; }final setHidden got no reply (rc $rc)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    sleep 2 || true
    rc=0
    reply="$("$SMHCTL" state --timeout-ms 3000 2>>"$RESULTS_FILE")" || rc=$?
    hidden="$(smh_field "$reply" hidden || true)"
    if [ "$rc" -ne 0 ]; then ok=0; detail="state did not answer after the burst (rc $rc)"
    elif [ "$hidden" != "$ONE_BID" ]; then ok=0; detail="hidden=[$hidden] after the burst, want $ONE_BID"; fi
    # A reveal from part 1 may still be running; give it up to 3 s to end.
    if probe_wait "$MAGENTA" hidden 3000 >/dev/null; then magenta="HIDDEN"; else magenta="$(probe_now "$MAGENTA")"; fi
    cyan="$(probe_now "$CYAN")"
    if [ "$magenta" != "HIDDEN" ]; then ok=0; detail="${detail:+$detail; }magenta is $magenta after the burst, want HIDDEN"; fi
    if [ "$cyan" != "VISIBLE" ]; then ok=0; detail="${detail:+$detail; }cyan is $cyan after the burst, want VISIBLE"; fi
  fi
  quit_bid "$MANY_BID"
  if ! wait_gone exact FixtureMany 5; then
    term_then_kill exact FixtureMany || true
  fi
  finish_case "$ok" "15 $REVEAL_CALLS rapid reveals, $SETHIDDEN_BURST concurrent setHidden" "$t0" \
    "state=$state answered in ${answer_ms} ms, RSS ${rss0} -> ${rss1} KB, $misses calls without a reply; after the burst magenta=$magenta cyan=$cyan" "$detail"
}

# ------------------------------------------------------------------- case 16 ---
# wait_conflict <want-contains|want-empty> <timeout-ms>: polls `state`.
wait_conflict() {
  local mode="$1" timeout_ms="$2" start reply="" conflict=""
  start=$(now_ms)
  while :; do
    if reply="$("$SMHCTL" state --timeout-ms 1000 2>/dev/null)"; then
      if smh_field "$reply" conflict >/dev/null; then
        conflict="$(smh_field "$reply" conflict || true)"
        if [ "$mode" = "contains" ]; then
          case ",$conflict," in *",$COMPETITOR_BID,"*) printf '%s' "$(( $(now_ms) - start ))"; return 0 ;; esac
        elif [ -z "$conflict" ]; then
          printf '%s' "$(( $(now_ms) - start ))"; return 0
        fi
      else
        conflict="<no conflict field>"
      fi
    fi
    if [ $(( $(now_ms) - start )) -ge "$timeout_ms" ]; then
      printf 'conflict=[%s]' "$conflict"
      return 1
    fi
    sleep 0.25 || true
  done
}

# quit_competitor: polite quit, then TERM and KILL. 0 when it is gone.
quit_competitor() {
  quit_bid "$COMPETITOR_BID"
  if wait_gone exact FixtureCompetitor 5; then return 0; fi
  term_then_kill exact FixtureCompetitor
}

case_16() {
  local t0 ok=1 detail="" out="" ms_on="" ms_off="" ms_paused="" user_paused=0 reply="" state="" magenta=""
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  # Part 1: a running competitor pauses SMH, and its quit hides again.
  if [ "$ok" -eq 1 ]; then
    if ! launch_app "$COMPETITOR_APP"; then ok=0; detail="FixtureCompetitor launch failed"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if out="$(wait_conflict contains 3000)"; then ms_on="$out"; else ok=0; detail="no conflict within 3 s ($out)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! out="$(wait_smh_state expanded no 3000)"; then ok=0; detail="not expanded with applied=no within 3 s while the competitor runs ($out)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! out="$(probe_wait "$MAGENTA" visible 3000)"; then ok=0; detail="magenta not VISIBLE within 3 s while the competitor runs ($out)"; fi
  fi
  if ! quit_competitor; then
    if [ "$ok" -eq 1 ]; then ok=0; detail="FixtureCompetitor did not quit"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if out="$(wait_conflict empty 3000)"; then ms_off="$out"; else ok=0; detail="conflict not empty 3 s after quit ($out)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! out="$(wait_smh_state collapsed yes 3000)"; then ok=0; detail="not collapsed with applied=yes within 3 s after the competitor quit ($out)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! out="$(probe_wait "$MAGENTA" hidden 3000)"; then ok=0; detail="magenta not HIDDEN within 3 s after the competitor quit ($out)"; fi
  fi
  # Part 2: the user's own pause stays on after a competitor comes and goes.
  if [ "$ok" -eq 1 ]; then
    user_paused=1
    if ! reply="$("$SMHCTL" pause --timeout-ms 5000 2>>"$RESULTS_FILE")"; then ok=0; detail="pause got no reply"; fi
    note "  pause: $reply"
  fi
  if [ "$ok" -eq 1 ]; then
    if ! out="$(wait_smh_state expanded no 3000)"; then ok=0; detail="pause did not expand ($out)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! launch_app "$COMPETITOR_APP"; then ok=0; detail="FixtureCompetitor second launch failed"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! out="$(wait_conflict contains 3000)"; then ok=0; detail="no conflict within 3 s while paused ($out)"; fi
  fi
  if ! quit_competitor; then
    if [ "$ok" -eq 1 ]; then ok=0; detail="FixtureCompetitor did not quit (second time)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! out="$(wait_conflict empty 3000)"; then ok=0; detail="conflict not empty 3 s after the second quit ($out)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    # Give a wrong resume time to happen before checking that it did not.
    sleep 1 || true
    reply="$(smh_state_reply || true)"
    state="$(smh_field "$reply" state || true)"
    magenta="$(probe_now "$MAGENTA")"
    if [ "$state" != "expanded" ] || [ "$magenta" != "VISIBLE" ]; then
      ok=0; detail="the user's pause did not hold after the competitor quit: state=[$state] magenta=$magenta"
    fi
  fi
  if [ "$user_paused" -eq 1 ]; then
    if ! reply="$("$SMHCTL" resume --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
      if [ "$ok" -eq 1 ]; then ok=0; detail="resume got no reply"; fi
    fi
    note "  resume: $reply"
  fi
  if [ "$ok" -eq 1 ]; then
    if out="$(wait_smh_state collapsed yes 3000)"; then ms_paused="$out"; else ok=0; detail="resume did not collapse within 3 s ($out)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! out="$(probe_wait "$MAGENTA" hidden 3000)"; then ok=0; detail="magenta not HIDDEN within 3 s after resume ($out)"; fi
  fi
  finish_case "$ok" "16 competing hider pauses SMH; the user's pause holds" "$t0" \
    "seen in ${ms_on} ms, cleared in ${ms_off} ms, user pause held, resume collapsed in ${ms_paused} ms" "$detail"
}

# ------------------------------------------------------------------- case 19 ---
# The debug command failNextApplies makes applies fail before the shim, so
# this checks the real retry path: icons show while failing, then the retry
# (2 s, then 5 s, then 15 s) hides them again.
case_19() {
  local t0 ok=1 detail="" out="" reply="" state="" applied="" fail_ms="" left_ms=0 pass="" \
    start=0 now=0 elapsed=0 samples=0 recovered_ms="" magenta=""
  t0=$(now_ms)
  if ! ensure_collapsed >/dev/null; then ok=0; detail="could not collapse hiding FixtureOne"; fi
  # Part 1: one failed apply, then the 2 s retry recovers.
  if [ "$ok" -eq 1 ]; then
    if ! fail_next_applies 1; then ok=0; detail="failNextApplies 1 could not be sent"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    # setHidden with the same set still asks for an apply, and that apply fails.
    if ! reply="$("$SMHCTL" setHidden "$ONE_BID" --timeout-ms 5000 2>>"$RESULTS_FILE")"; then ok=0; detail="setHidden got no reply"; fi
    fail_ms=$(now_ms)
    note "  after failNextApplies 1: $reply"
    state="$(smh_field "$reply" state || true)"
    applied="$(smh_field "$reply" applied || true)"
  fi
  if [ "$ok" -eq 1 ]; then
    case "$state" in
      "unavailable:Hiding failed"*) ;;
      *) ok=0; detail="expected state unavailable with applyFailed, got state=[$state]" ;;
    esac
    if [ "$ok" -eq 1 ] && [ "$applied" != "no" ]; then ok=0; detail="expected applied=no after the failure, got [$applied]"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! out="$(probe_wait "$MAGENTA" visible 2000)"; then ok=0; detail="magenta not VISIBLE within 2 s after the failure ($out)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    left_ms=$(( 4000 - ($(now_ms) - fail_ms) ))
    if [ "$left_ms" -lt 1 ]; then left_ms=1; fi
    if ! out="$(wait_smh_state collapsed yes "$left_ms")"; then ok=0; detail="not collapsed within 4 s after the failure ($out)"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    left_ms=$(( 4000 - ($(now_ms) - fail_ms) ))
    if [ "$left_ms" -lt 1 ]; then left_ms=1; fi
    if out="$(probe_wait "$MAGENTA" hidden "$left_ms")"; then
      pass="1 failure: hidden again after $(( $(now_ms) - fail_ms )) ms"
    else
      ok=0; detail="magenta not HIDDEN within 4 s after the failure ($out)"
    fi
  fi
  # Part 2: three failures. The retries come 2 s, then 5 s, then 15 s apart,
  # so the third retry (about 22 s after the first failure) is the first that
  # works. Until then the icons must stay visible.
  if [ "$ok" -eq 1 ]; then
    if ! fail_next_applies 3; then ok=0; detail="failNextApplies 3 could not be sent"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    if ! reply="$("$SMHCTL" setHidden "$ONE_BID" --timeout-ms 5000 2>>"$RESULTS_FILE")"; then ok=0; detail="setHidden got no reply (3 failures)"; fi
    note "  after failNextApplies 3: $reply"
    state="$(smh_field "$reply" state || true)"
    case "$state" in
      "unavailable:Hiding failed"*) ;;
      *) if [ "$ok" -eq 1 ]; then ok=0; detail="expected state unavailable after the first of 3 failures, got state=[$state]"; fi ;;
    esac
  fi
  if [ "$ok" -eq 1 ]; then
    start=$(now_ms)
    while :; do
      now=$(now_ms)
      elapsed=$(( now - start ))
      reply="$(smh_state_reply || true)"
      state="$(smh_field "$reply" state || true)"
      applied="$(smh_field "$reply" applied || true)"
      if [ "$state" = "collapsed" ] && [ "$applied" = "yes" ]; then
        recovered_ms="$elapsed"
        break
      fi
      case "$state" in
        "unavailable:"*)
          samples=$((samples + 1))
          magenta="$(probe_now "$MAGENTA")"
          if [ "$magenta" != "VISIBLE" ]; then
            ok=0; detail="magenta was $magenta while SMH was failing, $elapsed ms after the first failure"; break
          fi
          ;;
      esac
      if [ "$elapsed" -ge 30000 ]; then
        ok=0; detail="not collapsed within 30 s after 3 failures (state=[$state] applied=[$applied])"; break
      fi
      sleep 0.5 || true
    done
  fi
  if [ "$ok" -eq 1 ] && [ "$recovered_ms" -lt 20000 ]; then
    ok=0; detail="recovered after $recovered_ms ms, before the third retry (about 22 s): the backoff was not used"
  fi
  if [ "$ok" -eq 1 ]; then
    if out="$(probe_wait "$MAGENTA" hidden 3000)"; then
      pass="$pass; 3 failures: VISIBLE in all $samples checks while failing, hidden again after $recovered_ms ms"
    else
      ok=0; detail="magenta not HIDDEN within 3 s after recovery ($out)"
    fi
  fi
  # Never leave planned failures behind for a later case.
  fail_next_applies 0 || true
  finish_case "$ok" "19 apply failure recovers" "$t0" "$pass" "$detail"
}

# ------------------------------------------------------------------- reset ---
step_reset() {
  local t0 ok=1 reply="" state=""
  t0=$(now_ms)
  if [ -n "$(smh_pids)" ]; then
    if reply="$("$SMHCTL" setHidden "" --timeout-ms 5000 2>>"$RESULTS_FILE")"; then
      state="$(smh_field "$reply" state || true)"
      if [ "$state" != "expanded" ]; then ok=0; fi
    else
      ok=0
    fi
  fi
  if ! stop_smh; then ok=0; fi
  quit_bid "$ONE_BID"
  quit_bid "$WIDE_BID"
  quit_bid "$FLICKER_BID"
  quit_bid "$COMPETITOR_BID"
  local name
  for name in FixtureOne FixtureWide FixtureFlicker FixtureCompetitor; do
    if ! wait_gone exact "$name" 5; then ok=0; fi
  done
  finish_case "$ok" "reset and quit all" "$t0" "" "reply=[$reply]"
}

print_manual() {
  log "MANUAL (not run by this script; write results in docs/test-log.md):"
  log "  4  Sleep and wake, screen lock, fast user switching: state is right afterwards."
  log "  5  Reboot with launch at login, three times: SMH still hides correctly."
  log "  12 Revoke Accessibility while running: SMH stops hiding, restores icons, shows the warning."
  log "  17 While collapsed, click the clock (Notification Center) and Control Center; Spotlight and Siri still open."
  log "  18 Full-screen app, menu bar auto-hide, two displays, notched MacBook."
}

main() {
  log "ADV start $(date -u +%Y-%m-%dT%H:%M:%SZ) quick=$QUICK results=$RESULTS_FILE"
  if ! step_prereq; then
    log "ADV FAIL $FAILED/$TOTAL"
    exit 2
  fi
  save_prefs
  # From here on the run may change SMH's settings; cleanup puts them back.
  PREFS_TOUCHED=1
  step_clean_start
  case_1
  case_2
  case_3
  case_6
  case_7
  case_8
  case_9a
  case_9b
  case_10
  case_11
  case_13
  case_14
  case_15
  case_16
  case_19
  step_reset
  print_manual
  if [ "$FAILED" -eq 0 ]; then
    log "ADV PASS $TOTAL/$TOTAL"
  else
    log "ADV FAIL $FAILED/$TOTAL"
    exit 1
  fi
}

main
