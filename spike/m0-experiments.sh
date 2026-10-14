#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/build/smh-spike"
source_app="$here/build/FixtureOne.app"
target_app='/Applications/FixtureOne.app'
fixture_id='dev.yili.smh.fixture.one'

# Check inputs before any side effects.
for command_name in cp open kill date mkdir mktemp sleep cat grep awk tee rm dirname pwd python3 osascript sort pgrep; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "FAIL missing tool: $command_name" >&2; exit 1; }
done
[[ -x "$tool" ]] || { echo "FAIL missing $tool" >&2; exit 1; }
[[ -d "$source_app" && -x "$source_app/Contents/MacOS/FixtureOne" ]] || { echo "FAIL missing $source_app" >&2; exit 1; }
[[ -d /Applications && -w /Applications ]] || { echo 'FAIL /Applications is not writable' >&2; exit 1; }
[[ ! -e "$target_app" || -d "$target_app" ]] || { echo "FAIL $target_app is not an app directory" >&2; exit 1; }
"$tool" probe >/dev/null || { echo 'FAIL probe' >&2; exit 1; }

mkdir -p "$here/results"
result="$here/results/m0-$(date -u +%Y%m%dT%H%M%S).txt"
: > "$result"
record() { printf '%s\n' "$*" | tee -a "$result"; }
now_ms() { python3 -c 'import time; print(time.time_ns() // 1000000)'; }
stamp_ms() { python3 -c 'from datetime import datetime; import sys; print(int(datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp() * 1000))' "$1"; }

hold_pid=''
hold_output=''
cleanup_hold() {
    if [[ -n "$hold_pid" ]] && kill -0 "$hold_pid" 2>/dev/null; then
        kill -TERM "$hold_pid" 2>/dev/null || true
        for ((j=0; j<50; j++)); do
            kill -0 "$hold_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$hold_pid" 2>/dev/null; then kill -KILL "$hold_pid" 2>/dev/null || true; fi
        wait "$hold_pid" 2>/dev/null || true
    fi
    hold_pid=''
    if [[ -n "$hold_output" ]]; then rm -f "$hold_output"; hold_output=''; fi
}
trap cleanup_hold EXIT

