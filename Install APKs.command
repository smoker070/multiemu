#!/bin/bash
# Installs every .apk sitting in this folder onto the running Android device.
# Drop your APKs next to this file, then double-click it.
set -u

export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
export PATH="$ANDROID_SDK_ROOT/platform-tools:$PATH"
cd "$(dirname "$0")" || exit 1

if ! adb devices | grep -q "device$"; then
  echo "No device is running. Start one in Multiemu first."
  read -r -p "Press Return to close."
  exit 1
fi

shopt -s nullglob
apks=(*.apk)
if [ ${#apks[@]} -eq 0 ]; then
  echo "No .apk files in: $(pwd)"
  echo "Put the APKs you want to test next to this script and run it again."
  read -r -p "Press Return to close."
  exit 1
fi

failed=0
for apk in "${apks[@]}"; do
  echo "── installing $apk"
  # -r reinstalls over an existing copy, -d allows an older version than the
  # one already installed, -g grants runtime permissions so a test build does
  # not stall on permission dialogs.
  if adb install -r -d -g "$apk"; then
    echo "   OK"
  else
    echo "   FAILED: $apk"
    failed=$((failed + 1))
  fi
done

echo
echo "Done. $(( ${#apks[@]} - failed ))/${#apks[@]} installed."
[ "$failed" -gt 0 ] && echo "A failure is usually a wrong ABI (needs arm64) or a bad signature."
read -r -p "Press Return to close."
