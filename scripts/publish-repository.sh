#!/usr/bin/env bash
# Publish generated assets with at most ten linear snapshots on a dedicated branch.
set -euo pipefail
umask 077

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

: "${RELEASE_TAG:?Set RELEASE_TAG}"
: "${SOURCE_SHA:?Set SOURCE_SHA}"
branch=${REPOSITORY_BRANCH:-repository}
[[ $branch == repository ]] || die 'Publication is restricted to the repository branch'
[[ $RELEASE_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid release tag'
[[ $SOURCE_SHA =~ ^[[:xdigit:]]{40}$|^[[:xdigit:]]{64}$ ]] || die 'Invalid source commit'
[[ -f public/index.html ]] || die 'Generated public/index.html is missing'
generated=$(cd public && pwd)
origin=$(git remote get-url origin)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
git init --quiet "$work"
git -C "$work" remote add origin "$origin"
git -C "$work" config user.name 'github-actions[bot]'
git -C "$work" config user.email '41898282+github-actions[bot]@users.noreply.github.com'

# Preserve actions/checkout's HTTP authentication in the isolated publishing repo.
# Never print headers or modify the source checkout's index, HEAD or history.
while IFS= read -r key; do
  [[ -n $key ]] || continue
  while IFS= read -r value; do
    git -C "$work" config --add "$key" "$value"
  done < <(git config --get-all "$key")
done < <(git config --name-only --get-regexp '^http\..*\.extraheader$' || true)

old_head=''
if git -C "$work" ls-remote --exit-code --heads origin "refs/heads/$branch" > "$work/remote-head"; then
  git -C "$work" fetch --quiet --no-tags --depth=10 origin "refs/heads/$branch"
  old_head=$(git -C "$work" rev-parse FETCH_HEAD)
  marker=$(git -C "$work" show "$old_head:publication.txt")
  [[ $marker == format=wstunnel-repository-v1$'\n'* ]] || die 'Existing repository branch is not a generated publication branch'
else
  status=$?
  [[ $status == 2 ]] || die 'Failed to query the publication branch'
fi
if [[ ${EXPECTED_REPOSITORY_HEAD+x} && $old_head != "$EXPECTED_REPOSITORY_HEAD" ]]; then
  die 'Repository branch changed since package planning; retry with the current packages'
fi

# Retain nine previous snapshots plus this publication. Recreate the oldest
# retained commit as a root, then replay only trees and original commit metadata.
# No source checkout, package regeneration or binary conflict resolution is needed.
parent=''
if [[ -n $old_head ]]; then
  git -C "$work" rev-list --first-parent --max-count=9 "$old_head" | tac > "$work/retained"
  while IFS= read -r commit; do
    tree=$(git -C "$work" rev-parse "$commit^{tree}")
    git -C "$work" show -s --format=format:%B "$commit" > "$work/message"
    parents=()
    [[ -z $parent ]] || parents=(-p "$parent")
    parent=$(
      GIT_AUTHOR_NAME=$(git -C "$work" show -s --format=%an "$commit") \
      GIT_AUTHOR_EMAIL=$(git -C "$work" show -s --format=%ae "$commit") \
      GIT_AUTHOR_DATE=$(git -C "$work" show -s --format=%aI "$commit") \
      GIT_COMMITTER_NAME=$(git -C "$work" show -s --format=%cn "$commit") \
      GIT_COMMITTER_EMAIL=$(git -C "$work" show -s --format=%ce "$commit") \
      GIT_COMMITTER_DATE=$(git -C "$work" show -s --format=%cI "$commit") \
      git -C "$work" commit-tree "$tree" "${parents[@]}" -F "$work/message"
    )
  done < "$work/retained"
fi

mkdir "$work/public"
cp -a "$generated/." "$work/public/"
printf 'format=wstunnel-repository-v1\ntag=%s\nsource_sha=%s\nconfig_hash=%s\n' \
  "$RELEASE_TAG" "$SOURCE_SHA" "${CONFIG_HASH:-}" > "$work/publication.txt"
git -C "$work" add -- public publication.txt
tree=$(git -C "$work" write-tree)
parents=()
[[ -z $parent ]] || parents=(-p "$parent")
head=$(printf 'Publish package repositories for %s\n' "$RELEASE_TAG" | \
  git -C "$work" commit-tree "$tree" "${parents[@]}")
git -C "$work" update-ref "refs/heads/$branch" "$head"
count=$(git -C "$work" rev-list --count "$head")
(( count <= 10 )) || die 'Publication history exceeded ten snapshots'

# An exact lease rejects concurrent changes, including unexpected branch creation.
git -C "$work" push "--force-with-lease=refs/heads/$branch:$old_head" \
  origin "$head:refs/heads/$branch"
printf 'Published %s to %s (%s snapshots retained)\n' "$RELEASE_TAG" "$branch" "$count"
