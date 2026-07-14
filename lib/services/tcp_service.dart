import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/message.dart';
import 'media_store_helper.dart';
import 'protocol.dart';

/// High level connection state exposed to the UI.
enum LanConnectionState { disconnected, listening, connected }

/// Internal parser state used while reading the incoming byte stream.
/// Every incoming packet is: [4-byte header length][JSON header][payload].
enum _ReadState { headerLength, header, payload }

/// Singleton service that owns the single active TCP connection (either as
/// server or client), implements the wire protocol from [Protocol], and
/// exposes connection/transfer state to the UI via [ChangeNotifier].
///
/// Only one socket is ever active at a time: the server accepts exactly one
/// client and then stops listening for further connections.
class TcpService extends ChangeNotifier {
  TcpService._internal();
  static final TcpService instance = TcpService._internal();

  static const int defaultPort = 5000;

  // ---------------------------------------------------------------------
  // Public state (read by the UI, changes are announced via
  // ChangeNotifier.notifyListeners()).
  // ---------------------------------------------------------------------

  LanConnectionState connectionState = LanConnectionState.disconnected;
  String? localIp;
  int port = defaultPort;
  String? remoteAddress;

  String? lastReceivedClipboard;
  List<ReceivedFileInfo> receivedFiles = <ReceivedFileInfo>[];

  /// 0.0-1.0 while a file is being sent, null when idle.
  double? sendProgress;

  /// 0.0-1.0 while a file is being received, null when idle.
  double? receiveProgress;

  String? get currentSendingFileName => _currentSendingFileName;
  String? _currentSendingFileName;

  /// One-off human readable status messages meant to be shown as SnackBars
  /// (e.g. "Connected", "Clipboard Sent", "File Received: photo.jpg").
  final StreamController<String> _snackbarController =
      StreamController<String>.broadcast();
  Stream<String> get snackbarStream => _snackbarController.stream;

  // ---------------------------------------------------------------------
  // Private socket / parser state.
  // ---------------------------------------------------------------------

  ServerSocket? _serverSocket;
  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;

  final List<int> _buffer = <int>[];
  _ReadState _state = _ReadState.headerLength;
  bool _isDraining = false;

  int _pendingHeaderLength = 0;
  Map<String, dynamic>? _pendingHeader;
  int _payloadRemaining = 0;

  MessageType? _currentType;

  // Clipboard receive state.
  List<int>? _clipboardChunks;

  // File receive state.
  IOSink? _fileSink;
  String? _currentFileName;
  String? _currentFilePath;
  int _currentFileReceived = 0;

  // ---------------------------------------------------------------------
  // Server / client setup.
  // ---------------------------------------------------------------------

  /// Starts listening for a single incoming connection on [port].
  /// Throws if the socket cannot be bound (e.g. port already in use).
  Future<void> startServer({int port = defaultPort}) async {
    await disconnect(silent: true);

    this.port = port;
    localIp = await getLocalIpAddress();
    connectionState = LanConnectionState.listening;
    notifyListeners();

    try {
      _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    } catch (e) {
      connectionState = LanConnectionState.disconnected;
      notifyListeners();
      rethrow;
    }

    _serverSocket!.listen(
      (Socket client) {
        // This app accepts exactly one client. Reject anyone else.
        if (_socket != null) {
          client.destroy();
          return;
        }
        _attachSocket(client);
        // Stop accepting further connections once we have our one peer.
        _serverSocket?.close();
        _serverSocket = null;
      },
      onError: (Object e) {
        _emitSnackbar('Server error: $e');
      },
    );
  }

  /// Connects to a remote server as a client.
  /// Throws on failure (invalid IP, connection refused, timeout, etc.) so
  /// the caller (Join Server page) can show an error dialog.
  Future<void> connect(String ip, int port) async {
    await disconnect(silent: true);
    this.port = port;

    final socket = await Socket.connect(
      ip,
      port,
      timeout: const Duration(seconds: 8),
    );
    _attachSocket(socket);
  }

