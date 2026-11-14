import 'dart:convert';
import 'dart:io';

import 'peer_protocol.dart';

const peerDiscoveryVersion = 1;
const peerDiscoveryPort = 47832;
const peerDiscoveryPacketLimit = 1024;
const pairingQrPrefix = 'NEXUS-PAIR/2\n';

/// A short-lived capability used only by the explicit QR/manual pairing flow.
/// The secret is never included in LAN discovery advertisements.
class PairingInvitePayload {
  const PairingInvitePayload({
    required this.deviceId,
    required this.displayName,
    required this.addresses,
    required this.port,
    required this.pairingCode,
    required this.expiresAt,
  });

  final String deviceId;
  final String displayName;
  final List<String> addresses;
  final int port;
  final String pairingCode;
  final DateTime expiresAt;

  String encode() => '$pairingQrPrefix${jsonEncode({
        'version': 2,
        'device_id': deviceId,
        'display_name': displayName,
        'addresses': addresses,
        'port': port,
        'pairing_code': pairingCode,
        'expires_at_unix_ms': expiresAt.millisecondsSinceEpoch,
      })}';

  factory PairingInvitePayload.decode(
    String raw, {
    DateTime? now,
  }) {
    if (raw.length > 4096 || !raw.startsWith(pairingQrPrefix)) {
      throw const FormatException('هذا الرمز ليس دعوة NEXUS صالحة.');
    }
    final decoded = jsonDecode(raw.substring(pairingQrPrefix.length));
    if (decoded is! Map) {
      throw const FormatException('بنية دعوة الاقتران غير صالحة.');
    }
    final data = decoded.map((key, value) => MapEntry(key.toString(), value));
    if (data['version'] != 2) {
      throw const FormatException('إصدار دعوة الاقتران غير مدعوم.');
    }

    final deviceId = data['device_id'];
    final displayName = data['display_name'];
    final rawAddresses = data['addresses'];
    final port = data['port'];
    final pairingCode = data['pairing_code'];
    final expiresAt = data['expires_at_unix_ms'];

    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceId.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(deviceId)) {
      throw const FormatException('معرّف الجهاز في الدعوة غير صالح.');
    }
    if (displayName is! String || displayName.length > 64) {
      throw const FormatException('اسم الجهاز في الدعوة غير صالح.');
    }
    final safeDisplayName = displayName
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '')
        .trim();
    if (safeDisplayName.isEmpty) {
      throw const FormatException('اسم الجهاز في الدعوة غير صالح.');
    }
    if (rawAddresses is! List ||
        rawAddresses.isEmpty ||
        rawAddresses.length > 8) {
      throw const FormatException('لا تحتوي الدعوة على عناوين اتصال صالحة.');
    }
    final addresses = <String>[];
    for (final value in rawAddresses) {
      if (value is! String ||
          !isPrivatePeerAddress(value) ||
          addresses.contains(value)) {
        throw const FormatException('تحتوي الدعوة على عنوان غير مسموح به.');
      }
      addresses.add(value);
    }
    if (port is! int || port < 1 || port > 65535) {
      throw const FormatException('منفذ الاقتران في الدعوة غير صالح.');
    }
    if (pairingCode is! String ||
        pairingCode.isEmpty ||
        pairingCode.length > 128) {
      throw const FormatException('رمز الاقتران في الدعوة غير صالح.');
    }
    try {
      final secret = base64Url.decode(base64Url.normalize(pairingCode));
      if (secret.length != 32) throw const FormatException();
    } on FormatException {
      throw const FormatException('سر الاقتران في الدعوة غير صالح.');
    }
    if (expiresAt is! int) {
      throw const FormatException('تاريخ انتهاء الدعوة غير صالح.');
    }
    final currentTime = now ?? DateTime.now();
    final nowMilliseconds = currentTime.millisecondsSinceEpoch;
    final latestAllowedExpiry =
        nowMilliseconds + const Duration(minutes: 15).inMilliseconds;
    if (expiresAt <= nowMilliseconds || expiresAt > latestAllowedExpiry) {
      throw const FormatException('انتهت صلاحية الدعوة أو أن تاريخها غير موثوق.');
    }
    final expiry = DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true);

    return PairingInvitePayload(
      deviceId: deviceId,
      displayName: safeDisplayName,
      addresses: List.unmodifiable(addresses),
      port: port,
      pairingCode: pairingCode,
      expiresAt: expiry,
    );
  }
}

class DiscoveredPeer {
  const DiscoveredPeer({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.address,
    required this.port,
    required this.lastSeenAt,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final String address;
  final int port;
  final DateTime lastSeenAt;

  bool isFresh({DateTime? now}) =>
      (now ?? DateTime.now()).difference(lastSeenAt) <= const Duration(seconds: 15);
}

class PeerDiscoveryProtocol {
  const PeerDiscoveryProtocol._();

  static Map<String, Object?> createProbe(String nonce) => {
        'type': 'nexus_probe',
        'version': peerDiscoveryVersion,
        'nonce': nonce,
      };

  static Map<String, Object?> createAdvertisement({
    required String nonce,
    required String deviceId,
    required String displayName,
    required String platform,
    required int port,
  }) => {
        'type': 'nexus_peer',
        'version': peerDiscoveryVersion,
        'nonce': nonce,
        'device_id': deviceId,
        'display_name': displayName,
        'platform': platform,
        'port': port,
      };

  static DiscoveredPeer? parseAdvertisement({
    required Map<String, Object?> message,
    required InternetAddress sourceAddress,
    required Set<String> validNonces,
    required String localDeviceId,
    DateTime? now,
  }) {
    if (message['type'] != 'nexus_peer' ||
        message['version'] != peerDiscoveryVersion) {
      return null;
    }
    final nonce = message['nonce'];
    final deviceId = message['device_id'];
    final displayName = message['display_name'];
    final platform = message['platform'];
    final port = message['port'];
    final address = sourceAddress.address;
    if (nonce is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{16}$').hasMatch(nonce) ||
        !validNonces.contains(nonce)) {
      return null;
    }
    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceId.length > 128 ||
        deviceId == localDeviceId ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(deviceId)) {
      return null;
    }
    if (displayName is! String || displayName.length > 64 ||
        platform is! String || !RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(platform)) {
      return null;
    }
    final safeDisplayName = displayName
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '')
        .trim();
    if (safeDisplayName.isEmpty) return null;
    if (port is! int || port < 1 || port > 65535) return null;
    if (!isPrivatePeerAddress(address)) return null;
    return DiscoveredPeer(
      deviceId: deviceId,
      displayName: safeDisplayName,
      platform: platform,
      address: address,
      port: port,
      lastSeenAt: now ?? DateTime.now(),
    );
  }
}
