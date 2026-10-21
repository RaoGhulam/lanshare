import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A server this device has successfully connected to before.
class RecentDevice {
  final String ip;
  final int port;
  final DateTime lastConnected;

  const RecentDevice({
    required this.ip,
    required this.port,
    required this.lastConnected,
  });

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'port': port,
        'lastConnected': lastConnected.toIso8601String(),
      };

  factory RecentDevice.fromJson(Map<String, dynamic> json) {
    return RecentDevice(
      ip: json['ip'] as String,
      port: json['port'] as int,
      lastConnected: DateTime.parse(json['lastConnected'] as String),
    );
  }
}

/// Remembers recently joined servers so the Join screen can offer them as
/// one-tap shortcuts instead of typing/scanning the IP every time.
///
/// Stored as a small JSON file in the app support directory (works on
/// Android, Windows and Linux with no extra plugin).
class RecentDevicesService {
  RecentDevicesService._();
  static final RecentDevicesService instance = RecentDevicesService._();

  static const int _maxEntries = 10;

  List<RecentDevice>? _cache;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/recent_devices.json');
  }

  /// Most recently connected first.
  Future<List<RecentDevice>> load() async {
    if (_cache != null) return List.of(_cache!);
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString()) as List;
        _cache = decoded
            .map((e) => RecentDevice.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (_) {
      // Corrupt or unreadable file - start fresh.
    }
    _cache ??= <RecentDevice>[];
    return List.of(_cache!);
  }

  /// Records a successful connection, moving it to the top of the list.
  Future<void> remember(String ip, int port) async {
    final list = await load();
    list.removeWhere((d) => d.ip == ip && d.port == port);
    list.insert(
      0,
      RecentDevice(ip: ip, port: port, lastConnected: DateTime.now()),
    );
    if (list.length > _maxEntries) list.removeRange(_maxEntries, list.length);
    await _save(list);
  }

  Future<void> forget(RecentDevice device) async {
    final list = await load();
    list.removeWhere((d) => d.ip == device.ip && d.port == device.port);
    await _save(list);
  }

  Future<void> _save(List<RecentDevice> list) async {
    _cache = list;
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(list.map((d) => d.toJson()).toList()));
    } catch (_) {
      // Not fatal - the list just won't survive a restart.
    }
  }
}
