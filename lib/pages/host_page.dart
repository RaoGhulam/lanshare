import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/join_info.dart';
import '../services/hotspot_service.dart';
import '../services/tcp_service.dart';
import 'transfer_page.dart';

/// Shown after the user taps "Create Server". Starts listening on TCP port
/// 5000, displays this device's IP/port, and automatically navigates both
/// devices to the Transfer screen once a client connects.
///
/// With [hotspot] set (Android only), it first starts an offline hotspot
/// so devices can connect without any Wi-Fi router, and the QR code also
/// carries the hotspot's name/password so a scanning phone joins it
/// automatically.
class HostPage extends StatefulWidget {
  final bool hotspot;

  const HostPage({super.key, this.hotspot = false});

  @override
  State<HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<HostPage> {
  final TcpService _service = TcpService.instance;
  String? _errorMessage;
  HotspotCredentials? _hotspot;
  bool _startingHotspot = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _startServer();
  }

  Future<void> _startServer() async {
    try {
      String? advertisedIp;
      if (widget.hotspot) {
        setState(() => _startingHotspot = true);
        final creds = await HotspotService.instance.startHotspot();
        if (!mounted) {
          await HotspotService.instance.stopAll();
          return;
        }
        setState(() {
          _hotspot = creds;
          _startingHotspot = false;
        });
        advertisedIp = creds.ip;
      }
      await _service.startServer(
        port: TcpService.defaultPort,
        advertisedIp: advertisedIp,
      );
    } catch (e) {
      if (widget.hotspot) await HotspotService.instance.stopAll();
      if (!mounted) return;
      setState(() {
        _startingHotspot = false;
        _hotspot = null;
        _errorMessage = widget.hotspot
            ? 'Could not start offline hotspot: $e'
            : 'Could not start server: $e';
      });
    }
  }

  void _onServiceChanged() {
    if (!mounted) return;
    if (_service.connectionState == LanConnectionState.connected) {
      // A client has connected - move both this device (as server) and,
      // independently, the client device to the Transfer screen.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TransferPage()),
      );
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    // Leaving before anyone connected: don't keep the hotspot running. Once
    // connected, HotspotService stops it when the session ends instead.
    if (widget.hotspot &&
        _service.connectionState != LanConnectionState.connected) {
      HotspotService.instance.stopAll();
    }
    super.dispose();
  }

  String? get _qrData {
    final ip = _service.localIp;
    if (ip == null) return null;
    final hotspot = _hotspot;
    if (hotspot == null) return ip; // Plain IP: works with older versions.
    return JoinInfo(
      ip: ip,
      port: _service.port,
      ssid: hotspot.ssid,
      password: hotspot.password,
    ).toQrData();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final hotspot = _hotspot;
    final qrData = _qrData;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.hotspot ? 'Offline Hotspot' : 'Create Server'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24.0),
        children: [
          if (_errorMessage != null) ...[
            Card(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red.shade800),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                setState(() => _errorMessage = null);
                _startServer();
              },
              child: const Text('Retry'),
            ),
          ] else if (_startingHotspot) ...[
            const SizedBox(height: 48),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            const Text(
              'Starting offline hotspot...',
              textAlign: TextAlign.center,
            ),
          ] else ...[
            Text(
              hotspot != null ? 'Hotspot Running' : 'Server Running',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 12),

            if (qrData != null)
              Center(
                child: QrImageView(
                  data: qrData,
                  version: QrVersions.auto,
                  size: screenHeight * 0.22,
                ),
              ),

            const SizedBox(height: 12),

            if (hotspot != null) ...[
              _InfoTile(label: 'Wi-Fi name', value: hotspot.ssid),
              const SizedBox(height: 8),
              _InfoTile(label: 'Wi-Fi password', value: hotspot.password),
              const SizedBox(height: 8),
            ],

            _InfoTile(
              label: 'IP',
              value: _service.localIp ?? '...',
            ),

            const SizedBox(height: 8),

            _InfoTile(
              label: 'Port',
              value: '${_service.port}',
            ),

            const SizedBox(height: 8),

            _InfoTile(
              label: 'Status',
              value: _service.connectionState == LanConnectionState.listening
                  ? 'Listening...'
                  : 'Starting...',
            ),

            const SizedBox(height: 16),

            const Center(
              child: CircularProgressIndicator(),
            ),

            const SizedBox(height: 8),

            Text(
              hotspot != null
                  ? 'Phone: tap Join Server > Scan QR Code.\n'
                      'Laptop: connect to the Wi-Fi above, then Join Server with the IP.'
                  : 'Waiting for a device to connect...',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String label;
  final String value;

  const _InfoTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 4),
            SelectableText(
              value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
