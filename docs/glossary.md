# Glossary

Every term used in this project, defined once. Alphabetical.

---

**ABI** — Application Binary Interface. The processor family machine code is compiled for.
This app is `arm64-v8a` (64-bit ARM). *Analogy: the voltage a plug is built for.*

**ADB** — Android Debug Bridge, a developer tool for controlling a phone from a computer.
**Not used anywhere in this project.**

**AGP** — Android Gradle Plugin. Teaches Gradle how to build Android apps.

**APK** — Android Package. The single file that *is* an installable app.

**`applicationId`** — the dotted package name that identifies an app (`com.estiaksoyeb.termux`).
The reason this fork can coexist with stock Termux.

**arm64-v8a** — 64-bit ARM. The architecture of the target phone.

**`.deb`** — Debian package format. Termux's official packages, reused here.

**bootstrap** — the archive of programs (`ssh`, a shell, libraries) the app needs before it can
run anything. Embedded in the APK, unpacked on first launch.

**chroot** — a folder made to look like the root of a filesystem. Where Ubuntu lives inside
Termux.

**closure (dependency closure)** — a program plus everything it needs, plus everything *they*
need, recursively. Used to decide what pruning may delete.

**compileSdk** — the Android version the app is *compiled against*.

**dhparam / host key** — cryptographic material `sshd` uses to identify itself.

**ELF** — the file format of Linux/Android programs. Its `PT_INTERP` and `RUNPATH` fields
matter here.

**foreground service** — an Android service that keeps running with a notification. Keeps
terminal sessions alive when the app is backgrounded.

**Gradle** — the build system. Runs "tasks" such as `assembleDebug`.

**GNUMAKE / `make`** — the program that actually runs the NDK's build recipes. Used as the
injection point for the host shim.

**`$PREFIX`** — `/data/data/com.estiaksoyeb.termux/files/usr`. The app's private software
folder. Baked into compiled programs, so it must be decided before building.

**JNI** — Java Native Interface. How Java calls C code. Used to hand the ZIP bytes to the app.

**`LD_LIBRARY_PATH`** — environment variable listing folders to search for libraries
*before* the ones compiled into a program. Outranks `RUNPATH`. Central to the relocation
strategy.

**`ld.lld`** — the LLVM linker. Joins compiled objects into a program or library.

**minSdk** — the oldest Android version the app supports (21).

**NDK** — Native Development Kit. Compilers and headers for building Android native code.

**package name** — see `applicationId`.

**PDT / PTY** — pseudo-terminal. A fake keyboard-and-screen a program runs against. Created by
`libtermux.so`.

**pruning** — deleting everything outside the ssh closure to shrink the archive.

**`RUNPATH` / `RPATH`** — a path baked into an ELF file saying where to find its libraries.

**shadow NDK** — a symlinked copy of the NDK with three wrapper scripts added. Lives in
`/tmp/opencode/ndk-shadow`; the installed NDK is never modified.

**shebang** — the `#!` first line of a script naming its interpreter. Limited to 127 bytes.

**signing** — stamping the APK with a certificate. Android refuses updates whose signature
differs.

**SSH** — Secure Shell. Encrypted remote-shell protocol. The only protocol this app speaks.

**`sshd`** — the SSH *server*. Runs inside stock Termux.

**SYMLINKS.txt** — a file at the ZIP root recording symbolic links as `target←link`.

**targetSdk** — the Android version the app declares it was *tested for* (28). Lower values
keep older behaviour that Termux depends on.

**Termux** — the stock Android app that hosts the Ubuntu environment.

**`termux-exec`** — a Termux library that fixes shebang/`PATH` behaviour on Android.

**UID** — the numeric identity Android gives an app. Different UIDs ⇒ kernel-enforced
isolation.

**wrapper script** — a small shell script installed under the program's usual name, which sets
up the environment and then runs the real binary (`ssh` → `ssh.real`).

**ZIP (bootstrap)** — see *bootstrap*.
