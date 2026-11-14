import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/devices/peer_discovery.dart';

void main() {
  final fixedNow = DateTime.utc(2026, 11, 14, 8);
  final validSecret = base64UrlEncode(List<int>.filled(32, 7)).replaceAll('=', '');

  PairingInvitePayload invite({
    List<String> addresses = const ['192.168.1.20'],
    String pairingCode = '',
    DateTime? expiresAt,
  }) => PairingInvitePayload(
        deviceId: 'peer_device_1',
        displayName: 'NEXUS Phone',
        addresses: addresses,
        port: 47831,
        pairingCode: pairingCode.isEmpty ? validSecret : pairingCode,
        expiresAt: expiresAt ?? fixedNow.add(const Duration(minutes: 5)),
      );

  group('pairing QR payload', () {
    test('round-trips a valid short-lived invitation', () {
      final original = invite();
      final decoded = PairingInvitePayload.decode(
        original.encode(),
        now: fixedNow,
      );
      expect(decoded.deviceId, original.deviceId);
      expect(decoded.displayName, original.displayName);
      expect(decoded.addresses, original.addresses);
      expect(decoded.port, original.port);
      expect(decoded.pairingCode, original.pairingCode);
      expect(decoded.expiresAt, original.expiresAt);
    });

    test('rejects an expired invitation', () {
      final raw = invite(
        expiresAt: fixedNow.subtract(const Duration(seconds: 1)),
      ).encode();
      expect(
        () => PairingInvitePayload.decode(raw, now: fixedNow),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects an out-of-range expiry before constructing DateTime', () {
      final payload = jsonDecode(invite().encode().substring(pairingQrPrefix.length)) as Map<String, dynamic>;
      payload['expires_at_unix_ms'] = 9223372036854775807;
      final raw = '$pairingQrPrefix${jsonEncode(payload)}';
      expect(
        () => PairingInvitePayload.decode(raw, now: fixedNow),
        throwsA(isA<FormatException>()),
      );
    });

    test('sanitizes control characters from invited device names', () {
      final payload = jsonDecode(invite().encode().substring(pairingQrPrefix.length)) as Map<String, dynamic>;
      payload['display_name'] = 'NEXUS\nPhone';
      final decoded = PairingInvitePayload.decode(
        '$pairingQrPrefix${jsonEncode(payload)}',
        now: fixedNow,
      );
      expect(decoded.displayName, 'NEXUSPhone');
    });

    test('rejects public and malformed IPv4 destinations', () {
      for (final address in ['8.8.8.8', '192.168.1.999', '127.0.0.1']) {
        final raw = invite(addresses: [address]).encode();
        expect(
          () => PairingInvitePayload.decode(raw, now: fixedNow),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rejects a pairing secret that is not exactly 32 bytes', () {
      final raw = invite(pairingCode: base64UrlEncode([1, 2, 3])).encode();
      expect(
        () => PairingInvitePayload.decode(raw, now: fixedNow),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unrelated QR formats', () {
      expect(
        () => PairingInvitePayload.decode('https://example.com'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('LAN discovery advertisements', () {
    Map<String, Object?> advertisement({
      String nonce = 'freshnonce123456',
      String deviceId = 'peer_device_2',
      int port = 47831,
    }) => PeerDiscoveryProtocol.createAdvertisement(
          nonce: nonce,
          deviceId: deviceId,
          displayName: 'Nearby NEXUS',
          platform: 'android',
          port: port,
        );

    test('accepts a private IPv4 advertisement with a current nonce', () {
      final peer = PeerDiscoveryProtocol.parseAdvertisement(
        message: advertisement(),
        sourceAddress: InternetAddress('192.168.1.30'),
        validNonces: const {'freshnonce123456'},
        localDeviceId: 'local_device',
        now: fixedNow,
      );
      expect(peer, isNotNull);
      expect(peer!.address, '192.168.1.30');
      expect(peer.deviceId, 'peer_device_2');
    });

    test('rejects an incorrectly shaped nonce even if it is allow-listed', () {
      expect(
        PeerDiscoveryProtocol.parseAdvertisement(
          message: advertisement(nonce: 'short'),
          sourceAddress: InternetAddress('192.168.1.30'),
          validNonces: const {'short'},
          localDeviceId: 'local_device',
          now: fixedNow,
        ),
        isNull,
      );
    });

    test('rejects an advertisement with a nonce that was not issued', () {
      expect(
        PeerDiscoveryProtocol.parseAdvertisement(
          message: advertisement(),
          sourceAddress: InternetAddress('192.168.1.30'),
          validNonces: const {'different_nonce'},
          localDeviceId: 'local_device',
          now: fixedNow,
        ),
        isNull,
      );
    });

    test('rejects public Internet source addresses', () {
      expect(
        PeerDiscoveryProtocol.parseAdvertisement(
          message: advertisement(),
          sourceAddress: InternetAddress('8.8.8.8'),
          validNonces: const {'freshnonce123456'},
          localDeviceId: 'local_device',
          now: fixedNow,
        ),
        isNull,
      );
    });

    test('rejects discovering the local device itself', () {
      expect(
        PeerDiscoveryProtocol.parseAdvertisement(
          message: advertisement(deviceId: 'local_device'),
          sourceAddress: InternetAddress('192.168.1.30'),
          validNonces: const {'freshnonce123456'},
          localDeviceId: 'local_device',
          now: fixedNow,
        ),
        isNull,
      );
    });

    test('rejects invalid ports and oversized identity fields', () {
      expect(
        PeerDiscoveryProtocol.parseAdvertisement(
          message: advertisement(port: 70000),
          sourceAddress: InternetAddress('192.168.1.30'),
          validNonces: const {'freshnonce123456'},
          localDeviceId: 'local_device',
          now: fixedNow,
        ),
        isNull,
      );
      expect(
        PeerDiscoveryProtocol.parseAdvertisement(
          message: {
            ...advertisement(),
            'display_name': List.filled(65, 'x').join(),
          },
          sourceAddress: InternetAddress('192.168.1.30'),
          validNonces: const {'freshnonce123456'},
          localDeviceId: 'local_device',
          now: fixedNow,
        ),
        isNull,
      );
    });
  });
}
