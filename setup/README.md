# Setup scripts

Helpers that prepare the inputs for the Android build. They are **not** run automatically by
Gradle and nothing here touches `/data/data/com.termux/` or uses `adb`.

Full reasoning lives in the docs:

- [../docs/bootstrap.md](../docs/bootstrap.md) — why the bootstrap is built this way
- [../docs/toolchain.md](../docs/toolchain.md) — why the NDK shim exists
- [../docs/build-guide.md](../docs/build-guide.md) — the complete build procedure

---

## `build-bootstrap.sh` — entry point for the bootstrap

Produces `app/src/main/cpp/bootstrap-aarch64.zip`, the archive the APK embeds.

```bash
./setup/build-bootstrap.sh           # reuse cached downloads
./setup/build-bootstrap.sh --clean   # re-download everything first
```

| Stage | Performed by |
|---|---|
| fetch stock bootstrap ZIP | this script |
| inject `openssh` `.deb` packages and relocate the prefix | `add-ssh.sh` |
| delete everything outside the ssh dependency closure | `prune-to-ssh.py` |
| verify and zip | this script |

Output is 8.1 MB (from 30.5 MB). Cached downloads live in `/tmp/opencode/sshterm-bootstrap/`,
so repeat runs need no network.

Environment:

| Variable | Effect |
|---|---|
| `SSHTERM_WORK_DIR` | cache directory |
| `SSHTERM_APT_BASE` | alternative package repository |
| `SSHTERM_PATCHELF=1` | rewrite ELF `RUNPATH` instead of using wrapper scripts |

---

## `add-ssh.sh` — the `.deb` injection stage

Downloads the official Termux arm64 packages for `openssh` and its dependencies, unpacks
them into a staging tree, rewrites the old prefix, and installs the `LD_LIBRARY_PATH`
wrapper scripts (`ssh` → `ssh.real`).

Called by `build-bootstrap.sh`. Can be run standalone against an existing staging dir:

```bash
./setup/add-ssh.sh <staging-dir>
```

---

## `prune-to-ssh.py` — the pruning stage

Computes the ELF/script dependency closure starting from the ssh tools and deletes everything
unreachable, then rewrites `SYMLINKS.txt` to list only surviving links.

```bash
./setup/prune-to-ssh.py <staging-dir> <prefix-path>
```

---

## `ndk-shim.sh` — local build support

Creates a shadow NDK tree with three wrappers so `ndk-build` can link on this aarch64 host,
without modifying the installed NDK.

```bash
eval "$(./setup/ndk-shim.sh --env)"   # create the tree and export GNUMAKE
./setup/ndk-shim.sh                   # create only, print the tree path
```

Only needed when the host architecture does not match the NDK's prebuilt toolchain
(aarch64 here). Not needed on x86-64.

---

## `postprocess-bootstrap.sh`

Early standalone prototype of the pruning step, kept for reference. The supported path is
`build-bootstrap.sh`. It is not referenced by the build.
