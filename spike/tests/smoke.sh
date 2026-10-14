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
printf 'PASS build, scripts, classes, and selectors\n'
