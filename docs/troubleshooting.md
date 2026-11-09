# Troubleshooting

Errors actually encountered while building this fork, what they mean, and the fix.
Ordered roughly by how early they appear.

---

## Build configuration

### `Could not get unknown property 'include' for … AbiSplitOptions`

**Meaning:** something tried to *read* `android.splits.abi.include`.

**Cause:** it is a write-only property in AGP 8.13.2; only `include '…'` assignment works,
never `.clear()` or `.add()`.

**Fix:** restrict ABIs with `defaultConfig.ndk.abiFilters` and disable splits separately.

---

### `Conflicting configuration : 'arm64-v8a' in ndk abiFilters cannot be present when splits abi filters are set : …`

**Cause:** `abiFilters` and `splits.abi` were both configured.

**Fix:** set `splits.abi.enable = false` before adding `abiFilters`.

---

### `Unresolved reference 'ext'` / `Unresolved reference 'path'` in `local-env.gradle.kts`

**Cause:** a Kotlin script applied via `apply(from=…)` has a minimal Gradle API and no typed
accessors.

**Fix:** keep `local-env.gradle.kts` to `gradle.extra.set(...)` and do DSL work in Groovy.

---

### `Could not get unknown property 'keepLocalBootstrap' for project ':app'`

**Cause:** a local variable defined at script scope is not visible inside a `doLast { }`
closure.

**Fix:** use `project.ext.keepLocalBootstrap = …` and read it as `project.ext.…`.

---

### `Skipping stock bootstrap download` never happens / stock ZIP reappears

**Cause:** `downloadBootstraps` ran and overwrote the custom archive.

**Fix:** ensure `ext.skipStockBootstrapDownload = true` is set **before** the task body runs
(it is an `ext` property, evaluated at configuration time).

---

### `bootstrap-arm.zip: No such file or directory` during `.incbin`

**Cause:** a module is building an ABI other than arm64.

**Fix:** apply the `abiFilters` restriction to **all** modules, not just `:app`.

---

## Native / NDK

### `ld.lld: error: unable to find library -lgcc`

**Cause:** on this aarch64 host, the NDK has no `libgcc.a` for API < 24 and the driver cannot
resolve the flag.

**Fix:** run `eval "$(./setup/ndk-shim.sh --env)"` before Gradle.

**Do not** simply strip `-lgcc` — see the next entry.

---

### `ld.lld: error: undefined symbol: _Unwind_Resume` / `__aarch64_ldadd4_acq_rel`

**Cause:** `-lgcc` was *removed* instead of *translated*. In a real Android link it stands for
`libunwind.a` + `libclang_rt.builtins-<abi>-android.a`.

**Fix:** use the linker wrapper from `setup/ndk-shim.sh`, which substitutes those archives.

---

### `clang: error: cannot open crtbegin_so.o`

**Cause:** `--sysroot PATH` (two tokens) is not rewritten by the system driver.

**Fix:** the clang wrapper rewrites it to `--sysroot=PATH`. Regenerate with
`./setup/ndk-shim.sh`.

---

### `python3: 1: Syntax error: word unexpected (expecting ")")`

**Cause:** ndk-build found the NDK's bundled `python3`, which is an x86-64 binary.

**Harmless in most cases**, but set `NDK_HOST_PYTHON` to a real interpreter to silence it —
the shim's `make` and `ndk-build` wrappers do this by default.

---

### The shim is ignored: the build still uses the real NDK

**Checks, in order:**

1. `echo "$GNUMAKE"` — must point at `<shadow>/host-make/make`.
2. Re-run `eval "$(./setup/ndk-shim.sh --env)"`; a new shell loses it.
3. Confirm the shadow's own `ndk-build` is the generated one, not a symlink:
   `head -3 /tmp/opencode/ndk-shadow/ndk-build`.
4. `android.ndkPath` and `ANDROID_NDK_HOME` will **not** help; they are ignored.

---

### `error: unknown argument: '-fno-canonical-system-headers'`

**Cause:** that flag belongs to GCC. Clang (this host) rejects it.

**Fix:** do not add host-compiler flags by hand; let ndk-build supply them.

---

### Duplicate `lib/arm64-v8a/libtermux-bootstrap.so` in `mergeDebugNativeLibs`

**Cause:** stale outputs from an earlier build with different ABI settings.

**Fix:**

```bash
rm -rf app/build/intermediates/cxx \
       termux-shared/build/intermediates/cxx \
       terminal-emulator/build/intermediates/cxx \
       terminal-view/build/intermediates/cxx \
       app/build/intermediates/merged_native_libs \
       app/build/intermediates/stripped_native_libs
```

---

## Bootstrap

### `Malformed symlink line` at first launch

**Cause:** a line in `SYMLINKS.txt` does not contain exactly one `←` (U+2190).

**Fix:** regenerate with `./setup/build-bootstrap.sh`, then inspect:

