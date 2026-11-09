# Bootstrap

How `ssh` gets inside the APK, what was removed to make it small, and why it is done this way.

---

## 1. What a bootstrap is

A `bootstrap-<arch>.zip` is simply the contents of a `$PREFIX` directory, zipped with
**relative** entry paths (`bin/...`, `lib/...`). On first launch it is unpacked into:

```
/data/data/com.estiaksoyeb.termux/files/usr
```

It is produced upstream by the `termux-packages` repository
(`scripts/build-bootstraps.sh`), which cross-compiles packages and zips the result.

### The special file `SYMLINKS.txt`

A ZIP cannot store symbolic links reliably, so they are recorded at the **root** of the ZIP,
one per line, as:

```
<target>←<link>
```

The `←` is U+2190. `TermuxInstaller` splits each line on that character and creates the link.
A line without exactly one `←` aborts installation with *"Malformed symlink line"*.

This fork's archive has two:

```
dash←./bin/sh
../share/terminfo←./lib/terminfo
```

---

## 2. Why `$PREFIX` is baked in at build time

The ZIP layout is relative, but the compiled programs inside it are not:

- `PT_INTERP` — the dynamic linker path,
- `DT_RPATH` / `DT_RUNPATH` — library directories,
- script shebangs — `#!/data/data/<pkg>/files/usr/bin/bash`.

So the address must be known **before** the programs are built. This is why the
`applicationId` had to be chosen first, and why it is short: a shebang is limited to
**127 bytes** including `#!`.

This fork's value:

```
length("/data/data/com.estiaksoyeb.termux/files/usr") = 44
```

comfortably inside the limit.

---

## 3. The build pipeline