  void _attachSocket(Socket socket) {
    _socket = socket;
    remoteAddress = '${socket.remoteAddress.address}:${socket.remotePort}';
    connectionState = LanConnectionState.connected;
    _resetParserState();

    _subscription = socket.listen(
      _onData,
      onDone: _handleRemoteClosed,
      onError: (Object e) {
        _emitSnackbar('Connection error: $e');
        _handleRemoteClosed();
      },
      cancelOnError: true,
    );

    _emitSnackbar('Connected');
    notifyListeners();
  }

  void _handleRemoteClosed() {
    if (connectionState == LanConnectionState.disconnected) return;
    disconnect();
  }

  /// Closes the active socket (and server socket, if any) and returns the
  /// service to the disconnected state. Safe to call multiple times.
  Future<void> disconnect({bool silent = false}) async {
    final wasActive = connectionState != LanConnectionState.disconnected;

    await _subscription?.cancel();
    _subscription = null;

    await _socket?.close();
    _socket = null;

    await _serverSocket?.close();
    _serverSocket = null;

    await _fileSink?.close();
    _fileSink = null;

    _resetParserState();

    connectionState = LanConnectionState.disconnected;
    remoteAddress = null;
    sendProgress = null;
    receiveProgress = null;
    _currentSendingFileName = null;

    if (wasActive && !silent) {
      _emitSnackbar('Disconnected');
    }
    notifyListeners();
  }

  void _resetParserState() {
    _buffer.clear();
    _state = _ReadState.headerLength;
    _pendingHeaderLength = 0;
    _pendingHeader = null;
    _payloadRemaining = 0;
    _currentType = null;
    _clipboardChunks = null;
    _currentFileName = null;
    _currentFilePath = null;
    _currentFileReceived = 0;
  }

  // ---------------------------------------------------------------------
  // Sending.
  // ---------------------------------------------------------------------

  /// Reads [text] (already fetched from the clipboard by the caller) and
  /// sends it to the peer.
  Future<void> sendClipboard(String text) async {
    if (_socket == null) {
      throw StateError('Not connected');
    }
    if (text.isEmpty) {
      throw StateError('Clipboard is empty');
    }
    final packet = Protocol.buildClipboardPacket(text);
    _socket!.add(packet);
    await _socket!.flush();
    _emitSnackbar('Clipboard Sent');
  }

