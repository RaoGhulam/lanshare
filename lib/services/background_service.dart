import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'tcp_service.dart';

/// Keeps the app (and its socket) alive while a session is active by
/// running an Android foreground service with a "LANShare connected"
/// notification. Without it, switching to another app - e.g. the Files app
/// to share something into LANShare - can get the app frozen or killed,
/// dropping the connection.
///
/// Bridges to native code in `android/.../ConnectionService.kt`. No-op on
/// desktop, where background apps keep running anyway.
class BackgroundService {
  BackgroundService._();
  static final BackgroundService instance = BackgroundService._();

  static const MethodChannel _channel = MethodChannel('lanshare/background');

  LanConnectionState? _lastState;
  bool _askedNotificationPermission = false;

  /// Starts/updates/stops the foreground service as [tcp]'s state changes.
  void attach(TcpService tcp) {
    if (!Platform.isAndroid) return;
    tcp.addListener(() {
      final state = tcp.connectionState;
      if (state == _lastState) return;
      _lastState = state;

      switch (state) {
        case LanConnectionState.listening:
          _start('Waiting for a device to connect');
        case LanConnectionState.connected:
          _start('Connected to ${tcp.remoteAddress ?? 'device'}');
        case LanConnectionState.disconnected:
          _channel.invokeMethod<void>('stop').catchError((Object _) {});
      }
    });
  }

  Future<void> _start(String text) async {
    // Android 13+ hides the notification without this; the service still
    // runs either way, so a denial is fine.
    if (!_askedNotificationPermission) {
      _askedNotificationPermission = true;
      try {
        await Permission.notification.request();
      } catch (_) {}
    }
    try {
      await _channel.invokeMethod<void>('start', {'text': text});
    } catch (_) {
      // Best effort - the session still works while the app is in front.
    }
  }
}
