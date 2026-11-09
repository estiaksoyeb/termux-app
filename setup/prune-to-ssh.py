#!/usr/bin/env python3
"""Prune a bootstrap staging tree down to what an ssh client actually needs.

Usage: prune-to-ssh.py <staging-dir> <prefix>

Keeps:
  - the login shell and its termux-exec hooks,
  - the ssh binaries and their ELF dependency closure,
  - certificates and ssh config,
  - termux bootstrap second-stage / login profile files,
  - the shim utilities required by termux-exec and the login flow,
  - the vim editor, injected from the vim package, with its runtime.

Everything else (git, python, coreutils tree, apt, extra libs, man
pages, tests) is deleted, together with its SYMLINKS.txt entries.
"""

import os
import re
import subprocess
import sys

SYSTEM_LIBS = {"libc.so", "libdl.so", "libm.so", "liblog.so", "libandroid.so"}

# Executables that must survive regardless of the ELF closure.
REQUIRED_BINS = {
    "sh", "bash", "dash", "login", "termux-exec-system-linker-exec",
    "termux-exec-ld-preload-lib",
    "ssh", "ssh.real", "scp", "scp.real", "sftp", "sftp.real",
    "ssh-keygen", "ssh-keygen.real", "ssh-keyscan", "ssh-keyscan.real",
    "ssh-copy-id", "ssh-copy-id.real", "ssh-add", "ssh-add.real",
    "env", "cat", "chmod", "mkdir", "ln", "rm", "cp", "mv", "ls", "stat",
    "readlink", "dirname", "basename", "touch", "mktemp", "id", "uname",
    "which", "sed", "grep", "awk", "gawk", "tr", "head", "tail", "sort",
    "wc", "cut", "tee", "sleep", "date", "printf", "test", "[", "true", "false",
    # terminal basics: `clear` is its own ncurses binary, not a coreutils alias
    "clear", "tput",
    # editor: injected by add-ssh.sh from the vim package (not in the stock bootstrap).
    # Its entry points are symlinks to libexec/vim/vim, so keep the real binary too.
    "vim", "vi", "ex", "view", "vimdiff", "vimtutor", "editor",
}

REQUIRED_LIBEXEC_PREFIXES = ("coreutils",)

KEEP_ETC_PREFIXES = (
    "ssh", "tls", "termux", "profile", "profile.d", "bash.bashrc",
    "motd", "termux-login.sh", "nsswitch.conf", "hosts", "resolv.conf",
    "passwd", "group", "inputrc", "terminfo",
)

KEEP_SHARE_PREFIXES = (
    "terminfo", "termux", "misc", "ca-certificates", "zoneinfo", "i18n",
    # vim runtime: syntax, ftplugin, colors, autoload and the global vimrc
    "vim",
)


def elf_needed(path):
    try:
        out = subprocess.run(
            ["readelf", "-dW", path], capture_output=True, text=True, timeout=20
        ).stdout
    except Exception:
        return []
    return re.findall(r"NEEDED.*\[(.*?)\]", out)


