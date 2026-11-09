# Decisions

Every significant choice, the alternatives considered, and why the one in place won.
Use this when you want to change something: the reasoning for the current state is here.

---

## Goal and non-goals

**Goal.** A small, personal, sideloadable terminal app that connects over SSH to an Ubuntu
environment already running inside stock Termux, looks and behaves like a normal terminal,
and **never touches** the existing `com.termux` installation or its data.

**Non-goals** (each is a decision, not an oversight):

- no `pkg`/`apt` inside this app — software lives in Ubuntu,
- no chroot/proot management inside this app,
- no plugin support (`Termux:API`, `:Boot`, `:Float`, `:Tasker`, `:Widget`),
- no replacement or upgrade path over the official Termux package,
- no auto-connect on launch (explicitly out of scope for now).

---

## Identity

### Separate `applicationId`

**Decision:** `com.estiaksoyeb.termux`.

**Why:** the app must install *next to* stock Termux, never over it. Android identifies an
app by package name; a second APK with the same name is an *update*, and with a different
signature it fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Uninstalling to "fix" that
would delete the Ubuntu chroot.

**Consequence:** `$PREFIX` becomes `/data/data/com.estiaksoyeb.termux/files/usr`, which is
why the bootstrap must be built with that address. Length 44 — within the 127-byte shebang
limit.

**Changed in:** `app/build.gradle` (`applicationId`, `manifestPlaceholders`),
`termux-shared/.../TermuxConstants.java`, `strings.xml`, `shortcuts.xml`.
Java package names stay `com.termux.*`; only the Android identity changes, which is what
upstream recommends for forks.

### No ADB

**Decision:** none of this workflow uses ADB.

**Why:** explicit user rule. Nothing here needs it — building produces an APK file, and
installation is a separate manual step.

---

## Toolchain

### NDK r27, not r29

**Decision:** system-installed `27.0.12077973`, pinned in committed `gradle.properties`.

**Why:** user request. Works because all three native modules use only API 21 POSIX/JNI.

**Caveat and mitigation:** r27 aligns libraries to 4 KB; 16 KB-page devices need 16 KB.
All three `Android.mk` add `-Wl,-z,max-page-size=16384`.

### arm64-v8a only

**Decision:** one ABI.

**Why:** the target device is arm64. Other ABIs would add build time, and each native module
would need its own bootstrap ZIP.

