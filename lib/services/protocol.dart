import 'dart:convert';
import 'dart:typed_data';

/// Wire protocol used between the two devices.
///
/// Every packet on the socket looks like this:
///
///   [ 4 bytes: header length, big-endian int32 ]
///   [ N bytes: UTF-8 JSON header               ]
///   [ M bytes: raw payload (clipboard text or file bytes) ]
///
/// There is no base64 encoding anywhere - everything is sent as raw bytes.
/// This file only contains small, stateless helpers for building the
/// header-length prefix and encoding/decoding the JSON header. The actual
/// stream parsing (handling partial reads) lives in [TcpService].
class Protocol {
  Protocol._();

  /// Encodes [headerLength] as a 4-byte big-endian integer, matching the
  /// "[int32 headerLength]" prefix described in the protocol spec.
  static Uint8List encodeHeaderLength(int headerLength) {
    final bytes = ByteData(4);
    bytes.setInt32(0, headerLength, Endian.big);
    return bytes.buffer.asUint8List();
  }

  /// Decodes a 4-byte big-endian integer back into the header length.
  static int decodeHeaderLength(Uint8List bytes) {
    final byteData = ByteData.sublistView(bytes);
    return byteData.getInt32(0, Endian.big);
  }

  /// Encodes a JSON header map into UTF-8 bytes.
  static Uint8List encodeHeader(Map<String, dynamic> header) {
    return Uint8List.fromList(utf8.encode(jsonEncode(header)));
  }

  /// Decodes UTF-8 JSON header bytes back into a map.
  static Map<String, dynamic> decodeHeader(Uint8List bytes) {
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  /// Builds a complete clipboard packet: header-length prefix + JSON header
  /// + the raw UTF-8 text bytes. Since clipboard payloads are normally small,
  /// it is safe to send them as a single packet.
  static Uint8List buildClipboardPacket(String text) {
    final textBytes = Uint8List.fromList(utf8.encode(text));
    final header = {
      'type': 'clipboard',
      'length': textBytes.length,
    };
    final headerBytes = encodeHeader(header);
    final lengthPrefix = encodeHeaderLength(headerBytes.length);

    final packet = BytesBuilder();
    packet.add(lengthPrefix);
    packet.add(headerBytes);
    packet.add(textBytes);
    return packet.toBytes();
  }

  /// Builds just the header portion (length prefix + JSON header) for a file
  /// transfer. The caller is responsible for streaming the raw file bytes
  /// separately afterwards, so large files never need to be fully buffered
  /// in memory as a single packet.
  static Uint8List buildFileHeader(String name, int size) {
    final header = {
      'type': 'file',
      'name': name,
      'size': size,
    };
    final headerBytes = encodeHeader(header);
    final lengthPrefix = encodeHeaderLength(headerBytes.length);

    final packet = BytesBuilder();
    packet.add(lengthPrefix);
    packet.add(headerBytes);
    return packet.toBytes();
  }
}
