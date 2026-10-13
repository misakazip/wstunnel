#!/usr/bin/env bash
# List fetched stable tags whose names match the Rust CLI package version.
set -euo pipefail

while IFS= read -r tag; do
  ref="refs/wstunnel-upstream/tags/$tag"
  manifest=''
  # v11+ uses a workspace; older Rust releases have the CLI at the root.
  for path in wstunnel-cli/Cargo.toml Cargo.toml; do
    if manifest=$(git show "$ref:$path" 2>/dev/null); then
      break
    fi
  done
  version=$(awk '
    /^[[:space:]]*\[package\][[:space:]]*$/ { package = 1; next }
    /^[[:space:]]*\[/ { package = 0 }
    package && /^[[:space:]]*version[[:space:]]*=[[:space:]]*"/ {
      sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit
    }
  ' <<< "$manifest")
  if [[ $version == "${tag#v}" ]]; then
    printf '%s\n' "$tag"
  else
    printf 'Skipping tag %s: CLI package version is %s\n' "$tag" "${version:-unavailable}" >&2
  fi
done < <(
  git for-each-ref --format='%(refname:strip=3)' refs/wstunnel-upstream/tags |
    awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/' | sort -V
)
