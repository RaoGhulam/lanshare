/// Everything a joining device needs to reach a host, as encoded in the
/// host's QR code.
///
/// Two QR formats are understood:
/// - A plain IPv4 address (`192.168.1.10`) - used in normal Wi-Fi mode, and
///   compatible with older versions of the app.
/// - `lanshare://join?ip=..&port=..&ssid=..&password=..` - used in offline
///   hotspot mode, so a scanning phone can join the host's hotspot first.
class JoinInfo {
  final String ip;
  final int port;

  /// Hotspot to join before connecting, or null in normal Wi-Fi mode.
  final String? ssid;
  final String? password;

  const JoinInfo({
    required this.ip,
    required this.port,
    this.ssid,
    this.password,
  });

  bool get viaHotspot => ssid != null && ssid!.isNotEmpty;

  String toQrData() {
    return Uri(
      scheme: 'lanshare',
      host: 'join',
      queryParameters: {
        'ip': ip,
        'port': '$port',
        if (ssid != null) 'ssid': ssid!,
        if (password != null) 'password': password!,
      },
    ).toString();
  }

  /// Parses a scanned QR value; returns null if it isn't a LANShare code.
  static JoinInfo? parse(String raw, {required int defaultPort}) {
    final value = raw.trim();
    if (isValidIpv4(value)) {
      return JoinInfo(ip: value, port: defaultPort);
    }

    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'lanshare') return null;
    final params = uri.queryParameters;
    final ip = params['ip'];
    if (ip == null || !isValidIpv4(ip)) return null;
    final port = int.tryParse(params['port'] ?? '') ?? defaultPort;

    return JoinInfo(
      ip: ip,
      port: port,
      ssid: params['ssid'],
      password: params['password'],
    );
  }

  static bool isValidIpv4(String value) {
    final parts = value.trim().split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }
}
