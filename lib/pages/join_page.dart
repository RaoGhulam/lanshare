import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/join_info.dart';
import '../services/hotspot_service.dart';
import '../services/recent_devices_service.dart';
import '../services/tcp_service.dart';
import 'transfer_page.dart';

/// Shown after the user taps "Join Server". Lets the user type in the
/// host's IP address and port, then connects to it as a TCP client.
///
/// Scanning an offline-hotspot QR code (see HostPage) also joins the host's
/// hotspot first, so no Wi-Fi router is needed.
class JoinPage extends StatefulWidget {
  const JoinPage({super.key});

  @override
  State<JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: '${TcpService.defaultPort}');
  final _formKey = GlobalKey<FormState>();

  bool _isConnecting = false;
  String _connectingLabel = 'Connecting...';
  List<RecentDevice> _recentDevices = <RecentDevice>[];

  @override
  void initState() {
    super.initState();
    _loadRecentDevices();
  }

  Future<void> _loadRecentDevices() async {
    final devices = await RecentDevicesService.instance.load();
    if (mounted) setState(() => _recentDevices = devices);
  }

  Future<void> _connectToRecent(RecentDevice device) async {
    _ipController.text = device.ip;
    _portController.text = '${device.port}';
    await _connect();
  }

  Future<void> _forgetRecent(RecentDevice device) async {
    await RecentDevicesService.instance.forget(device);
    await _loadRecentDevices();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  /// Connects to the IP/port in the form. When [hotspot] is given (scanned
  /// from an offline-hotspot QR code), joins that hotspot first.
  Future<void> _connect({JoinInfo? hotspot}) async {
    if (!_formKey.currentState!.validate()) return;

    final ip = _ipController.text.trim();
    final port = int.parse(_portController.text.trim());
    final ssid = hotspot?.ssid;
    final password = hotspot?.password ?? '';
    final joinHotspot = ssid != null &&
        ssid.isNotEmpty &&
        HotspotService.instance.isSupported;

    setState(() {
      _isConnecting = true;
      _connectingLabel =
          joinHotspot ? 'Joining "$ssid"...' : 'Connecting...';
    });

    var joined = false;
    try {
      if (joinHotspot) {
        await HotspotService.instance.joinNetwork(
          ssid!,
          password,
        );
        joined = true;
        if (mounted) setState(() => _connectingLabel = 'Connecting...');
      }
      await _connectWithRetry(ip, port, retries: joined ? 4 : 0);
      // Hotspot credentials are random per session, so only remember
      // regular Wi-Fi servers.
      if (!joined) {
        unawaited(RecentDevicesService.instance.remember(ip, port));
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TransferPage()),
      );
    } catch (e) {
      if (joined) await HotspotService.instance.stopAll();
      if (!mounted) return;
      setState(() => _isConnecting = false);
      _showErrorDialog(
        e is HotspotException
            ? 'Could not join the hotspot.\n\n$e'
            : 'Could not connect to $ip:$port.\n\n$e',
      );
    }
  }

  /// Right after joining a hotspot the network can take a moment to become
  /// routable, so retry a few times before giving up.
  Future<void> _connectWithRetry(
    String ip,
    int port, {
    required int retries,
  }) async {
    for (var attempt = 0;; attempt++) {
      try {
        await TcpService.instance.connect(ip, port);
        return;
      } on SocketException {
        if (attempt >= retries) rethrow;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  void _showErrorDialog(String message) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connection Failed'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String? _validateIp(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter the server IP address';
    }
    if (!JoinInfo.isValidIpv4(value)) {
      return 'Enter a valid IPv4 address (e.g. 192.168.1.10)';
    }
    return null;
  }

  String? _validatePort(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter a port number';
    }
    final port = int.tryParse(value.trim());
    if (port == null || port < 1 || port > 65535) {
      return 'Enter a valid port (1-65535)';
    }
    return null;
  }

  String _formatAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays} days ago';
  }

  Future<void> _scanQrCode() async {
    final info = await Navigator.of(context).push<JoinInfo>(
      MaterialPageRoute(builder: (_) => const _QrScannerPage()),
    );
    if (info == null || !mounted) return;

    _ipController.text = info.ip;
    _portController.text = '${info.port}';

    if (info.viaHotspot) {
      // Offline hotspot QR: join the hotspot and connect in one go.
      await _connect(hotspot: info);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('IP filled: ${info.ip}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join Server')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _ipController,
                enabled: !_isConnecting,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Server IP',
                  hintText: '192.168.1.10',
                  border: OutlineInputBorder(),
                ),
                validator: _validateIp,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _portController,
                enabled: !_isConnecting,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  border: OutlineInputBorder(),
                ),
                validator: _validatePort,
              ),
              const SizedBox(height: 20),

              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR Code'),
                onPressed: _isConnecting ? null : _scanQrCode,
              ),

              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: _isConnecting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.link),
                label: Text(_isConnecting ? _connectingLabel : 'Connect'),
                onPressed: _isConnecting ? null : _connect,
              ),

              if (_recentDevices.isNotEmpty) ...[
                const SizedBox(height: 32),
                const Text(
                  'Recent Devices',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                for (final device in _recentDevices)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.history),
                      title: Text('${device.ip}:${device.port}'),
                      subtitle: Text(
                        'Last connected ${_formatAgo(device.lastConnected)}',
                      ),
                      enabled: !_isConnecting,
                      onTap: () => _connectToRecent(device),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Forget',
                        onPressed:
                            _isConnecting ? null : () => _forgetRecent(device),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen camera that pops with the first valid LANShare QR code.
class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  bool _hasScanned = false; // guard against multiple onDetect calls

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Server QR')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_hasScanned) return; // ignore subsequent frames

          for (final barcode in capture.barcodes) {
            final raw = barcode.rawValue;
            if (raw == null) continue;
            final info =
                JoinInfo.parse(raw, defaultPort: TcpService.defaultPort);
            if (info != null) {
              _hasScanned = true; // lock it immediately
              Navigator.of(context).pop(info); // pop only once, guaranteed
              return;
            }
          }
        },
      ),
    );
  }
}
