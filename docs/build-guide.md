# Build Guide

How to build and verify the APK on this machine. Follow it top to bottom.

For *why* the NDK steps look unusual, see [toolchain.md](toolchain.md).

---

## 0. Prerequisites

| Need | Where it is here |
|---|---|
| JDK 17 | system `java` |
| Android SDK 36 | `/opt/android-sdk-custom/android-sdk` |
| NDK r27 `27.0.12077973` | `/opt/android-sdk-custom/android-sdk/ndk/27.0.12077973` |
| Gradle | `./gradlew` (wrapper 9.2.1) |
| `python3`, `zip`, `unzip`, `curl` | system |

`ANDROID_HOME` and `ANDROID_NDK_HOME` are already exported.

---

## 1. Build the bootstrap ZIP

The APK embeds `app/src/main/cpp/bootstrap-aarch64.zip`. It is **gitignored**, so a fresh
clone does not have it and it must be generated once.

```bash
./setup/build-bootstrap.sh
```

Expected output ends with:

```
    final ZIP size       : 8.1M
    original ZIP size    : 30M
[*] wrote .../app/src/main/cpp/bootstrap-aarch64.zip
```

This is **idempotent**: it reuses the downloaded stock ZIP and `.deb` files cached in
`/tmp/opencode/sshterm-bootstrap/`, so it does not need the network on a repeat run.
Pass `--clean` to force a re-download.

> **Why this is a separate step.** The bootstrap is produced by ordinary shell tools that
> download packages. Keeping it out of Gradle means a broken network never breaks the app
> build, and the archive can be inspected and rebuilt independently.

Details: [bootstrap.md](bootstrap.md).

---

## 2. Prepare the NDK shim (this machine only)

**Required on an aarch64 host.** Skipping it gives the error
`ld.lld: error: unable to find library -lgcc`.

```bash
eval "$(./setup/ndk-shim.sh --env)"
```

This creates `/tmp/opencode/ndk-shadow` and exports `GNUMAKE` in the current shell.
It never modifies the installed NDK.

> **The `eval` matters.** The script prints shell commands rather than setting variables,
> because a child process cannot change its parent's environment.

On a normal x86-64 machine, skip this step entirely.

---

## 3. Build

```bash
./gradlew :app:assembleDebug
```

Output:

```
app/build/outputs/apk/debug/termux-app_apt-android-7-debug_universal.apk
```

The name says "universal" because upstream generates one APK that carries every ABI. This
fork filters that down to `arm64-v8a` only, so the "universal" APK contains exactly one ABI.

Log the output if it is too long to read on screen:

```bash
./gradlew :app:assembleDebug > /tmp/opencode/build-apk.log 2>&1; echo "exit=$?"
```

---

## 4. Verify the result

Run all of these. Each answers a specific question.

```bash
cd /root/Forks/termux-app
APK=app/build/outputs/apk/debug/termux-app_apt-android-7-debug_universal.apk
BT=/opt/android-sdk-custom/android-sdk/build-tools/36.1.0
```

### 4.1 Is it the right app, for the right chip?

```bash
$BT/aapt2 dump badging "$APK" | grep -E '^package:|native-code'
```

Expect:

```
package: name='com.estiaksoyeb.termux' ...
native-code: 'arm64-v8a'
```

The package name being `com.estiaksoyeb.termux` and **not** `com.termux` is the entire
coexistence guarantee. If this is wrong, do not install it.

### 4.2 Does the APK contain only arm64 libraries?

```bash
unzip -l "$APK" | grep 'lib/'
unzip -l "$APK" | awk '{print $4}' | grep '^lib/' | cut -d/ -f2 | sort -u
```

The second command must print exactly one line: `arm64-v8a`.

### 4.3 Are the native libraries loadable on modern Android?

```bash
mkdir -p /tmp/opencode/apkcheck && cd /tmp/opencode/apkcheck
unzip -oq "/root/Forks/termux-app/$APK" 'lib/arm64-v8a/*'
for f in lib/arm64-v8a/*.so; do
    printf '%-30s ' "$(basename $f)"
    readelf -h "$f" | awk '/Machine/{printf "%s ", $2}'
    readelf -lW "$f" | awk '/LOAD/{print $NF}' | sort -u | tr '\n' ' '; echo
done
```

Every line must show `AArch64` and alignment `0x4000`. `0x1000` would mean the library may
fail to load on a device with 16 KB memory pages.

### 4.4 Is the embedded bootstrap the one we built?

The ZIP lives inside `libtermux-bootstrap.so` as raw bytes, starting at the beginning of its
`.rodata` section.

```bash
python3 - <<'PY'
d = open("/tmp/opencode/apkcheck/lib/arm64-v8a/libtermux-bootstrap.so","rb").read()
# .rodata file offset and size, from: readelf -SW lib/arm64-v8a/libtermux-bootstrap.so
off, size = 0x518, 0x8104b6
embedded = d[off:off+size]
built = open("/root/Forks/termux-app/app/src/main/cpp/bootstrap-aarch64.zip","rb").read()
print("embedded starts with the built archive:", embedded.startswith(built))
print("archive size:", len(built))
PY
```

Expect `True` and `8455346`. The section is 4 bytes longer than the archive — the assembler
adds padding, which is normal.

### 4.5 Does it actually contain `ssh`?

```bash
unzip -l /root/Forks/termux-app/app/src/main/cpp/bootstrap-aarch64.zip | grep -E 'bin/(ssh|scp|sftp|bash|login)$'
```

### 4.6 Is it signed, and with what?

```bash
$BT/apksigner verify --print-certs "$APK" | head -3
```

Expect signer `CN=APK Signer`. This is the public test key — see
[decisions.md § Signing](decisions.md#signing).

---

## 5. Full clean rebuild

Confirms nothing depends on stale build output:

```bash
cd /root/Forks/termux-app
./gradlew clean                      # must NOT delete the bootstrap ZIP
ls app/src/main/cpp/bootstrap-aarch64.zip
eval "$(./setup/ndk-shim.sh --env)"
./gradlew :app:assembleDebug
```

`clean` deliberately skips the upstream deletion of `bootstrap-*.zip`, because this fork
builds that file instead of downloading it. See
[decisions.md](decisions.md#clean-must-not-delete-the-bootstrap).

---

## 6. Installing

**Not covered here and not performed.** Installing on the device, and the decision about
which key to use, is a separate concern. See
[decisions.md § Signing](decisions.md#signing) before sideloading anything.

---

## 7. One-liner for a repeat build

```bash
cd /root/Forks/termux-app \
  && eval "$(./setup/ndk-shim.sh --env)" \
  && ./gradlew :app:assembleDebug \
  > /tmp/opencode/build-apk.log 2>&1; echo "exit=$?"
```
