#!/usr/bin/env bash
# Build on the matching native Linux runner, using the checked-out upstream source.
set -euo pipefail
: "${BUILD_TARGET:?Set BUILD_TARGET}"
: "${DEB_ARCH:?Set DEB_ARCH}"
: "${RELEASE_TAG:?Set RELEASE_TAG}"
[[ $RELEASE_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
case "$DEB_ARCH:$BUILD_TARGET" in
  amd64:x86_64-unknown-linux-musl|arm64:aarch64-unknown-linux-musl) ;;
  *) printf 'Unsupported architecture/target pair\n' >&2; exit 1 ;;
esac
output="$PWD/binaries/binary-$RELEASE_TAG-$DEB_ARCH"
mkdir -p "$output"
cd source
cargo build --release --locked --bin wstunnel --target "$BUILD_TARGET"
# Shared packages must run without the build host's glibc or dynamic loader.
readelf -l "target/$BUILD_TARGET/release/wstunnel" > "$output/elf-program-headers"
if grep -q INTERP "$output/elf-program-headers"; then
  printf 'Expected a static binary without an ELF interpreter\n' >&2
  exit 1
fi
install -m 755 "target/$BUILD_TARGET/release/wstunnel" "$output/wstunnel"
install -m 644 LICENSE "$output/LICENSE"
