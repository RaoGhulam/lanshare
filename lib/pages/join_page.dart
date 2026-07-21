import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/tcp_service.dart';
import 'transfer_page.dart';

/// Shown after the user taps "Join Server". Lets the user type in the
/// host's IP address and port, then connects to it as a TCP client.
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

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;

    final ip = _ipController.text.trim();
    final port = int.parse(_portController.text.trim());

    setState(() => _isConnecting = true);
    try {
      await TcpService.instance.connect(ip, port);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TransferPage()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isConnecting = false);
      _showErrorDialog('Could not connect to $ip:$port.\n\n$e');
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
    final parts = value.trim().split('.');
    if (parts.length != 4 ||
        parts.any((p) => int.tryParse(p) == null ||
            int.parse(p) < 0 ||
            int.parse(p) > 255)) {
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

  void _scanQrCode() {
    bool hasScanned = false; // guard against multiple onDetect calls

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Scan Server QR')),
          body: MobileScanner(
            onDetect: (capture) {
              if (hasScanned) return; // ignore subsequent frames

              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isEmpty) return;

              final String? ip = barcodes.first.rawValue;
              if (ip != null && _validateIp(ip) == null) {
                hasScanned = true; // lock it immediately

                _ipController.text = ip;

                Navigator.of(context).pop(); // pop only once, guaranteed

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('IP filled: $ip')),
                );
              }
            },
          ),
        ),
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join Server')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
                label: Text(_isConnecting ? 'Connecting...' : 'Connect'),
                onPressed: _isConnecting ? null : _connect,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
