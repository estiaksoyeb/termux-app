# Plain-English Guide

This page explains the project **without assuming you are a programmer**. Every technical
word is explained the first time it appears, and each section ends with a picture or an
analogy.

If you only read one page, read this one.

---

## 1. What you actually have

Your phone already runs **Termux**. Termux is a normal Android app, but instead of games or
chat it gives you a *terminal* — a screen where you type commands and the computer types
answers back. Inside Termux you set up an **Ubuntu** system (a full Linux operating system)
and a program called **`sshd`**, which is a small server that waits for connections.

This project is a **second, separate app** that you install next to Termux. Its only job is
to be a terminal window that talks to that Ubuntu system.

> **Analogy.** Termux is the *house* — it has all the rooms, tools, and furniture (Ubuntu,
> its programs, your files). `sshd` is the *front door with a lock*. This new app is a
> *car* you park outside: it has no furniture of its own and only one purpose, to drive you
> to that door. You never sleep in the car.

Why bother with a car when you already have a house? Because the new app is tiny, and you
can throw it away and rebuild it without touching a single thing in the house.

---

## 2. The single most important rule

**The new app never touches the old app's data. Not one byte.**

On Android, every app gets its own private folder, and no app may read or write another
app's folder. Termux's folder is `/data/data/com.termux/`. Your Ubuntu system lives inside
it. The new app is a *different* app, so Android physically prevents it from entering.

That is not a limitation — it is the safety guarantee you asked for. I never deleted,
moved, or edited anything in `/data/data/com.termux/`.

> **Analogy.** Your neighbour's house. You can ring the doorbell (connect over the network),
> but you cannot walk in and rearrange their furniture.

### Why the new app needs a different name

Android identifies apps by a **package name**, a dotted string like `com.termux`. Two apps
with the same name cannot both be installed — Android treats the second as an *update* of
the first. If the signing key differs (and it does), the install is refused; if you insisted,
the old app would be *replaced*, taking your Ubuntu install with it.

So this fork uses:

```
com.estiaksoyeb.termux
```

Different name → Android treats it as a brand-new app → it installs **alongside** Termux.
Nothing is replaced.

> **Analogy.** Two parcels with the same address and different senders confuse the postman.
> A different street number means both parcels arrive safely.

---

## 3. What is inside the new app (and why it is small)

Stock Termux is big because it ships a whole toolbox: a package manager (`apt`), compilers,
documentation, headers, hundreds of utilities. **This fork ships almost none of that.**

Here is what it contains instead:

| Piece | What it is, in plain words | Roughly |
|---|---|---|
| The terminal screen | the part that draws text and handles the keyboard | small |
| A tiny Android shell | the "glue" that lets the screen talk to a running program | small |
| **The bootstrap** | a compressed bundle of just enough programs to make an SSH connection | **8 MB** |
| Your own Java/Kotlin UI code | the app's windows and menus | small |

By far the biggest item is the **bootstrap**, so most of the work in this project was
shrinking it from 30 MB to 8 MB by *removing* things.

> **Analogy.** Stock Termux is a fully packed toolbox: hammer, saw, screws, nails, three
> kinds of glue, and a manual. This fork is a small pouch holding **one screwdriver** — the
> SSH tool — because all the real work happens inside the house (Ubuntu), which already has
> its own toolbox.

### What "bootstrap" means, and where it goes

A **bootstrap** is the set of files the app needs *before* it can run anything. On a
computer, that is the operating system's starting files. Here it is a compressed archive
(a `.zip`) containing `ssh`, `scp`, `sftp`, a shell, and the libraries they need.

When you install the app, the zip is **not** unpacked. It sits inside the app as a single
blob. The **first time you launch** the app, it unpacks itself into its own private folder:

```
/data/data/com.estiaksoyeb.termux/files/usr/
```

That path has a nickname: **`$PREFIX`**. ("Prefix" because it is the bit of the path that
comes *before* `/bin/ssh`.)

> **Analogy.** A flat-pack furniture kit. The box sits in your hallway (the APK). You open
> it once, on arrival day, and the parts get placed in one particular room (`$PREFIX`).
> After that the box is empty and you use the assembled furniture.

---

## 4. Why `$PREFIX` had to be decided before building

Here is the subtle part, and the reason the package name matters more than it looks.

The programs inside the bootstrap are *compiled* — translated in advance from human-written
code into machine instructions. During that translation, many of them baked in the exact
folder path they expect to run from:

```
#!/data/data/com.termux/files/usr/bin/bash
```

That line says "run me with the bash located *there*". If the app installed itself somewhere
else, every one of those programs would look for its helpers in a folder that does not exist.

So the address is written into the programs *permanently*, and you must therefore **decide
the address before building them**. You cannot move the furniture after the fact.

> **Analogy.** Printing a home address on a business card. You cannot change the address by
> moving house later — you must reprint every card. Choosing the app's name *is* choosing the
> address, so it is decided first.

---

## 5. The clever shortcut: reusing Termux's own programs

To get `ssh` into this app, there were two roads:

1. **Build it from scratch.** Download the source code of `ssh` and everything it needs,
   compile it for Android, and package it. Correct, but very slow and fiddly — it needs a
   whole separate build system and hours of compiling.

