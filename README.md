<p align="center">
  <img src="assets/icon.png" width="112" alt="Multiemu">
</p>

<h1 align="center">Multiemu</h1>

<p align="center">
  Run many Android phones side by side on your Mac: every Android version from 9 to 15, with Google Play, with root, or both.<br>
  <a href="../../releases/latest"><b>Download the latest version</b></a>
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-M1%2B-1a7f5a">
  <img alt="Android 9–15" src="https://img.shields.io/badge/Android-9%20%E2%80%93%2015-2bd38c">
  <img alt="License GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-555">
</p>

---

## What is Multiemu?

Multiemu is a multi-instance manager for Google's official Android emulator. One window lists all your
virtual phones; you create, start, clone and root them with a click, the way MEmu's Multiple Instance Manager works,
but on a Mac and with real Google system images.

- **Every version in one place**: Android 9, 10, 11, 12, 12L, 13, 14 and 15. A missing version downloads itself the first time you pick it.
- **Run several at once**: clone a phone and start the copies together, even of the same Android version. Clones are instant APFS copies and only use disk for what changes.
- **Three device types**:
  - **Play Store**: Google Play, Chrome and Files, like a normal phone.
  - **Play Store + Root**: the same, rooted with Magisk (`su` works), set up automatically. Tested on Android 12; the New dialog says, for each version, whether root is tested there.
  - **Root**: Google's userdebug build with `adb root` and a writable `/system`.
- **Per-device settings**: screen size, memory and CPU cores from drop-down lists.
- **Fast on Apple Silicon**: Google's emulator runs ARM64 images natively through Apple's Hypervisor.
- **Updates itself**: a new release shows up in the app with an **Update now** button.

## Download

| Platform | File | Requirements |
|---|---|---|
| macOS | `Multiemu-<version>.dmg` | macOS 14 Sonoma or newer, Apple Silicon (M1 or newer), about 3 GB free per Android version |

Get it from the [latest release](../../releases/latest).

### Install

1. Open the `.dmg` and drag **Multiemu** to **Applications**.
2. Open Multiemu. The app is not notarised yet, so the first time macOS blocks it:
   open **System Settings → Privacy & Security**, scroll down and press **Open Anyway**.
3. On first launch Multiemu sets up Google's Android emulator (about 1.5 GB, once). If you already use
   Android Studio, it finds your existing SDK in `~/Library/Android/sdk` and skips this step.
4. Press **New**, choose an Android version and a type, and press **Create**.

## Updates

Multiemu checks this repository's latest release when it starts. When a newer version is out, an
**Update now** button appears at the bottom of the window: it downloads the new `.dmg`, verifies its SHA-256 checksum
against the one GitHub publishes, replaces the app and reopens it.

## Privacy

Multiemu has no account, no analytics and no tracking. It connects to the internet only to:
check this page for updates, and download Google's emulator and Android images (and a Java runtime if needed) from their publishers.
Your virtual phones live in `~/.android/avd` on your Mac.

## Build from source

```bash
git clone https://github.com/smoker070/multiemu.git && cd multiemu
./build.sh             # dist/Multiemu.app
./build.sh --install   # also installs to /Applications
./build.sh --dmg       # dist/Multiemu-<version>.dmg
```

Needs Xcode Command Line Tools (`xcode-select --install`). The app is SwiftUI (`App/Sources/Multiemu`), with no dependencies.

| File | What it does |
|---|---|
| `Views.swift` | Main window, New and Settings dialogs |
| `Store.swift` | Create, start, stop, clone, delete, root |
| `Setup.swift` | First-run download of the Android SDK |
| `Updater.swift` | Update check and install from GitHub releases |
| `Model.swift` | Paths, Android versions, memory and CPU choices |

## Licence

Multiemu is free software under the **GNU General Public License v3.0** (see [LICENSE](LICENSE)), because it ships
[rootAVD](https://gitlab.com/newbit/rootAVD) and [Magisk](https://github.com/topjohnwu/Magisk) (both GPL-3.0).
Google's emulator and Android images are downloaded from Google under their own terms. Details in [THIRD_PARTY.md](THIRD_PARTY.md).

## Feedback

Found a bug or have an idea? [Open an issue](../../issues/new).

---

<sub>Android is a trademark of Google LLC. Multiemu is not affiliated with Google or MEmu.</sub>
