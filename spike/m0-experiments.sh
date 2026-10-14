#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/build/smh-spike"
source_app="$here/build/FixtureOne.app"
target_app='/Applications/FixtureOne.app'
fixture_id='dev.yili.smh.fixture.one'

# Complete these checks before launch, copy, or assertion activation.
for command_name in cp open kill date mkdir mktemp sleep cat grep awk stat ps tee rm dirname pwd python3 osascript; do
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
now_iso() { python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'))"; }
now_ms() { python3 -c "import time; print(time.time_ns() // 1000000)"; }

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
    "$tool" hold --hide "$1" >"$hold_output" 2>&1 &
    hold_pid=$!
    for ((j=0; j<100; j++)); do
        if grep -q '^ACTIVE ' "$hold_output"; then return 0; fi
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
    return 0
}
read_count() {
    local line
    if [[ -n "$1" ]]; then line="$("$tool" count --since "$1" 2>&1)" || return 1
    else line="$("$tool" count 2>&1)" || return 1; fi
    [[ "$line" =~ ^COUNT\ ([0-9]+)$ ]] || return 1
    REPLY="${BASH_REMATCH[1]}"
}
wait_count() {
    local since="$1" target="$2" relation="$3" deadline=$(( $(now_ms) + 10000 ))
    while (( $(now_ms) < deadline )); do
        if read_count "$since"; then
            if (( $(now_ms) >= deadline )); then return 1; fi
            if [[ "$relation" == eq && "$REPLY" -eq "$target" ]] ||
               [[ "$relation" == lt && "$REPLY" -lt "$target" ]] ||
               [[ "$relation" == gt && "$REPLY" -gt "$target" ]]; then return 0; fi
        fi
        sleep 0.1
    done
    return 1
}
fixture_owner() {
    local output
    output="$("$tool" owners --check "$fixture_id")" || return 1
    if printf '%s\n' "$output" | grep -q '^AX: not trusted$'; then return 2; fi
    printf '%s\n' "$output" | grep -q "^OWNER $fixture_id "
}

record "RESULTS $(now_iso)"
record 'PASS probe'
if [[ ! -d "$target_app" || "$source_app/Contents/MacOS/FixtureOne" -nt "$target_app/Contents/MacOS/FixtureOne" ]]; then
    cp -R "$source_app/." "$target_app/"
    record "COPIED $target_app"
fi
open -g "$target_app"
owner_ready=0
for ((j=0; j<100; j++)); do
    if fixture_owner; then owner_ready=1; break; else owner_status=$?; fi
    if (( owner_status == 2 )); then
        record 'AX: not trusted; owner checks skipped'
        owner_ready=1
        break
    fi
    sleep 0.1
done
if (( owner_ready == 0 )); then record 'FAIL fixture did not appear in owners'; exit 1; fi

fail=0
for ((i=1; i<=20; i++)); do
    if ! read_count ""; then record "FAIL cycle $i baseline count unknown"; fail=1; break; fi
    baseline="$REPLY"
    if ! start_hold "$fixture_id"; then fail=1; break; fi
    active="$(awk '/^ACTIVE / {print $2; exit}' "$hold_output")"
    if wait_count "$active" "$baseline" lt; then held="$REPLY"; else held='unknown'; fi
    owner_check='skipped'
    if fixture_owner; then owner_check='visible'; else
        owner_status=$?
        if (( owner_status == 1 )); then owner_check='gone'; fi
    fi
    if ! release_hold; then fail=1; break; fi
    released="$(awk '/^RELEASED / {print $2; exit}' "$hold_output")"
    if wait_count "$released" "$baseline" eq; then restored="$REPLY"; else restored='unknown'; fi
    if [[ "$held" != unknown && "$restored" != unknown && "$owner_check" != visible ]]; then
        record "PASS cycle $i baseline=$baseline held=$held restored=$restored ax=$owner_check"
    else
        record "FAIL cycle $i baseline=$baseline held=$held restored=$restored ax=$owner_check"
        fail=1
    fi
    cleanup_hold
done

if (( fail == 0 )); then
    if read_count ""; then
        baseline="$REPLY"
        if start_hold "$fixture_id"; then
            active="$(awk '/^ACTIVE / {print $2; exit}' "$hold_output")"
            if wait_count "$active" "$baseline" lt; then
                kill_started="$(now_ms)"
                kill -KILL "$hold_pid"
                wait "$hold_pid" 2>/dev/null || true
                hold_pid=''
                if wait_count "$(now_iso)" "$baseline" eq; then
                    elapsed=$(( $(now_ms) - kill_started ))
                    record "PASS kill-9 recovery_ms=$elapsed baseline=$baseline restored=$REPLY"
                else record 'FAIL kill-9 did not restore baseline in 10 seconds'; fail=1; fi
            else record 'FAIL kill-9 hold did not lower count'; fail=1; fi
        else fail=1; fi
        cleanup_hold
    else record 'FAIL kill-9 baseline count unknown'; fail=1; fi
fi

if (( fail == 0 )); then
    # Quit through AppleScript so the status item is removed before this check.
    if ! osascript -e 'tell application id "dev.yili.smh.fixture.one" to quit' >/dev/null 2>&1; then record 'FAIL fixture quit command'; fail=1; fi
    if (( fail == 0 )); then
        sleep 1
        if read_count ""; then
            before="$REPLY"
            if start_hold ''; then
                launch_since="$(now_iso)"
                open -g "$target_app"
                launch_started="$(now_ms)"
                appeared=0
                while (( $(now_ms) - launch_started < 3000 )); do
                    if read_count "$launch_since" && (( REPLY > before )) && (( $(now_ms) - launch_started <= 3000 )); then appeared=1; break; fi
                    sleep 0.1
                done
                if (( appeared )); then record "PASS launch-while-active baseline=$before appeared=$REPLY elapsed_ms=$(( $(now_ms) - launch_started ))";
                else record "FAIL launch-while-active baseline=$before no count rise in 3 seconds"; fail=1; fi
                release_hold || fail=1
                cleanup_hold
            else fail=1; fi
        else record 'FAIL launch-while-active baseline count unknown'; fail=1; fi
    fi
fi

record 'MANUAL: Click Notification Center while hold is active and check that it opens.'
record 'MANUAL: Restart MenuBarAgent while hold is active and check hiding and recovery.'
record 'MANUAL: Repeat on two displays and check both menu bars.'
record "RESULTS FILE $result"
if (( fail )); then exit 1; fi
record 'PASS all automated experiments'
