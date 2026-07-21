# LANShare

A simple Flutter app for sharing clipboard text and files between two
Android devices on the same Wi-Fi network, using raw TCP sockets
(`dart:io` `ServerSocket` / `Socket`). No Firebase, no backend, no HTTP,
no WebSockets - just a direct peer-to-peer TCP connection over LAN.

---

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

---

## Platform Integration

LANShare primarily uses Flutter APIs and plugins for cross-platform system access, with native platform APIs used only when required.

- **Networking:** Uses Dart `Socket` and `ServerSocket` APIs for LAN TCP communication.
- **QR Scanning:** Uses the `mobile_scanner` plugin for camera-based QR detection.
- **Clipboard:** Uses Flutter's `Clipboard` API for system clipboard sharing.
- **Files:** Uses `file_picker` for selecting files and Dart `File` APIs for reading and transferring files.
- **Storage:** Uses `permission_handler` for legacy Android storage permissions and a Flutter `MethodChannel` bridge to Android's native `MediaStore` API for saving received files to the public Downloads folder.
- **Storage Paths:** Uses `path_provider` to access platform-specific directories such as temporary storage, Downloads, and application documents folders.
- **Drag & Drop:** Uses the `desktop_drop` plugin for desktop file drag-and-drop support.

Most functionality is implemented using Flutter abstractions. Platform-specific code is only used where required, such as Android's native `MediaStore` integration for public file storage.

---

## Wire protocol

LANShare uses a custom TCP-based binary protocol for device-to-device communication.

```
Each packet follows this format:
[ 4 bytes ] Header length (big-endian int32)
[ N bytes ] UTF-8 JSON header
[ M bytes ] Raw payload data
```


### Packet Types

- **Clipboard Transfer**
  - Header contains:
    - `type`: `"clipboard"`
    - `length`: size of text payload in bytes
  - Payload contains raw UTF-8 clipboard text.

- **File Transfer**
  - Header contains:
    - `type`: `"file"`
    - `name`: file name
    - `size`: file size in bytes
  - Payload contains the raw file bytes streamed over TCP.

### Design Notes

- Uses JSON only for packet metadata.
- Transfers actual content as raw bytes (no Base64 encoding).
- File data is streamed separately to support large files without loading them completely into memory.
- Handles packet parsing and partial TCP reads in the networking layer.

---

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

---

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
