import 'dart:convert';

class PairedDeviceRecord {
  const PairedDeviceRecord({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.lastAddress,
    required this.lastPort,
    required this.fingerprint,
    required this.capabilities,
    required this.trustStatus,
    required this.pairedAtUnixMs,
    required this.lastSeenUnixMs,
    required this.createdAtUnixMs,
  });

  final String id;
  final String displayName;
  final String platform;
  final String lastAddress;
  final int lastPort;
  final String fingerprint;
  final Map<String, Object?> capabilities;
  final String trustStatus;
  final int pairedAtUnixMs;
  final int lastSeenUnixMs;
  final int createdAtUnixMs;

  bool get isBlocked => trustStatus == 'blocked';

  factory PairedDeviceRecord.fromMap(Map<String, Object?> map) {
    final decoded = jsonDecode(map['capabilities_json']! as String);
    return PairedDeviceRecord(
      id: map['id']! as String,
      displayName: map['display_name']! as String,
      platform: map['platform']! as String,
      lastAddress: map['last_address']! as String,
      lastPort: map['last_port']! as int,
      fingerprint: map['fingerprint']! as String,
      capabilities: decoded is Map
          ? decoded.map((key, value) => MapEntry(key.toString(), value))
          : const {},
      trustStatus: map['trust_status']! as String,
      pairedAtUnixMs: map['paired_at_unix_ms']! as int,
      lastSeenUnixMs: map['last_seen_unix_ms']! as int,
      createdAtUnixMs: map['created_at_unix_ms']! as int,
    );
  }
}
