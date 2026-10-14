#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
bash -n "$here/build.sh"
bash -n "$here/m0-experiments.sh"
bash "$here/build.sh"
[[ -x "$here/build/smh-spike" ]]
[[ -x "$here/build/FixtureOne.app/Contents/MacOS/FixtureOne" ]]
probe="$("$here/build/smh-spike" probe)"
for text in 'class MBAssessmentModeConfiguration: found' 'class MBAssessmentModeAssertion: found' 'selector initWithAllowedSystemItems:allowedBundleIdentifiers:: found' 'selector activateWithConfiguration:completionHandler:: found' 'selector invalidate: found'; do
    printf '%s\n' "$probe" | grep -Fq "$text"
done
visible_output="$("$here/build/smh-spike" visible 2>&1)" && visible_status=0 || visible_status=$?
if (( visible_status == 7 )); then
    [[ "$visible_output" == *'capture'* ]] || { echo "FAIL visible capture error missing: $visible_output"; exit 1; }
elif (( visible_status == 0 || visible_status == 1 )); then
    [[ "$visible_output" =~ (VISIBLE|HIDDEN)\ [0-9]+ ]] || { echo "FAIL visible output: $visible_output"; exit 1; }
else
    echo "FAIL visible exit $visible_status: $visible_output"
    exit 1
fi
python3 "$here/tests/test_visible_color.py"
printf 'PASS build, scripts, classes, selectors, and visible command\n'
