/// Data models shared across the app.
///
/// These are plain Dart classes with no external dependencies, used to
/// represent the two kinds of messages this app exchanges (clipboard text
/// and files) and to keep track of files that have been received.
library;

/// The two message kinds our simple wire protocol supports.
enum MessageType { clipboard, file }

/// Helpers to convert [MessageType] to/from the string used in the JSON
/// header ("clipboard" / "file").
extension MessageTypeX on MessageType {
  String get wireName => this == MessageType.clipboard ? 'clipboard' : 'file';

  static MessageType fromWireName(String name) {
    switch (name) {
      case 'clipboard':
        return MessageType.clipboard;
      case 'file':
        return MessageType.file;
      default:
        throw FormatException('Unknown message type: $name');
    }
  }
}

/// Metadata describing an in-flight file transfer, parsed from the JSON
/// header that precedes the raw file bytes on the wire.
class FileHeader {
  final String name;
  final int size;

  const FileHeader({required this.name, required this.size});

  Map<String, dynamic> toJson() => {
        'type': MessageType.file.wireName,
        'name': name,
        'size': size,
      };

  factory FileHeader.fromJson(Map<String, dynamic> json) {
    return FileHeader(
      name: json['name'] as String,
      size: json['size'] as int,
    );
  }
}

/// Record of a file that has been fully received and saved to disk.
/// Used to populate the "Received Files" list on the Transfer screen.
class ReceivedFileInfo {
  final String name;
  final String path;
  final int size;
  final DateTime receivedAt;

  ReceivedFileInfo({
    required this.name,
    required this.path,
    required this.size,
    required this.receivedAt,
  });
}
