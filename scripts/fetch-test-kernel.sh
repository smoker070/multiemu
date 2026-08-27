#!/bin/bash
# Downloads a minimal Linux kernel + initramfs used only as a Milestone 2 boot
# fixture. This is NOT an Android image and it is never shipped.
#
# Alpine's netboot artifacts are used because they are small, boot to a shell
# with no disk at all, and exist for both aarch64 and x86_64 - exactly what a
# "does the accelerator work" experiment needs.
#
#   scripts/fetch-test-kernel.sh [arm64|x86_64]
#
# REQUIRES NETWORK ACCESS. Files land in vendor/test-kernels/<arch>/ (gitignored).
set -euo pipefail

cd "$(dirname "$0")/.."

arch="${1:-arm64}"
case "$arch" in
  arm64)  alpine_arch="aarch64" ;;
  x86_64) alpine_arch="x86_64" ;;
  *) echo "usage: $0 [arm64|x86_64]" >&2; exit 64 ;;
esac

release="v3.21"
version="3.21.0"
base="https://dl-cdn.alpinelinux.org/alpine/${release}/releases/${alpine_arch}/netboot-${version}"
destination="vendor/test-kernels/${arch}"
mkdir -p "$destination"

echo "Fetching Alpine ${version} netboot artifacts for ${alpine_arch}"
echo "  from $base"
echo "  into $destination"
echo

for file in vmlinuz-lts initramfs-lts; do
  echo "  $file"
  curl --fail --location --progress-bar --output "${destination}/${file}" "${base}/${file}"
done

echo
echo "Recording checksums. A kernel image runs with full guest privileges, so it"
echo "is verified on every use, not only at download time."
shasum -a 256 "${destination}"/* | tee "${destination}/SHA256SUMS"

echo
echo "Boot it with:"
echo
echo "  swift run multiemu-boot \\"
echo "      --kernel ${destination}/vmlinuz-lts \\"
echo "      --initrd ${destination}/initramfs-lts \\"
echo "      --arch ${arch} --accel hvf \\"
echo "      --append console=ttyAMA0 --echo"
