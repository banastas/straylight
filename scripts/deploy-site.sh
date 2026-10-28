#!/usr/bin/env bash
# Publishes https://straylight.banast.as: the page in site/, site/appcast.xml,
# and every release in releases/ (DMGs, deltas, notes), as the static-assets
# Worker configured in wrangler.jsonc.
#
#   scripts/deploy-site.sh              assemble dist/site and deploy it
#   scripts/deploy-site.sh --no-deploy  assemble only, to preview locally
#
# Uses wrangler's Cloudflare login (npx wrangler login).
set -euo pipefail
cd "$(dirname "$0")/.."

WRANGLER=(npx --yes wrangler@4.152.0)
RELEASES=releases
OUT=dist/site

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f site/appcast.xml ]] || fail "site/appcast.xml is missing; run scripts/release.sh first"
LATEST=$(ls "$RELEASES"/straylight-*.dmg 2>/dev/null | sed -E 's/.*straylight-(.*)\.dmg$/\1/' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
[[ -n $LATEST ]] || fail "no releases in $RELEASES/"
grep -q "straylight-$LATEST.dmg" site/appcast.xml || fail "site/appcast.xml does not list $LATEST"

rm -rf "$OUT"
mkdir -p "$OUT/releases"
cp -R site/. "$OUT/"
cp "$RELEASES"/*.dmg "$RELEASES"/*.html "$OUT/releases/"
cp "$RELEASES"/*.delta "$OUT/releases/" 2>/dev/null || true

# Fill in the download button and release notes for the newest version.
SIZE=$(stat -f%z "$RELEASES/straylight-$LATEST.dmg" | awk '{ printf "%.1f MB", $1 / 1000000 }')
VERSION=$LATEST SIZE=$SIZE NOTES=$(cat "$RELEASES/straylight-$LATEST.html") perl -0pi -e '
    s/\{\{VERSION\}\}/$ENV{VERSION}/g; s/\{\{SIZE\}\}/$ENV{SIZE}/g; s/\{\{NOTES\}\}/$ENV{NOTES}/g
' "$OUT/index.html"
echo "/download /releases/straylight-$LATEST.dmg 302" > "$OUT/_redirects"

if [[ ${1:-} == --no-deploy ]]; then
    echo "==> Assembled $OUT for straylight $LATEST (not deployed)"
    exit 0
fi
echo "==> Deploying straylight $LATEST"
"${WRANGLER[@]}" deploy
