# Shared validation for the package repository builders. Source from Bash.
: "${VERSIONS_FILE:?Set VERSIONS_FILE}"
: "${PREVIOUS_REPOSITORY_DIR:?Set PREVIOUS_REPOSITORY_DIR}"
mapfile -t versions < "$VERSIONS_FILE"
(( ${#versions[@]} > 0 && ${#versions[@]} <= 10 )) || die 'Expected between one and ten versions'
declare -A seen_versions=()
for retained_tag in "${versions[@]}"; do
  [[ $retained_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid version: $retained_tag"
  [[ -z ${seen_versions[$retained_tag]:-} ]] || die "Duplicate version: $retained_tag"
  seen_versions[$retained_tag]=1
done
[[ ${versions[0]} == "$RELEASE_TAG" ]] || die 'The selected release must be the newest retained version'
[[ $(printf '%s\n' "${versions[@]}" | sort -Vr) == "$(printf '%s\n' "${versions[@]}")" ]] || die 'Versions must be sorted newest first'
previous=$(cd "$PREVIOUS_REPOSITORY_DIR" && pwd)
