#!/usr/bin/env bash
#
# build-bootstrap.sh — produce a minimal bootstrap ZIP for this fork.
#
# WHAT THIS DOES (honest scope):
#   1. Fetches the upstream aarch64 bootstrap ZIP (already built for the
#      com.termux prefix, which is why it is physically installed and the
#      prefix is fixed up at install time).
#   2. Strips content that has no runtime value (headers, docs, man/info pages,
#      test binaries, apt/dpkg tooling, termux-am) and re-zips it.
#   3. Verifies the result and drops it at app/src/main/cpp/bootstrap-<arch>.zip
#
# WHY NOT A TRUE CROSS-COMPILE YET:
#   Building openssh + deps from source for a custom $PREFIX needs either the
#   termux-packages docker image (not installed here) or a full NDK cross
#   toolchain setup, and requires patching the prefix inside termux-packages.
#   The stripping pass delivers most of the size win immediately and keeps the
#   project buildable today. See docs/bootstrap.md § "Known limitation".
#
# Usage:
#   ./setup/build-bootstrap.sh            # default: aarch64, stripped stock ZIP
#   ./setup/build-bootstrap.sh --clean    # re-download the stock ZIP and rebuild
#
# Env:
#   SSHTERM_BOOTSTRAP_URL   override the source ZIP URL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ARCH="aarch64"
CLEAN=0
OUT_DIR="$PROJECT_DIR/app/src/main/cpp"
OUT_ZIP="$OUT_DIR/bootstrap-$ARCH.zip"
WORK_DIR="${SSHTERM_WORK_DIR:-/tmp/opencode/sshterm-bootstrap}"
CACHE_ZIP="$WORK_DIR/stock-bootstrap-$ARCH.zip"

# Matches the checksum pinned in app/build.gradle for bootstrap 2026.02.12-r1.
BOOTSTRAP_VERSION="2026.02.12-r1%2Bapt.android-7"
DEFAULT_URL="https://github.com/termux/termux-packages/releases/download/bootstrap-2026.02.12-r1%2Bapt.android-7/bootstrap-$ARCH.zip"
SRC_URL="${SSHTERM_BOOTSTRAP_URL:-$DEFAULT_URL}"

