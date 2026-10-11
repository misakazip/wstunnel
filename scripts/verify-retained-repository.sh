#!/usr/bin/env bash
# Authenticate packages copied from the previous publication before signing a new index.
set -euo pipefail

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

: "${VERSIONS_FILE:?Set VERSIONS_FILE}"
: "${PREVIOUS_REPOSITORY_DIR:?Set PREVIOUS_REPOSITORY_DIR}"
: "${REPOSITORY_SIGNING_KEY_FINGERPRINT:?Set REPOSITORY_SIGNING_KEY_FINGERPRINT}"
for tool in gpg sha256sum awk rpm; do
  command -v "$tool" >/dev/null || die "Required tool is missing: $tool"
done

previous=$(cd "$PREVIOUS_REPOSITORY_DIR" && pwd)
[[ -d $previous/dists || -d $previous/rpm ]] || exit 0
[[ -d $previous/dists && -d $previous/rpm ]] || die 'Previous repository is incomplete'
fingerprint=${REPOSITORY_SIGNING_KEY_FINGERPRINT//[[:space:]]/}
fingerprint=${fingerprint^^}
[[ $fingerprint =~ ^[0-9A-F]{40}$|^[0-9A-F]{64}$ ]] || die 'Invalid signing key fingerprint'

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -m 700 "$work/gnupg" "$work/rpmdb"
gpg_args=(gpg --homedir "$work/gnupg" --batch)
[[ -s $previous/wstunnel.gpg ]] || die 'Previous apt signing key is missing'
"${gpg_args[@]}" --import "$previous/wstunnel.gpg"
mapfile -t imported_fingerprints < <(
  "${gpg_args[@]}" --with-colons --fingerprint |
    awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print toupper($10); want = 0 }'
)
(( ${#imported_fingerprints[@]} == 1 )) && [[ ${imported_fingerprints[0]} == "$fingerprint" ]] || \
  die 'Previous repository key does not match REPOSITORY_SIGNING_KEY_FINGERPRINT'

for suite in noble resolute; do
  status=$("${gpg_args[@]}" --status-fd 1 --verify "$previous/dists/$suite/InRelease" 2>/dev/null)
  awk -v expected="$fingerprint" '
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" && ($3 == expected || $NF == expected) { valid = 1 }
    END { exit !valid }
  ' <<< "$status" || die "Unexpected signature on previous $suite metadata"
  "${gpg_args[@]}" --output "$work/$suite-release" --decrypt \
    "$previous/dists/$suite/InRelease" 2>/dev/null
  for arch in amd64 arm64; do
    relative="main/binary-$arch/Packages"
    expected=$(awk -v target="$relative" '
      /^SHA256:/ { section = 1; next }
      /^[^[:space:]]/ { section = 0 }
      section && $3 == target { print $1 }
    ' "$work/$suite-release")
    [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || die "Missing signed checksum: $suite/$relative"
    actual=$(sha256sum "$previous/dists/$suite/$relative" | awk '{print $1}')
    [[ $actual == "$expected" ]] || die "Retained apt index checksum failed: $suite/$relative"
  done
done

# Debian packages are authenticated by the signed Packages index. Verify each
# retained file against its indexed SHA-256 before it can enter a newly signed index.
while IFS= read -r tag; do
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid retained version: $tag"
  version=${tag#v}-1
  for arch in amd64 arm64; do
    relative="pool/main/w/wstunnel/wstunnel_${version}_${arch}.deb"
    package="$previous/$relative"
    [[ -s $package ]] || continue
    index="$previous/dists/noble/main/binary-$arch/Packages"
    expected=$(
      awk -v target="$relative" '
        /^Filename: / { filename = substr($0, 11) }
        /^SHA256: / { digest = substr($0, 9) }
        /^$/ {
          if (filename == target) print digest
          filename = digest = ""
        }
        END { if (filename == target) print digest }
      ' "$index"
    )
    [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || die "Package is absent from signed apt metadata: $relative"
    [[ $(sha256sum "$package" | awk '{print $1}') == "$expected" ]] || \
      die "Retained apt package checksum failed: $relative"
  done
done < "$VERSIONS_FILE"

[[ -s $previous/RPM-GPG-KEY-wstunnel ]] || die 'Previous RPM signing key is missing'
mapfile -t rpm_key_fingerprints < <(
  "${gpg_args[@]}" --with-colons --import-options show-only --import \
    "$previous/RPM-GPG-KEY-wstunnel" 2>/dev/null |
    awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print toupper($10); want = 0 }'
)
(( ${#rpm_key_fingerprints[@]} == 1 )) && [[ ${rpm_key_fingerprints[0]} == "$fingerprint" ]] || \
  die 'Previous RPM key does not match REPOSITORY_SIGNING_KEY_FINGERPRINT'
rpm --dbpath "$work/rpmdb" --initdb
rpm --dbpath "$work/rpmdb" --import "$previous/RPM-GPG-KEY-wstunnel"
for el in 9 10; do
  for arch in x86_64 aarch64; do
    repodata="$previous/rpm/el$el/$arch/repodata"
    status=$("${gpg_args[@]}" --status-fd 1 --verify \
      "$repodata/repomd.xml.asc" "$repodata/repomd.xml" 2>/dev/null)
    awk -v expected="$fingerprint" '
      $1 == "[GNUPG:]" && $2 == "VALIDSIG" && ($3 == expected || $NF == expected) { valid = 1 }
      END { exit !valid }
    ' <<< "$status" || die "Unexpected signature on previous EL$el/$arch metadata"
    while IFS= read -r tag; do
      package="$previous/rpm/el$el/$arch/Packages/wstunnel-${tag#v}-1.el$el.$arch.rpm"
      [[ -s $package ]] || continue
      output=$(LC_ALL=C rpm --dbpath "$work/rpmdb" --checksig "$package")
      [[ $output == *'digests signatures OK'* ]] || die "Retained RPM signature failed: $package"
    done < "$VERSIONS_FILE"
  done
done

printf 'Authenticated retained packages from the previous publication\n'
