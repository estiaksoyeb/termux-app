#!/usr/bin/env bash
#
# postprocess-bootstrap.sh — strip non-runtime content and sanity-check a ZIP.
#
# Removes C headers, documentation, man/info pages and test binaries, then
# reports the resulting size and verifies the structure the app expects.
#
# Usage:
#   ./setup/postprocess-bootstrap.sh <bootstrap-arch.zip> [output.zip]
#
# See docs/bootstrap.md.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <bootstrap-arch.zip> [output.zip]" >&2
    exit 1
fi

IN_ZIP="$1"
OUT_ZIP="${2:-${1%.zip}-min.zip}"

command -v unzip >/dev/null || { echo "unzip is required" >&2; exit 1; }
command -v zip   >/dev/null || { echo "zip is required" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-min.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "[*] extracting $IN_ZIP"
unzip -q "$IN_ZIP" -d "$TMP/root"

echo "[*] removing non-runtime content"
rm -rf "$TMP/root/include" \
       "$TMP/root/share/doc" \
       "$TMP/root/share/info" \
       "$TMP/root/share/man" \
       "$TMP/root/libexec/installed-tests" \
       "$TMP/root/libexec/termux-am"

if [ ! -f "$TMP/root/SYMLINKS.txt" ]; then
    echo "[!] warning: SYMLINKS.txt missing at ZIP root" >&2
fi

echo "[*] checking for absolute paths"
if find "$TMP/root" -type l | grep -q .; then
    echo "[!] warning: symlinks remain in the tree; they must be listed in SYMLINKS.txt" >&2
fi

(cd "$TMP/root" && zip -qr9 "$OUT_ZIP" ./*)

echo
echo "[*] result: $OUT_ZIP"
du -h "$OUT_ZIP"
echo
echo "[*] top-level entries:"
unzip -l "$OUT_ZIP" | awk 'NR>3 {print $4}' | cut -d/ -f1 | sort -u | sed '/^$/d'
echo
echo "[*] symlink entries: $(unzip -p "$OUT_ZIP" SYMLINKS.txt 2>/dev/null | wc -l)"
echo
echo "Next: cp $OUT_ZIP app/src/main/cpp/bootstrap-\${arch}.zip"
