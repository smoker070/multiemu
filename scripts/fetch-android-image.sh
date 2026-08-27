#!/bin/bash
# Downloads an AOSP Cuttlefish arm64 image set for Milestone 4.
#
# REQUIRES NETWORK ACCESS to the Android CI host.
#
# The CI site offers no stable "latest" download URL, so the build id is a
# deliberate manual step - and that exact id is then recorded in the image
# manifest as its provenance.
#
#   1. Open the RELEASE branch grid. arm64 Cuttlefish is not built on
#      aosp-main, which is why it looks missing there:
#        https://ci.android.com/builds/branches/aosp-android-latest-release/grid
#      (alternative: aosp-main-throttled, with ?legacy=1)
#   2. Find the target  aosp_cf_arm64_only_phone-userdebug
#      Note "only": the 64-bit-only variant is the one that exists. There
#      is no aosp_cf_arm64_phone on current branches.
#   3. Click a green build and copy its numeric build id.
#   4. Run:   scripts/fetch-android-image.sh <build-id> [target]
#
#   Do NOT take a build from the aosp_arm64 target: that is a GSI, a system
#   image meant to be flashed over a real device's vendor partition, with
#   no kernel of its own, so there is nothing for a VMM to boot.
#
#   The host package cvd-host_package.tar.gz is NOT needed: it contains
#   Cuttlefish's own Linux launcher, and Multiemu builds the composite disk
#   and boots the images itself.
#
# Downloads land in vendor/android/<build-id>/ (gitignored, 1-2 GB).
#
# STATUS: the URL SHAPE is confirmed against a real published artifact link
#   .../builds/submitted/<build-id>/<target>/latest/<artifact>
# but this project has never completed a download, so the ARTIFACT NAME is
# still a guess - hence the two candidates tried below. If both 404, open the
# build's Artifacts tab, copy the real link, save the file where this script
# says, and re-run it. See docs/VERIFY.md -> ANDROID-IMAGE-DOWNLOAD-URL.
set -euo pipefail

cd "$(dirname "$0")/.."

build_id="${1:-}"
target="${2:-aosp_cf_arm64_only_phone-userdebug}"

if [ -z "$build_id" ]; then
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

destination="vendor/android/${build_id}"
mkdir -p "$destination"

# The artifact is named after the PRODUCT, which is the part of the target
# before the first "-" — so aosp_cf_arm64_phone-trunk_staging-userdebug yields
# aosp_cf_arm64_phone-img-<id>.zip. Deriving it means passing a different target
# actually changes the URL; hardcoding it meant a second argument was silently
# ignored and the download 404'd for no visible reason.
product="${target%%-*}"

# The artifact name is not consistent across targets: some builds publish
# <product>-img-<id>.zip and others <product>-<id>.zip. Rather than guess,
# try each and report what was attempted. A 404 with no explanation is the
# failure mode this replaces.
candidates=("${product}-img-${build_id}.zip" "${product}-${build_id}.zip")
artifact="${candidates[0]}"

case "$product" in
  aosp_cf_*) ;;
  *)
    echo "WARNING: \"$product\" is not a Cuttlefish target." >&2
    echo "         Multiemu expects a virtual-device build (aosp_cf_arm64_phone-...)," >&2
    echo "         which ships boot.img, vendor_boot.img and the system partitions." >&2
    echo "         A plain GSI target such as aosp_arm64 provides a system image only" >&2
    echo "         and has no kernel to boot. Continuing, but the image set will" >&2
    echo "         probably be incomplete — check the Artifacts tab for boot.img." >&2
    echo >&2
    ;;
esac
ci_host="ci.android.com"

echo "Cuttlefish arm64 image set"
echo "  build id   ${build_id}"
echo "  target     ${target}"
echo "  artifact   ${candidates[*]}"
echo "  into       ${destination}"
echo