  /// Streams [file] to the peer, updating [sendProgress] as bytes go out.
  Future<void> sendFile(File file) async {
    if (_socket == null) {
      throw StateError('Not connected');
    }

    final size = await file.length();
    final name = _basename(file.path);

    _currentSendingFileName = name;
    sendProgress = 0;
    notifyListeners();

    try {
      final headerBytes = Protocol.buildFileHeader(name, size);
      _socket!.add(headerBytes);

      if (size == 0) {
        sendProgress = 1;
        notifyListeners();
      } else {
        int sent = 0;
        await for (final chunk in file.openRead()) {
          _socket!.add(chunk);
          sent += chunk.length;
          sendProgress = sent / size;
          notifyListeners();
        }
      }
      await _socket!.flush();
      _emitSnackbar('File Sent: $name');
    } finally {
      sendProgress = null;
      _currentSendingFileName = null;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  // Receiving / parsing.
  // ---------------------------------------------------------------------

  void _onData(Uint8List chunk) {
    _buffer.addAll(chunk);
    // Fire and forget: _drain() guards itself against re-entrancy so it is
    // safe to call without awaiting from this synchronous callback.
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_isDraining) return;
    _isDraining = true;
    try {
      bool progressed = true;
      while (progressed) {
        progressed = false;
        switch (_state) {
          case _ReadState.headerLength:
            if (_buffer.length >= 4) {
              final lengthBytes = _takeBytes(4);
              _pendingHeaderLength = Protocol.decodeHeaderLength(lengthBytes);
              _state = _ReadState.header;
              progressed = true;
            }
            break;

          case _ReadState.header:
            if (_buffer.length >= _pendingHeaderLength) {
              final headerBytes = _takeBytes(_pendingHeaderLength);
              _pendingHeader = Protocol.decodeHeader(headerBytes);
              await _beginPayload();
              _state = _ReadState.payload;
              progressed = true;
            }
            break;

          case _ReadState.payload:
            if (_payloadRemaining <= 0) {
              await _finishPayload();
              _state = _ReadState.headerLength;
              progressed = true;
            } else if (_buffer.isNotEmpty) {
              final take = _buffer.length < _payloadRemaining
                  ? _buffer.length
                  : _payloadRemaining;
              final chunk = _takeBytes(take);
              await _consumePayloadChunk(chunk);
              _payloadRemaining -= take;
              progressed = true;
            }
            break;
        }
      }
    } catch (e) {
      _emitSnackbar('Protocol error: $e');
      _resetParserState();
    } finally {
      _isDraining = false;
    }
  }

  Uint8List _takeBytes(int n) {
    final taken = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return taken;
  }

  Future<void> _beginPayload() async {
    final header = _pendingHeader!;
    final type = header['type'] as String;

    if (type == 'clipboard') {
      _currentType = MessageType.clipboard;
      _payloadRemaining = header['length'] as int;
      _clipboardChunks = <int>[];
    } else if (type == 'file') {
      final fileHeader = FileHeader.fromJson(header);
      _currentType = MessageType.file;
      _payloadRemaining = fileHeader.size;
      _currentFileName = fileHeader.name;
      _currentFileReceived = 0;

      // Always stream into the app's private temp directory first. This
      // location is guaranteed writable with zero permissions on every
      // platform/OS version, so the transfer itself can never fail with a
      // permission error. The file is only "published" to its public,
      // user-visible destination after it has fully landed (see
      // _finishPayload), which keeps the risky part small and recoverable.
      final tempDir = await getTemporaryDirectory();
      _currentFilePath = await _uniqueFilePath(
        tempDir,
        '${DateTime.now().microsecondsSinceEpoch}_${fileHeader.name}',
      );
      _fileSink = File(_currentFilePath!).openWrite();

      receiveProgress = fileHeader.size == 0 ? 1 : 0;
      notifyListeners();
    } else {
      throw FormatException('Unknown message type in header: $type');
    }
  }

  Future<void> _consumePayloadChunk(Uint8List chunk) async {
    if (_currentType == MessageType.clipboard) {
      _clipboardChunks!.addAll(chunk);
    } else if (_currentType == MessageType.file) {
      _fileSink!.add(chunk);
      _currentFileReceived += chunk.length;
      final total = _pendingHeader!['size'] as int;
      receiveProgress = total == 0 ? 1 : _currentFileReceived / total;
      notifyListeners();
    }
  }

  Future<void> _finishPayload() async {
    if (_currentType == MessageType.clipboard) {
      final text = utf8.decode(_clipboardChunks ?? <int>[]);
      lastReceivedClipboard = text;
      _clipboardChunks = null;
      _emitSnackbar('Clipboard Received');
    } else if (_currentType == MessageType.file) {
      await _fileSink?.flush();
      await _fileSink?.close();
      _fileSink = null;

      final finalPath = await _publishReceivedFile(
        tempPath: _currentFilePath!,
        fileName: _currentFileName!,
      );

      receivedFiles = <ReceivedFileInfo>[
        ...receivedFiles,
        ReceivedFileInfo(
          name: _currentFileName!,
          path: finalPath,
          size: _currentFileReceived,
          receivedAt: DateTime.now(),
        ),
      ];
      receiveProgress = null;
      _emitSnackbar('File Received: $_currentFileName');
    }

    _currentType = null;
    _pendingHeader = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Helpers.
  // ---------------------------------------------------------------------

  /// Finds a usable IPv4 LAN address for this device (e.g. 192.168.1.23).
  Future<String> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {
      // Fall through to the placeholder below.
    }
    return '0.0.0.0';
  }

  /// On very old Android (API 28 and below, i.e. pre-scoped-storage) a
  /// classic storage permission is still required to write into a public
  /// folder like Downloads. On API 29+ this is a no-op: MediaStore handles
  /// the write and no permission dialog is needed at all, so there is
  /// nothing to be denied. Safe to call unconditionally before publishing
  /// a file.
  Future<void> _ensureLegacyStoragePermissionIfNeeded() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        await Permission.storage.request();
      }
    } catch (_) {
      // Not fatal - _publishReceivedFile() falls back gracefully below if
      // the eventual write actually fails.
    }
  }

  /// Moves a fully-received file from its private temp location to its
  /// real, user-visible destination and returns the path that should be
  /// shown/stored for it.
  ///
  /// - On Android this publishes into the public **Downloads/LANShare**
  ///   folder via `MediaStore` (see `MediaStoreHelper` / the native
  ///   `MainActivity.kt` snippet), so files show up in the Files app, the
  ///   Downloads app, and (for supported media types) the Gallery - not
  ///   just inside this app. This requires no risky "All files access"
  ///   permission on Android 10+.
  /// - On Windows/macOS/Linux it copies the file straight into the user's
  ///   real **Downloads/LANShare** folder via `path_provider`'s
  ///   `getDownloadsDirectory()`, so it shows up in File Explorer/Finder
  ///   exactly where a browser download would land - no extra permission
  ///   dialogs needed on desktop.
  /// - On iOS (no public Downloads concept reachable this way) it falls
  ///   back to the app's own documents directory.
  /// - If publishing fails for any reason (e.g. permission genuinely
  ///   denied on very old Android, or the Downloads folder can't be
  ///   resolved), the file is kept at its temp path instead of being
  ///   lost, and a SnackBar explains what happened.
  Future<String> _publishReceivedFile({
    required String tempPath,
    required String fileName,
  }) async {
    if (Platform.isAndroid) {
      await _ensureLegacyStoragePermissionIfNeeded();
      try {
        return await MediaStoreHelper.saveToDownloads(
          sourcePath: tempPath,
          displayName: fileName,
        );
      } catch (e) {
        _emitSnackbar(
          'Could not save to Downloads - kept in app storage instead',
        );
        return tempPath;
      }
    }

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          final dir = Directory('${downloadsDir.path}/LANShare');
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          final finalPath = await _uniqueFilePath(dir, fileName);
          await File(tempPath).copy(finalPath);
          await File(tempPath).delete();
          return finalPath;
        }
      } catch (e) {
        _emitSnackbar(
          'Could not save to Downloads - kept in app storage instead',
        );
        return tempPath;
      }
    }

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${docsDir.path}/ReceivedFiles');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final finalPath = await _uniqueFilePath(dir, fileName);
      await File(tempPath).copy(finalPath);
      await File(tempPath).delete();
      return finalPath;
    } catch (e) {
      _emitSnackbar('Could not move file - kept in temporary storage');
      return tempPath;
    }
  }

  /// Returns a path inside [dir] for [fileName] that does not already
  /// exist, appending "(1)", "(2)", ... before the extension if needed so
  /// repeated transfers of the same filename never overwrite each other.
  Future<String> _uniqueFilePath(Directory dir, String fileName) async {
    String base = fileName;
    String ext = '';
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex > 0) {
      base = fileName.substring(0, dotIndex);
      ext = fileName.substring(dotIndex);
    }

    var candidate = '${dir.path}/$fileName';
    var counter = 1;
    while (await File(candidate).exists()) {
      candidate = '${dir.path}/$base($counter)$ext';
      counter++;
    }
    return candidate;
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  void _emitSnackbar(String message) {
    if (!_snackbarController.isClosed) {
      _snackbarController.add(message);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _socket?.close();
    _serverSocket?.close();
    _fileSink?.close();
    _snackbarController.close();
    super.dispose();
  }
}
