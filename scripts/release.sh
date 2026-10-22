#!/usr/bin/env bash
set -Eeuo pipefail

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
for tool in git xcodegen xcodebuild codesign ditto hdiutil xcrun spctl shasum rg python3 file find sort; do
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
dmg="$release_dir/SimpleMenubarHider-$version.dmg"
signing_identity='Developer ID Application: Yi Li (8Q5V8XK85Y)'

step='clean release folder'
[[ -n "$repo_root" && "$repo_root" != / ]] || fail "bad repo root: $repo_root"
[[ "$release_dir" == "$repo_root/build/release" && "$release_dir" == */build/release ]] || fail "refusing to delete unexpected path: $release_dir"
if [[ -e "$release_dir" ]]; then
  rm -rf -- "$release_dir"
fi
[[ ! -e "$release_dir" ]] || fail "could not delete $release_dir"
mkdir -p "$release_dir"
pass

# Print every Mach-O file under the app, deepest path first, one per line.
list_macho() {
  local path
  find "$app" -type f -print0 | while IFS= read -r -d '' path; do
    if [[ "$(file -b -- "$path")" == *'Mach-O'* ]]; then
      printf '%s\t%s\n' "$(tr -cd / <<< "$path" | wc -c | tr -d ' ')" "$path"
    fi
  done | sort -t "$(printf '\t')" -k1,1nr | cut -f2-
}

step='generate Xcode project'
xcodegen generate
pass

step='build Release app'
xcodebuild -project SimpleMenubarHider.xcodeproj -scheme SimpleMenubarHider \
  -configuration Release -derivedDataPath "$derived_data" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$commit_count" \
  INFOPLIST_KEY_CFBundleShortVersionString="$version" \
  INFOPLIST_KEY_CFBundleVersion="$commit_count" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS='--timestamp --options=runtime' build
[[ -d "$app" ]] || fail "built app missing: $app"
info="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" == "$version" ]] || fail 'app version does not match VERSION'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" == "$commit_count" ]] || fail 'app build number does not match the git commit count'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$info" 2>/dev/null || true)" == AppIcon ]] || fail 'app icon name missing from Info.plist'
[[ -f "$app/Contents/Resources/AppIcon.icns" && -f "$app/Contents/Resources/Assets.car" ]] || fail 'app icon files missing from Resources'
pass

step='timestamp nested code'
main_executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
[[ -f "$main_executable" ]] || fail "main executable missing: $main_executable"
macho_list="$release_dir/macho-files.txt"
list_macho > "$macho_list"
[[ -s "$macho_list" ]] || fail 'no Mach-O files found in app'
resigned=false
while IFS= read -r path; do
  [[ "$path" != "$main_executable" ]] || continue
  if ! details="$(codesign -dvv -- "$path" 2>&1)" || [[ "$details" != *$'\n''Timestamp='* ]]; then
    printf 'RESIGN: %s\n' "$path"
    codesign --force --timestamp --options runtime --preserve-metadata=entitlements,requirements --sign "$signing_identity" -- "$path"
    resigned=true
  fi
done < "$macho_list"
if [[ "$resigned" == true ]]; then
  printf 'RESIGN: %s\n' "$app"
  codesign --force --timestamp --options runtime --preserve-metadata=entitlements,requirements --sign "$signing_identity" -- "$app"
fi
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
list_macho > "$macho_list"
[[ -s "$macho_list" ]] || fail 'no Mach-O files found in app'
bad_signature=false
while IFS= read -r path; do
  if ! details="$(codesign -dvv -- "$path" 2>&1)"; then
    printf 'BAD SIGNATURE: %s: not signed\n' "$path" >&2
    bad_signature=true
    continue
  fi
  if ! path_entitlements="$(codesign -d --entitlements - -- "$path" 2>&1)"; then
    printf 'BAD SIGNATURE: %s: cannot read entitlements\n' "$path" >&2
    bad_signature=true
  elif [[ "$path_entitlements" == *'com.apple.security.get-task-allow'* ]]; then
    printf 'BAD SIGNATURE: %s: has com.apple.security.get-task-allow\n' "$path" >&2
    bad_signature=true
  fi
  if [[ "$details" != *$'\n''Timestamp='* ]]; then
    printf 'BAD SIGNATURE: %s: no secure timestamp\n' "$path" >&2
    bad_signature=true
  fi
  if [[ "$details" != *'flags='*'(runtime)'* ]]; then
    printf 'BAD SIGNATURE: %s: hardened runtime flag is missing\n' "$path" >&2
    bad_signature=true
  fi
  if [[ "$details" != *$'\n'"Authority=$signing_identity"$'\n'* ]]; then
    printf 'BAD SIGNATURE: %s: authority is not %s\n' "$path" "$signing_identity" >&2
    bad_signature=true
  fi
