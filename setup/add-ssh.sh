#!/usr/bin/env bash
#
# add-ssh.sh — inject a working ssh client into the bootstrap staging tree.
#
# Downloads the official Termux arm64 .deb packages for openssh and its
# dependencies, relocates them from the stock prefix
# (/data/data/com.termux/files/usr) into a flat bootstrap layout
# (bin/, lib/, etc/, share/), rewrites stale RUNPATH/RPATH entries, and fixes
# any absolute symlink targets.
#
# WHY THIS WORKS WITHOUT REBUILDING FROM SOURCE:
#   Termux binaries are linked against /system/bin/linker64 (Android's own
#   linker), not a prefix-relative interpreter, so the binary itself is
#   prefix-agnostic. The only prefix-bound piece is the ELF RUNPATH string
#   pointing at /data/data/com.termux/files/usr/lib, plus absolute symlink
#   targets and config paths. All of those are rewritten here.
#
# Called by setup/build-bootstrap.sh. Can also be run standalone:
#   ./setup/add-ssh.sh <staging-dir>
#
# Env:
#   SSHTERM_APT_BASE   APT repo base URL
#   SSHTERM_WORK_DIR   cache dir (default /tmp/opencode/sshterm-bootstrap)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

STAGE="${1:-}"
if [ -z "$STAGE" ] || [ ! -d "$STAGE" ]; then
    echo "usage: $0 <staging-dir>" >&2
    exit 1
fi

WORK_DIR="${SSHTERM_WORK_DIR:-/tmp/opencode/sshterm-bootstrap}"
APT_BASE="${SSHTERM_APT_BASE:-https://packages-cf.termux.dev/apt/termux-main}"
PKG_LIST="$WORK_DIR/packages-aarch64.txt"
DEB_DIR="$WORK_DIR/debs"
DEB_STAGE="$WORK_DIR/deb-stage"

STOCK_PREFIX='/data/data/com.termux/files/usr'

APP_ID=$(grep -oP 'applicationId\s+"\K[^"]+' "$PROJECT_DIR/app/build.gradle" | head -1)
if [ -z "$APP_ID" ]; then
    echo "error: could not read applicationId from app/build.gradle" >&2
    exit 1
fi
FORK_PREFIX="/data/data/$APP_ID/files/usr"

# Packages required for a functioning ssh client.
# krb5/ldns are hard dependencies of the stock openssh build (GSSAPI + DNSSEC).
PACKAGES=(
    openssh
    openssh-sftp-server
    openssl
    ca-certificates
    zlib
    krb5
    ldns
    libandroid-support
    libandroid-glob
    libresolv-wrapper
    resolv-conf
    libedit
    readline
    ncurses
    libdb
    libc++
    termux-auth
)

mkdir -p "$WORK_DIR" "$DEB_DIR"
rm -rf "$DEB_STAGE"
mkdir -p "$DEB_STAGE"

# ---------------------------------------------------------------------------
# 1. Package index
# ---------------------------------------------------------------------------
if [ ! -s "$PKG_LIST" ]; then
    echo "[*] fetching package index"
    curl -fsSL "$APT_BASE/dists/stable/main/binary-aarch64/Packages.gz" \
        | gzip -dc > "$PKG_LIST"
else
    echo "[*] using cached package index"
fi

pkg_field() {
    # $1 = package, $2 = field
    awk -v p="$1" -v f="$2" '
        $0 == "Package: " p { found = 1; next }
        found && $0 == "" { exit }
        found && index($0, f ": ") == 1 { print substr($0, length(f) + 3); exit }
    ' "$PKG_LIST"
}

# ---------------------------------------------------------------------------
# 2. Download debs
# ---------------------------------------------------------------------------
for pkg in "${PACKAGES[@]}"; do
    filename=$(pkg_field "$pkg" Filename)
    if [ -z "$filename" ]; then
        echo "[!] package '$pkg' not found in index, skipping" >&2
        continue
    fi
    deb="$DEB_DIR/$(basename "$filename")"
    if [ -s "$deb" ]; then
        echo "[*] cached: $(basename "$filename")"
        continue
    fi
    echo "[*] downloading $pkg ($(basename "$filename"))"
    curl -fsSL --retry 3 --retry-delay 2 -o "$deb.part" "$APT_BASE/$filename"
    mv -f "$deb.part" "$deb"
done