`setup/build-bootstrap.sh` runs five stages. Each is a separate script so it can be run and
inspected on its own.

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. fetch     stock aarch64 bootstrap ZIP from termux-packages       │
│              (30.5 MB, SHA-256 pinned)                              │
├─────────────────────────────────────────────────────────────────────┤
│ 2. inject    download official .deb files for openssh + deps        │
│              unpack into a staging tree, relocate the prefix        │
│              install LD_LIBRARY_PATH wrapper scripts                │
├─────────────────────────────────────────────────────────────────────┤
│ 3. prune     delete everything outside ssh's ELF dependency closure │
│              rewrite SYMLINKS.txt                                   │
├─────────────────────────────────────────────────────────────────────┤
│ 4. verify    ssh present, closure complete, symlinks valid          │
├─────────────────────────────────────────────────────────────────────┤
│ 5. zip       bootstrap-aarch64.zip  →  app/src/main/cpp/            │
└─────────────────────────────────────────────────────────────────────┘
```

Result: **30.5 MB → 8.7 MB** compressed, **21.5 MB** unpacked (230 entries).

The earliest build was 8.1 MB / 23 files, but that archive was too thin to be usable: it had
no `chmod`, `mkdir`, `ls` or `cat` at all. The extra ~0.6 MB is `bin/coreutils` (1.2 MB
on disk, its aliases are symlinks) and `libandroid-selinux.so`, which coreutils needs.

### Where the original 30.5 MB actually went

Measured from the real stock archive (`2026.02.12-r1+apt.android-7`):

| Item | Size |
|---|---|
| `bootstrap-aarch64.zip` (compressed, embedded in APK) | **30.5 MB** |
| Uncompressed `$PREFIX` (installed footprint) | **73.6 MB** |
| `lib/` | 28.1 MB |
| `bin/` | 13.7 MB |
| `share/info` | 8.4 MB |
| `include/` (C headers) | 7.2 MB |
| `share/doc` | 7.1 MB |
| `installed-tests/` | 2.8 MB |
| `share/man` | 2.6 MB |

The conclusion that shaped this project: **70–80 % of the app's size is the embedded
bootstrap**, not the app code. The Java/UI/assets are negligible. Shrinking the archive is
therefore the only lever worth pulling, and pruning headers, docs, man pages and tests is
where most of the win comes from.

---

## 4. Stage 2 — why the `.deb` injection works

### The problem

The stock bootstrap does **not** contain `ssh`. Upstream installs it later with `apt`. This
fork has no `apt`, deliberately, so `ssh` must be present from the start.

### The obvious solution, and why it was rejected

Build `openssh` and its dependencies from source with the correct prefix. Correct, but it
needs the `termux-packages` build environment — a Docker image or a full cross-compile
setup — with hours of compilation, and the Docker route was ruled out.

### The solution used

Take the **official Termux arm64 `.deb` packages** and relocate them.

These are the packages that matter, and why each is required:

| Package | Required | Provides / why |
|---|---|---|
| `openssh` | yes | `ssh`, `scp`, `sftp`, `ssh-keygen` |
| `openssl` | yes | `libcrypto`, `libssl` — the actual cryptography |
| `ca-certificates` | yes | `etc/tls/cert.pem`; without it host verification fails |
| `zlib` | yes | SSH compression |
| `libc++_shared` | yes | C++ runtime the above link against |
| `bash` / `dash` | yes | login shell; `dash` is far smaller |
| `termux-exec` | yes | **mandatory** — fixes shebang/`PATH` handling on Android |
| `ncurses` | yes | readline for bash and ssh |
| `coreutils` / busybox | yes | basic utilities (`ls`, `cat`, `env`, …) |

Deliberately **excluded**: `apt`, `dpkg`, `gpgv`, `command-not-found`, `termux-am`,
`termux-licenses`, C headers (`include/`), documentation (`share/doc`, `share/info`,
`share/man`), `installed-tests/`.

This works because of how Termux binaries are linked:

| Property | Value | Consequence |
|---|---|---|
| Interpreter | `/system/bin/linker64` | **prefix-independent** — Android's own linker, present on every device |
| `RUNPATH` | `/data/data/com.termux/files/usr/lib` | points at the *old* prefix |
| Compiled-in paths | `/data/data/com.termux/files/usr/etc/…` | bash's profile, ncurses' terminfo, etc. |

The `RUNPATH` must be rewritten in **every** ELF, not just the ssh tools — `bash` is the login
shell, and if its `RUNPATH` still points at the other app it dies before the prompt appears:

```
CANNOT LINK EXECUTABLE ".../bin/bash": library "libandroid-support.so" not found
```

Three mechanisms handle this:

1. **`patchelf` on every ELF** (default, `setup/add-ssh.sh` step 6a) — the `RUNPATH` lives in the
   ELF, and the new prefix is longer than the old one, so patching bytes in place would shift
   everything after it and corrupt the file. `patchelf` relocates the string table properly.
   A verification pass then aborts the build if *any* ELF still mentions the stock prefix.

2. **Text rewriting** (step 6b) — any file containing the old prefix string is rewritten. This
   covers `.conf` files, scripts and similar.

3. **Targeted fixes for compiled-in behaviour** (steps 6c–6f) — a path baked into a binary is
   not covered by either of the above, because changing its length would break the ELF:
   - `bin/login` stops passing `-l` and sources the fork's own `etc/profile` instead. As a login
     shell, bash otherwise reads the stock `etc/profile`, which lives in the other app's private
     directory, producing
     `bash: /data/data/com.termux/files/usr/etc/profile: Permission denied`.
   - the same script passes `--norc`, because an interactive bash reads the stock
     `etc/bash.bashrc` before any `--rcfile` is honoured.
   - `etc/profile.d/02-sshterm-terminfo.sh` exports `TERMINFO` pointing at the fork's own copy,
     otherwise ncurses reports `terminals database is inaccessible` for `clear`.

`LD_LIBRARY_PATH` wrapper scripts are still installed for the ssh tools as defence in depth
(pairs such as `ssh`/`ssh.real`), but they are no longer the primary mechanism: they only ever
covered the ssh binaries, which is exactly why `bash` was broken while `ssh` worked.

> **Analogy.** The old address is printed inside the machine in a way that is hard to erase.
> Originally we put a redirect note on just one door — the ssh door — so everything entering
> through that door was fine, while everything else still walked to the old address and got
> turned away. Now every machine has its own address corrected, and a few appliances that
> cannot be re-engraved are simply handed a note as they start.

---

## 5. Stage 3 — pruning to the ssh closure

`setup/prune-to-ssh.py` deletes everything that `ssh` cannot reach.

The **closure** is computed by walking ELF `NEEDED` entries and script interpreter references
from the wanted binaries, transitively. Anything not reached is removed: headers, docs, man
pages, `apt`/`dpkg`, tests, `termux-am`, and every program unrelated to ssh.

Kept:

| Path | Contents |
|---|---|
| `bin/` | 24 files: `ssh`, `scp`, `sftp`, `ssh-keygen`, `ssh-keyscan`, `ssh-add`, `ssh-copy-id` (each with a `.real`), `bash`, `dash`, `sh→dash`, `login`, `sed`, `grep`, `gawk`, `clear`, `coreutils`, `termux-exec-*` |
| `lib/` | 28 shared libraries — the resolved dependency closure |
| `etc/ssh/` | ssh client configuration |
| `etc/tls/` | CA certificates (without these, host verification fails) |
| `libexec/`, `share/` | what remains after closure filtering |

### Coreutils aliases

`chmod`, `mkdir`, `ls`, `cat`, `rm`, … are **not** separate programs. They are symlinks to one
multi-call binary, `bin/coreutils`, and in the stock ZIP they exist only as `SYMLINKS.txt`
entries — there is no `bin/chmod` file to find.

Two things follow, and both were bugs:

- `bin/coreutils` must be kept explicitly, or every alias dangles. It must also join the ELF
  closure walk, otherwise its `NEEDED` library `libandroid-selinux.so` is dropped.
- A symlink target is resolved **relative to the link's own directory**:
  `coreutils←./bin/chmod` means `bin/chmod` → `bin/coreutils`. Code that strips `./` from a
  target must not also eat the leading dots of `../share/terminfo`, or that link silently
  disappears and `clear` breaks.

`SYMLINKS.txt` is rewritten afterwards so it only lists links that still exist. It ends up with
**121** entries: 100 coreutils aliases, the `.so` soname links, `bin/sh`, and `lib/terminfo`.

An entry whose name is *also* a real file is removed: `TermuxInstaller` extracts all real files
first and then calls `symlink()` for each entry, so a duplicate name throws `EEXIST` and aborts
the entire install. `build-bootstrap.sh` fails the build if such a collision ever appears.

---

## 6. Auto-connect (not implemented)

There is a well-defined hook for making the app open an SSH connection immediately, without
changing any Java:

`UnixShellEnvironment.LOGIN_SHELL_BINARIES` is `{"login", "bash", "zsh", "fish", "sh"}`.
The first **executable** match in `$PREFIX/bin` is run as the login shell. Because `login`
comes first, replacing `$PREFIX/bin/login` with a small script wins:

```sh
#!/data/data/com.estiaksoyeb.termux/files/usr/bin/sh
exec /data/data/com.estiaksoyeb.termux/files/usr/bin/ssh -p 8022 user@127.0.0.1
```

**This is deliberately not done.** The archive ships a `login` script that sources the fork's
own `etc/profile` and then opens a local `bash` (see step 6c above) — the same behaviour as
Termux. Connecting to Ubuntu is a manual `ssh …` for now.

Keep `bash` and `sh` in place if this is ever enabled, so a failed connection still leaves a
usable shell.

---

## 7. How the ZIP gets into the APK

`app/src/main/cpp/termux-bootstrap-zip.S`:

```asm
.section .rodata
blob:
#if defined __aarch64__
    .incbin "bootstrap-aarch64.zip"