start_hold() {
    hold_output="$(mktemp)"
    "$tool" hold --hide "$1" "${@:2}" >"$hold_output" 2>&1 &
    hold_pid=$!
    for ((j=0; j<100; j++)); do
        if grep -q '^ACTIVE ' "$hold_output"; then
            active_ms="$(stamp_ms "$(awk '/^ACTIVE / {print $2; exit}' "$hold_output")")"
            return 0
        fi
        if ! kill -0 "$hold_pid" 2>/dev/null; then
            record "FAIL hold exited before ACTIVE: $(cat "$hold_output")"
            wait "$hold_pid" 2>/dev/null || true
            hold_pid=''
            return 1
        fi
        sleep 0.1
    done
    record 'FAIL hold did not become ACTIVE in 10 seconds'
    return 1
}
release_hold() {
    [[ -n "$hold_pid" ]] || return 1
    kill -TERM "$hold_pid" || return 1
    local status=0
    wait "$hold_pid" || status=$?
    hold_pid=''
    if (( status != 0 )) || ! grep -q '^RELEASED ' "$hold_output"; then
        record "FAIL hold did not release cleanly (exit $status): $(cat "$hold_output")"
        return 1
    fi
    released_ms="$(stamp_ms "$(awk '/^RELEASED / {print $2; exit}' "$hold_output")")"
}
read_visible() {
    local output status
    output="$("$tool" visible 2>&1)" && status=0 || status=$?
    if (( status == 0 )) && [[ "$output" == *"VISIBLE "* ]]; then visible_state=VISIBLE
    elif (( status == 1 )) && [[ "$output" == *"HIDDEN "* ]]; then visible_state=HIDDEN
    else record "FAIL visible probe (exit $status): $output"; return 2; fi
}
wait_state() {
    local wanted="$1" started="$2" deadline=$(( $2 + 3000 )) observed
    while :; do
        read_visible || return 2
        observed="$(now_ms)"
        if [[ "$visible_state" == "$wanted" ]] && (( observed <= deadline )); then
            REPLY=$(( observed - started ))
            return 0
        fi
        if (( observed >= deadline )); then return 1; fi
        sleep 0.1
    done
}
quit_fixture() {
    osascript -e 'tell application id "dev.yili.smh.fixture.one" to quit' >/dev/null 2>&1 || return 1
    wait_state HIDDEN "$(now_ms)"
}
latency_summary() {
    local label="$1"; shift
    if (( $# != 20 )); then record "FAIL $label summary has $# of 20 samples"; return; fi
    local sorted=()
    while IFS= read -r value; do sorted+=("$value"); done < <(printf '%s\n' "$@" | sort -n)
    record "$label min=${sorted[0]} median=$(( (sorted[9] + sorted[10]) / 2 )) max=${sorted[19]} ms"
}

record "RESULTS $(date -u +%Y-%m-%dT%H:%M:%SZ)"
record 'PASS probe'
if [[ ! -d "$target_app" || "$source_app/Contents/MacOS/FixtureOne" -nt "$target_app/Contents/MacOS/FixtureOne" ]]; then
    mkdir -p "$target_app"
    cp -R "$source_app/." "$target_app/"
    record "COPIED $target_app"
fi
open -g "$target_app"
if ! wait_state VISIBLE "$(now_ms)"; then record 'FAIL fixture was not visible within 3 seconds'; exit 1; fi

fail=0
hide_samples=()
restore_samples=()
for ((i=1; i<=20; i++)); do
    if ! start_hold "$fixture_id"; then fail=1; break; fi
    hide_ms='timeout'
    if wait_state HIDDEN "$active_ms"; then hide_ms="$REPLY"; hide_samples+=("$REPLY"); fi
    if ! release_hold; then fail=1; cleanup_hold; break; fi
    restore_ms='timeout'
    if wait_state VISIBLE "$released_ms"; then restore_ms="$REPLY"; restore_samples+=("$REPLY"); fi
    if [[ "$hide_ms" == timeout || "$restore_ms" == timeout ]]; then
        record "FAIL cycle $i hide_ms=$hide_ms restore_ms=$restore_ms"
        fail=1
    else
        record "PASS cycle $i hide_ms=$hide_ms restore_ms=$restore_ms"
    fi
    cleanup_hold
done
latency_summary hide "${hide_samples[@]}"
latency_summary restore "${restore_samples[@]}"

if (( fail == 0 )); then
    if start_hold "$fixture_id"; then
        if wait_state HIDDEN "$active_ms"; then
            kill_started="$(now_ms)"
            kill -KILL "$hold_pid"
            wait "$hold_pid" 2>/dev/null || true
            hold_pid=''
            if wait_state VISIBLE "$kill_started"; then record "PASS kill-9 recovery_ms=$REPLY"
            else record 'FAIL kill-9 fixture did not become visible within 3 seconds'; fail=1; fi
        else record 'FAIL kill-9 fixture did not hide'; fail=1; fi
        cleanup_hold
    else fail=1; fi
fi

if (( fail == 0 )); then
    if ! quit_fixture; then record 'FAIL fixture did not quit or stay hidden'; fail=1
    elif start_hold ''; then
        launch_started="$(now_ms)"
        open -g "$target_app"
        if wait_state VISIBLE "$launch_started"; then record "PASS launch-while-active visible_ms=$REPLY"
        else record 'FAIL launch-while-active fixture did not become visible within 3 seconds'; fail=1; fi
        release_hold || fail=1
        cleanup_hold
    else fail=1; fi
fi

if (( fail == 0 )); then
    if ! quit_fixture; then record 'FAIL fixture did not quit before late hide'; fail=1
    elif start_hold "$fixture_id"; then
        launch_started="$(now_ms)"
        open -g "$target_app"
        late_hidden=1
        deadline=$(( launch_started + 3000 ))
        while :; do
            if ! read_visible; then late_hidden=0; break; fi
            if [[ "$visible_state" != HIDDEN ]]; then late_hidden=0; break; fi
            if (( $(now_ms) >= deadline )); then break; fi
            sleep 0.1
        done
        if ! pgrep -x FixtureOne >/dev/null; then late_hidden=0; record 'FAIL late-hide fixture did not launch'; fi
        if (( late_hidden )); then record 'PASS late-hide stayed hidden for 3 seconds'
        else record 'FAIL late-hide became visible, did not launch, or capture failed'; fail=1; fi
        release_hold || fail=1
        cleanup_hold
        if ! wait_state VISIBLE "$(now_ms)"; then record 'FAIL fixture did not restore after late hide'; fail=1; fi
    else fail=1; fi
fi

if (( fail == 0 )); then
    if start_hold "$fixture_id" --release-after 2 --linger 5; then
        if ! wait_state HIDDEN "$active_ms"; then record 'FAIL release-without-exit did not hide'; fail=1; fi
        released_found=0
        deadline=$(( active_ms + 5000 ))
        while (( $(now_ms) < deadline )); do
            if grep -q '^RELEASED ' "$hold_output"; then released_found=1; break; fi
            if ! kill -0 "$hold_pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if (( released_found )); then
            released_ms="$(stamp_ms "$(awk '/^RELEASED / {print $2; exit}' "$hold_output")")"
            if wait_state VISIBLE "$released_ms" && kill -0 "$hold_pid" 2>/dev/null; then
                record "PASS release-without-exit visible_ms=$REPLY process_alive=yes"
            else record 'FAIL release-without-exit did not restore while process lived'; fail=1; fi
        else record 'FAIL release-without-exit missing RELEASED'; fail=1; fi
        linger_status=0
        wait "$hold_pid" || linger_status=$?
        hold_pid=''
        if (( linger_status != 0 )) || ! grep -q '^EXITING ' "$hold_output"; then
            record "FAIL release-without-exit did not exit cleanly (exit $linger_status)"
            fail=1
        fi
        cleanup_hold
    else fail=1; fi
fi

record 'MANUAL: Click the clock during release-without-exit linger and check that it opens.'
record 'MANUAL: Restart MenuBarAgent while hold is active and check hiding and recovery.'
record 'MANUAL: Repeat on two displays and check both menu bars.'
record "RESULTS FILE $result"
if (( fail )); then exit 1; fi
record 'PASS all automated experiments'
