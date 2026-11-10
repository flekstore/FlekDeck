#!/usr/bin/env bash
#
# build.sh — rebuilds IdevicePairing.dylib, which is kept in the repository.
#
# The dylib is the part of idevice (https://github.com/jkcoxson/idevice, MIT)
# that FlekDeck calls itself: the functions listed in exports.txt and whatever
# they need, nothing else. FlekDeck uses it to create a pairing file on the
# device itself, see LCDevicePairing.m, and to record the device's log for a
# JIT report, see LCDeviceLog.m.
#
# It is linked from the static library the StikJIT repository carries, taken
# at a pinned commit and checked against a pinned hash. That library is 57 MB,
# which is why it is fetched here rather than kept beside the result.
#
# Usage:
#   ./build.sh                                  # downloads the library
#   IDEVICE_ARCHIVE=/path/libidevice_ffi.a ./build.sh   # uses a copy already at hand

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

STIKJIT_COMMIT=32287268fa5824f9edce4cb359f5833ce0cf7b00
ARCHIVE_SHA256=4db23fe1d342927b9480bb9a8577f219994365621dc28aa0018e23ea1990ecc8

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARCHIVE="${IDEVICE_ARCHIVE:-$WORK/libidevice_ffi.a}"
if [[ -z "${IDEVICE_ARCHIVE:-}" ]]; then
  echo "==> Downloading libidevice_ffi.a from StikJIT @ ${STIKJIT_COMMIT:0:7}"
  curl -fsSL --retry 3 -o "$ARCHIVE" \
    "https://raw.githubusercontent.com/StikDebug/StikJIT/$STIKJIT_COMMIT/idevice/libidevice_ffi.a"
fi
echo "$ARCHIVE_SHA256  $ARCHIVE" | shasum -a 256 -c -

# A static library gives up only the members something asks for, so each
# exported function is asked for by name; -dead_strip then drops the rest.
WANTED=()
while read -r symbol; do
  [[ -n "$symbol" ]] && WANTED+=("-Wl,-u,$symbol")
done < exports.txt

echo "==> Linking"
xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -miphoneos-version-min=17.0 \
  -o IdevicePairing.dylib \
  "${WANTED[@]}" \
  -Wl,-exported_symbols_list,exports.txt \
  -Wl,-dead_strip \
  -install_name @rpath/IdevicePairing.dylib \
  "$ARCHIVE" \
  -framework Security -framework CoreFoundation -framework SystemConfiguration -framework Foundation

xcrun strip -x IdevicePairing.dylib
codesign --force --sign - IdevicePairing.dylib

echo "==> Built: $(pwd)/IdevicePairing.dylib ($(stat -f %z IdevicePairing.dylib) bytes)"