#elif ...
1:
blob_size:
    .int 1b - blob
```

`.incbin` is an assembler directive: the file's raw bytes are copied into the output with no
compression or transformation. `termux-bootstrap.c` exposes them through JNI as `getZip()`,
which `TermuxInstaller.loadZipBytes()` reads.

Because the arch macro selects one file, an arm64 build needs **only**
`bootstrap-aarch64.zip`.

---

## 8. Timeline

| When | What happens |
|---|---|
| Build | ZIP embedded verbatim in `libtermux-bootstrap.so` |
| Install | nothing extracted |
| First launch | extracted to a staging dir, symlinks created, exec bits set, renamed to `$PREFIX` |
| Later launches | extraction skipped, `$PREFIX/bin/ssh` is a normal file |

---

## 9. Verifying the archive by hand

```bash
cd /root/Forks/termux-app
Z=app/src/main/cpp/bootstrap-aarch64.zip

unzip -l "$Z" | tail -2                     # size + entry count
unzip -p "$Z" SYMLINKS.txt                  # symlinks (expect 121)
unzip -l "$Z" | grep -E 'bin/(ssh|bash|login|coreutils|clear)$'

# No shipped file may still reference the stock prefix. This is the check that
# was missing when `bash` broke with "libandroid-support.so not found".
mkdir -p /tmp/opencode/zb && cd /tmp/opencode/zb && unzip -oq "/root/Forks/termux-app/$Z"
find . -type f -print0 | while IFS= read -r -d '' f; do
  grep -Iq . "$f" 2>/dev/null && grep -lF "/data/data/com.termux/files" "$f"
done; echo "text check done (no output above = clean)"

# Every ELF must be aarch64 AND resolve all of its NEEDED libraries.
find . -type f -print0 | while IFS= read -r -d '' f; do
  head -c4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
  file "$f" | grep -qv AArch64 && echo "WRONG ARCH: $f"
  for n in $(readelf -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
    case "$n" in libc.so|libdl.so|libm.so|liblog.so|libandroid.so) continue;; esac
    [ -e "lib/$n" ] || echo "MISSING LIB: $f needs $n"
  done
done; echo "elf check done (no output above = clean)"
```

---

## 10. Why the bootstrap is not built by Gradle

| Concern | Separate script |
|---|---|
| Network failures | do not break `./gradlew` |
| Inspectability | the tree can be examined before zipping |
| Rebuild cost | the ZIP survives `clean` |
| Tool choice | plain shell/python, no Gradle plugin |

This required two small changes in `app/build.gradle`, both controlled by
`skipStockBootstrapDownload`:

- `downloadBootstraps` returns immediately instead of overwriting the archive,
- `clean` no longer deletes `bootstrap-*.zip`.

---

## 11. Known limitation

The injected `.deb` packages are taken from the official Termux repository, which builds
them for `com.termux`'s prefix. Relocation makes them work, but it is not a clean rebuild.
The consequences:

- `RUNPATH` is rewritten by `patchelf`, so that part is genuinely fixed rather than masked;
- paths **compiled into** a binary (bash's profile, ncurses' terminfo) cannot be rewritten
  because the replacement is longer, so they are worked around at runtime (steps 6c–6f);
- version pinning is by download date, not by a manifest;
- a future clean solution is a proper cross-compile, which would remove all three caveats.

This trade-off was accepted deliberately: it produces a working `ssh` today, offline, with
no Docker.
