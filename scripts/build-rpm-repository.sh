#!/usr/bin/env bash
# Package the same static binaries for EL9 and EL10 and sign packages and metadata.
set -euo pipefail

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

# Reuse the existing repository signing secrets for both package formats.
: "${REPOSITORY_SIGNING_KEY:?Set REPOSITORY_SIGNING_KEY}"
: "${REPOSITORY_SIGNING_KEY_FINGERPRINT:?Set REPOSITORY_SIGNING_KEY_FINGERPRINT}"
: "${RELEASE_TAG:?Set RELEASE_TAG}"
: "${BINARIES_DIR:?Set BINARIES_DIR}"
for tool in rpmbuild rpmsign rpm createrepo_c gpg stat; do
  command -v "$tool" >/dev/null || die "Required tool is missing: $tool"
done
[[ $RELEASE_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Unsupported stable release tag: $RELEASE_TAG"
source "$(dirname "${BASH_SOURCE[0]}")/repository-versions.sh"
repository_url=${REPOSITORY_URL:-https://wstunnel.repository.miru10.net}
[[ $repository_url =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || die 'REPOSITORY_URL must be an HTTPS origin without a trailing slash'
[[ -d public && ! -e public/rpm ]] || die 'Build apt first into a clean public/ directory'
root=$(cd public && pwd)
binaries=$(cd "$BINARIES_DIR" && pwd)
umask 077
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -m 700 "$work/gnupg"
export GNUPGHOME="$work/gnupg"
gpg_args=(gpg --homedir "$GNUPGHOME" --batch --yes)
printf '%s\n' "$REPOSITORY_SIGNING_KEY" | "${gpg_args[@]}" --import
"${gpg_args[@]}" --armor --export "$REPOSITORY_SIGNING_KEY_FINGERPRINT" > "$root/RPM-GPG-KEY-wstunnel"
[[ -s $root/RPM-GPG-KEY-wstunnel ]] || die 'Signing key fingerprint did not match an imported key'
chmod 644 "$root/RPM-GPG-KEY-wstunnel"
mkdir "$work/rpmdb"
rpm --dbpath "$work/rpmdb" --initdb
rpm --dbpath "$work/rpmdb" --import "$root/RPM-GPG-KEY-wstunnel"

# Feed the passphrase privately to rpmsign's GPG child, without command-line secrets.
export RPM_PASSPHRASE_FILE="$work/passphrase"
printf '%s\n' "${REPOSITORY_SIGNING_KEY_PASSPHRASE:-}" > "$RPM_PASSPHRASE_FILE"
cat > "$work/gpg-rpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec gpg --batch --pinentry-mode loopback --passphrase-file "$RPM_PASSPHRASE_FILE" "$@"
EOF
chmod 700 "$work/gpg-rpm"

for el in 9 10; do
  mkdir -p "$root/rpm/el$el"
  cat > "$root/rpm/el$el/wstunnel.repo" <<EOF
[wstunnel]
name=wstunnel EL$el
baseurl=$repository_url/rpm/el$el/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-wstunnel
EOF
  for arch in x86_64 aarch64; do
    directory="$root/rpm/el$el/$arch"
    mkdir -p "$directory/Packages"
    deb_arch=amd64
    [[ $arch != aarch64 ]] || deb_arch=arm64
    for retained_tag in "${versions[@]}"; do
      top="$work/$retained_tag-el$el-$arch"
      filename="wstunnel-${retained_tag#v}-1.el$el.$arch.rpm"
      package="$top/RPMS/$arch/$filename"
      binary_dir="$binaries/binary-$retained_tag-$deb_arch"
      if [[ -s $binary_dir/wstunnel ]]; then
        [[ -s $binary_dir/LICENSE ]] || die "Missing license: $retained_tag/$deb_arch"
        mkdir -p "$top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
        cp "$binary_dir/wstunnel" "$top/SOURCES/wstunnel"
        cp "$binary_dir/LICENSE" "$top/SOURCES/LICENSE"
        cat > "$top/SPECS/wstunnel.spec" <<EOF
Name: wstunnel
Version: ${retained_tag#v}
Release: 1.el$el
Summary: Tunnel traffic over WebSocket or HTTP/2
License: BSD-3-Clause
URL: https://github.com/erebe/wstunnel
Source0: wstunnel
Source1: LICENSE
AutoReqProv: no

%description
wstunnel built from an upstream release tag as a static musl binary.

%prep
%build

%install
install -D -m 0755 %{SOURCE0} %{buildroot}/usr/bin/wstunnel
install -D -m 0644 %{SOURCE1} %{buildroot}/usr/share/licenses/wstunnel/LICENSE

%files
%defattr(-,root,root,-)
/usr/bin/wstunnel
%license /usr/share/licenses/wstunnel/LICENSE
EOF
        # The binary is already built and stripped on its native runner; do not run
        # host strip/debug processing when packaging another architecture.
        rpmbuild -bb --target "$arch" \
          --define "_topdir $top" \
          --define '__os_install_post %{nil}' \
          --define 'debug_package %{nil}' \
          --define '_binary_payload w9.xzdio' \
          "$top/SPECS/wstunnel.spec"
      else
        old_package="$previous/rpm/el$el/$arch/Packages/$filename"
        [[ -s $old_package ]] || die "Missing retained package: $filename"
        actual=$(rpm --dbpath "$work/rpmdb" -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$old_package")
        [[ $actual == "${retained_tag#v}-1.el$el.$arch" ]] || die "Invalid retained package: $filename"
        mkdir -p "$top/RPMS/$arch"
        cp "$old_package" "$package"
      fi
      [[ -s $package ]] || die "Expected RPM was not generated: $filename"
      rpmsign --define "_gpg_name $REPOSITORY_SIGNING_KEY_FINGERPRINT" \
        --define "_gpg_path $GNUPGHOME" \
        --define "__gpg $work/gpg-rpm" \
        --define '_gpg_digest_algo sha256' --addsign "$package"
      rpm --dbpath "$work/rpmdb" --checksig "$package"
      install -m 644 "$package" "$directory/Packages/$filename"
    done
    createrepo_c --database --compress-type gz "$directory"
    printf '%s\n' "${REPOSITORY_SIGNING_KEY_PASSPHRASE:-}" | \
      "${gpg_args[@]}" --pinentry-mode loopback --passphrase-fd 0 \
        --local-user "$REPOSITORY_SIGNING_KEY_FINGERPRINT" --armor \
        --output "$directory/repodata/repomd.xml.asc" \
        --detach-sign "$directory/repodata/repomd.xml"
    "${gpg_args[@]}" --verify "$directory/repodata/repomd.xml.asc" "$directory/repodata/repomd.xml"
  done
done
# umask 077 protects signing material, but published metadata must be readable.
find "$root/rpm" -type d -exec chmod 755 {} +
find "$root/rpm" -type f -exec chmod 644 {} +
while IFS= read -r -d '' file; do
  (( $(stat -c %s "$file") <= 25 * 1024 * 1024 )) || \
    die "Cloudflare Pages 25 MiB file limit exceeded: $file"
done < <(find "$root" -type f -print0)
printf 'Built EL9/EL10 RPM repositories for %s: %s/rpm\n' "$RELEASE_TAG" "$root"