while [ $# -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        --arch)  ARCH="$1"; shift;
                 OUT_ZIP="$OUT_DIR/bootstrap-$ARCH.zip"
                 CACHE_ZIP="$WORK_DIR/stock-bootstrap-$ARCH.zip" ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

for cmd in curl unzip zip python3; do
    command -v "$cmd" >/dev/null || { echo "error: '$cmd' is required" >&2; exit 1; }
done

mkdir -p "$WORK_DIR" "$OUT_DIR"

# ---------------------------------------------------------------------------
# 1. Get the stock ZIP (cached).
# ---------------------------------------------------------------------------
if [ "$CLEAN" = "1" ] || [ ! -f "$CACHE_ZIP" ]; then
    echo "[*] downloading stock bootstrap ($ARCH)"
    echo "    $SRC_URL"
    curl -fL --retry 3 --retry-delay 2 -o "$CACHE_ZIP.part" "$SRC_URL"
    mv -f "$CACHE_ZIP.part" "$CACHE_ZIP"
else
    echo "[*] using cached stock bootstrap: $CACHE_ZIP"
fi

STOCK_SIZE=$(du -h "$CACHE_ZIP" | cut -f1)
echo "[*] stock ZIP size: $STOCK_SIZE"

# ---------------------------------------------------------------------------
# 2. Extract, prune, re-zip.
# ---------------------------------------------------------------------------
STAGE="$WORK_DIR/stage-$ARCH"
echo "[*] extracting"
rm -rf "$STAGE"
mkdir -p "$STAGE"
unzip -q "$CACHE_ZIP" -d "$STAGE"

echo "[*] pruning non-runtime content"
# Documentation and headers ----------------------------------------------------
rm -rf "$STAGE/include" \
       "$STAGE/share/doc" \
       "$STAGE/share/info" \
       "$STAGE/share/man" \
       "$STAGE/share/locale" \
       "$STAGE/share/aclocal" \
       "$STAGE/share/pkgconfig" \
       "$STAGE/share/gir-1.0" \
       "$STAGE/share/terminfo" \
       "$STAGE/share/bash-completion" \
       "$STAGE/share/nano" \
       "$STAGE/share/vim" 2>/dev/null || true

# Test / debug artifacts -------------------------------------------------------
rm -rf "$STAGE/libexec/installed-tests" \
       "$STAGE/libexec/termux-am" 2>/dev/null || true

# Package manager (not used by this fork) --------------------------------------
rm -rf "$STAGE/var/lib/apt" \
       "$STAGE/var/cache/apt" \
       "$STAGE/var/lib/dpkg" 2>/dev/null || true
rm -f  "$STAGE"/bin/apt "$STAGE"/bin/apt-* "$STAGE"/bin/dpkg "$STAGE"/bin/dpkg-* \
       "$STAGE/bin/gpgv" "$STAGE/bin/lz4" "$STAGE/bin/pkg" 2>/dev/null || true
rm -f  "$STAGE"/lib/libapt-*.so* "$STAGE"/lib/libapt-private*.so* 2>/dev/null || true

# Inject the ssh client ---------------------------------------------------------
# The stock bootstrap ships apt instead of openssh, so ssh is added from the
# official arm64 .deb packages and relocated into this prefix. See add-ssh.sh.
if [ "${SSHTERM_SKIP_SSH:-0}" != "1" ]; then
    "$SCRIPT_DIR/add-ssh.sh" "$STAGE"
else
    echo "[*] SSHTERM_SKIP_SSH=1: skipping ssh injection"
fi

# Fix absolute symlink targets ---------------------------------------------------
# A handful of upstream symlink entries point at the *stock* prefix, e.g.
#   /data/data/com.termux/files/usr/share/termux-keyring/x.gpg<-←./etc/apt/trusted.gpg.d/x.gpg
# Those would silently link into the stock Termux install (or dangle) on a fork
# that uses a different applicationId. Rewrite them to this fork's prefix.
# The prefix is read from app/build.gradle's applicationId.
APP_ID=$(grep -oP 'applicationId\s+"\K[^"]+' "$PROJECT_DIR/app/build.gradle" | head -1)
if [ -z "$APP_ID" ]; then
    echo "error: could not read applicationId from app/build.gradle" >&2
    exit 1
fi
FORK_PREFIX="/data/data/$APP_ID/files/usr"
echo "[*] fixing absolute symlink targets -> $FORK_PREFIX"

SYMLINKS_FILE="$STAGE/SYMLINKS.txt"
ABSOLUTE_COUNT=$(grep -c '^/data/data/com\.termux/files/usr/' "$SYMLINKS_FILE" || true)
ABSOLUTE_COUNT=${ABSOLUTE_COUNT:-0}
sed -i "s|^/data/data/com\.termux/files/usr/|$FORK_PREFIX/|" "$SYMLINKS_FILE"
echo "    rewritten absolute targets: $ABSOLUTE_COUNT"

# Drop apt repository keyring symlinks entirely, they are useless without apt.
sed -i '/^.*<-\.\/etc\/apt\//d' "$SYMLINKS_FILE"

# ---------------------------------------------------------------------------
# 3. Re-zip.
# ---------------------------------------------------------------------------
TMP_ZIP="$WORK_DIR/bootstrap-$ARCH-min.zip"
rm -f "$TMP_ZIP"
echo "[*] re-zipping"
(cd "$STAGE" && zip -qr9 "$TMP_ZIP" ./*)

# ---------------------------------------------------------------------------
# 4. Sanity checks.
# ---------------------------------------------------------------------------
echo
echo "[*] sanity checks"

if ! unzip -p "$TMP_ZIP" SYMLINKS.txt >/dev/null 2>&1; then
    echo "[!] WARNING: SYMLINKS.txt missing from ZIP root" >&2
fi
SYMLINK_COUNT=$(unzip -p "$TMP_ZIP" SYMLINKS.txt 2>/dev/null | wc -l || echo 0)
echo "    symlink entries        : $SYMLINK_COUNT"

if unzip -p "$TMP_ZIP" SYMLINKS.txt 2>/dev/null | grep -qv '←'; then
    echo "[!] WARNING: SYMLINKS.txt has a line without the '←' separator" >&2
fi

if unzip -l "$TMP_ZIP" | awk 'NR>3 {print $4}' | grep -q '^/'; then
    echo "[!] WARNING: absolute paths found in archive" >&2
fi

# A symlink entry whose name is also a regular file aborts extraction on device
# with "symlink failed: EEXIST". Catch it here, not at install time.
unzip -Z1 "$TMP_ZIP" > "$WORK_DIR/entries-names-$ARCH.txt" 2>/dev/null || true
COLLISIONS=""
while IFS= read -r l; do
    [ -n "$l" ] || continue
    if grep -qxF "$l" "$WORK_DIR/entries-names-$ARCH.txt"; then
        COLLISIONS="$COLLISIONS $l"
    fi
done <<EOF
$(unzip -p "$TMP_ZIP" SYMLINKS.txt 2>/dev/null | sed 's|^[^←]*←||; s|^\./||')
EOF
if [ -n "$COLLISIONS" ]; then
    echo "[!] error: symlink names collide with real files (install would fail):$COLLISIONS" >&2
    exit 1
fi
echo "    symlink/file collisions: none"

ENTRIES="$WORK_DIR/entries-$ARCH.txt"
unzip -l "$TMP_ZIP" | awk 'NR>3 && NF>=4 {print $4}' > "$ENTRIES"

# Capture SYMLINKS.txt once. Piping it straight into `grep -q` under
# `set -o pipefail` causes SIGPIPE (unzip exits 141) because grep -q exits on the
# first match and closes the pipe.
SYMLINK_LINKS_FILE="$WORK_DIR/symlink-links-$ARCH.txt"
unzip -p "$TMP_ZIP" SYMLINKS.txt 2>/dev/null | sed 's|^[^←]*←||' | sed 's|^\./||' > "$SYMLINK_LINKS_FILE" || true

check_entry() {
    # $1 = path inside the ZIP
    if grep -qx -- "$1" "$ENTRIES"; then
        echo "    present: $1"
    elif grep -qx -- "$1" "$SYMLINK_LINKS_FILE"; then
        echo "    present: $1 (symlink)"
    else
        echo "    MISSING: $1" >&2
        MISSING=1
    fi
}

MISSING=0
for required in bin/sh bin/bash bin/dash bin/termux-exec-system-linker-exec bin/termux-exec-ld-preload-lib; do
    check_entry "$required"
done
if [ "$MISSING" = "1" ]; then
    echo "[!] WARNING: required shell/termux-exec entries missing from bootstrap" >&2
fi

if grep -qx -- 'bin/ssh' "$ENTRIES"; then
    echo "    present: bin/ssh"
elif grep -qx -- 'bin/ssh' "$SYMLINK_LINKS_FILE"; then
    echo "    present: bin/ssh (symlink)"
else
    echo "    MISSING: bin/ssh" >&2
    MISSING=1
fi

TOP_LEVEL=$(unzip -l "$TMP_ZIP" | awk 'NR>3 {print $4}' | cut -d/ -f1 | sort -u | sed '/^$/d' | tr '\n' ' ')
echo "    top-level entries      : $TOP_LEVEL"
echo "    uncompressed total     : $(unzip -l "$TMP_ZIP" | tail -1 | awk '{printf "%.1f MB", $1/1048576}')"
echo "    final ZIP size         : $(du -h "$TMP_ZIP" | cut -f1)"
echo "    original ZIP size      : $STOCK_SIZE"

# ---------------------------------------------------------------------------
# 5. Install.
# ---------------------------------------------------------------------------
cp -f "$TMP_ZIP" "$OUT_ZIP"
echo
echo "[*] wrote $OUT_ZIP"

# The bootstrap task in app/build.gradle only touches ABIs it is told to build.
# Keep the other arch ZIPs out of the way so a universal build cannot silently
# pick them up.
for other in arm i686 x86_64; do
    rm -f "$OUT_DIR/bootstrap-$other.zip"
done
echo "[*] removed other-ABI bootstrap ZIPs from app/src/main/cpp (arm64-only fork)"
