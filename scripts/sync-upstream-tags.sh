#!/usr/bin/env bash
# Import upstream tags without fetching or merging upstream branches.
set -euo pipefail

upstream=https://github.com/erebe/wstunnel.git
git fetch --no-tags "$upstream" 'refs/tags/*:refs/tags/*'
git push --atomic origin --tags

# Select the highest stable version actually advertised by upstream.
tags=$(git ls-remote --tags --refs "$upstream")
tag=$(printf '%s\n' "$tags" | awk '$2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ {
  sub(/^refs\/tags\//, "", $2); print $2
}' | sort -V | tail -n 1)
[[ -n $tag ]] || { printf 'No stable upstream tag found\n' >&2; exit 1; }
sha=$(git rev-parse "refs/tags/$tag^{commit}")
printf 'Selected upstream tag: %s (%s)\n' "$tag" "$sha"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'tag=%s\nsha=%s\n' "$tag" "$sha" >> "$GITHUB_OUTPUT"
fi
