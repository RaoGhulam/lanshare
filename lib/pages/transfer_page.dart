import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/tcp_service.dart';
import 'home_page.dart';

/// The main screen once two devices are connected. Identical on both the
/// server and the client. Lets the user send/receive clipboard text and
/// send/receive files.
class TransferPage extends StatefulWidget {
  const TransferPage({super.key});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  final TcpService _service = TcpService.instance;
  StreamSubscription<String>? _snackbarSubscription;
  bool _isSendingClipboard = false;
  bool _isPickingFiles = false;
  bool _hasLeft = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _snackbarSubscription = _service.snackbarStream.listen(_showSnackbar);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _snackbarSubscription?.cancel();
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    if (_service.connectionState == LanConnectionState.disconnected &&
        !_hasLeft) {
      _hasLeft = true;
      // The peer disconnected (or we did) - return to the Home screen.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomePage()),
        (route) => false,
      );
      return;
    }
    setState(() {});
  }

  void _showSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  Future<void> _disconnect() async {
    _hasLeft = true;
    await _service.disconnect();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomePage()),
      (route) => false,
    );
  }

  Future<void> _sendClipboard() async {
    setState(() => _isSendingClipboard = true);
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text ?? '';
      if (text.isEmpty) {
        _showSnackbar('Clipboard is empty');
        return;
      }
      await _service.sendClipboard(text);
    } catch (e) {
      _showSnackbar('Failed to send clipboard: $e');
    } finally {
      if (mounted) setState(() => _isSendingClipboard = false);
    }
  }

  Future<void> _selectAndSendFiles() async {
    setState(() => _isPickingFiles = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;

      for (final platformFile in result.files) {
        final path = platformFile.path;
        if (path == null) continue;
        final file = File(path);
        try {
          await _service.sendFile(file);
        } catch (e) {
          _showSnackbar('Failed to send ${platformFile.name}: $e');
        }
      }
    } catch (e) {
      _showSnackbar('File selection failed: $e');
    } finally {
      if (mounted) setState(() => _isPickingFiles = false);
    }
  }

  void _showReceivedFiles() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final files = _service.receivedFiles;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (context, scrollController) {
            if (files.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32.0),
                  child: Text('No files received yet.'),
                ),
              );
            }
            return ListView.separated(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: files.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (context, index) {
                // Show most recent first.
                final file = files[files.length - 1 - index];
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(file.name),
                  subtitle: Text(
                    '${_formatBytes(file.size)} · ${file.path}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final connected = _service.connectionState == LanConnectionState.connected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfer'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            color: connected ? Colors.green.shade50 : Colors.orange.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    connected ? Icons.check_circle : Icons.error,
                    color: connected ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          connected ? 'Connected' : 'Not connected',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        Text('Remote: ${_service.remoteAddress ?? '-'}'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // --- Clipboard ---
          ElevatedButton.icon(
            icon: const Icon(Icons.content_copy),
            label: Text(_isSendingClipboard ? 'Sending...' : 'Send Clipboard'),
            onPressed: _isSendingClipboard ? null : _sendClipboard,
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Received Clipboard',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    _service.lastReceivedClipboard?.isNotEmpty == true
                        ? _service.lastReceivedClipboard!
                        : '(nothing received yet)',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // --- Files ---
          ElevatedButton.icon(
            icon: const Icon(Icons.upload_file),
            label: Text(_isPickingFiles ? 'Selecting...' : 'Select File'),
            onPressed: _isPickingFiles ? null : _selectAndSendFiles,
          ),
          if (_service.sendProgress != null) ...[
            const SizedBox(height: 12),
            Text('Sending: ${_service.currentSendingFileName ?? ''}'),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: _service.sendProgress),
          ],
          if (_service.receiveProgress != null) ...[
            const SizedBox(height: 12),
            const Text('Receiving file...'),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: _service.receiveProgress),
          ],
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.folder),
            label: Text('Received Files (${_service.receivedFiles.length})'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: _showReceivedFiles,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: ElevatedButton.icon(
            onPressed: _disconnect,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(56),
            ),
            icon: const Icon(Icons.link_off),
            label: const Text('Disconnect'),
          ),
        ),
      ),
    );
  }
}
