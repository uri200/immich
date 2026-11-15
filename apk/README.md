# Prebuilt APK

Easiest download on a phone (served as an Android app, opens the installer): https://github.com/uri200/immich/releases/latest/download/immich-offline-arm64.apk

`immich-offline-arm64.apk` — Android release build of this branch (`offline-mirror`), arm64 only.

- Built from: `3eee78cfe` — official Immich v3.4.1 + rcarpa's offline mirror (without its rebrand) + full quality on demand
- Package: `app.alextran.immich`, version 3.4.1 — it **replaces** the official Immich app rather than installing beside it. Uninstall the Play Store / F-Droid Immich first (server data is unaffected; you just log in again).
- Signed with a personal key, certificate SHA-256 `6267257d53cdeb891761e2a0c45ea13b4ca28288c793f9f2bf5372cedd8283f9`. Updates only install over it if signed with the same key.
- APK SHA-256: `0be947e8c25c85c7a5df3f020edf1d31ab757b6568a6999b7c7cdb27b15fc245`

Personal, unofficial build — not affiliated with or supported by the Immich project. Source is this repository (AGPL-3.0).