# ---------------------------------------------------------------------------
# 3. Unpack debs into a single tree
# ---------------------------------------------------------------------------
echo "[*] unpacking debs"
for deb in "$DEB_DIR"/*.deb; do
    [ -e "$deb" ] || continue
    tmp=$(mktemp -d "$WORK_DIR/deb-XXXXXX")
    ( cd "$tmp" && ar x "$deb" )
    data=$(ls "$tmp"/data.tar.* 2>/dev/null | head -1)
    if [ -z "$data" ]; then
        echo "[!] no data.tar in $deb" >&2
        rm -rf "$tmp"; continue
    fi
    tar xf "$data" -C "$DEB_STAGE"
    rm -rf "$tmp"
done

STOCK_ROOT="$DEB_STAGE/data/data/com.termux/files/usr"
if [ ! -d "$STOCK_ROOT" ]; then
    echo "error: expected package root not found at $STOCK_ROOT" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Copy only runtime files into the staging prefix
# ---------------------------------------------------------------------------
echo "[*] relocating runtime files into staging prefix"
copy_if_dir() {
    [ -d "$STOCK_ROOT/$1" ] || return 0
    mkdir -p "$STAGE/$1"
    cp -a "$STOCK_ROOT/$1/." "$STAGE/$1/"
}
copy_if_dir bin
copy_if_dir lib
copy_if_dir libexec
copy_if_dir etc
copy_if_dir share

# Runtime data dirs, but drop the runit service definitions (not used here).
if [ -d "$STOCK_ROOT/var" ]; then
    mkdir -p "$STAGE/var"
    for d in "$STOCK_ROOT"/var/*; do
        [ -e "$d" ] || continue
        base=$(basename "$d")
        [ "$base" = "service" ] && continue
        cp -a "$d" "$STAGE/var/"
    done
fi

# ---------------------------------------------------------------------------
# 5. Strip unneeded payload from the injected packages
# ---------------------------------------------------------------------------
echo "[*] stripping package docs/man pages"
rm -rf "$STAGE/share/doc" "$STAGE/share/man"
rm -f  "$STAGE/var/run/README.openssh" 2>/dev/null || true
# sshd is not needed by a client-only build.
rm -f "$STAGE/bin/sshd" \
      "$STAGE/bin/ssh-agent" \
      "$STAGE/libexec/sshd-auth" \
      "$STAGE/libexec/sshd-session" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Rewrite the stock prefix everywhere it is baked in
# ---------------------------------------------------------------------------
echo "[*] rewriting '$STOCK_PREFIX' -> '$FORK_PREFIX'"

# 6a. ELF RUNPATH/RPATH.
#
#     Every Termux binary has the *stock* prefix baked into its RUNPATH:
#         RUNPATH = /data/data/com.termux/files/usr/lib
#     That directory belongs to the other app, so the loader finds nothing there.
#     This must be rewritten in the ELF itself, for EVERY binary, not just ssh:
#     otherwise `bash` (the login shell) dies with
#         CANNOT LINK EXECUTABLE ...: library "libandroid-support.so" not found
#
#     The replacement is longer than the original, so patching bytes in place is
#     unsafe. patchelf relocates the dynamic string table properly.
#     Set SSHTERM_PATCHELF=0 to skip this (runtime LD_LIBRARY_PATH wrappers then
#     become the only mechanism, which only covers the ssh tools).
if [ "${SSHTERM_PATCHELF:-1}" = "1" ]; then
    if ! command -v patchelf >/dev/null; then
        echo "    [!] patchelf is required to fix ELF RUNPATH but was not found." >&2
        echo "        Install it, or set SSHTERM_PATCHELF=0 to fall back to wrappers." >&2
        exit 1
    fi
    echo "    rewriting ELF RUNPATH with patchelf"
    patched=0
    # Recursive: ELFs also live in nested dirs such as libexec/coreutils/.
    while IFS= read -r -d '' f; do
        file -b "$f" 2>/dev/null | grep -q '^ELF' || continue
        old_rpath=$(patchelf --print-rpath "$f" 2>/dev/null || true)
        case "$old_rpath" in
            *"$STOCK_PREFIX"*)
                if patchelf --set-rpath "$FORK_PREFIX/lib" "$f" 2>/dev/null; then
                    patched=$((patched + 1))
                else
                    echo "    [!] patchelf failed on ${f#"$STAGE"/}" >&2
                    exit 1
                fi
                ;;
        esac
    done < <(find "$STAGE" -type f -print0 2>/dev/null)
    echo "    patched $patched ELF file(s)"
else
    echo "    patchelf disabled: relying on runtime LD_LIBRARY_PATH wrappers (ssh only)"
fi

# 6a-check. No ELF may still reference the stock prefix, or it will fail to
#           load at runtime. Catch it here instead of on the device.
stale=0
while IFS= read -r -d '' f; do
    file -b "$f" 2>/dev/null | grep -q '^ELF' || continue
    if patchelf --print-rpath "$f" 2>/dev/null | grep -qF "$STOCK_PREFIX"; then
        echo "    [!] stale RUNPATH still present: ${f#"$STAGE"/}" >&2
        stale=$((stale + 1))
    fi
done < <(find "$STAGE" -type f -print0 2>/dev/null)
if [ "$stale" -gt 0 ]; then
    echo "    error: $stale ELF file(s) still point at the stock prefix" >&2
    exit 1
fi
echo "    verified: no ELF references the stock prefix"

# 6b. Text files with the absolute prefix baked in (configs, scripts, pkg
#     metadata). Longest-first replacement is unnecessary; the new string is
#     longer and we are writing whole files, not patching in place.
find "$STAGE" -type f \
    ! -path "$STAGE/lib/*" \
    ! -name '*.so*' \
    -size -2M -print0 2>/dev/null |
while IFS= read -r -d '' f; do
    if grep -Iq . "$f" 2>/dev/null && grep -qF "$STOCK_PREFIX" "$f" 2>/dev/null; then
        sed -i "s|$STOCK_PREFIX|$FORK_PREFIX|g" "$f"
        echo "    patched text: ${f#"$STAGE"/}"
    fi
done

# 6c. The stock prefix is ALSO compiled into bash/dash as the location of their
#     login files:
#         /data/data/com.termux/files/usr/etc/profile
#         /data/data/com.termux/files/usr/etc/bash.bashrc
#     patchelf only rewrites RUNPATH; 6b only touches text files. So `bash -l`
#     still tries to read the *other* app's profile and dies with:
#         bash: /data/data/com.termux/files/usr/etc/profile: Permission denied
#     The replacement path is longer, so patching bytes in place would corrupt
#     the ELF. Instead we stop bash from ever asking: `bin/login` sources our
#     own profile and then execs a non-login shell.
STOCK_HOME="${STOCK_PREFIX%/usr}/home"
FORK_HOME="${FORK_PREFIX%/usr}/home"
LOGIN="$STAGE/bin/login"
if [ -f "$LOGIN" ]; then
    echo "    patching bin/login to use the fork's own profile"
    # -l makes bash read the compiled-in stock profile, which is unreadable.
    # Source ours up front and hand bash a plain interactive shell instead.
    sed -i 's|exec "$SHELL" -l "$@"|exec "$SHELL" "$@"|' "$LOGIN"
    if ! grep -q 'SSHTERM_PROFILE_FIX' "$LOGIN"; then
        # Written via a variable so the fork prefix is expanded at build time,
        # not left as a literal "$FORK_PREFIX" inside the shipped script.
        #
        # Two separate stock paths must be avoided:
        #   * `-l` makes bash read the compiled-in stock etc/profile
        #   * an interactive bash additionally reads the compiled-in stock
        #     etc/bash.bashrc, before any --rcfile is considered  (see NORC_FIX)
        sed -i "s|^if \[ -n \"\$TERM\" \]; then\$|# SSHTERM_PROFILE_FIX: bash has the stock prefix compiled in, so \`-l\` would\n# read the other app's unreadable profile. Source ours instead.\nif [ -n \"\$TERM\" ] \&\& [ -r \"$FORK_PREFIX/etc/profile\" ]; then . \"$FORK_PREFIX/etc/profile\"; fi\nif [ -n \"\$TERM\" ]; then|" \
            "$LOGIN"
    fi
    if grep -q 'exec "$SHELL" -l' "$LOGIN"; then
        echo "    [!] bin/login still execs a login shell" >&2
        exit 1
    fi
    # Separate, idempotent patch: an interactive bash reads the compiled-in
    # stock bash.bashrc before --rcfile is honoured, printing
    #   bash: /data/data/com.termux/files/usr/etc/bash.bashrc: Permission denied
    # `--norc` suppresses that probe; our profile sources the fork's bash.bashrc.
    if ! grep -q 'SSHTERM_NORC_FIX' "$LOGIN"; then
        sed -i 's|^\texec "\$SHELL" "\$@"$|\t# SSHTERM_NORC_FIX: skip bash'"'"'s compiled-in (stock) bash.bashrc.\n\tcase "$SHELL" in *bash) set -- --norc "$@" ;; esac\n\texec "$SHELL" "$@"|' "$LOGIN"
    fi
    grep -q 'SSHTERM_NORC_FIX' "$LOGIN" || {
        echo "    [!] failed to insert --norc fix into bin/login" >&2
        exit 1
    }
    grep -q 'SSHTERM_PROFILE_FIX' "$LOGIN" || {
        echo "    [!] failed to insert profile fix into bin/login" >&2
        exit 1
    }
fi

# 6e. The stock MOTD advertises `pkg install`, but this fork ships no package
#     manager on purpose. Telling users to run a command that does not exist is
#     worse than saying nothing, so replace the message.
if [ -f "$STAGE/etc/motd" ]; then
    cat > "$STAGE/etc/motd" <<'EOF'
Welcome to the SSH-only Termux build.

This build deliberately ships no package manager (no pkg/apt), so the
environment is fixed: bash, coreutils, sed, grep, gawk and an OpenSSH client.

Useful commands:

  ssh user@host          connect to a machine
  ssh-keygen             create a key pair
  ssh-copy-id user@host  install your public key on a host

To install more software, use your regular Termux install instead.
EOF
    echo "    replaced MOTD (no pkg/apt in this build)"
fi

# 6f. ncurses has the *stock* prefix compiled in as its terminfo search path, so
#     our binaries look in the other app's directory and report
#         terminals database is inaccessible
#     for `clear`, `tput` and anything else that needs a terminal description.
#     Point them at the fork's own copy instead.
cat > "$STAGE/etc/profile.d/02-sshterm-terminfo.sh" <<EOF
# Generated by setup/add-ssh.sh 6f — see the comment there.
# The shipped ncurses binaries were built for the stock prefix, so without this
# they cannot find their terminal database.
if [ -d "$FORK_PREFIX/share/terminfo" ]; then
    TERMINFO="$FORK_PREFIX/share/terminfo"
    export TERMINFO
fi
EOF
echo "    set TERMINFO for the fork's own terminfo database"

# Any remaining stock-$HOME references in scripts point at the other app's
# private directory. Writing there fails (or, worse, would succeed if the
# sandbox ever allowed it), so repoint them at our own home.
find "$STAGE/etc" "$STAGE/bin" -type f -size -2M -print0 2>/dev/null |
while IFS= read -r -d '' f; do
    grep -Iq . "$f" 2>/dev/null || continue
    grep -qF "$STOCK_HOME" "$f" 2>/dev/null || continue
    sed -i "s|$STOCK_HOME|$FORK_HOME|g" "$f"
    echo "    patched stock-home ref: ${f#"$STAGE"/}"
done

# 6d. init-termux-properties.sh copies a sample termux.properties out of
#     share/examples/, which the pruning pass deletes. Left as-is it prints a
#     `cp: bad ...` error on every shell start. Make the copy conditional.
PROPS_SH="$STAGE/etc/profile.d/init-termux-properties.sh"
if [ -f "$PROPS_SH" ] && grep -q 'share/examples/termux/termux.properties' "$PROPS_SH"; then
    EXAMPLE="$FORK_PREFIX/share/examples/termux/termux.properties"
    cat > "$PROPS_SH" <<EOF
if [ ! -f $FORK_HOME/.config/termux/termux.properties ] && [ ! -e $FORK_HOME/.termux/termux.properties ]; then
	mkdir -p $FORK_HOME/.termux
	if [ -f $EXAMPLE ]; then
		cp $EXAMPLE $FORK_HOME/.termux/
	fi
fi
EOF
    echo "    guarded optional termux.properties copy"
fi

# ---------------------------------------------------------------------------
# 7. Install the ssh wrapper that pins the library path
#
#    The RUNPATH of every ELF was already rewritten in step 6a, so these wrappers
#    are belt-and-braces: they also survive a future regression where a binary is
#    re-injected without patching. Kept deliberately.
# ---------------------------------------------------------------------------
echo "[*] installing ssh wrapper"
for tool in ssh scp sftp ssh-keygen ssh-keyscan ssh-copy-id ssh-add; do
    real="$STAGE/bin/$tool"
    [ -f "$real" ] || continue
    if [ ! -e "${real}.real" ]; then
        mv "$real" "${real}.real"
    fi
    cat > "$real" <<EOF
#!/system/bin/sh
# Generated by setup/add-ssh.sh — keeps the stock RUNPATH out of the picture.
LD_LIBRARY_PATH="$FORK_PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
exec "$FORK_PREFIX/bin/$tool.real" "\$@"
EOF
    chmod 755 "$real" "${real}.real"
done

# ---------------------------------------------------------------------------
# 8. Symlink targets created by the packages
#    (they are recorded by build-bootstrap.sh; remove duplicates here)
# ---------------------------------------------------------------------------
if [ -d "$STAGE/var/service" ]; then
    rm -rf "$STAGE/var/service"
fi

# ---------------------------------------------------------------------------
# 9. Prune everything not reachable from the ssh toolchain.
#    The stock bootstrap ships a full userland; keeping it defeats the point.
# ---------------------------------------------------------------------------
if [ "${SSHTERM_PRUNE_TO_SSH:-1}" = "1" ]; then
    echo "[*] pruning $FORK_PREFIX to the ssh toolchain"
    python3 "$SCRIPT_DIR/prune-to-ssh.py" "$STAGE" "$FORK_PREFIX"
fi

echo "[*] ssh injection complete"
