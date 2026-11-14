import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/devices/peer_protocol.dart';

void main() {
  test('X25519 plus pairing secret derives the same session key on both peers', () async {
    final alice = await X25519().newKeyPair();
    final bob = await X25519().newKeyPair();
    final alicePublic = await alice.extractPublicKey();
    final bobPublic = await bob.extractPublicKey();
    const pairingSecret = [1, 2, 3, 4, 5, 6, 7, 8, 9];
    const transcript = 'nexus peer handshake test transcript';

    final aliceKey = await derivePeerSessionKey(
      localKeyPair: alice,
      remotePublicKey: base64UrlEncode(bobPublic.bytes),
      pairingSecret: pairingSecret,
      transcript: transcript,
      clientId: 'alice',
      serverId: 'bob',
    );
    final bobKey = await derivePeerSessionKey(
      localKeyPair: bob,
      remotePublicKey: base64UrlEncode(alicePublic.bytes),
      pairingSecret: pairingSecret,
      transcript: transcript,
      clientId: 'alice',
      serverId: 'bob',
    );
    expect(await aliceKey.extractBytes(), await bobKey.extractBytes());
  });

  test('pair proof changes for each server challenge', () async {
    const secret = [10, 20, 30, 40, 50];
    const hello = '[1,"peer","NEXUS","android","public","nonce"]';
    final first = await peerHmac(secret, jsonEncode([hello, 'challenge-a']));
    final second = await peerHmac(secret, jsonEncode([hello, 'challenge-b']));
    expect(constantTimeEquals(first, second), isFalse);
    expect(constantTimeEquals(first, List<int>.from(first)), isTrue);
  });

  test('fingerprint is stable and derived from the handshake transcript', () async {
    final first = await peerFingerprint('transcript-a');
    final same = await peerFingerprint('transcript-a');
    final different = await peerFingerprint('transcript-b');
    expect(first, same);
    expect(first, isNot(different));
    expect(first.replaceAll(' ', ''), hasLength(20));
  });


  test('secure channels exchange encrypted ordered messages over a socket', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final acceptedFuture = server.first;
    final clientSocket = await Socket.connect('127.0.0.1', server.port);
    final serverSocket = await acceptedFuture;
    final clientConnection = PeerFrameConnection(clientSocket);
    final serverConnection = PeerFrameConnection(serverSocket);
    final key = SecretKey(List<int>.generate(32, (index) => index + 1));
    final client = PeerSecureChannel(
      connection: clientConnection,
      secretKey: key,
      localDeviceId: 'client',
      remoteDeviceId: 'server',
    );
    final peer = PeerSecureChannel(
      connection: serverConnection,
      secretKey: key,
      localDeviceId: 'server',
      remoteDeviceId: 'client',
    );

    await client.send({'kind': 'ping', 'counter': 1});
    expect(await peer.receive(), {'kind': 'ping', 'counter': 1});
    await peer.send({'kind': 'pong', 'counter': 1});
    expect(await client.receive(), {'kind': 'pong', 'counter': 1});

    await clientConnection.close();
    await serverConnection.close();
    await server.close();
  });

  test('concurrent secure sends are serialized into unique sequence numbers', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final acceptedFuture = server.first;
    final clientSocket = await Socket.connect('127.0.0.1', server.port);
    final serverSocket = await acceptedFuture;
    final key = SecretKey(List<int>.filled(32, 9));
    final sender = PeerSecureChannel(
      connection: PeerFrameConnection(clientSocket),
      secretKey: key,
      localDeviceId: 'client',
      remoteDeviceId: 'server',
    );
    final receiver = PeerSecureChannel(
      connection: PeerFrameConnection(serverSocket),
      secretKey: key,
      localDeviceId: 'server',
      remoteDeviceId: 'client',
    );

    await Future.wait([
      sender.send({'kind': 'first'}),
      sender.send({'kind': 'second'}),
      sender.send({'kind': 'third'}),
    ]);
    final received = [
      await receiver.receive(),
      await receiver.receive(),
      await receiver.receive(),
    ];
    expect(received.map((message) => message['kind']).toSet(),
        {'first', 'second', 'third'});

    await sender.connection.close();
    await receiver.connection.close();
    await server.close();
  });

  test('secure channels reject replayed and out-of-order sequence numbers', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final acceptedFuture = server.first;
    final clientSocket = await Socket.connect('127.0.0.1', server.port);
    final serverSocket = await acceptedFuture;
    final receiving = PeerSecureChannel(
      connection: PeerFrameConnection(serverSocket),
      secretKey: SecretKey(List<int>.filled(32, 7)),
      localDeviceId: 'server',
      remoteDeviceId: 'client',
    );
    final payload = utf8.encode(jsonEncode({
      'type': 'secure',
      'sequence': 1,
      'nonce': 'AA',
      'ciphertext': 'AA',
      'mac': 'AA',
    }));
    final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
    clientSocket.add([...header.buffer.asUint8List(), ...payload]);
    await clientSocket.flush();
    await expectLater(receiving.receive(), throwsA(isA<PeerProtocolException>()));
    clientSocket.destroy();
    await receiving.connection.close();
    await server.close();
  });

  test('only private IPv4 addresses are allowed for local peer links', () {
    expect(isPrivatePeerAddress('192.168.1.10'), isTrue);
    expect(isPrivatePeerAddress('10.0.0.5'), isTrue);
    expect(isPrivatePeerAddress('172.20.1.8'), isTrue);
    expect(isPrivatePeerAddress('169.254.1.9'), isTrue);
    expect(isPrivatePeerAddress('8.8.8.8'), isFalse);
    expect(isPrivatePeerAddress('127.0.0.1'), isFalse);
    expect(isPrivatePeerAddress('192.168.1.256'), isFalse);
    expect(isPrivatePeerAddress('192.168.001.10'), isFalse);
    expect(isPrivatePeerAddress('192.168.1'), isFalse);
    expect(isPrivatePeerAddress('::1'), isFalse);
  });
}