```bash
unzip -p app/src/main/cpp/bootstrap-aarch64.zip SYMLINKS.txt | cat -A
```

---

### `CANNOT LINK EXECUTABLE … library "…" not found`

**Cause:** the ELF's `RUNPATH` still points at the stock prefix
(`/data/data/com.termux/files/usr/lib`), which belongs to the other app.

This is the bug that shipped in the first working APK: only the ssh tools had their
`RUNPATH` fixed (via `LD_LIBRARY_PATH` wrappers), so `ssh` worked while `bash` — the login
shell — failed immediately with:

```
CANNOT LINK EXECUTABLE "/data/data/com.estiaksoyeb.termux/files/usr/bin/bash":
library "libandroid-support.so" not found
```

**Diagnose:**

```bash
# on the build machine, inside the extracted archive
readelf -d bin/bash | grep -E 'NEEDED|RUNPATH|RPATH'
```

`RUNPATH` must read `/data/data/com.estiaksoyeb.termux/files/usr/lib`. If it says
`com.termux`, the archive is bad — it is **not** harmless.

**Fix:** `patchelf` now rewrites every ELF by default (`SSHTERM_PATCHELF=1`). Re-run
`./setup/build-bootstrap.sh`; step 6a-check aborts if any stale path survives.

---

### `bash: /data/data/com.termux/files/usr/etc/profile: Permission denied`

**Cause:** a different problem from the one above. The `RUNPATH` is fine; the path is compiled
**into** bash as its login profile, and our app cannot read the other app's private directory.

It cannot be patched in place: the replacement is 12 bytes longer, so byte surgery would shift
the rest of the ELF and corrupt it.

**Fix:** `setup/add-ssh.sh` step 6c rewrites `bin/login` so it sources the fork's own
`etc/profile` and never passes `-l`. It also passes `--norc`, because an interactive bash reads
the stock `etc/bash.bashrc` before any `--rcfile` is honoured.

**Verify on device:**

```bash
adb shell "run-as com.estiaksoyeb.termux sh -c \
  'P=/data/data/com.estiaksoyeb.termux/files/usr; TERM=xterm \$P/bin/login -c \"echo LOGIN_OK\"'"
```

---

### `terminals database is inaccessible`

**Cause:** ncurses has the stock prefix compiled in as its terminfo search path.

**Fix:** `etc/profile.d/02-sshterm-terminfo.sh` exports `TERMINFO` to the fork's own
`share/terminfo`. If `clear` fails, check that `lib/terminfo` is a symlink to
`../share/terminfo` (the pruner used to drop it — see [bootstrap.md](bootstrap.md)).

---

### `bash: clear: command not found` / `ls: not found`

**Cause:** over-pruning. `chmod`, `mkdir`, `ls`, `cat` are symlinks to `bin/coreutils`; if the
multi-call binary is dropped, they all vanish. `clear` is its own ncurses binary and was never
in the keep list until it was added explicitly.

**Check:** `unzip -l app/src/main/cpp/bootstrap-aarch64.zip | grep -E 'bin/(coreutils|clear)$'`

---

### `symlink failed: EEXIST (File exists)` at first launch

**Cause:** a `SYMLINKS.txt` entry has the same name as a real file in the ZIP. `TermuxInstaller`
extracts real files first, then creates links, so the duplicate name aborts the whole install.

**Fix:** the pruner drops any entry whose name already exists. `build-bootstrap.sh` now fails
the build (`symlink/file collisions`) instead of letting this reach a device.

---

### `vim` is missing after an upgrade

**Cause:** the app only extracts the bootstrap when `$PREFIX` is empty. Installing a new APK over an
existing install leaves the old prefix in place, so vim never appears.

**Fix:** remove (or rename) `files/usr` and start the app; it reinstalls the prefix from the new
APK. Your `files/home` — dotfiles, `.ssh`, editor history — is untouched because it lives beside
`usr`, not inside it.

---

### `E117: Unknown function` / `E1186` / no syntax highlighting in `vim`

**Cause:** vim finds no runtime files. It has the *stock* prefix compiled in and would look in the
other app's `share/vim`.

**Fix:** `setup/add-ssh.sh` writes `etc/profile.d/03-sshterm-vimruntime.sh`, which exports
`VIMRUNTIME` to the fork's own `share/vim/vim92`. Check with:

```sh
echo $VIMRUNTIME
vim -es -c 'syntax on' -c 'echo &syntax' -c 'q' somefile.sh
```

The second line prints `sh` when the runtime is found.

---

### The terminal font is not Roboto Mono

**Cause:** the bundled font lives in the APK as `res/font/roboto_mono.ttf` and is used only when
`~/.termux/font.ttf` does not exist
(`TermuxTerminalSessionActivityClient.checkForFontAndColors()`).

**Check:** `ls -l ~/.termux/font.ttf`. A file there wins over the bundled font, by design — it is
how the user installs their own.

**Fix:** delete that file and restart the app to go back to the bundled font.

---

### `ssh: not found`

