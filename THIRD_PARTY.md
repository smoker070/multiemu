# Third-party components

Multiemu itself is released under the GNU GPL v3.0 (see [LICENSE](LICENSE)).

## Shipped inside the app

| Component | Version | Licence | Used for |
|---|---|---|---|
| [rootAVD](https://gitlab.com/newbit/rootAVD) by NewBit | commit `613caa4` (2024-10-04) | GPL-3.0 | Patching the boot ramdisk of "Play Store + Root" devices |
| [Magisk](https://github.com/topjohnwu/Magisk) by topjohnwu (bundled by rootAVD) | 26.4 | GPL-3.0 | `su` inside "Play Store + Root" devices |

The unmodified rootAVD sources are in [`rootAVD-src/`](rootAVD-src), with their own `LICENSE` and `SOURCE.txt`.

## Downloaded on your Mac, not shipped

Multiemu downloads these from their publishers the first time it needs them. They are not part of
the Multiemu download and keep their own licences:

| Component | From | Licence |
|---|---|---|
| Android SDK command-line tools, emulator, platform-tools | Google (`dl.google.com`) | [Android SDK License Agreement](https://developer.android.com/studio/terms) |
| Android system images (with and without Google Play) | Google, through `sdkmanager` | Android SDK and Google APIs licences, shown by `sdkmanager --licenses` |
| Eclipse Temurin 17 Java runtime (only if your Mac has no Java 17+) | Eclipse Adoptium (`api.adoptium.net`) | GPL-2.0 with Classpath Exception |

Android is a trademark of Google LLC. Multiemu is not affiliated with or endorsed by Google, MEmu or NewBit.
