#!/usr/bin/env bash
# Exercise real apt/dnf signature validation and binary startup before deployment.
set -euo pipefail
: "${RELEASE_TAG:?Set RELEASE_TAG}"
: "${TEST_DISTRO:?Set TEST_DISTRO}"
: "${DEB_ARCH:?Set DEB_ARCH}"
repository_url=${REPOSITORY_URL:-https://wstunnel.repository.miru10.net}
[[ $RELEASE_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
case "$TEST_DISTRO" in
  ubuntu24.04) image=docker.io/library/ubuntu:24.04 ;;
  ubuntu26.04) image=docker.io/library/ubuntu:26.04 ;;
  el9) image=docker.io/library/almalinux:9 ;;
  el10) image=docker.io/library/almalinux:10 ;;
  *) printf 'Unsupported test distro\n' >&2; exit 1 ;;
esac
case "$DEB_ARCH:$(uname -m)" in
  amd64:x86_64|arm64:aarch64) ;;
  *) printf 'Tests must run on the native architecture\n' >&2; exit 1 ;;
esac
sudo podman run --rm \
  --volume "$PWD/public:/repo:ro" \
  --env "RELEASE_TAG=$RELEASE_TAG" --env "TEST_DISTRO=$TEST_DISTRO" --env "DEB_ARCH=$DEB_ARCH" \
  --env "REPOSITORY_URL=$repository_url" \
  --interactive "$image" bash -s <<'EOF'
set -euo pipefail
source /etc/os-release
if [[ $ID == ubuntu ]]; then
  [[ $TEST_DISTRO == "ubuntu$VERSION_ID" ]]
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates gnupg coreutils grep sed
  install -m 644 /repo/wstunnel.gpg /usr/share/keyrings/wstunnel.gpg
  # Test the configuration we actually publish, using local files for transport.
  config="/repo/ubuntu/$VERSION_CODENAME/wstunnel.sources"
  grep -Fx "URIs: $REPOSITORY_URL" "$config"
  install -m 644 "$config" /etc/apt/sources.list.d/wstunnel.sources
  sed -i 's|^URIs:.*|URIs: file:/repo|' /etc/apt/sources.list.d/wstunnel.sources
  # Fetch the test repository independently so distro mirror failures cannot
  # conceal an invalid signature or missing package index.
  apt-get -o Dir::Etc::sourcelist=sources.list.d/wstunnel.sources \
    -o Dir::Etc::sourceparts=- -o APT::Update::Error-Mode=any update
  while IFS= read -r tag; do
    apt-cache show "wstunnel=${tag#v}-1" >/dev/null
  done < /repo/versions.txt
  apt-get install -y "wstunnel=${RELEASE_TAG#v}-1"
  [[ $(dpkg-query -W -f='${Version}' wstunnel) == "${RELEASE_TAG#v}-1" ]]
  [[ $(dpkg-query -W -f='${Architecture}' wstunnel) == "$DEB_ARCH" ]]
  wstunnel --version
  wstunnel --help >/dev/null
  oldest=$(tail -n 1 /repo/versions.txt)
  apt-get install -y --allow-downgrades "wstunnel=${oldest#v}-1"
  [[ $(dpkg-query -W -f='${Version}' wstunnel) == "${oldest#v}-1" ]]
else
  [[ $ID == almalinux && $TEST_DISTRO == "el${VERSION_ID%%.*}" ]]
  el=${VERSION_ID%%.*}
  arch=$(uname -m)
  # Minimal EL images provide coreutils-single. Request commands by path so
  # DNF can keep either coreutils implementation without a package conflict.
  dnf install -y ca-certificates gnupg2 grep sed /usr/bin/install /usr/bin/tail
  install -m 644 /repo/RPM-GPG-KEY-wstunnel /etc/pki/rpm-gpg/RPM-GPG-KEY-wstunnel
  rpm --import /repo/RPM-GPG-KEY-wstunnel
  gpg --batch --import /repo/RPM-GPG-KEY-wstunnel
  gpg --batch --verify "/repo/rpm/el$el/$arch/repodata/repomd.xml.asc" \
    "/repo/rpm/el$el/$arch/repodata/repomd.xml"
  config="/repo/rpm/el$el/wstunnel.repo"
  grep -Fx "baseurl=$REPOSITORY_URL/rpm/el$el/\$basearch" "$config"
  install -m 644 "$config" /etc/yum.repos.d/wstunnel.repo
  sed -i "s|^baseurl=.*|baseurl=file:///repo/rpm/el$el/$arch|" /etc/yum.repos.d/wstunnel.repo
  dnf --disablerepo='*' --enablerepo=wstunnel install -y wstunnel
  [[ $(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' wstunnel) == "${RELEASE_TAG#v}-1.el$el.$arch" ]]
  wstunnel --version
  wstunnel --help >/dev/null
  while IFS= read -r tag; do
    rpm --checksig "/repo/rpm/el$el/$arch/Packages/wstunnel-${tag#v}-1.el$el.$arch.rpm"
  done < /repo/versions.txt
  oldest=$(tail -n 1 /repo/versions.txt)
  if [[ $oldest != "$RELEASE_TAG" ]]; then
    dnf --disablerepo='*' --enablerepo=wstunnel downgrade -y "wstunnel-${oldest#v}-1.el$el.$arch"
    [[ $(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' wstunnel) == "${oldest#v}-1.el$el.$arch" ]]
  fi
fi
wstunnel --version
wstunnel --help >/dev/null
EOF
