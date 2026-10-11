#!/usr/bin/env bash
# Select ten stable upstream versions and reuse packages from the published tree.
set -euo pipefail
: "${RELEASE_TAG:?Set RELEASE_TAG}"
: "${SOURCE_SHA:?Set SOURCE_SHA}"
: "${CONFIG_HASH:?Set CONFIG_HASH}"
: "${GITHUB_OUTPUT:?Set GITHUB_OUTPUT}"
[[ $RELEASE_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ ! -e repository-plan ]] || { echo 'repository-plan already exists' >&2; exit 1; }
mkdir -p repository-plan/previous/public
# Artifact uploads omit empty directories on the first publication.
touch repository-plan/previous/public/empty-repository
git fetch --quiet --no-tags https://github.com/erebe/wstunnel.git \
  'refs/tags/*:refs/wstunnel-upstream/tags/*'
[[ $(git rev-parse "refs/wstunnel-upstream/tags/$RELEASE_TAG^{commit}") == "$SOURCE_SHA" ]]
git for-each-ref --format='%(refname:strip=3)' refs/wstunnel-upstream/tags \
  | awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/' | sort -V > repository-plan/upstream-tags
awk -v selected="$RELEASE_TAG" '{ print; if ($0 == selected) exit }' \
  repository-plan/upstream-tags | tail -n 10 | sort -Vr > repository-plan/versions.txt
[[ $(head -n 1 repository-plan/versions.txt) == "$RELEASE_TAG" ]]

repository_head=''
previous_config=''
if git ls-remote --exit-code --heads origin refs/heads/repository > repository-plan/remote-head; then
  git fetch --quiet --no-tags --depth=1 origin refs/heads/repository
  repository_head=$(git rev-parse FETCH_HEAD)
  git show "$repository_head:publication.txt" > repository-plan/previous-publication.txt
  grep -qx 'format=wstunnel-repository-v1' repository-plan/previous-publication.txt
  git archive "$repository_head" public | tar -x -C repository-plan/previous
  previous_config=$(awk -F= '$1 == "config_hash" { print $2 }' repository-plan/previous-publication.txt)
else
  status=$?
  [[ $status == 2 ]] || { echo 'Failed to query published repository' >&2; exit 1; }
fi

printf '{"include":[]}\n' > repository-plan/build-matrix.json
while IFS= read -r tag; do
  missing=false
  for arch in amd64 arm64; do
    [[ -s repository-plan/previous/public/pool/main/w/wstunnel/wstunnel_${tag#v}-1_${arch}.deb ]] || missing=true
  done
  for el in 9 10; do
    for arch in x86_64 aarch64; do
      [[ -s repository-plan/previous/public/rpm/el$el/$arch/Packages/wstunnel-${tag#v}-1.el$el.$arch.rpm ]] || missing=true
    done
  done
  # Rebuild the selected tag on manual runs or when the build configuration changes.
  if [[ $missing == true || ( $tag == "$RELEASE_TAG" && ( ${MANUAL:-false} == true || $previous_config != "$CONFIG_HASH" ) ) ]]; then
    sha=$(git rev-parse "refs/wstunnel-upstream/tags/$tag^{commit}")
    jq --arg tag "$tag" --arg sha "$sha" '.include += [
      {tag: $tag, sha: $sha, arch: "amd64", runner: "ubuntu-24.04", target: "x86_64-unknown-linux-musl"},
      {tag: $tag, sha: $sha, arch: "arm64", runner: "ubuntu-24.04-arm", target: "aarch64-unknown-linux-musl"}
    ]' repository-plan/build-matrix.json > repository-plan/matrix.next
    mv repository-plan/matrix.next repository-plan/build-matrix.json
  fi
done < repository-plan/versions.txt
build=$(jq -r '.include | length > 0' repository-plan/build-matrix.json)
printf 'build=%s\nmatrix=%s\nrepository_head=%s\nconfig_hash=%s\n' "$build" \
  "$(jq -c . repository-plan/build-matrix.json)" "$repository_head" "$CONFIG_HASH" >> "$GITHUB_OUTPUT"
printf 'Selected versions:\n'
cat repository-plan/versions.txt
