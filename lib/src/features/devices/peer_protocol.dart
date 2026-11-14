import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const peerProtocolVersion = 1;
const peerDefaultPort = 47831;
const peerMaximumFrameBytes = 1024 * 1024;
const peerMaximumHandshakeBytes = 16 * 1024;

class PeerProtocolException implements Exception {
  const PeerProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PeerFrameConnection {
  PeerFrameConnection(this.socket) : _chunks = StreamIterator<Uint8List>(socket);

  final Socket socket;
  final StreamIterator<Uint8List> _chunks;
  final List<int> _pending = [];
  bool _closed = false;

  Future<Map<String, Object?>> readFrame({
    int maximumBytes = peerMaximumFrameBytes,
  }) async {
    final header = await _readExact(4);
    final length = ByteData.sublistView(Uint8List.fromList(header))
        .getUint32(0, Endian.big);
    if (length == 0 || length > maximumBytes) {
      throw const PeerProtocolException('حجم إطار الشبكة غير مقبول.');
    }
    final payload = await _readExact(length);
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map) {
      throw const PeerProtocolException('رسالة الشبكة ليست كائن JSON.');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<void> writeFrame(Map<String, Object?> frame, {
    int maximumBytes = peerMaximumFrameBytes,
  }) async {
    if (_closed) throw const PeerProtocolException('قناة الجهاز مغلقة.');
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(frame)));
    if (payload.isEmpty || payload.length > maximumBytes) {
      throw const PeerProtocolException('تجاوزت الرسالة حجم النقل المسموح.');
    }
    final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
    socket.add([...header.buffer.asUint8List(), ...payload]);
    await socket.flush();
  }

  Future<List<int>> _readExact(int length) async {
    while (_pending.length < length) {
      if (!await _chunks.moveNext()) {
        throw const PeerProtocolException('انقطع اتصال الجهاز.');
      }
      _pending.addAll(_chunks.current);
    }
    final result = _pending.sublist(0, length);
    _pending.removeRange(0, length);
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _chunks.cancel();
    socket.destroy();
  }
}

class PeerSecureChannel {
  PeerSecureChannel({
    required this.connection,
    required this.secretKey,
    required this.localDeviceId,
    required this.remoteDeviceId,
  });

  final PeerFrameConnection connection;
  final SecretKey secretKey;
  final String localDeviceId;
  final String remoteDeviceId;
  final AesGcm _cipher = AesGcm.with256bits();
  int _outgoingSequence = 0;
  int _incomingSequence = 0;
  Future<void> _sendQueue = Future<void>.value();

  /// Serializes concurrent writers so every encrypted frame receives a
  /// unique monotonically increasing sequence number.
  Future<void> send(Map<String, Object?> message) {
    final completed = Completer<void>();
    _sendQueue = _sendQueue.then((_) async {
      try {
        await _sendNow(message);
        completed.complete();
      } on Object catch (error, stackTrace) {
        completed.completeError(error, stackTrace);
      }
    });
    return completed.future;
  }