def is_elf(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(4) == b"\x7fELF"
    except OSError:
        return False


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    stage, prefix = sys.argv[1], sys.argv[2]
    bindir = os.path.join(stage, "bin")
    libdir = os.path.join(stage, "lib")

    # ---- build the keep set ------------------------------------------------
    keep = set()

    def keep_path(relpath):
        full = os.path.join(stage, relpath)
        if os.path.lexists(full):
            keep.add(relpath)

    for b in REQUIRED_BINS:
        keep_path(os.path.join("bin", b))

    # Coreutils is one multi-call binary; `chmod`, `mkdir`, `ls`, ... are
    # symlinks to it. In the stock ZIP those aliases only exist as SYMLINKS.txt
    # entries, so keep_path("bin/chmod") above finds nothing and silently skips
    # it. Keep the real binary explicitly or every alias dangles.
    keep_path(os.path.join("bin", "coreutils"))

    # bin/sh is a symlink (-> dash). Record the entry so it is not dropped
    # below, and make sure its target is kept too.
    dash_link = os.path.join(bindir, "sh")
    if os.path.islink(dash_link):
        keep.add(os.path.join("bin", "sh"))
        keep_path(os.path.join("bin", os.readlink(dash_link)))

    # Walk the ELF closure from every kept binary plus the ssh tools.
    queue = [os.path.join("bin", f) for f in os.listdir(bindir)
             if f.endswith(".real")] if os.path.isdir(bindir) else []
    queue += [os.path.join("bin", b) for b in REQUIRED_BINS
              if os.path.lexists(os.path.join(bindir, b))]
    # coreutils was only added to `keep` above; it must join the closure walk
    # too, otherwise its NEEDED libs (libandroid-selinux.so) are dropped.
    queue.append(os.path.join("bin", "coreutils"))

    # vim lives in libexec/vim/ and bin/vim is a symlink to it. Keep the whole
    # directory and walk its ELFs so libsodium/libiconv join the closure.
    vim_dir = os.path.join(stage, "libexec", "vim")
    if os.path.isdir(vim_dir):
        for name in os.listdir(vim_dir):
            rel = os.path.join("libexec", "vim", name)
            if os.path.isfile(os.path.join(stage, rel)):
                queue.append(rel)

    seen = set()
    while queue:
        rel = queue.pop()
        if rel in seen:
            continue
        seen.add(rel)
        full = os.path.join(stage, rel)
        if not os.path.isfile(full) or not is_elf(full):
            continue
        keep.add(rel)
        for lib in elf_needed(full):
            if lib in SYSTEM_LIBS:
                continue
            librel = os.path.join("lib", lib)
            libfull = os.path.join(stage, librel)
            # Follow symlinks to the real file.
            if os.path.islink(libfull):
                keep.add(librel)
                target = os.path.realpath(libfull)
                try:
                    realrel = os.path.relpath(target, stage)
                    keep.add(realrel)
                    queue.append(realrel)
                except ValueError:
                    pass
            elif os.path.exists(libfull):
                queue.append(librel)

    # Termux shims required for the login flow.
    for d in REQUIRED_LIBEXEC_PREFIXES:
        libexec = os.path.join(stage, "libexec", d)
        if os.path.isdir(libexec):
            for name in os.listdir(libexec):
                keep_path(os.path.join("libexec", d, name))

    # Keep the whole of etc/ssh, tls and termux bootstrap bits.
    for root in ("etc", "share"):
        base = os.path.join(stage, root)
        if not os.path.isdir(base):
            continue
        for name in os.listdir(base):
            if name.startswith(KEEP_ETC_PREFIXES if root == "etc" else KEEP_SHARE_PREFIXES):
                keep_path(os.path.join(root, name))

    keep.add("SYMLINKS.txt")

    # ---- delete everything else -------------------------------------------
    removed_entries = 0
    for root_name in sorted(os.listdir(stage)):
        if root_name in ("SYMLINKS.txt", "tmp"):
            continue
        root_path = os.path.join(stage, root_name)
        if not os.path.isdir(root_path):
            continue
        for dirpath, dirnames, filenames in os.walk(root_path, topdown=False):
            for name in filenames + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, stage)
                if rel in keep or any(rel.startswith(k + os.sep) for k in keep):
                    continue
                try:
                    os.remove(full)
                    removed_entries += 1
                except OSError:
                    pass
            # Drop empty directories.
            if not os.listdir(dirpath):
                try:
                    os.rmdir(dirpath)
                except OSError:
                    pass

    # Remove empty top-level dirs too.
    for root_name in sorted(os.listdir(stage)):
        full = os.path.join(stage, root_name)
        if os.path.isdir(full) and not os.listdir(full):
            try:
                os.rmdir(full)
            except OSError:
                pass

    # ---- re-filter SYMLINKS.txt -------------------------------------------
    # Keep only symlinks we explicitly depend on. A link is kept when:
    #   - it is a required bin alias (bin/sh -> dash), or
    #   - it lives under lib/ and its target still exists (soname links), or
    #   - it lives under lib/ and points at share/terminfo.
    symlinks_path = os.path.join(stage, "SYMLINKS.txt")
    if os.path.isfile(symlinks_path):
        kept, dropped = [], 0
        with open(symlinks_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line:
                    continue
                target, link = line.split("\u2190")
                link_rel = link.lstrip("./")
                # NOTE: do NOT lstrip("./") on the target. It would also eat the
                # leading dots of a parent reference, turning "../share/terminfo"
                # into "share/terminfo", which then matches nothing. Only strip a
                # single leading "./".
                target_rel = target[2:] if target.startswith("./") else target
                # A symlink target is resolved relative to the LINK's directory,
                # not the prefix root: `coreutils←./bin/chmod` creates
                # bin/chmod pointing at `coreutils` *inside bin/*.
                target_exists = os.path.lexists(
                    os.path.normpath(os.path.join(
                        stage, os.path.dirname(link_rel), target_rel)))

                keep_it = False
                if link_rel in ("bin/sh", "bin/dash", "bin/bash"):
                    keep_it = True
                # vim entry points (bin/vim -> ../libexec/vim/vim, ...), added to
                # SYMLINKS.txt by add-ssh.sh because the package normally creates
                # them through update-alternatives.
                elif link_rel.startswith("bin/") and target_rel.startswith("../libexec/vim/"):
                    keep_it = True
                # Coreutils aliases (bin/ls -> coreutils): keep the alias as long
                # as the real multi-call binary survived the prune. Without these
                # the shell has no ls/cat/mkdir/chmod and is unusable.
                elif link_rel.startswith("bin/") and target_rel == "coreutils" \
                        and target_exists:
                    keep_it = True
                elif link_rel.startswith("lib/") and (
                    target_exists or target_rel.startswith("../share/terminfo")
                ):
                    keep_it = True

                # TermuxInstaller extracts every real file first, then calls
                # symlink() for each entry. Creating a link whose name is already
                # a real file throws EEXIST and aborts the whole install, so a
                # colliding entry must never be written. (The real file provides
                # the name anyway.)
                if keep_it and os.path.lexists(os.path.join(stage, link_rel)):
                    keep_it = False

                if keep_it:
                    kept.append(line)
                else:
                    dropped += 1
        with open(symlinks_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(kept) + ("\n" if kept else ""))
        print("    removed %d files, %d symlink entries" % (removed_entries, dropped))
        print("    kept symlinks: %s" % ", ".join(l.split("\u2190")[1] for l in kept))
    else:
        print("    removed %d files" % removed_entries)

    return 0


if __name__ == "__main__":
    sys.exit(main())
