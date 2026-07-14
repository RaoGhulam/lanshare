import 'package:flutter/services.dart';

/// Bridges to a small piece of native Android code (see
/// `android_kotlin_snippet/MainActivity.kt`) that publishes a file into the
/// public **Downloads/LANShare** folder using the `MediaStore` API.
///
/// Why MediaStore instead of writing directly to
/// `/storage/emulated/0/Download`:
/// - On Android 10+ (API 29+), direct `File` access to public folders is
///   blocked by scoped storage. The only way around that with plain file
///   paths is `MANAGE_EXTERNAL_STORAGE` ("All files access"), which (a)
///   requires the user to manually flip a toggle in a special Settings
///   screen and (b) still throws `EACCES: Permission denied` on plenty of
///   devices/OEM skins even once "granted".
/// - `MediaStore.Downloads` is the API Android actually wants apps to use
///   for this. Inserting through it requires **no runtime permission at
///   all** on API 29+, so there is nothing to be denied.
/// - On API 28 and below there is no scoped storage yet, so a normal file
///   copy into the public Downloads directory works fine as long as
///   `WRITE_EXTERNAL_STORAGE` is granted (a plain, one-tap dialog - not a
///   Settings redirect).
class MediaStoreHelper {
  MediaStoreHelper._();

  static const MethodChannel _channel = MethodChannel(
    'lanshare/media_store',
  );

  /// Copies the file currently at [sourcePath] (app-private storage, always
  /// writable) into the public Downloads/LANShare folder as [displayName].
  ///
  /// Returns a human-readable path/description of where the file ended up.
  /// Throws a [PlatformException] if the native side can't publish it (e.g.
  /// legacy-storage permission denied on very old Android) - callers should
  /// catch this and fall back to keeping the file in app storage instead of
  /// losing the transfer.
  static Future<String> saveToDownloads({
    required String sourcePath,
    required String displayName,
  }) async {
    final result = await _channel.invokeMethod<String>('saveToDownloads', {
      'sourcePath': sourcePath,
      'displayName': displayName,
    });
    return result ?? 'Download/LANShare/$displayName';
  }
}
