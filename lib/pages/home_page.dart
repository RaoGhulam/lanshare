import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/hotspot_service.dart';
import '../services/share_intent_service.dart';
import 'host_page.dart';
import 'join_page.dart';

/// The very first screen: pick whether this device will host (Create
/// Server) or join (Join Server) the LAN session.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ShareIntentService _shares = ShareIntentService.instance;

  @override
  void initState() {
    super.initState();
    _shares.addListener(_onSharesChanged);
    _requestStoragePermissionIfNeeded();
  }

  @override
  void dispose() {
    _shares.removeListener(_onSharesChanged);
    super.dispose();
  }

  void _onSharesChanged() {
    if (mounted) setState(() {});
  }

  /// Requests the storage permission on Android up front, so the user
  /// isn't interrupted mid-transfer.
  ///
  /// Received files are published to the public Downloads folder via the
  /// `MediaStore` API (see `MediaStoreHelper`), which requires **no
  /// permission at all** on Android 10+ (API 29+) - so on modern devices
  /// this is a no-op. Only Android 9 and below (pre-scoped-storage) still
  /// need the classic storage permission, requested here via a normal,
  /// one-tap dialog (not the fragile "All files access" Settings redirect
  /// the old code used, which is what was causing permission-denied
  /// errors).
  Future<void> _requestStoragePermissionIfNeeded() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        await Permission.storage.request();
      }
    } catch (_) {
      // Ignore - not fatal, individual actions will surface their own
      // errors if a permission is truly missing.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LANShare')),
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_shares.hasPending) ...[
                  _PendingSharesCard(
                    count: _shares.pendingCount,
                    onClear: _shares.clear,
                  ),
                  const SizedBox(height: 24),
                ],
                const Icon(Icons.wifi_tethering, size: 96, color: Colors.indigo),
                const SizedBox(height: 16),
                const Text(
                  'Share clipboard text and files with another device\non the same Wi-Fi network - or without one, using offline hotspot mode.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.black54),
                ),
                const SizedBox(height: 48),
                ElevatedButton.icon(
                  icon: const Icon(Icons.dns),
                  label: const Text('Create Server'),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const HostPage()),
                    );
                  },
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  icon: const Icon(Icons.link),
                  label: const Text('Join Server'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const JoinPage()),
                    );
                  },
                ),
                if (HotspotService.instance.isSupported) ...[
                  const SizedBox(height: 24),
                  TextButton.icon(
                    icon: const Icon(Icons.wifi_off),
                    label: const Text('No Wi-Fi? Create Offline Hotspot'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const HostPage(hotspot: true),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when files/text were shared into the app from another app and are
/// waiting for a connection.
class _PendingSharesCard extends StatelessWidget {
  final int count;
  final VoidCallback onClear;

  const _PendingSharesCard({required this.count, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.indigo.shade50,
      child: ListTile(
        leading: const Icon(Icons.outbox, color: Colors.indigo),
        title: Text('$count item${count == 1 ? '' : 's'} ready to send'),
        subtitle: const Text(
          'Create or join a server - they will be sent as soon as a device connects.',
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Discard',
          onPressed: onClear,
        ),
      ),
    );
  }
}