**Details:** `abiFilters`, not `splits.abi` (mutually exclusive). Applied to **every** module,
not just `:app`. See [toolchain.md §4](toolchain.md#4-abi-arm64-v8a-only).

### Shadow NDK instead of patching the installed one

**Decision:** `setup/ndk-shim.sh` creates `/tmp/opencode/ndk-shadow`.

**Why:** the installed NDK must not be modified — it is shared system state. A symlinked
shadow tree reproduces it exactly while allowing three wrappers.

**Rejected:** editing the NDK in place (destructive); a full custom toolchain (days of work);
clang-level `-lgcc` stripping (does not work — see
[toolchain.md §5](toolchain.md#the-trap-with--lgcc)).

### `GNUMAKE` as the injection point

**Decision:** the make wrapper, not `android.ndkPath`.

**Why:** AGP ignores every NDK-path override once `ndkVersion` matches an installed NDK
(verified: `ndkPath`, `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`, `-Pandroid.ndkPath`). `GNUMAKE`
is honoured by `ndk-build`, and a make command-line assignment overrides `NDK_ROOT :=`.

---

## Bootstrap

### Inject `.deb` packages instead of cross-compiling

**Decision:** download official Termux arm64 `.deb`, relocate them.

**Why:** produces a working `ssh` without Docker or a `termux-packages` checkout.

**Rejected:** cross-compiling (correct but hours of work, Docker ruled out); shipping
`openssh` via `apt` (no package manager in this app by design).

**Accepted cost:** paths compiled into bash and ncurses are worked around at runtime rather
than rewritten. Documented in [bootstrap.md §11](bootstrap.md#11-known-limitation).

### `patchelf` on every ELF, not just wrappers

**Decision (revised):** rewrite `RUNPATH` in every ELF with `patchelf`. Wrappers are kept for
the ssh tools as defence in depth, not as the primary mechanism.

**Superseded decision:** the original plan was `LD_LIBRARY_PATH` wrappers only
(`ssh`/`ssh.real` pairs), leaving the stale `RUNPATH` in place because `LD_LIBRARY_PATH`
outranks it.

**Why it was wrong:** wrappers only existed for the seven ssh tools. `bash` is the login
shell and had no wrapper, so it still consulted the stock `RUNPATH` and died with
`library "libandroid-support.so" not found`. "Never consulted" was only true for the binaries
that had a wrapper. `patchelf` itself can grow the string table safely — the risk was
in-place byte patching, which is not what `patchelf` does.

**Cost:** a build dependency on `patchelf`, and the `ssh`/`ssh.real` pairs remain redundant.
Step 6a-check aborts the build if any ELF still references the stock prefix.

### Compiled-in paths are worked around, not rewritten

**Decision:** fix bash's profile, bash's `bash.bashrc` and ncurses' terminfo at runtime
(`bin/login`, `etc/profile.d/02-sshterm-terminfo.sh`) rather than patching the binaries.

**Why:** the fork prefix is 12 bytes longer than the stock one, so these strings cannot be
rewritten in place, and they are not in the dynamic string table that `patchelf` relocates.
Recompiling bash and ncurses would need the Docker toolchain this project avoids.

### Prune to the ssh closure

**Decision:** delete everything unreachable from `ssh`.

**Why:** 30.5 MB → 8.7 MB for the ssh-only cut (22 MB once vim is included). The closure is computed,
not guessed, so no required library is removed.

**Revised after testing:** the first prune claimed "no loss of function" and was wrong — it
also removed `bin/coreutils` and `clear`, so the shell had no `ls`, `cat`, `mkdir`, `chmod` or
`clear`. A terminal without those is not usable, whatever the size table says. The keep set now
includes `coreutils` (plus its ELF closure and its symlink aliases) and `clear`.

### No package manager

**Decision:** no `apt`, no `pkg`.

**Why:** software belongs in Ubuntu. A second package manager on the phone side would need
its own repository built for this exact prefix, and would add tens of megabytes for no
benefit.

### Ship an editor: vim

**Decision:** inject the official Termux `vim` package into the bootstrap, and make it the only
editor.

**Why:** config files such as `~/.termux/termux.properties` and `~/.ssh/config` are plain text on
the device. Without an editor the user has to edit them on a computer and copy them across — the
exact friction that made the extra-keys problem take far longer than it should have. There is no
package manager to add one later, so it has to be shipped.

**Why vim and not nano:** vim's package carries its full runtime (syntax highlighting, filetype
plugins, colors) and is the editor the user already reaches for. nano was the first choice and was
dropped before the rebuild: it is present in the stock bootstrap but has no dependency tree worth
keeping for a single-file editor.

**Cost:** ~37 MB unpacked, ~7 MB compressed, mostly the runtime — of which 12 MB (`doc/`) was
dropped as documentation.

### Default font: Roboto Mono Nerd Font

**Decision:** bundle `Roboto-Mono.ttf` as `res/font/roboto_mono.ttf` and use it whenever
`~/.termux/font.ttf` is absent.

**Why:** Termux's terminal reads its typeface from `~/.termux/font.ttf` and otherwise falls back to
the system monospace font. Shipping the font as a resource is one file and one line of Java; no
first-run copying, no asset pipeline, no state to get out of sync.

**Why the user's file still wins:** dropping a font at `~/.termux/font.ttf` is how the user (or
Termux:Styling) chooses a different font. Silently overriding it would make that impossible. The
bundled font is the fallback, not a lock-in.

**Why this file:** Roboto Mono patched with Nerd Font glyphs — a monospace font with the icon range
the terminal needs for Powerline and prompt glyphs to render.

### Bootstrap built outside Gradle

**Decision:** `setup/build-bootstrap.sh`.

**Why:** network-independent builds, inspectable output, survives `clean`, no Gradle plugin
needed.

**Consequence:** two guards in `app/build.gradle` under `skipStockBootstrapDownload`.

### `clean` must not delete the bootstrap

**Decision:** override upstream's `clean` deletion.

**Why:** upstream deletes downloaded archives so they are re-fetched. This fork *builds* the
archive; deleting it forces a 30 MB re-download and a full re-prune for no reason.

### Auto-connect not implemented

**Decision:** leave the stock `login`; the app opens `bash`.

**Why:** explicitly out of scope. The mechanism is documented in
[bootstrap.md §6](bootstrap.md#6-auto-connect-not-implemented) so it can be enabled
later without rediscovering it.

---

## Signing

**Decision:** keep `app/testkey_untrusted.jks`.

**Why:** user's explicit choice, made after being warned.

**The risk, stated plainly:** this key is **public**. Anyone can create an APK signed with the
same key, and Android will accept it as an update to this app. It also means several projects
share one identity.

**Before installing or distributing anything, consider a private key:**

```bash
keytool -genkeypair -v -keystore ~/keys/sshterm.jks -alias sshterm \
    -keyalg RSA -keysize 4096 -validity 10000 \
    -storepass '<pass>' -keypass '<pass>' \
    -dname "CN=Termux SSH Terminal"
```

Keep it forever: losing it means future updates cannot be installed over the existing app.

---

## Documentation and repository hygiene

### `.gitignore` gets exactly one added line

**Decision:** only `local-env.gradle.kts` is added.

**Why:** the user manages `.gitignore` otherwise. The bootstrap ZIP is already covered by the
existing `*.zip` rule.

### No commits, no stashes

**Decision:** all changes remain uncommitted.

**Why:** the user decides when and how to commit. `git stash` was never used.

---

## Reference: rejected alternatives at a glance

| Area | Rejected | Because |
|---|---|---|
| Identity | same `com.termux` package | would replace/uninstall stock Termux and lose the chroot |
| Architecture | run Ubuntu inside this app | different UID, ~700 MB in private storage, needs root to copy |
| Bootstrap | cross-compile from source | Docker ruled out; hours of build time |
| Bootstrap | ship `apt` | wrong prefix, huge, unnecessary |
| Signing | upstream release key | not available; would also clash with coexistence |
| Tooling | modify installed NDK | shared system state, destructive |
| Tooling | clang-level `-lgcc` fix | clang re-adds the flag after the wrapper |
