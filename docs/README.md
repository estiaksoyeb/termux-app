# Documentation

Documentation for this fork of `termux-app`: a small, personal, SSH-only terminal app that
installs **next to** the stock Termux app and is used to reach an Ubuntu environment that
already runs on the same phone.

Not a developer? Start with **[plain-english.md](plain-english.md)** — no jargon.

---

## Where to start

| If you want to… | Read |
|---|---|
| understand what this is, with analogies | [plain-english.md](plain-english.md) |
| understand how the parts fit together | [architecture.md](architecture.md) |
| build the APK and check the result | [build-guide.md](build-guide.md) |
| know why the NDK build looks strange | [toolchain.md](toolchain.md) |
| know how `ssh` gets inside the app | [bootstrap.md](bootstrap.md) |
| know why a choice was made | [decisions.md](decisions.md) |
| fix an error | [troubleshooting.md](troubleshooting.md) |
| look up a word | [glossary.md](glossary.md) |

Every page states **what** something is, **why** it is that way, and **how** it works. Pages
cross-reference each other rather than repeating themselves.

---

## Status

| Item | State |
|---|---|
| APK builds and is verified | ✅ done |
| Package `com.estiaksoyeb.termux`, arm64-v8a only | ✅ done |
| Embedded bootstrap with working `ssh`/`scp`/`sftp` | ✅ done |
| Shell starts and works on a device | ✅ done — `bash`, coreutils, `clear`, `sed`, `grep`, `gawk`, `ssh` |
| Auto-connect on launch | ⬜ **not done** — out of scope |
| Connecting to the Ubuntu chroot | ⬜ **not done** — the app opens `bash` |

The app currently behaves like a leaner Termux: it opens a local shell, and you type
`ssh …` yourself. The hook for auto-connect is documented in
[bootstrap.md](bootstrap.md#6-auto-connect-not-implemented) but deliberately not enabled.

---

## Source layout

| Path | Meaning |
|---|---|
| `app/` | the Android application module (UI, installer, `$PREFIX` bootstrap) |
| `terminal-emulator/` | terminal screen emulator (a library) |
| `terminal-view/` | the view that draws the terminal |
| `termux-shared/` | code shared by the app and its plugins |
| `app/src/main/cpp/` | native code: embeds the bootstrap ZIP |
| `setup/` | **this fork's build scripts** (bootstrap, NDK shim) |
| `docs/` | this documentation |

Only `setup/`, `docs/` and a small number of edited upstream files differ from upstream
`termux-app`. Everything else is untouched.

---

## The scripts

| Script | Purpose |
|---|---|
| `setup/build-bootstrap.sh` | produces the 8 MB bootstrap ZIP (entry point) |
| `setup/add-ssh.sh` | downloads `.deb` packages, relocates them into the prefix |
| `setup/prune-to-ssh.py` | deletes everything outside the ssh dependency closure |
| `setup/ndk-shim.sh` | builds the shadow NDK needed to link on this aarch64 host |

Each script has a header comment explaining why it exists; the reasoning in full is in
[bootstrap.md](bootstrap.md) and [toolchain.md](toolchain.md).

---

## Quick reference

```bash
# build
eval "$(./setup/ndk-shim.sh --env)"
./setup/build-bootstrap.sh
./gradlew :app:assembleDebug

# result
app/build/outputs/apk/debug/termux-app_apt-android-7-debug_universal.apk
```