**Cause:** the archive is the stock one without openssh, or injection was skipped.

**Check:** `unzip -l app/src/main/cpp/bootstrap-aarch64.zip | grep bin/ssh`

---

### `ssh` connects but host verification fails

**Cause:** CA certificates missing from the archive (`etc/tls/cert.pem`).

**Check:** `unzip -l app/src/main/cpp/bootstrap-aarch64.zip | grep etc/tls`

---

### `ssh` reads the *stock* Termux `known_hosts`

**Symptom:** connecting prints

```
hostkeys_find_by_key_hostfile: hostkeys_foreach failed for
/data/data/com.termux/files/home/.ssh/known_hosts: Permission denied
```

or ssh silently consults stock Termux's known-hosts list.

**Cause:** OpenSSH builds its default `UserKnownHostsFile`, `GlobalKnownHostsFile` and
`IdentityFile` paths from the passwd home/prefix compiled into the binary. Android has
no usable passwd entry, so Termux bakes in `/data/data/com.termux/files/home` and
`/data/data/com.termux/files/usr`. Setting `$HOME` does **not** override these —
verified with `ssh.real -G`.

**Why not patch the binary:** the fork's path is 12 bytes longer, the compiled-in string
has no slack after it, and every loaded segment is packed solid (RX `filesz` ends exactly
where `.plt` ends). A same-length in-place edit works, but a longer one needs a full ELF
relayout. Relocating into `.data` corrupts the string because that segment's first page is
overlapped by the preceding `LOAD` under 16 KB pages.

**Fix:** the generated wrapper in `setup/add-ssh.sh` (step 7) passes the correct paths with
`-o`, which OpenSSH honours over the compiled-in defaults. Only `ssh`, `scp` and `sftp`
take these options; `ssh-add`, `ssh-keygen`, `ssh-keyscan` and `ssh-copy-id` reject `-o`
(and `ssh-copy-id` is a shell script that calls `ssh` itself, so it inherits the fix).

**Check:**

```sh
ssh -G -- localhost | grep -E 'userknownhostsfile|globalknownhostsfile'
```

Both lines must start with `/data/data/com.estiaksoyeb.termux/`, not `com.termux`.

---

### Every connection asks to trust the host again (`yes` each time)

**Symptom:** after answering `yes`, the next connection asks again, and the previous one
printed

```
Failed to add the host to the list of known hosts (…/.ssh/known_hosts)
```

**Cause:** ssh never creates `~/.ssh` itself. With stock Termux the directory already
exists, so this only shows up on a fresh fork: nothing is saved, so nothing is remembered.

**Fix:** `etc/profile.d/04-sshterm-ssh-dir.sh` creates `~/.ssh` with mode `700` on first
shell start. For an installation that predates it:

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
```

**Check:** `ls -la ~/.ssh/known_hosts` after accepting a host key — the file should exist
and grow with each new host.

---

### `no such identity: …/.ssh/id_rsa: No such file or directory`

**Cause:** ssh was given absolute `-o IdentityFile` paths, so it announced every key that
did not exist. Its real default is `~/.ssh/id_*` (six entries, including the `_sk`
variants), expanded against `$HOME` at runtime and correct without any override.

**Fix:** the wrapper no longer sets `IdentityFile`. Nothing is left to silence — a missing
key is simply not mentioned.

---

## Verification / results

### Native libraries are not 16 KB aligned

**Cause:** `-Wl,-z,max-page-size=16384` missing from an `Android.mk`.

**Check:** `readelf -lW lib/arm64-v8a/libtermux.so | grep LOAD` → last column must be `0x4000`.

---

### The embedded bootstrap "differs" from the built archive

**This is expected in one specific way.** `readelf -SW` reports the `.rodata` section as
4 bytes larger than the ZIP: the assembler pads it. Compare with `startswith`, not `==`:

```python
embedded.startswith(built)   # True
```

---

### `INSTALL_FAILED_UPDATE_INCOMPATIBLE` on install

**Cause:** installing over an app with the same package name but a different signature.

**Check:** `aapt2 dump badging <apk> | grep '^package:'` must show
`com.estiaksoyeb.termux`. If it shows `com.termux`, **stop** — that APK would replace stock
Termux.

---

## Where to look in the logs

| Log | Content |
|---|---|
| `/tmp/opencode/build-apk.log` | last Gradle build |
| `/tmp/opencode/ndkbuild.log` | last standalone `ndk-build` run |
| `/tmp/opencode/bootstrap-rebuild.log` | last bootstrap build |
| `app/build/reports/problems/problems-report.html` | Gradle's own diagnostics |

---

## Nuclear option

Only for build artefacts — it does not touch source, the bootstrap ZIP, or any user data:

```bash
cd /root/Forks/termux-app
./gradlew clean
rm -rf .gradle app/build */build
./setup/build-bootstrap.sh
eval "$(./setup/ndk-shim.sh --env)"
./gradlew :app:assembleDebug
```
