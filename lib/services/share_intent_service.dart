import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Holds files/text that were shared into LANShare from another app via
/// Android's share sheet, until a peer is connected to send them to.
///
/// Bridges to native code in `android/.../ShareHandler.kt`, which copies
/// shared content into the app's cache so these are plain file paths.
class ShareIntentService extends ChangeNotifier {
  ShareIntentService._();
  static final ShareIntentService instance = ShareIntentService._();

  static const MethodChannel _channel = MethodChannel('lanshare/share');

  final List<String> _pendingFiles = <String>[];
  final List<String> _pendingTexts = <String>[];

  List<String> get pendingFiles => List.unmodifiable(_pendingFiles);
  List<String> get pendingTexts => List.unmodifiable(_pendingTexts);
  int get pendingCount => _pendingFiles.length + _pendingTexts.length;
  bool get hasPending => pendingCount > 0;

  /// Call once at startup. Picks up a share that launched the app and
  /// listens for shares arriving while it's running.
  Future<void> init() async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShare') _add(call.arguments);
    });
    try {
      final initial = await _channel.invokeListMethod<dynamic>('getInitialShares');
      initial?.forEach(_add);
    } catch (_) {
      // Not fatal - sharing into the app just won't work.
    }
  }

  void _add(dynamic raw) {
    if (raw is! Map) return;
    final files = (raw['files'] as List?)?.cast<String>() ?? const <String>[];
    final text = raw['text'] as String?;
    _pendingFiles.addAll(files);
    if (text != null && text.isNotEmpty) _pendingTexts.add(text);
    notifyListeners();
  }

  /// Removes and returns everything pending, so it's only sent once.
  ({List<String> files, List<String> texts}) takePending() {
    final taken = (
      files: List<String>.of(_pendingFiles),
      texts: List<String>.of(_pendingTexts),
    );
    _pendingFiles.clear();
    _pendingTexts.clear();
    notifyListeners();
    return taken;
  }

  /// Discards everything pending (and the cached copies).
  void clear() {
    for (final path in _pendingFiles) {
      deleteCachedFile(path);
    }
    _pendingFiles.clear();
    _pendingTexts.clear();
    notifyListeners();
  }

  /// Deletes the cache copy of a shared file once it has been sent.
  void deleteCachedFile(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // The OS clears the cache eventually anyway.
    }
  }
}
