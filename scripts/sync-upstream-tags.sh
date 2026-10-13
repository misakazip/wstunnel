#!/usr/bin/env bash
# Fetch upstream tags locally without modifying fork tags or branches.
set -euo pipefail

upstream=https://github.com/erebe/wstunnel.git
git fetch --no-tags "$upstream" 'refs/tags/*:refs/wstunnel-upstream/tags/*'

# Select from the fetched snapshot, excluding tags with mismatched versions.
tags=$(bash "$(dirname "${BASH_SOURCE[0]}")/list-upstream-versions.sh")
tag=$(printf '%s\n' "$tags" | tail -n 1)
[[ -n $tag ]] || { printf 'No stable upstream tag found\n' >&2; exit 1; }
sha=$(git rev-parse "refs/wstunnel-upstream/tags/$tag^{commit}")
printf 'Selected upstream tag: %s (%s)\n' "$tag" "$sha"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'tag=%s\nsha=%s\n' "$tag" "$sha" >> "$GITHUB_OUTPUT"
fi
