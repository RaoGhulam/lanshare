import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'tcp_service.dart';

/// Credentials of the offline hotspot this device is hosting.
class HotspotCredentials {
  final String ssid;
  final String password;

  /// This device's IP on the hotspot network, or null if it couldn't be
  /// detected (the caller falls back to the regular IP lookup).
  final String? ip;

  const HotspotCredentials({
    required this.ssid,
    required this.password,
    this.ip,
  });
}

class HotspotException implements Exception {
  final String message;
  const HotspotException(this.message);

  @override
  String toString() => message;
}

/// Offline mode for when there is no Wi-Fi router: one Android device hosts
/// a local-only hotspot (no internet / mobile data involved) and the other
/// device - phone or laptop - joins it. After that, the regular TCP transfer
/// in [TcpService] runs over the hotspot unchanged.
///
/// Bridges to native code in `android/.../HotspotHandler.kt`. Android only;
/// laptops simply join the hotspot from their normal Wi-Fi menu.
class HotspotService {
  HotspotService._();
  static final HotspotService instance = HotspotService._();

  static const MethodChannel _channel = MethodChannel('lanshare/hotspot');

  bool get isSupported => Platform.isAndroid;

  bool _hosting = false;
  bool _joined = false;
  bool _wasConnected = false;

  /// Releases the hotspot (or the joined hotspot network) automatically when
  /// a session that used it ends.
  void attach(TcpService tcp) {
    tcp.addListener(() {
      if (tcp.connectionState == LanConnectionState.connected) {
        _wasConnected = true;
      } else if (tcp.connectionState == LanConnectionState.disconnected &&
          _wasConnected) {
        _wasConnected = false;
        stopAll();
      }
    });
  }

  /// Starts an offline hotspot on this device and returns its credentials.
  Future<HotspotCredentials> startHotspot() async {
    await _ensureHostPermissions();
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('startHotspot');
      _hosting = true;
      return HotspotCredentials(
        ssid: result?['ssid'] as String? ?? '',
        password: result?['password'] as String? ?? '',
        ip: result?['ip'] as String?,
      );
    } on PlatformException catch (e) {
      throw HotspotException(e.message ?? e.code);
    }
  }

  /// Joins another device's hotspot. On Android 10+ the system shows a
  /// one-tap confirmation dialog.
  Future<void> joinNetwork(String ssid, String password) async {
    try {
      await _channel.invokeMethod<void>('joinNetwork', {
        'ssid': ssid,
        'password': password,
      });
      _joined = true;
    } on PlatformException catch (e) {
      throw HotspotException(e.message ?? e.code);
    }
  }

  /// Stops hosting and/or leaves a joined hotspot. Safe to call any time.
  Future<void> stopAll() async {
    if (!isSupported) return;
    try {
      if (_hosting) await _channel.invokeMethod<void>('stopHotspot');
      if (_joined) await _channel.invokeMethod<void>('leaveNetwork');
    } catch (_) {
      // Best effort.
    }
    _hosting = false;
    _joined = false;
  }

  /// Android 13+ gates hotspots on "Nearby Wi-Fi devices"; older versions
  /// on location.
  Future<void> _ensureHostPermissions() async {
    final sdk = await _channel.invokeMethod<int>('sdkInt') ?? 0;
    final permission =
        sdk >= 33 ? Permission.nearbyWifiDevices : Permission.locationWhenInUse;
    final status = await permission.request();
    if (!status.isGranted) {
      throw HotspotException(
        sdk >= 33
            ? 'The "Nearby devices" permission is needed to create a hotspot.'
            : 'Android needs the Location permission to create a hotspot.',
      );
    }
  }
}
