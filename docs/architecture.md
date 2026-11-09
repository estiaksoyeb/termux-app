# Architecture

How the pieces fit together, and what actually happens at each stage.
For the jargon-free version, see [plain-english.md](plain-english.md).

---

## 1. The three layers

```
┌──────────────────────────────────────────────────────────────────┐
│  Android                                                         │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────────────┐   ┌───────────────────────────┐  │
│  │ THIS APP                   │   │ STOCK TERMUX              │  │
│  │ com.estiaksoyeb.termux     │   │ com.termux                │  │
│  │ UID A (its own)            │   │ UID B (its own)           │  │
│  │                            │   │                           │  │
│  │ TermuxActivity             │   │ sshd  ← :8022 loopback    │  │
│  │   └─ TermuxService         │   │  └─ shell                 │  │
│  │       └─ libtermux.so  ────┼───┼──► └─ Ubuntu (chroot)     │  │
│  │            (PTY + exec)    │SSH│                           │  │
│  │                            │   │                           │  │
│  │ $PREFIX = .../files/usr    │   │ $PREFIX = .../files/usr   │  │
│  │ (8 MB: openssh + shell)    │   │ (full Termux toolchain)   │  │
│  └────────────────────────────┘   └───────────────────────────┘  │
│             ▲                               ▲                    │
└─────────────┼───────────────────────────────┼────────────────────┘
              │                               │
      never leaves the device          untouched by this project
```

Three things are worth naming precisely:

- **A PTY** ("pseudo-terminal") is a fake keyboard-and-screen that a program writes to and
  reads from, as though it were a real terminal. Android apps cannot open a terminal window
  for a Unix program, so the app creates a PTY and connects the program's input/output to it.
  That is what `libtermux.so` does.
- **A UID** is the numeric identity Android gives an app. Two apps with different UIDs are
  isolated by the kernel, not by convention.
- **`127.0.0.1`** is loopback: the device talking to itself.

---

## 2. The two component types in the app

The app is not one monolithic thing. Upstream splits it into:

| Module | Role | Ships with the APK? |
|---|---|---|
| `terminal-emulator` | the *emulator*: interprets escape sequences (`\e[31m` = red, cursor moves, etc.) | yes, as compiled code |
| `terminal-view` | the Android `View` that draws the emulator's screen and handles touches/keys | yes |
| `termux-shared` | shared helpers: constants, `$PREFIX` bootstrapping, sockets, logs | yes |
| `app` | the activity, service, settings, and the installer | yes |

The term "emulator" here does **not** mean emulating a different CPU. It means emulating a
**terminal device** — the historic hardware that terminals used to be. This is why a
smartphone can display a Linux program correctly: the program thinks it is talking to a
1970s glass terminal.

---

## 3. What happens on first launch

The sequence matters because nothing works before the bootstrap exists.

```
user taps icon
      │
      ▼
TermuxActivity.onCreate()
      │
      ▼
TermuxService starts (a foreground service)
      │
      ▼
TermuxInstaller.setupBootstrapIfNeeded()
      │
      ├── if $PREFIX already exists ────────────────► skip (normal launch)
      │
      ▼
loadZipBytes()
      │  System.loadLibrary("termux-bootstrap")
      ▼
libtermux-bootstrap.so : getZip()      ← raw ZIP bytes from .rodata
      │
      ▼
ZipInputStream unpacks into $STAGING_PREFIX
      │  • SYMLINKS.txt is parsed ("target←link")
      │  • exec bit set for bin/, libexec/
      ▼
staging dir renamed to $PREFIX
      │
      ▼
TermuxSession.execute()
      │  picks the first executable of: login, bash, zsh, fish, sh
      ▼
libtermux.so creates a PTY, forks, execs the shell
      │
      ▼
a prompt appears
```

Two consequences of this order:

- **The bootstrap is the gate.** If the ZIP is malformed, the app stops at step
  `ZipInputStream` with an error dialog. The error text is a reliable diagnosis, see
  [troubleshooting.md](troubleshooting.md).
- **The shell choice is automatic, not configured.** There is no setting that names the
  shell. A list of candidate names is searched in `$PREFIX/bin`, first match wins. This is
  the hook that would allow auto-connect without Java changes (see
  [bootstrap.md §6](bootstrap.md#6-auto-connect-not-implemented)) — but it is
  **not** used in the current build, which ships a `login` script that sources the fork's own
  profile and then opens a local `bash`.

---

## 4. Why there is a `$PREFIX` at all

Termux does not install software into `/usr` like a normal Linux. It installs into its
private app folder, because that is the only place Android lets it write:

```
/data/data/com.estiaksoyeb.termux/files/usr      = $PREFIX
                                        ├── bin/    programs
                                        ├── lib/    shared libraries
                                        ├── etc/    configuration (ssh, tls)
                                        ├── libexec/
                                        └── share/  terminfo, misc data
```

Everything the app runs lives under there, and the app can write there without any special
permissions.

---

## 5. Why SSH and not "just run Ubuntu directly"

Running the Ubuntu chroot inside this app would mean *this* app owning and managing it, which
means migrating ~700 MB out of Termux's private storage — impossible without root — and
re-implementing all the setup.

SSH sidesteps that completely:

- Ubuntu stays where it is, owned by the app that already works.
- The connection is a normal network protocol; no special privileges are needed.
- The rendering problems seen when running the chroot directly are avoided, because the
  chroot's output is written to a clean SSH stream, not to a nested terminal.

The trade-off is a dependency: **stock Termux's `sshd` must be running** for a connection to
succeed. This app cannot start another app's server.

---

## 6. Where each requirement is implemented

| Requirement | Implemented in | Verified by |
|---|---|---|
| Distinct install identity | `app/build.gradle` (`applicationId`), `TermuxConstants.java` | `aapt2 dump badging` |
| `$PREFIX` follows the new name | `TermuxConstants.TERMUX_PACKAGE_NAME` | same, plus bootstrap path rewriting |
| Only arm64 | root `build.gradle` (`abiFilters`) | `unzip -l` on the APK |
| `ssh` present at runtime | `setup/build-bootstrap.sh` → embedded ZIP | bytes compared against the built ZIP |
| Loadable on 16 KB-page devices | `-Wl,-z,max-page-size=16384` in all three `Android.mk` | `readelf -lW` |
| Build reproducible on this host | `setup/ndk-shim.sh` | clean rebuild |
