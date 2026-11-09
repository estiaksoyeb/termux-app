# Toolchain

Why the build is configured the way it is, and what the host-architecture shim does.

---

## 1. Installed toolchain

| Component | Version | Location |
|---|---|---|
| Android SDK | platforms 33–37, build-tools 36.1.0 | `/opt/android-sdk-custom/android-sdk` |
| **NDK** | **r27 `27.0.12077973`** | `…/ndk/27.0.12077973` |
| JDK | 17 | system |
| Gradle | wrapper 9.2.1 | `~/.gradle/wrapper/dists` |
| AGP | 8.13.2 | root `build.gradle` |
| compileSdk / minSdk / targetSdk | 36 / 21 / 28 | `gradle.properties` |

`ndkVersion` is pinned in the **committed** `gradle.properties` (upstream asks for r29),
and the root `build.gradle` re-applies it to every Android module so it cannot drift.

---

## 2. Why an NDK is needed at all

The bootstrap programs (including `ssh`) are **prebuilt** and need no compiler. Three small
native modules do:

| Module | Source | Role |
|---|---|---|
| `libtermux-bootstrap.so` | `app/src/main/cpp/` | embeds the bootstrap ZIP + JNI accessor |
| `libtermux.so` | `terminal-emulator/src/main/jni/termux.c` | PTY layer: `setsid`, `TIOCSWINSZ`, `execvp` |
| `liblocal-socket.so` | `termux-shared/src/main/cpp/local-socket.cpp` | Unix sockets with `SO_PEERCRED` |

Without `libtermux.so` there is no terminal at all, regardless of how good the bootstrap is.

All three use only POSIX/JNI APIs available since API 21, so r27 is sufficient.

---

## 3. Why r27 instead of upstream's r29

Requested by the user. It works: the modules use nothing newer than API 21 APIs.

**One caveat, and its fix.** NDK r27 aligns native libraries to **4 KB** by default; some
Android 15+ devices use **16 KB** memory pages and may refuse to load 4 KB-aligned libraries.
All three `Android.mk` files therefore pass:

```make
LOCAL_LDFLAGS += -Wl,-z,max-page-size=16384
```

This is safe on 4 KB devices too. Verify with `readelf -lW … | grep LOAD` — the last column
must be `0x4000`.

---

## 4. ABI: arm64-v8a only

Set from the gitignored `local-env.gradle.kts`:

```kotlin
gradle.extra.set("useArm64V8aOnly", true)
```

and applied in the root `build.gradle`:

```gradle
if (gradle.ext.has("useArm64V8aOnly") && gradle.ext.useArm64V8aOnly) {
    project.android.splits.abi.enable = false
    project.android.defaultConfig.ndk.abiFilters.clear()
    project.android.defaultConfig.ndk.abiFilters.add("arm64-v8a")
}
```

Two hard-won details:

- **`abiFilters` and `splits.abi` are mutually exclusive.** AGP aborts configuration with
  *"Conflicting configuration : 'arm64-v8a' in ndk abiFilters cannot be present when splits
  abi filters are set"*. Splits are opt-in (`splitAPKsFor*Builds`), so they are disabled
  first. Also note `splits.abi.include` is **write-only** in this AGP — reading it throws
  *"Could not get unknown property 'include'"*.
- **Every Android module must be restricted, not just `:app`.** Otherwise
  `termux-shared` still builds `liblocal-socket.so` for four ABIs, which is wasted work and
  fails on the `bootstrap-<abi>.zip` includes.

---

## 5. The host-architecture problem (aarch64)

The NDK ships an **x86-64-only** prebuilt toolchain
(`toolchains/llvm/prebuilt/linux-x86_64`). This machine is **aarch64**. On this box the NDK's
binaries have been replaced by the system LLVM 18. Three things then break:

| # | Symptom | Cause |
|---|---|---|
| 1 | `ld.lld: error: unable to find library -lgcc` | the NDK ships no `libgcc.a` below API 24; `minSdk` is 21 |
| 2 | `cannot open crtbegin_so.o` | the system driver does not rewrite the two-token `--sysroot PATH` form |
| 3 | `python3: 1: Syntax error: word unexpected` | the NDK's bundled `python3` is an x86-64 binary |

### The trap with `-lgcc`

The obvious fix — strip `-lgcc` — **is wrong**. In a real Android link, `-lgcc` is satisfied
by the compiler runtime, not by GCC. Removing it produces:

```
ld.lld: error: undefined symbol: _Unwind_Resume
ld.lld: error: undefined symbol: __aarch64_ldadd4_acq_rel
```