  Future<void> _sendNow(Map<String, Object?> message) async {
    final sequence = _outgoingSequence;
    final associatedData = utf8.encode(
      'NEXUS-PEER-$peerProtocolVersion|$localDeviceId|$remoteDeviceId|$sequence',
    );
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(message)),
      secretKey: secretKey,
      aad: associatedData,
    );
    await connection.writeFrame({
      'type': 'secure',
      'sequence': sequence,
      'nonce': base64UrlEncode(box.nonce),
      'ciphertext': base64UrlEncode(box.cipherText),
      'mac': base64UrlEncode(box.mac.bytes),
    });
    _outgoingSequence++;
  }

  Future<Map<String, Object?>> receive() async {
    final frame = await connection.readFrame();
    if (frame['type'] != 'secure' || frame['sequence'] != _incomingSequence) {
      throw const PeerProtocolException(
        'تسلسل رسائل الجهاز غير صحيح؛ تم رفض الإطار لاحتمال إعادة تشغيله.',
      );
    }
    final nonce = _decodeBytes(frame['nonce'], 'nonce');
    final cipherText = _decodeBytes(frame['ciphertext'], 'ciphertext');
    final mac = _decodeBytes(frame['mac'], 'mac');
    final associatedData = utf8.encode(
      'NEXUS-PEER-$peerProtocolVersion|$remoteDeviceId|$localDeviceId|$_incomingSequence',
    );
    final plainText = await _cipher.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: secretKey,
      aad: associatedData,
    );
    final decoded = jsonDecode(utf8.decode(plainText));
    if (decoded is! Map) {
      throw const PeerProtocolException('محتوى الرسالة المشفر غير صالح.');
    }
    _incomingSequence++;
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  List<int> _decodeBytes(Object? value, String field) {
    if (value is! String || value.isEmpty || value.length > 2 * peerMaximumFrameBytes) {
      throw PeerProtocolException('حقل $field غير صالح.');
    }
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      throw PeerProtocolException('ترميز $field غير صالح.');
    }
  }
}

Future<List<int>> peerHmac(List<int> secret, String message) async {
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode(message),
    secretKey: SecretKey(secret),
  );
  return mac.bytes;
}

Future<SecretKey> derivePeerSessionKey({
  required KeyPair localKeyPair,
  required String remotePublicKey,
  required List<int> pairingSecret,
  required String transcript,
  required String clientId,
  required String serverId,
}) async {
  final remote = SimplePublicKey(
    base64Url.decode(base64Url.normalize(remotePublicKey)),
    type: KeyPairType.x25519,
  );
  final shared = await X25519().sharedSecretKey(
    keyPair: localKeyPair,
    remotePublicKey: remote,
  );
  final sharedBytes = await shared.extractBytes();
  final combinedSecret = SecretKey([...sharedBytes, ...pairingSecret]);
  final salt = await Sha256().hash(utf8.encode(transcript));
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: combinedSecret,
    nonce: salt.bytes,
    info: utf8.encode('NEXUS-PEER-$peerProtocolVersion|$clientId|$serverId'),
  );
}

String peerTranscript({
  required String clientId,
  required String clientName,
  required String clientPlatform,
  required String clientPublicKey,
  required String clientNonce,
  required String serverId,
  required String serverName,
  required String serverPlatform,
  required String serverPublicKey,
  required String serverNonce,
}) => jsonEncode([
      peerProtocolVersion,
      clientId,
      clientName,
      clientPlatform,
      clientPublicKey,
      clientNonce,
      serverId,
      serverName,
      serverPlatform,
      serverPublicKey,
      serverNonce,
    ]);

Future<String> peerFingerprint(String transcript) async {
  final digest = await Sha256().hash(utf8.encode(transcript));
  final hex = digest.bytes
      .take(10)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return hex.toUpperCase().replaceAllMapped(
    RegExp(r'.{4}'),
    (match) => '${match.group(0)} ',
  ).trim();
}

bool constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool isPrivatePeerAddress(String address) {
  // Parse strict dotted-decimal IPv4 directly. InternetAddress.tryParse may
  // normalize address forms differently across host platforms, while pairing
  // payloads and LAN advertisements must accept only canonical IPv4 literals.
  final parts = address.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    if (part.isEmpty ||
        !RegExp(r'^\d{1,3}$').hasMatch(part) ||
        (part.length > 1 && part.startsWith('0'))) {
      return false;
    }
    final value = int.tryParse(part);
    if (value == null || value > 255) return false;
    octets.add(value);
  }
  final a = octets[0];
  final b = octets[1];
  if (a == 0 || a == 127 || a >= 224) return false;
  // RFC 1918 private networks and IPv4 link-local addresses (169.254/16)
  // are valid destinations for direct local peer connections.
  if (a == 10 || (a == 169 && b == 254)) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  return false;
}