# Is this actually an Android image set, or the CI site's web page?
#
# An unknown artifact path returns the "Artifact Viewer" SPA with HTTP 200, so
# --fail cannot catch it. Without this check the script records a SHA-256 of an
# HTML page and calls it provenance.
minimum_bytes=104857600   # 100 MB; a real image set is 1-2 GB
looks_like_an_image_set() {
  local file_path="$1"
  [ -s "$file_path" ] || return 1
  case "$(file -b "$file_path")" in
    *Zip*|*ZIP*|*zip*) ;;
    *) return 1 ;;
  esac
  local size
  size=$(stat -f %z "$file_path" 2>/dev/null || stat -c %s "$file_path")
  [ "$size" -ge "$minimum_bytes" ]
}

existing=""
for candidate in "${candidates[@]}"; do
  if [ -f "${destination}/${candidate}" ]; then
    # A file left by a previous failed attempt must not be adopted.
    if looks_like_an_image_set "${destination}/${candidate}"; then
      existing="$candidate"
    else
      echo "Discarding ${candidate}: it is not an image set (probably a saved web page)."
      /bin/rm -f -- "${destination}/${candidate}"
    fi
  fi
done

if [ -n "$existing" ]; then
  artifact="$existing"
  echo "Already downloaded (${artifact}); skipping fetch."
else
  downloaded=false
  for candidate in "${candidates[@]}"; do
    url="https://ci.android.com/builds/submitted/${build_id}/${target}/latest/${candidate}"
    echo "Trying ${candidate} (1-2 GB)..."
    if curl --fail --location --progress-bar --output "${destination}/${candidate}" "$url"; then
      if looks_like_an_image_set "${destination}/${candidate}"; then
        artifact="$candidate"
        downloaded=true
        break
      fi
      echo "  the server answered, but with $(file -b "${destination}/${candidate}")"
      echo "  rather than an image set - this endpoint needs a browser session"
    else
      echo "  not found under that name"
    fi
    # Whatever arrived is not usable; leaving it would look downloaded.
    /bin/rm -f -- "${destination}/${candidate}"
  done

  if [ "$downloaded" = false ]; then
    echo >&2
    echo "Could not fetch the image set from the command line." >&2
    echo >&2
    echo "This is expected: ci.android.com serves artifacts through a signed" >&2
    echo "URL its web app obtains, and answers a direct request with the page" >&2
    echo "itself. There is no documented raw download endpoint." >&2
    echo >&2
    echo "Download it in a browser instead:" >&2
    echo "  1. Open build ${build_id}, target ${target}" >&2
    echo "  2. Click the Artifacts tab" >&2
    echo "  3. Download the image set - it matches aosp_cf_*img*.zip" >&2
    echo "  4. Save it as:" >&2
    echo "       ${destination}/${candidates[0]}" >&2
    echo "  5. Re-run this script; it verifies and extracts the file it finds." >&2
    echo >&2
    echo "Names tried automatically:" >&2
    for candidate in "${candidates[@]}"; do echo "  - $candidate" >&2; done
    exit 65
  fi
fi

echo
echo "Recording the checksum of exactly what we downloaded:"
shasum -a 256 "${destination}/${artifact}" | tee "${destination}/${artifact}.sha256"

echo
echo "Extracting..."
unzip -o -q "${destination}/${artifact}" -d "${destination}/extracted"
ls -la "${destination}/extracted" | head -20

echo
echo "Next steps:"
echo
echo "  swift build -c release"
echo "  .build/release/multiemu-image plan ${destination}/extracted"
echo "  .build/release/multiemu-image install ${destination}/extracted \\"
echo "      --id cuttlefish-arm64-${build_id} \\"
echo "      --name \"AOSP Cuttlefish arm64\" \\"
echo "      --release 15 --api 35 --arch arm64 \\"
echo "      --source \"Android CI ${target} build ${build_id}\" \\"
echo "      --license \"AOSP Apache-2.0; kernel GPL-2.0 - source must be published if redistributed\""
echo "  .build/release/multiemu-image unpack cuttlefish-arm64-${build_id}"