done < "$macho_list"
[[ "$bad_signature" == false ]] || fail 'Mach-O signature checks failed'
signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
[[ "$signature" == *'Authority=Developer ID Application:'* ]] || fail 'signature is not Developer ID Application'
[[ "$signature" == *'TeamIdentifier=8Q5V8XK85Y'* ]] || fail 'signature has the wrong team'
[[ "$signature" == *'flags='*'(runtime)'* ]] || fail 'hardened runtime flag is missing'
entitlements="$(codesign -d --entitlements - "$app" 2>&1)"
[[ "$entitlements" != *'com.apple.security.app-sandbox'* ]] || fail 'app has a sandbox entitlement'
pass

submit_for_notarization() {
  local artifact="$1" submission submission_id status
  if ! submission="$(xcrun notarytool submit "$artifact" --keychain-profile "$profile" --wait --output-format json)"; then
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
}

if "$notarize"; then
  step='create temporary notary zip'
  mkdir -p "$release_dir/notary"
  notary_zip="$release_dir/notary/SimpleMenubarHider-$version.zip"
  ditto -c -k --keepParent "$app" "$notary_zip"
  [[ -s "$notary_zip" ]] || fail "zip missing: $notary_zip"
  pass

  step='notarize app'
  submit_for_notarization "$notary_zip"
  pass

  step='staple app'
  xcrun stapler staple "$app"
  pass

  step='validate stapled app'
  xcrun stapler validate "$app"
  spctl --assess --type execute -vv "$app"
  pass

  step='remove temporary notary zip'
  rm "$notary_zip"
  rmdir "$release_dir/notary"
  pass
else
  printf 'PASS: notarize and staple skipped (--no-notarize)\n'
fi

step='create DMG'
staging="$release_dir/dmg-staging"
mkdir -p "$staging"
ditto "$app" "$staging/Simple Menubar Hider.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Simple Menubar Hider" -srcfolder "$staging" -ov -format UDZO "$dmg"
[[ -s "$dmg" ]] || fail "DMG missing: $dmg"
rm -r "$staging"
pass

step='sign DMG'
codesign --force --timestamp --sign "$signing_identity" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
pass

if "$notarize"; then
  step='notarize DMG'
  submit_for_notarization "$dmg"
  pass

  step='staple DMG'
  xcrun stapler staple "$dmg"
  pass

  step='validate stapled DMG'
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature -vv "$dmg"
  pass
fi

verify_mounted_app() {
  local mounted_app="$mount_dir/Simple Menubar Hider.app"
  [[ -d "$mounted_app" ]] || { printf 'Missing app in DMG: %s\n' "$mounted_app" >&2; return 1; }
  [[ -L "$mount_dir/Applications" && "$(readlink "$mount_dir/Applications")" == /Applications ]] || {
    printf 'Missing Applications link in DMG\n' >&2
    return 1
  }
  codesign --verify --deep --strict "$mounted_app" || return 1
  if "$notarize"; then
    xcrun stapler validate "$mounted_app" || return 1
  fi
}

step='verify DMG contents'
mount_dir="$(mktemp -d "$release_dir/dmg-mount.XXXXXX")"
detach_on_exit() { hdiutil detach -force "$mount_dir" >/dev/null 2>&1 || true; }
trap detach_on_exit EXIT
trap 'exit 130' INT TERM
if ! hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount_dir" "$dmg"; then
  fail 'could not attach DMG'
fi
verified=true
if ! verify_mounted_app; then verified=false; fi
if ! hdiutil detach "$mount_dir"; then fail 'could not detach DMG'; fi
trap - EXIT INT TERM
rmdir "$mount_dir"
[[ "$verified" == true ]] || fail 'DMG contents failed verification'
pass

step='ZIP guard'
[[ -z "$(find "$release_dir" -name '*.zip' -print -quit)" ]] || fail 'ZIP file remains under release folder'
pass

step='SHA-256'
shasum -a 256 "$dmg"
pass
printf 'Next commands (run after review):\n'
printf '  git tag v%s\n' "$version"
printf '  gh release create v%s %q --draft --title %q\n' "$version" "$dmg" "v$version"