2. **Borrow the ready-made program** that Termux already publishes, and move it into a new
   folder. Fast, and it is the same program Termux itself uses.

This project uses **road 2**, plus a patch-up job.

### Why borrowing works at all

Termux's programs are built for Android, not for Termux specifically. The part of a program
that knows how to *start* is a standard Android component (`/system/bin/linker64`) that every
Android app has. Only the *library folder* note inside the program points at Termux's own
address.

So the patch-up is:

- copy the programs, libraries, and settings into the new folder,
- rewrite the old address `…/com.termux/files/usr` to the new one **inside every program**,
- and, for the few addresses that are baked in so deeply they cannot be re-engraved, hand the
  program a corrected note as it starts.

> **Analogy.** You buy a second-hand appliance with a sticker on the back saying "fuse box is
> in the old garage". You reprint the sticker on every appliance. A few appliances have it
> welded into the casing where it cannot be reprinted, so instead you greet them at the door
> and hand them a note: "the fuse box has moved — it is in *this* garage." Same appliances,
> right directions.

### The mistake worth remembering

The first working version only did that door-greeting part, and only for the SSH tools. It
looked fine, because the tools being tested were the SSH ones.

Then the terminal opened and died instantly:

```
bash: …/com.termux/files/usr/etc/profile: Permission denied
```

`bash` — the shell that draws the prompt, not an SSH tool — had never been given directions.
The lesson: **"it works" must be tested from the thing the user actually runs**, not from the
part that was easiest to check. The shell itself is the first thing to verify, not the last.

---

## 6. The two apps, side by side

```
        YOUR PHONE
┌───────────────────────────┐      ┌───────────────────────────┐
│  THIS APP                 │      │  STOCK TERMUX             │
│  com.estiaksoyeb.termux   │      │  com.termux               │
│                           │      │                           │
│  • terminal screen        │      │  • sshd (the front door)  │
│  • tiny bootstrap (ssh)   │ ───► │  • Ubuntu inside          │
│  • its own private folder │ SSH  │  • your files & tools     │
│                           │  :8022│                          │
│  = the "car"              │      │  = the "house"            │
└───────────────────────────┘      └───────────────────────────┘
       installable & removable          untouched, always yours
```

The arrow is the only connection: an **SSH** connection over the phone's own loopback
network address (`127.0.0.1`), on port `8022`. SSH is the standard "secure remote shell"
protocol: it encrypts what travels over the wire and asks for a password or key.

> **Analogy.** `127.0.0.1` means "this same phone". The connection never leaves the device.
> It is a phone call between two rooms of the same building.

---

## 7. How a build turns into an app

A quick tour of the words you will see while following the build guide.

| Word | Plain meaning |
|---|---|
| **APK** | the single file that *is* an Android app; what you install |
| **Gradle** | the tool that orchestrates the build ("recipe runner") |
| **NDK** | a toolkit for compiling the small native parts of an app |
| **ABI** | the processor type the native code is compiled for; this app is `arm64-v8a` (the modern 64-bit ARM chip in phones) |
| **Bootstrap ZIP** | the bundle of `ssh` and friends described in §3 |
| **Signing** | stamping the APK with a digital certificate so Android knows who made it |

The build is roughly:

1. `setup/build-bootstrap.sh` produces the 8 MB bootstrap ZIP.
2. Gradle compiles the Java/Kotlin UI and the three tiny native libraries.
3. One of those native libraries **swallows the ZIP whole** and puts it inside itself.
4. Gradle packages everything into one APK and signs it.

Step 3 is worth a second look. The zip is not listed as a normal file inside the APK. It is
*embedded as raw bytes* inside a compiled library (`libtermux-bootstrap.so`), so that the app
carries it wherever it goes. On first launch, the app reaches into itself, takes those bytes
out, and unzips them.

> **Analogy.** Instead of carrying a suitcase (a separate file), you have the suitcase's
> contents sewn into the lining of your coat. One item to carry, and it cannot be separated.

On this machine, one more thing is needed, because the machine is unusual — see
[toolchain.md](toolchain.md).

---

## 8. Where the risk is, and how it was controlled

| Risk | How it is handled |
|---|---|
| Damaging your existing Termux | Different app name and UID; this app *cannot* write to `com.termux`'s folder |
| Replacing stock Termux by accident | Different package name ⇒ Android sees a different app |
| Building for the wrong chip | Only `arm64-v8a` is compiled |
| The app failing to start on a modern phone | Native libraries aligned for 16 KB memory pages |
| A broken build silently shipping | Every build is checked: package name, ABIs, alignment, and that the embedded zip really contains `ssh` |
| Losing the code changes | Nothing was committed or stashed; no files were deleted |

One deliberate, temporary risk remains: the APK is signed with a **publicly known test key**.
See [decisions.md](decisions.md#signing) for why that matters and what to do about it.

---

## 9. What is *not* done

- The app does **not** auto-connect. It opens a local shell, exactly like Termux.
- There is **no** package manager inside it, by design. Software belongs in Ubuntu.
- It does **not** manage the Ubuntu system, its startup, or its `sshd`.

These are choices, not accidents. The reasoning is in
[decisions.md](decisions.md).
