#!/usr/bin/env bash
# Package locally built binaries into a signed, static apt repository.
set -euo pipefail

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

: "${REPOSITORY_SIGNING_KEY:?Set REPOSITORY_SIGNING_KEY}"
: "${REPOSITORY_SIGNING_KEY_FINGERPRINT:?Set REPOSITORY_SIGNING_KEY_FINGERPRINT}"
: "${RELEASE_TAG:?Set RELEASE_TAG}"
: "${BINARIES_DIR:?Set BINARIES_DIR}"
for tool in dpkg-deb apt-ftparchive gpg gzip stat; do
  command -v "$tool" >/dev/null || die "Required tool is missing: $tool"
done

[[ ! -e public ]] || die 'public/ already exists; use a clean output directory'
tag=$RELEASE_TAG
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Unsupported stable release tag: $tag"
source "$(dirname "${BASH_SOURCE[0]}")/repository-versions.sh"
repository_url=${REPOSITORY_URL:-https://wstunnel.repository.miru10.net}
[[ $repository_url =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || die 'REPOSITORY_URL must be an HTTPS origin without a trailing slash'

binaries=$(cd "$BINARIES_DIR" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p public/pool/main/w/wstunnel
root=$(cd public && pwd)
printf '%s\n' "${versions[@]}" > "$root/versions.txt"
for retained_tag in "${versions[@]}"; do
  version="${retained_tag#v}-1"
  for arch in amd64 arm64; do
    filename="wstunnel_${version}_${arch}.deb"
    binary_dir="$binaries/binary-$retained_tag-$arch"
    if [[ ! -s $binary_dir/wstunnel ]]; then
      old_package="$previous/pool/main/w/wstunnel/$filename"
      [[ -s $old_package ]] || die "Missing retained package: $filename"
      [[ $(dpkg-deb -f "$old_package" Version) == "$version" ]] || die "Invalid package version: $filename"
      [[ $(dpkg-deb -f "$old_package" Architecture) == "$arch" ]] || die "Invalid package architecture: $filename"
      cp "$old_package" "$root/pool/main/w/wstunnel/$filename"
      continue
    fi
    [[ -s $binary_dir/LICENSE ]] || die "Missing license: $retained_tag/$arch"
    package="$work/$retained_tag-$arch"
    mkdir -p "$package/usr/bin" "$package/DEBIAN"
    cp "$binary_dir/wstunnel" "$package/usr/bin/wstunnel"
    chmod 755 "$package/usr/bin/wstunnel"
    install -D -m 644 "$binary_dir/LICENSE" "$package/usr/share/doc/wstunnel/copyright"
    size=$(stat -c %s "$package/usr/bin/wstunnel")
    cat > "$package/DEBIAN/control" <<EOF
Package: wstunnel
Version: $version
Architecture: $arch
Maintainer: misakazip <git@misaka.zip>
Section: net
Priority: optional
Installed-Size: $(( (size + 1023) / 1024 ))
Homepage: https://github.com/erebe/wstunnel
Description: Tunnel traffic over WebSocket or HTTP/2
EOF
    dpkg-deb --root-owner-group -Zxz --build "$package" \
      "$root/pool/main/w/wstunnel/wstunnel_${version}_${arch}.deb"
  done
done

cd "$root"
mkdir -m 700 "$work/gnupg"
gpg_args=(gpg --homedir "$work/gnupg" --batch --yes)
printf '%s\n' "$REPOSITORY_SIGNING_KEY" | "${gpg_args[@]}" --import
"${gpg_args[@]}" --export "$REPOSITORY_SIGNING_KEY_FINGERPRINT" > wstunnel.gpg
[[ -s wstunnel.gpg ]] || die 'Signing key fingerprint did not match an imported key'
for suite in noble resolute; do
  for arch in amd64 arm64; do
    directory="dists/$suite/main/binary-$arch"
    mkdir -p "$directory"
    apt-ftparchive -a "$arch" packages pool > "$directory/Packages"
    gzip -n -9 -c "$directory/Packages" > "$directory/Packages.gz"
  done
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=wstunnel \
    -o APT::FTPArchive::Release::Label=wstunnel \
    -o "APT::FTPArchive::Release::Suite=$suite" \
    -o "APT::FTPArchive::Release::Codename=$suite" \
    -o 'APT::FTPArchive::Release::Architectures=amd64 arm64' \
    -o APT::FTPArchive::Release::Components=main \
    -o 'APT::FTPArchive::Release::Description=Built from upstream tags for Ubuntu' \
    release "dists/$suite" > "dists/$suite/Release"
  for output in InRelease Release.gpg; do
    mode=--clearsign
    [[ $output != Release.gpg ]] || mode=--detach-sign
    printf '%s\n' "${REPOSITORY_SIGNING_KEY_PASSPHRASE:-}" | \
      "${gpg_args[@]}" --pinentry-mode loopback --passphrase-fd 0 \
        --local-user "$REPOSITORY_SIGNING_KEY_FINGERPRINT" \
        --output "dists/$suite/$output" "$mode" "dists/$suite/Release"
  done
  "${gpg_args[@]}" --verify "dists/$suite/InRelease"
  mkdir -p "ubuntu/$suite"
  cat > "ubuntu/$suite/wstunnel.sources" <<EOF
Types: deb
URIs: $repository_url
Suites: $suite
Components: main
Architectures: amd64 arm64
Signed-By: /usr/share/keyrings/wstunnel.gpg
EOF
done
cat > _headers <<'EOF'
/*
  Cache-Control: no-cache
  X-Content-Type-Options: nosniff
EOF
cat > index.html <<EOF
<!doctype html><title>wstunnel packages</title>
<h1>wstunnel package repositories</h1><p>Release: $tag</p>
<p>Latest ${#versions[@]} package versions are available. <a href="/versions.txt">Version list</a></p>
<p>Repository URL: <a href="$repository_url">$repository_url</a></p>
<p>Ubuntu 24.04 (noble), 26.04 (resolute): main; amd64, arm64.</p>
<p>Enterprise Linux 9, 10: /rpm/el9/, /rpm/el10/; x86_64, aarch64.</p>
<ul>
<li><a href="/ubuntu/noble/wstunnel.sources">Ubuntu 24.04 apt configuration</a></li>
<li><a href="/ubuntu/resolute/wstunnel.sources">Ubuntu 26.04 apt configuration</a></li>
<li><a href="/rpm/el9/wstunnel.repo">EL9 dnf configuration</a></li>
<li><a href="/rpm/el10/wstunnel.repo">EL10 dnf configuration</a></li>
</ul>
<a href="/wstunnel.gpg">Repository signing key</a>
<a href="/RPM-GPG-KEY-wstunnel">RPM signing key</a>
EOF
while IFS= read -r -d '' file; do
  (( $(stat -c %s "$file") <= 25 * 1024 * 1024 )) || \
    die "Cloudflare Pages 25 MiB file limit exceeded: $file"
done < <(find . -type f -print0)
printf 'Built apt repository for %s: %s\n' "$tag" "$root"
