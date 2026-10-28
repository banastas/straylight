#!/usr/bin/env bash
# Builds, signs, notarizes and packages straylight as a DMG in dist/, and keeps
# a copy with its release notes in releases/ (local, not in git). The Sparkle
# update feed and the site arrive in M9.
#
#   scripts/release.sh                  full release
#   scripts/release.sh --skip-notarize  signed but not notarized (dry run)
#
# Release notes come from the "## <version>" section of CHANGELOG.md.
# Notarization reads credentials from a keychain profile (default "straylight",
# override with NOTARY_PROFILE; flatline's profile works too, since it's the
# same team). Create it once with:
#   xcrun notarytool store-credentials straylight --team-id F87BNUZAVJ
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID=F87BNUZAVJ
PROFILE=${NOTARY_PROFILE:-straylight}
NOTARIZE=1
[[ ${1:-} == --skip-notarize ]] && NOTARIZE=0

VERSION=$(awk '/MARKETING_VERSION:/ { print $2; exit }' project.yml)
BUILD=$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' project.yml)
DIST=dist
ARCHIVE=$DIST/straylight.xcarchive
EXPORT=$DIST/export
APP=$EXPORT/straylight.app
DMG=$DIST/straylight-$VERSION.dmg
RELEASES=releases

step() { printf '\n==> %s\n' "$*"; }
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# The CHANGELOG.md section for $VERSION as an HTML fragment: bullets become a
# list, other lines paragraphs. Sparkle embeds fragments without <html>/<body>.
release_notes_html() {
    awk -v version="$VERSION" '
        /^## / { if (found) exit; if (index($0, "## " version) == 1) { found = 1 }; next }
        !found { next }
        /^- / { if (!list) { print "<ul>"; list = 1 }; sub(/^- /, ""); print "  <li>" $0 "</li>"; next }
        NF { if (list) { print "</ul>"; list = 0 }; print "<p>" $0 "</p>" }
        END { if (list) print "</ul>" }
    ' < <(html_escape < CHANGELOG.md)
}
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Submits a file for notarization and waits; prints Apple's log on rejection.
notarize() {
    local result id status
    result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format plist)
    id=$(plutil -extract id raw - <<<"$result")
    status=$(plutil -extract status raw - <<<"$result")
    echo "    submission $id: $status"
    if [[ $status != Accepted ]]; then
        xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        fail "notarization of $1 was not accepted"
    fi
}

IDENTITY=$(security find-identity -v -p codesigning | sed -nE "s/.*\"(Developer ID Application: .*\($TEAM_ID\))\"/\1/p" | head -1)
[[ -n $IDENTITY ]] || fail "no Developer ID Application certificate for team $TEAM_ID in the keychain"
NOTES=$(release_notes_html)
[[ -n $NOTES ]] || fail "CHANGELOG.md has no \"## $VERSION\" section"
if (( NOTARIZE )); then
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
        || fail "no notary credentials in keychain profile '$PROFILE'; run: xcrun notarytool store-credentials $PROFILE --team-id $TEAM_ID"
    [[ ! -e $RELEASES/straylight-$VERSION.dmg ]] \
        || fail "$VERSION is already in $RELEASES/; run scripts/bump-version.sh first"
fi

step "straylight $VERSION ($BUILD), signing as $IDENTITY"
rm -rf "$DIST"
mkdir -p "$DIST"

step "Generating Xcode project"
xcodegen generate --quiet

step "Testing StraylightKit"
swift test --package-path Packages/StraylightKit --quiet

step "Archiving"
xcodebuild -project Straylight.xcodeproj -scheme Straylight -configuration Release \
    -destination generic/platform=macOS -derivedDataPath build -archivePath "$ARCHIVE" archive -quiet

step "Exporting for Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist scripts/ExportOptions.plist -quiet

step "Verifying signature"
codesign --verify --deep --strict "$APP"
details=$(codesign -dv --verbose=4 "$APP" 2>&1)
grep -q "Authority=Developer ID Application" <<<"$details" || fail "app is not signed with Developer ID"
grep -q "TeamIdentifier=$TEAM_ID" <<<"$details" || fail "app is signed by the wrong team"
grep -q "flags=0x10000(runtime)" <<<"$details" || fail "hardened runtime is off"
grep -q "^Timestamp=" <<<"$details" || fail "signature has no secure timestamp"
[[ $(lipo -archs "$APP/Contents/MacOS/straylight") == arm64 ]] || fail "binary is not arm64-only"
[[ -e $APP/Contents/Resources/AppIcon.icns || -e $APP/Contents/Resources/Assets.car ]] || fail "app has no icon"
echo "    Developer ID, team $TEAM_ID, hardened runtime, timestamped, arm64"

if (( NOTARIZE )); then
    # Notarize and staple the app itself, so a copy dragged out of the DMG
    # (and later, Sparkle updates) pass Gatekeeper offline.
    step "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$DIST/straylight-notarize.zip"
    notarize "$DIST/straylight-notarize.zip"
    rm "$DIST/straylight-notarize.zip"
    xcrun stapler staple -q "$APP"
fi

step "Building DMG"
STAGING=$DIST/dmg
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/straylight.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname straylight -srcfolder "$STAGING" -fs APFS -format ULFO -ov "$DMG"
rm -rf "$STAGING"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if (( NOTARIZE )); then
    step "Notarizing the DMG"
    notarize "$DMG"
    xcrun stapler staple -q "$DMG"

    step "Checking Gatekeeper"
    spctl --assess --type execute "$APP"
    spctl --assess --type open --context context:primary-signature "$DMG"
    echo "    app and DMG accepted (notarized, stapled)"

    step "Keeping $VERSION in $RELEASES/"
    mkdir -p "$RELEASES"
    cp "$DMG" "$RELEASES/"
    printf '%s\n' "$NOTES" > "$RELEASES/straylight-$VERSION.html"
    echo "    $RELEASES/straylight-$VERSION.dmg"
fi

step "Done"
echo "    $DMG"
echo "    $(du -h "$DMG" | cut -f1)  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
if (( ! NOTARIZE )); then
    echo "    not notarized: run without --skip-notarize for a shippable build"
fi
