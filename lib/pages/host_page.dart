import 'package:flutter/material.dart';

import '../services/tcp_service.dart';
import 'transfer_page.dart';

/// Shown after the user taps "Create Server". Starts listening on TCP port
/// 5000, displays this device's IP/port, and automatically navigates both
/// devices to the Transfer screen once a client connects.
class HostPage extends StatefulWidget {
  const HostPage({super.key});

  @override
  State<HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<HostPage> {
  final TcpService _service = TcpService.instance;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _startServer();
  }

  Future<void> _startServer() async {
    try {
      await _service.startServer(port: TcpService.defaultPort);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Could not start server: $e');
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Server')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() => _errorMessage = null);
                  _startServer();
                },
                child: const Text('Retry'),
              ),
            ] else ...[
              const Text(
                'Server Running',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 32),
              _InfoTile(label: 'IP', value: _service.localIp ?? '...'),
              const SizedBox(height: 16),
              _InfoTile(label: 'Port', value: '${_service.port}'),
              const SizedBox(height: 16),
              _InfoTile(
                label: 'Status',
                value: _service.connectionState == LanConnectionState.listening
                    ? 'Listening...'
                    : 'Starting...',
              ),
              const SizedBox(height: 40),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              const Text(
                'Waiting for a device to connect...',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
            ],
          ],
        ),
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
            Text(
              value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