when linking `liblocal-socket.so` (C++). The flag must be **replaced** by
`libunwind.a` + `libclang_rt.builtins-<arch>-android.a`, not dropped.

### Why the fix cannot live in a clang wrapper

An earlier attempt wrapped `clang` to drop `-lgcc`. It failed because the clang **driver**
constructs its linker argument list itself and re-adds `-lgcc` after any wrapper has run.
The flag only exists by the time the **linker** sees it, so the linker is where it must be
handled.

---

## 6. `setup/ndk-shim.sh` — the shadow NDK

The script builds a complete shadow NDK tree and never modifies the installed one:

```
/tmp/opencode/ndk-shadow/
├── ndk-build                        real script: pins NDK_ROOT to this tree
├── build/            → real NDK
├── source.properties → real NDK
├── toolchains/llvm/prebuilt/linux-x86_64/
│   ├── sysroot/      → real NDK
│   └── bin/
│       ├── clang, clang++           wrapper: normalize --sysroot, force shim linker
│       ├── ld.lld                   wrapper: translate -lgcc into compiler runtimes
│       ├── ld        → ld.lld
│       └── (all other tools)        → real NDK
└── host-make/make                   wrapper: injects NDK_ROOT and NDK_HOST_PYTHON
```

### What each wrapper does and why

**`bin/ld.lld`** — reads the emulation name (`aarch64linux`, seen as a separate token after
`-m`) to learn the target ABI, then replaces every `-lgcc` with the matching
`libunwind.a` and `libclang_rt.builtins-<abi>-android.a`, and delegates to the real linker.

**`bin/clang`, `bin/clang++`** — rewrite `--sysroot PATH` to `--sysroot=PATH` (the form the
driver understands), and force `-fuse-ld=<shim ld.lld>` so the linker wrapper above is
always used.

**`host-make/make`** — see §7.

**`ndk-build`** (top level) — the stock script forwards to `$DIR/build/ndk-build`, which
derives `ANDROID_NDK_ROOT` from its *own* path. Because `build/` is a symlink here, that
resolves back to the real NDK and silently bypasses every wrapper. The replacement pins
`NDK_ROOT` and `NDK_HOST_PYTHON` explicitly.

### Why the per-API entry points work

Scripts such as `aarch64-linux-android21-clang` do `"$bin_dir/clang"`. Bash does **not**
resolve `$0` through symlinks, so `bin_dir` stays the shadow `bin/` and they pick up the
wrappers automatically.

---

## 7. Selecting the shadow NDK from Gradle

**AGP resolves the NDK from `ndkVersion` against the SDK and ignores `android.ndkPath`** when
it finds a matching installed NDK. Setting `ndkPath`, `ANDROID_NDK_HOME`, or
`-Pandroid.ndkPath=` all had no effect — the build kept invoking the real `ndk-build`.

The working hook is one level lower: `ndk-build` honours the `GNUMAKE` environment variable,
and a **make command-line assignment beats** the `NDK_ROOT := …` that `build-local.mk` derives
from its own location.

```bash
eval "$(./setup/ndk-shim.sh --env)"   # exports GNUMAKE=<shadow>/host-make/make
./gradlew :app:assembleDebug
```

> **Analogy.** The receptionist at the NDK (Gradle) insists on sending you to the official
> workshop, whatever note you hand her. So instead we intercept the workshop's foreman
> (`make`), who does accept instructions.

---

## 8. Constraints this AGP imposes

Discovered while building; do not spend time rediscovering them.

| Attempt | Result |
|---|---|
| `android.splits.abi.include` (read or modify) | throws — write-only property |
| `android.ndk`, `android.ndk.toolchainVersion` | not accessible from this Gradle script context |
| `externalNativeBuild.ndkBuild.arguments` | property does not exist in AGP 8.13.2 |
| `-Pandroid.ndkPath=…`, `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT` | ignored once `ndkVersion` matches an SDK install |
| `PATH` prepended with a clang shim | ignored — ndk-build uses an absolute toolchain path |

---

## 9. A note on `local-env.gradle.kts`

A Kotlin script applied via `apply(from = …)` from a Groovy init script has a **minimal API
surface**. Typed accessors such as `gradle.ext` and `project.android` are unavailable.

Therefore it does exactly one thing:

```kotlin
gradle.extra.set("useArm64V8aOnly", true)
```

and all real Gradle work lives in the Groovy `build.gradle`, which is not limited this way.
The file is gitignored.
