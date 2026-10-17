#!/usr/bin/env bash
set -euo pipefail

step='input checks'
trap 'result=$?; printf "FAIL: %s (exit %s)\n" "$step" "$result" >&2' ERR
pass() { printf 'PASS: %s\n' "$step"; }
fail() { printf 'FAIL: %s: %s\n' "$step" "$1" >&2; exit 1; }

version=''
notarize=true
for argument in "$@"; do
  case "$argument" in
    --no-notarize) notarize=false ;;
    *)
      if [[ -n "$version" ]]; then
        fail 'usage: scripts/release.sh VERSION [--no-notarize]'
      fi
      version="$argument"
      ;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'VERSION must look like 0.1.0'
pass

step='tool checks'
for tool in git xcodegen xcodebuild codesign ditto xcrun spctl shasum rg python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail 'missing tool: /usr/libexec/PlistBuddy'
pass

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
step='git checks'
[[ -z "$(git status --porcelain)" ]] || fail 'git tree is not clean; commit or remove local changes before releasing'
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  fail "tag v$version already exists"
fi
commit_count="$(git rev-list --count HEAD)"
[[ "$commit_count" =~ ^[0-9]+$ && "$commit_count" -gt 0 ]] || fail 'cannot read git commit count'
pass

profile="${NOTARY_PROFILE:-smh-notary}"
if "$notarize"; then
  step='notary profile check'
  if ! xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null; then
    fail "notary profile '$profile' is unavailable. Store it with: xcrun notarytool store-credentials $profile --apple-id <email> --team-id 8Q5V8XK85Y"
  fi
  pass
fi

release_dir="$repo_root/build/release"
derived_data="$release_dir/DerivedData"
app="$derived_data/Build/Products/Release/Simple Menubar Hider.app"
zip="$release_dir/SimpleMenubarHider-$version.zip"
mkdir -p "$release_dir"

step='generate Xcode project'
xcodegen generate
pass

step='build Release app'
xcodebuild -project SimpleMenubarHider.xcodeproj -scheme SimpleMenubarHider \
  -configuration Release -derivedDataPath "$derived_data" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$commit_count" \
  INFOPLIST_KEY_CFBundleShortVersionString="$version" \
  INFOPLIST_KEY_CFBundleVersion="$commit_count" build
[[ -d "$app" ]] || fail "built app missing: $app"
info="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" == "$version" ]] || fail 'app version does not match VERSION'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" == "$commit_count" ]] || fail 'app build number does not match the git commit count'
pass

step='release leak scan'
scan_hits="$release_dir/leak-hits.txt"
leaked=false
for marker in \
  dev.yili.smh.debug.command \
  SMH_DEBUG_FORCE_SHIM_MISSING \
  failNextApplies \
  useTestConfigurationClass \
  dev.yili.smh.fixture.competitor \
  SMH_SHIM_TESTS; do
  if rg -a -l -F -- "$marker" "$app" > "$scan_hits"; then
    while IFS= read -r file; do
      printf 'LEAK: %s: %s\n' "$file" "$marker" >&2
    done < "$scan_hits"
    leaked=true
  else
    result=$?
    [[ "$result" -eq 1 ]] || fail "rg failed while scanning for $marker (exit $result)"
  fi
done
[[ "$leaked" == false ]] || fail 'debug or fixture text found in app'
pass

step='verify code signature'
codesign --verify --deep --strict --verbose=2 "$app"
signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
[[ "$signature" == *'Authority=Developer ID Application:'* ]] || fail 'signature is not Developer ID Application'
[[ "$signature" == *'TeamIdentifier=8Q5V8XK85Y'* ]] || fail 'signature has the wrong team'
[[ "$signature" == *'flags='*'(runtime)'* ]] || fail 'hardened runtime flag is missing'
entitlements="$(codesign -d --entitlements - "$app" 2>&1)"
[[ "$entitlements" != *'com.apple.security.app-sandbox'* ]] || fail 'app has a sandbox entitlement'
pass

step='create zip'
ditto -c -k --keepParent "$app" "$zip"
[[ -s "$zip" ]] || fail "zip missing: $zip"
pass

if "$notarize"; then
  step='notarize zip'
  submission=''
  if ! submission="$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait --output-format json)"; then
    printf '%s\n' "$submission" >&2
    submission_id="$(printf '%s' "$submission" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null || true)"
    if [[ -n "$submission_id" ]]; then xcrun notarytool log "$submission_id" --keychain-profile "$profile" || true; fi
    fail 'notarytool submit failed'
  fi
  submission_id="$(printf '%s' "$submission" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))')"
  status="$(printf '%s' "$submission" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))')"
  if [[ "$status" != Accepted ]]; then
    if [[ -n "$submission_id" ]]; then xcrun notarytool log "$submission_id" --keychain-profile "$profile" || true; fi
    fail "notary status: ${status:-unknown}"
  fi
  pass

  step='staple app'
  xcrun stapler staple "$app"
  pass

  step='validate stapled app'
  xcrun stapler validate "$app"
  spctl --assess --type execute -vv "$app"
  pass

  step='zip stapled app'
  ditto -c -k --keepParent "$app" "$zip"
  [[ -s "$zip" ]] || fail "zip missing: $zip"
  pass
else
  printf 'PASS: notarize and staple skipped (--no-notarize)\n'
fi

step='SHA-256'
shasum -a 256 "$zip"
pass
printf 'Next commands (run after review):\n'
printf '  git tag v%s\n' "$version"
printf '  gh release create v%s %q --draft --title %q\n' "$version" "$zip" "v$version"
