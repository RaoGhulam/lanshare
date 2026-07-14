# LANShare

A simple Flutter app for sharing clipboard text and files between two
Android devices on the same Wi-Fi network, using raw TCP sockets
(`dart:io` `ServerSocket` / `Socket`). No Firebase, no backend, no HTTP,
no WebSockets - just a direct peer-to-peer TCP connection over LAN.

## Project layout

```
lib/
  main.dart                 App entry point / MaterialApp
  pages/
    home_page.dart           "Create Server" / "Join Server" buttons
    host_page.dart           Starts the TCP server, shows IP/port, waits for a client
    join_page.dart           Enter IP + port, connects as a client
    transfer_page.dart       Shared screen: send/receive clipboard + files
  services/
    tcp_service.dart         Singleton managing the socket + wire protocol
    protocol.dart            Encode/decode helpers for the wire format
    media_store_helper.dart  Bridges to native MediaStore code (see below)
  models/
    message.dart              MessageType, FileHeader, ReceivedFileInfo
android_kotlin_snippet/
  MainActivity.kt            Native Android side of media_store_helper.dart
                              (goes in android/app/src/main/kotlin/...)
```

## Wire protocol

Every packet sent over the socket has this shape:

```
[ 4 bytes: header length, big-endian int32 ]
[ N bytes: UTF-8 JSON header               ]
[ M bytes: raw payload (text or file bytes) ]
```

Clipboard header: `{"type":"clipboard","length":23}`
File header: `{"type":"file","name":"photo.jpg","size":12345678}`

No base64 - payload bytes are sent as-is, and files are streamed in chunks
directly to disk as they arrive, so there's no practical file size limit
imposed by the app itself.

## Where received files are saved

On Android, received files are saved to the **public Downloads folder**:

```
Download/LANShare/
```

so they show up in the Files app, the Downloads app, and (for image files)
typically the Gallery too - not hidden away in the app's private storage.

Files are streamed to a private temp file first (always writable, so the
transfer itself can't fail on a permission), then **published** into the
public Downloads folder through Android's `MediaStore` API once the
transfer is complete:

- **Android 10+ (API 29+):** publishing goes through `MediaStore.Downloads`
  (native code in `android_kotlin_snippet/MainActivity.kt`). This requires
  **no runtime permission at all** - it's the API scoped storage actually
  wants apps to use, so there's nothing that can be denied. (The old
  approach of requesting `MANAGE_EXTERNAL_STORAGE` "All files access" is
  intentionally **not** used anymore - that permission needs a manual
  Settings-screen toggle and can still throw permission-denied on some
  devices even when "granted".)
- **Android 9 and below (API 28-):** scoped storage doesn't exist yet, so
  a plain file copy into the public Downloads folder is used, gated by the
  classic `WRITE_EXTERNAL_STORAGE` permission (a normal one-tap dialog).
- **If publishing still fails for any reason** (e.g. permission genuinely
  denied on very old Android), the file is kept at its private temp path
  instead of being lost, and a SnackBar explains what happened.

## Setup

This is a pure Dart/`lib` source tree. Because the sandbox this was
generated in has no Flutter SDK / network access to pub.dev, the Flutter
project scaffolding (`android/`, `ios/`, etc.) was not generated here. To
run the app:

1. Create a fresh Flutter project and copy these files in. Note: Dart/Flutter
   project names must be lowercase, so the generated project folder is
   `lanshare` even though this source folder is `LANShare`:

   ```bash
   flutter create lanshare
   cd lanshare
   # copy pubspec.yaml and lib/ from this project over the generated ones
   ```

2. Add the Android permissions in
   `android_manifest_snippet/AndroidManifest_additions.xml` to your
   generated `android/app/src/main/AndroidManifest.xml` (INTERNET permission
   is required for sockets to work at all).

3. Replace the generated
   `android/app/src/main/kotlin/<your/package/path>/MainActivity.kt`
   with `android_kotlin_snippet/MainActivity.kt` from this project, then
   fix the `package com.example.lanshare` line at the top of that file so
   it matches your app's actual package name (same one used for
   `applicationId`/`namespace` in `android/app/build.gradle`). This is what
   makes received files actually land in the public Downloads folder
   instead of just app-private storage.

4. Install dependencies and run:

   ```bash
   flutter pub get
   flutter run
   ```

5. Make sure `android/app/build.gradle` has `minSdkVersion 21` or higher
   (required by `file_picker` / `permission_handler`).

6. Generate the app launcher icon (a wifi glyph, see `assets/icon/icon.png`)
   for Android and iOS:

   ```bash
   dart run flutter_launcher_icons
   ```

   This reads the `flutter_launcher_icons:` config in `pubspec.yaml` and
   writes the platform-specific icon files into `android/` and `ios/`
   automatically - no manual asset wrangling needed.

## Usage

1. On device A, tap **Create Server**. It starts listening on port 5000
   and shows its LAN IP address.
2. On device B, tap **Join Server**, type in device A's IP (port 5000 by
   default), and tap **Connect**.
3. Once connected, both devices land on the same **Transfer** screen:
   - **Send Clipboard** reads the device's clipboard and sends it over the
     socket; the peer sees it instantly under "Received Clipboard".
   - **Select File** opens the file picker (any file type, multiple
     selection supported) and streams the chosen file(s) to the peer with
     a progress bar.
   - Received files are saved to the public `Download/LANShare/` folder
     (visible in the Files app / Downloads app / Gallery) and listed under
     **Received Files**.
   - **Disconnect** (red button, top-right of the Transfer screen) closes
     the socket; the peer's socket then reports "closed" automatically, so
     **both** devices are returned to the Home screen, not just the one
     that tapped it.

Both devices must be on the same Wi-Fi network/subnet - this app does not
use the internet, only LAN sockets.
