#!/usr/bin/env bash
# Sets the marketing version and increments the build number in project.yml.
# Sparkle compares build numbers, so every release must have a higher one.
#
#   scripts/bump-version.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -eq 1 && $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <major.minor.patch>" >&2; exit 1; }

build=$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' project.yml)
next=$((build + 1))
sed -i '' -E \
    -e "s/^(    MARKETING_VERSION: ).*/\1$1/" \
    -e "s/^(    CURRENT_PROJECT_VERSION: ).*/\1$next/" \
    project.yml
echo "straylight $1 (build $next)"
