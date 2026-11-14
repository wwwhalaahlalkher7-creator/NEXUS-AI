import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import '../resources/resource_settings.dart';
import '../orchestration/agent_task_repository.dart';
import 'device_record.dart';
import 'device_repository.dart';
import 'peer_protocol.dart';
import 'peer_discovery.dart';
import 'peer_task_transfer.dart';

class PairingInvite {
  const PairingInvite({
    required this.addresses,
    required this.port,
    required this.code,
    required this.expiresAt,
    required this.deviceId,
    required this.displayName,
    required this.discoveryAvailable,
  });

  final List<String> addresses;
  final int port;
  final String code;
  final DateTime expiresAt;
  final String deviceId;
  final String displayName;
  final bool discoveryAvailable;

  String get qrPayload => PairingInvitePayload(
        deviceId: deviceId,
        displayName: displayName,
        addresses: addresses,
        port: port,
        pairingCode: code,
        expiresAt: expiresAt,
      ).encode();
}

class PeerPairingRequest {
  const PeerPairingRequest({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.fingerprint,
    required this.address,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final String fingerprint;
  final String address;
}

enum DeviceNetworkEventType {
  listening,
  stopped,
  peerConnected,
  peerDisconnected,
  capabilitiesUpdated,
  discoveryStarted,
  discoveryStopped,
  discoveryUpdated,
  networkChanged,
  inviteExpired,
  inviteConsumed,
  message,
  taskProposalReceived,
  taskProposalSent,
  taskProposalDeclined,
  taskProposalRejected,
  error,
}

class DeviceNetworkEvent {
  const DeviceNetworkEvent({
    required this.type,
    required this.message,
    this.deviceId,
  });

  final DeviceNetworkEventType type;
  final String message;
  final String? deviceId;
}

class DeviceNetworkService {
  DeviceNetworkService({
    LocalDatabase? database,
    FlutterSecureStorage? secureStorage,
    PairedDeviceRepository? repository,
  })  : _database = database ?? LocalDatabase.instance,
        _secureStorage = secureStorage ?? FlutterSecureStorage(),
        repository = repository ?? PairedDeviceRepository(database: database),
        _transferRepository = RemoteTaskTransferRepository(database: database);

  static const int port = peerDefaultPort;
  static const int discoveryPort = peerDiscoveryPort;
  static const Duration _inviteLifetime = Duration(minutes: 10);
  static const Duration _discoveryWindow = Duration(seconds: 30);
  static const Duration _probeInterval = Duration(seconds: 2);
  static const Duration _nonceLifetime = Duration(seconds: 12);
  static const Duration _peerStaleAfter = Duration(seconds: 15);
  // Bounds only concurrent unauthenticated handshakes, not paired devices.
  static const int _maximumPendingHandshakes = 4;
  static const String _secretPrefix = 'nexus.peer.secret.';
  static const String _identityKey = 'local_device_id';
  static const String _nameKey = 'local_device_name';

  final LocalDatabase _database;
  final FlutterSecureStorage _secureStorage;
  final PairedDeviceRepository repository;
  final RemoteTaskTransferRepository _transferRepository;
  final AgentTaskRepository _taskRepository = AgentTaskRepository();
  final DeviceResourceMonitor _resourceMonitor = const DeviceResourceMonitor();
  final StreamController<DeviceNetworkEvent> _events =
      StreamController<DeviceNetworkEvent>.broadcast();
  final Map<String, _PeerSession> _sessions = {};
  final Map<String, Completer<Map<String, Object?>>> _pendingTaskAcks = {};
  final Map<String, String> _pendingTaskAckDevices = {};
  final Set<String> _taskTransfersInFlight = {};
  final Set<String> _pendingIncomingTaskPrompts = {};
  final Set<PeerFrameConnection> _pendingConnections = {};
  final Map<String, DiscoveredPeer> _discoveredPeers = {};
  final Map<String, DateTime> _validDiscoveryNonces = {};
  final Map<String, DateTime> _lastDiscoveryReplyAt = {};
  final Random _random = Random.secure();

  ServerSocket? _server;
  RawDatagramSocket? _discoverySocket;
  Future<void>? _discoverySocketOpening;
  StreamSubscription<RawSocketEvent>? _discoverySubscription;
  Timer? _discoveryProbeTimer;
  Timer? _discoveryStopTimer;
  Timer? _networkWatchTimer;
  Timer? _inviteExpiryTimer;
  String? _networkFingerprint;
  bool _isDiscovering = false;
  StreamSubscription<Socket>? _serverSubscription;
  _InviteState? _activeInvite;
  bool _inviteClaimed = false;
  Future<void>? _initialization;
  Future<void>? _stoppingListener;
  String? _localDeviceId;
  String? _localDeviceName;
  bool _disposed = false;
  int _listenerGeneration = 0;
  int _pendingHandshakes = 0;
  Future<bool> Function(PeerPairingRequest request)? onPairingRequest;
  Future<bool?> Function(PeerTaskProposalRequest request)? onTaskProposalRequest;

  Stream<DeviceNetworkEvent> get events => _events.stream;
  bool get isListening => _server != null;
  bool get isDiscovering => _isDiscovering;
  List<DiscoveredPeer> get discoveredPeers {
    final now = DateTime.now();
    final current = _discoveredPeers.values
        .where((peer) => peer.isFresh(now: now))
        .toList()
      ..sort((left, right) => left.displayName.compareTo(right.displayName));
    return List.unmodifiable(current);
  }
  String? get localDeviceId => _localDeviceId;
  String? get localDeviceName => _localDeviceName;
  Set<String> get connectedDeviceIds => Set.unmodifiable(_sessions.keys);

  Future<void> initialize() async {
    await (_initialization ??= _loadIdentity().then<void>((_) {}));
  }

  Future<String> _loadIdentity() async {
    final db = await _database.database;
    final existingId = await _readSetting(db, _identityKey);
    final id = existingId ?? _randomToken(18);
    if (existingId == null) await _writeSetting(db, _identityKey, id);
    final existingName = await _readSetting(db, _nameKey);
    final name = existingName ?? 'NEXUS-${id.substring(0, 6).toUpperCase()}';
    if (existingName == null) await _writeSetting(db, _nameKey, name);
    _localDeviceId = id;
    _localDeviceName = name;
    return id;
  }

  Future<String?> _readSetting(Database db, String key) async {
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String?;
  }

  Future<void> _writeSetting(Database db, String key, String value) async {
    await db.insert(
      'app_settings',
      {
        'key': key,
        'value': value,
        'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<PairingInvite> createInvite() async {
    await initialize();
    await startListening();
    final secret = _randomBytes(32);
    final expiresAt = DateTime.now().add(_inviteLifetime);
    final inviteState = _InviteState(secret: secret, expiresAt: expiresAt);
    _activeInvite = inviteState;
    _inviteClaimed = false;
    _syncNetworkWatcher();
    _inviteExpiryTimer?.cancel();
    _inviteExpiryTimer = Timer(_inviteLifetime, () {
      if (identical(_activeInvite, inviteState)) {
        _activeInvite = null;
        _inviteClaimed = false;
        _syncNetworkWatcher();
        unawaited(_syncDiscoverySocket());
        if (!_disposed) {
          _events.add(const DeviceNetworkEvent(
            type: DeviceNetworkEventType.inviteExpired,
            message: 'انتهت صلاحية دعوة الاقتران. أنشئ دعوة جديدة عند الحاجة.',
          ));
        }
      }
    });
    final addresses = await _localPrivateAddresses();
    if (addresses.isEmpty) {
      _activeInvite = null;
      await stopListening();
      throw const PeerProtocolException(
        'لم أجد عنوان IPv4 محلياً. اتصل بالشبكة نفسها أو فعّل نقطة اتصال محلية.',
      );
    }
    var discoveryAvailable = true;
    try {
      await _ensureDiscoverySocket();
    } on Object catch (error) {
      discoveryAvailable = false;
      // Discovery is an optional convenience. Keep the authenticated TCP
      // invitation and QR/manual pairing usable when UDP broadcast is blocked.
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.message,
        message: 'تعذر تشغيل الاكتشاف التلقائي؛ لا يزال الاقتران عبر QR أو العنوان والرمز متاحاً: $error',
      ));
    }
    return PairingInvite(
      addresses: addresses,
      port: port,
      code: base64UrlEncode(secret).replaceAll('=', ''),
      expiresAt: expiresAt,
      deviceId: _localDeviceId!,
      displayName: _localDeviceName!,
      discoveryAvailable: discoveryAvailable,
    );
  }

  Future<void> startListening() async {
    await initialize();
    await _stoppingListener;
    if (_server != null) return;
    if (_disposed) throw StateError('DeviceNetworkService disposed');
    final server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
      shared: false,
    );
    _server = server;
    final generation = ++_listenerGeneration;
    _serverSubscription = server.listen(
      (socket) => _dispatchIncoming(socket, generation),
      onError: (Object error, StackTrace stack) {
        _events.add(DeviceNetworkEvent(
          type: DeviceNetworkEventType.error,
          message: 'تعذر استقبال اتصال محلي: $error',
        ));
      },
    );
    _events.add(const DeviceNetworkEvent(
      type: DeviceNetworkEventType.listening,
      message: 'بدأ استقبال الاتصالات المحلية.',
    ));
  }

  Future<void> stopListening() {
    final activeStop = _stoppingListener;
    if (activeStop != null) return activeStop;
    late final Future<void> trackedStop;
    trackedStop = _performStopListening().whenComplete(() {
      if (identical(_stoppingListener, trackedStop)) {
        _stoppingListener = null;
      }
    });
    _stoppingListener = trackedStop;
    return trackedStop;
  }

  Future<void> _performStopListening() async {
    _activeInvite = null;
    _inviteClaimed = false;
    _inviteExpiryTimer?.cancel();
    _inviteExpiryTimer = null;
    _listenerGeneration++;
    final subscription = _serverSubscription;
    _serverSubscription = null;
    final server = _server;
    _server = null;
    await subscription?.cancel();
    await server?.close();
    final pending = _pendingConnections.toList(growable: false);
    for (final connection in pending) {
      await connection.close();
    }
    _events.add(const DeviceNetworkEvent(
      type: DeviceNetworkEventType.stopped,
      message: 'تم إيقاف استقبال الأجهزة الجديدة.',
    ));
    await _syncDiscoverySocket();
    _syncNetworkWatcher();
  }

  Future<void> connect({
    required String address,
    required int port,
    required String pairingCode,
  }) async {
    final secret = _decodePairingCode(pairingCode);
    await _connectWithSecret(address: address, port: port, secret: secret);
  }

  Future<void> connectToPairedDevice(String deviceId) async {
    final record = await repository.get(deviceId);
    if (record == null || record.isBlocked) {
      throw const PeerProtocolException('الجهاز غير موجود أو محظور.');
    }
    final encoded = await _secureStorage.read(key: '$_secretPrefix$deviceId');
    if (encoded == null) {
      throw const PeerProtocolException('مفتاح الجهاز غير موجود؛ أعد الاقتران.');
    }
    final secret = base64Url.decode(base64Url.normalize(encoded));
    await _connectWithSecret(
      address: record.lastAddress,
      port: record.lastPort,
      secret: secret,
      expectedRemoteDeviceId: deviceId,
    );
  }

  Future<void> connectWithInvite(PairingInvitePayload invite) async {
    if (!invite.expiresAt.isAfter(DateTime.now())) {
      throw const PeerProtocolException('انتهت صلاحية دعوة الاقتران.');
    }
    final secret = _decodePairingCode(invite.pairingCode);
    Object? lastError;
    for (final address in invite.addresses) {
      try {
        await _connectWithSecret(
          address: address,
          port: invite.port,
          secret: secret,
          expectedRemoteDeviceId: invite.deviceId,
        );
        return;
      } on Object catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) throw lastError;
    throw const PeerProtocolException('لا يوجد عنوان اتصال صالح في الدعوة.');
  }

  Future<void> connectToDiscoveredPeer(DiscoveredPeer peer) async {
    if (!peer.isFresh()) {
      throw const PeerProtocolException('انتهت صلاحية نتيجة الاكتشاف؛ أعد البحث عن الجهاز.');
    }
    final record = await repository.get(peer.deviceId);
    if (record == null || record.isBlocked) {
      throw const PeerProtocolException(
        'هذا الجهاز غير مقترن مسبقاً. امسح دعوة QR الخاصة به لإجراء اقتران آمن.',
      );
    }
    final encoded = await _secureStorage.read(key: '$_secretPrefix${peer.deviceId}');
    if (encoded == null) {
      throw const PeerProtocolException('مفتاح الجهاز غير موجود؛ أعد الاقتران.');
    }
    final secret = base64Url.decode(base64Url.normalize(encoded));
    await _connectWithSecret(
      address: peer.address,
      port: peer.port,
      secret: secret,
      expectedRemoteDeviceId: peer.deviceId,
    );
  }

  Future<void> _connectWithSecret({
    required String address,
    required int port,
    required List<int> secret,
    String? expectedRemoteDeviceId,
  }) async {
    await initialize();
    if (!isPrivatePeerAddress(address)) {
      throw const PeerProtocolException(
        'يسمح هذا الإصدار بعناوين IPv4 الخاصة بالشبكة المحلية فقط.',
      );
    }
    if (port < 1 || port > 65535) {
      throw const PeerProtocolException('منفذ الاتصال غير صالح.');
    }
    final localId = _localDeviceId!;
    final localName = _localDeviceName!;
    final socket = await Socket.connect(
      address,
      port,
      timeout: const Duration(seconds: 12),
    );
    final connection = PeerFrameConnection(socket);
    try {
      final localKeyPair = await X25519().newKeyPair();
      final localPublic = await localKeyPair.extractPublicKey();
      final localPublicEncoded = base64UrlEncode(localPublic.bytes);
      final localNonce = _randomToken(24);
      final helloCore = jsonEncode([
        peerProtocolVersion,
        localId,
        localName,
        Platform.operatingSystem,
        localPublicEncoded,
        localNonce,
      ]);
      await connection.writeFrame({
        'type': 'hello',
        'protocol': peerProtocolVersion,
        'device_id': localId,
        'display_name': localName,
        'platform': Platform.operatingSystem,
        'public_key': localPublicEncoded,
        'nonce': localNonce,
      }, maximumBytes: peerMaximumHandshakeBytes);

      final challenge = await connection
          .readFrame(maximumBytes: peerMaximumHandshakeBytes)
          .timeout(const Duration(seconds: 12));
      if (challenge['type'] == 'error') {
        throw PeerProtocolException(
          challenge['message'] as String? ?? 'رفض الجهاز الاتصال.',
        );
      }
      if (challenge['type'] != 'hello_challenge') {
        throw const PeerProtocolException('تحدي الاقتران غير متوافق.');
      }
      final serverChallenge = _requiredString(challenge, 'server_nonce');
      final clientProof = await peerHmac(
        secret,
        jsonEncode([helloCore, serverChallenge]),
      );
      await connection.writeFrame({
        'type': 'hello_proof',
        'proof': base64UrlEncode(clientProof),
      }, maximumBytes: peerMaximumHandshakeBytes);

      final ack = await connection
          .readFrame(maximumBytes: peerMaximumHandshakeBytes)
          .timeout(const Duration(seconds: 12));
      if (ack['type'] == 'error') {
        throw PeerProtocolException(
          ack['message'] as String? ?? 'رفض الجهاز الاتصال.',
        );
      }
      if (ack['type'] != 'hello_ack' ||
          ack['protocol'] != peerProtocolVersion) {
        throw const PeerProtocolException('استجابة الاقتران غير متوافقة.');
      }
      final remoteId = _requiredString(ack, 'device_id');
      if (remoteId == localId) {
        throw const PeerProtocolException('لا يمكن إقران الجهاز بنفسه.');
      }
      if (expectedRemoteDeviceId != null && remoteId != expectedRemoteDeviceId) {
        throw const PeerProtocolException(
          'معرّف الجهاز لا يطابق الدعوة أو الجهاز المقترن المتوقع.',
        );
      }
      final remoteName = _requiredString(ack, 'display_name');
      final remotePlatform = _requiredString(ack, 'platform');
      final remotePublic = _requiredString(ack, 'public_key');
      final remoteNonce = _requiredString(ack, 'nonce');
      _validatePeerMaterial(remotePublic, remoteNonce);
      final transcript = peerTranscript(
        clientId: localId,
        clientName: localName,
        clientPlatform: Platform.operatingSystem,
        clientPublicKey: localPublicEncoded,
        clientNonce: localNonce,
        serverId: remoteId,
        serverName: remoteName,
        serverPlatform: remotePlatform,
        serverPublicKey: remotePublic,
        serverNonce: remoteNonce,
      );
      final expectedServerProof = await peerHmac(secret, transcript);
      final receivedServerProof = _decodeBase64(_requiredString(ack, 'proof'));
      if (!constantTimeEquals(expectedServerProof, receivedServerProof)) {
        throw const PeerProtocolException(
          'فشل التحقق من هوية الجهاز المقابل. رمز الاقتران أو المفتاح غير صحيح.',
        );
      }
      final key = await derivePeerSessionKey(
        localKeyPair: localKeyPair,
        remotePublicKey: remotePublic,
        pairingSecret: secret,
        transcript: transcript,
        clientId: localId,
        serverId: remoteId,
      );
      final channel = PeerSecureChannel(
        connection: connection,
        secretKey: key,
        localDeviceId: localId,
        remoteDeviceId: remoteId,
      );
      final pairResult = await channel.receive().timeout(
        const Duration(seconds: 75),
      );
      if (pairResult['kind'] != 'pair_result' || pairResult['accepted'] != true) {
        throw PeerProtocolException(
          pairResult['message'] as String? ?? 'لم يوافق الجهاز على الاقتران.',
        );
      }
      await channel.send({'kind': 'pair_commit'});
      final commitResult = await channel.receive().timeout(
        const Duration(seconds: 30),
      );
      if (commitResult['kind'] != 'pair_commit_result' ||
          commitResult['accepted'] != true) {
        throw PeerProtocolException(
          commitResult['message'] as String? ?? 'لم يكتمل تثبيت الاقتران.',
        );
      }
      final fingerprint = await peerFingerprint(transcript);
      await _secureStorage.write(
        key: '$_secretPrefix$remoteId',
        value: base64UrlEncode(secret),
      );
      final previousRecord = await repository.get(remoteId);
      await repository.upsert(
        id: remoteId,
        displayName: remoteName,
        platform: remotePlatform,
        address: address,
        port: port,
        fingerprint: fingerprint,
        capabilities: previousRecord?.capabilities ?? const {},
      );
      _installSession(
        deviceId: remoteId,
        displayName: remoteName,
        connection: connection,
        channel: channel,
      );
      await _sendCapabilities(remoteId);
    } on Object {
      await connection.close();
      rethrow;
    }
  }

  void _dispatchIncoming(Socket socket, int generation) {
    if (_pendingHandshakes >= _maximumPendingHandshakes) {
      socket.destroy();
      _events.add(const DeviceNetworkEvent(
        type: DeviceNetworkEventType.error,
        message: 'تم رفض اتصال وارد مؤقتاً لأن المصافحة المحلية مشغولة.',
      ));
      return;
    }
    final connection = PeerFrameConnection(socket);
    _pendingHandshakes++;
    _pendingConnections.add(connection);
    unawaited(() async {
      try {
        await _acceptIncoming(connection, socket.remoteAddress.address, generation);
      } on Object catch (error) {
        await connection.close();
        if (!_disposed) {
          _events.add(DeviceNetworkEvent(
            type: DeviceNetworkEventType.error,
            message: 'تعذر إكمال المصافحة الواردة: $error',
          ));
        }
      } finally {
        _pendingConnections.remove(connection);
        _pendingHandshakes--;
      }
    }());
  }

  void _ensureListenerActive(int generation) {
    if (_disposed || _server == null || generation != _listenerGeneration) {
      throw const PeerProtocolException('تم إيقاف استقبال الأجهزة أثناء المصافحة.');
    }
  }

  Future<void> _acceptIncoming(
    PeerFrameConnection connection,
    String remoteAddress,
    int generation,
  ) async {
    var claimedInvite = false;
    _InviteState? claimedInviteState;
    _ensureListenerActive(generation);
    if (!isPrivatePeerAddress(remoteAddress)) {
      await connection.writeFrame({
        'type': 'error',
        'message': 'الاتصال مسموح من الشبكة المحلية فقط.',
      }, maximumBytes: peerMaximumHandshakeBytes);
      await connection.close();
      return;
    }
    try {
      final hello = await connection
          .readFrame(maximumBytes: peerMaximumHandshakeBytes)
          .timeout(const Duration(seconds: 12));
      if (hello['type'] != 'hello' || hello['protocol'] != peerProtocolVersion) {
        throw const PeerProtocolException('طلب اقتران غير متوافق.');
      }
      final remoteId = _requiredString(hello, 'device_id');
      if (remoteId == _localDeviceId) {
        throw const PeerProtocolException('لا يمكن إقران الجهاز بنفسه.');
      }
      final remoteName = _requiredString(hello, 'display_name');
      final remotePlatform = _requiredString(hello, 'platform');
      final remotePublic = _requiredString(hello, 'public_key');
      final remoteNonce = _requiredString(hello, 'nonce');
      _validatePeerMaterial(remotePublic, remoteNonce);
      final existing = await repository.get(remoteId);
      if (existing?.isBlocked == true) {
        throw const PeerProtocolException('هذا الجهاز محظور.');
      }
      final storedSecret = existing == null
          ? null
          : await _secureStorage.read(key: '$_secretPrefix$remoteId');
      final invite = _activeInvite;
      final requiresApproval = storedSecret == null;
      final List<int> secret;
      if (storedSecret != null) {
        secret = base64Url.decode(base64Url.normalize(storedSecret));
      } else if (invite != null &&
          !_inviteClaimed &&
          DateTime.now().isBefore(invite.expiresAt)) {
        secret = invite.secret;
        _inviteClaimed = true;
        claimedInvite = true;
        claimedInviteState = invite;
        _syncNetworkWatcher();
        unawaited(_syncDiscoverySocket());
      } else {
        throw const PeerProtocolException(
          'لا يوجد رمز اقتران فعّال لهذا الجهاز. أنشئ دعوة جديدة.',
        );
      }
      final helloCore = jsonEncode([
        peerProtocolVersion,
        remoteId,
        remoteName,
        remotePlatform,
        remotePublic,
        remoteNonce,
      ]);
      final localId = _localDeviceId!;
      final localName = _localDeviceName!;
      final localNonce = _randomToken(24);
      await connection.writeFrame({
        'type': 'hello_challenge',
        'server_nonce': localNonce,
      }, maximumBytes: peerMaximumHandshakeBytes);
      final proofFrame = await connection
          .readFrame(maximumBytes: peerMaximumHandshakeBytes)
          .timeout(const Duration(seconds: 12));
      if (proofFrame['type'] != 'hello_proof') {
        throw const PeerProtocolException('لم يكتمل إثبات رمز الاقتران.');
      }
      final expectedClientProof = await peerHmac(
        secret,
        jsonEncode([helloCore, localNonce]),
      );
      final receivedClientProof =
          _decodeBase64(_requiredString(proofFrame, 'proof'));
      if (!constantTimeEquals(expectedClientProof, receivedClientProof)) {
        throw const PeerProtocolException('رمز الاقتران غير صحيح.');
      }
      _ensureListenerActive(generation);

      final localKeyPair = await X25519().newKeyPair();
      final localPublic = await localKeyPair.extractPublicKey();
      final localPublicEncoded = base64UrlEncode(localPublic.bytes);
      final transcript = peerTranscript(
        clientId: remoteId,
        clientName: remoteName,
        clientPlatform: remotePlatform,
        clientPublicKey: remotePublic,
        clientNonce: remoteNonce,
        serverId: localId,
        serverName: localName,
        serverPlatform: Platform.operatingSystem,
        serverPublicKey: localPublicEncoded,
        serverNonce: localNonce,
      );
      final serverProof = await peerHmac(secret, transcript);
      await connection.writeFrame({
        'type': 'hello_ack',
        'protocol': peerProtocolVersion,
        'device_id': localId,
        'display_name': localName,
        'platform': Platform.operatingSystem,
        'public_key': localPublicEncoded,
        'nonce': localNonce,
        'proof': base64UrlEncode(serverProof),
      }, maximumBytes: peerMaximumHandshakeBytes);
      final key = await derivePeerSessionKey(
        localKeyPair: localKeyPair,
        remotePublicKey: remotePublic,
        pairingSecret: secret,
        transcript: transcript,
        clientId: remoteId,
        serverId: localId,
      );
      final channel = PeerSecureChannel(
        connection: connection,
        secretKey: key,
        localDeviceId: localId,
        remoteDeviceId: remoteId,
      );
      final fingerprint = await peerFingerprint(transcript);
      if (requiresApproval) {
        final approved = await onPairingRequest?.call(PeerPairingRequest(
              deviceId: remoteId,
              displayName: remoteName,
              platform: remotePlatform,
              fingerprint: fingerprint,
              address: remoteAddress,
            )) ??
            false;
        if (!approved) {
          if (claimedInvite && identical(_activeInvite, claimedInviteState)) {
            _inviteClaimed = false;
            _syncNetworkWatcher();
            unawaited(_syncDiscoverySocket());
          }
          await channel.send({
            'kind': 'pair_result',
            'accepted': false,
            'message': 'رفض المستخدم طلب الاقتران.',
          });
          await connection.close();
          return;
        }
        _ensureListenerActive(generation);
      }
      _ensureListenerActive(generation);
      await channel.send({
        'kind': 'pair_result',
        'accepted': true,
        'message': 'وافق الجهاز المستضيف؛ جارٍ تثبيت الاقتران.',
      });
      final commit = await channel.receive().timeout(
        const Duration(seconds: 30),
      );
      if (commit['kind'] != 'pair_commit') {
        throw const PeerProtocolException('لم يؤكد الجهاز إتمام الاقتران.');
      }
      _ensureListenerActive(generation);
      await _secureStorage.write(
        key: '$_secretPrefix$remoteId',
        value: base64UrlEncode(secret),
      );
      await repository.upsert(
        id: remoteId,
        displayName: remoteName,
        platform: remotePlatform,
        address: remoteAddress,
        port: port,
        fingerprint: fingerprint,
        capabilities: existing?.capabilities ?? const {},
      );
      await channel.send({
        'kind': 'pair_commit_result',
        'accepted': true,
        'message': 'تم تثبيت الاقتران على الجهازين.',
      });
      if (claimedInvite && identical(_activeInvite, claimedInviteState)) {
        _activeInvite = null;
        _inviteClaimed = false;
        _syncNetworkWatcher();
        _inviteExpiryTimer?.cancel();
        _inviteExpiryTimer = null;
        unawaited(_syncDiscoverySocket());
        _events.add(const DeviceNetworkEvent(
          type: DeviceNetworkEventType.inviteConsumed,
          message: 'اكتمل استخدام دعوة الاقتران بنجاح.',
        ));
      }
      _ensureListenerActive(generation);
      _installSession(
        deviceId: remoteId,
        displayName: remoteName,
        connection: connection,
        channel: channel,
      );
      await _sendCapabilities(remoteId);
    } on Object catch (error) {
      if (claimedInvite && identical(_activeInvite, claimedInviteState)) {
        _inviteClaimed = false;
        _syncNetworkWatcher();
        unawaited(_syncDiscoverySocket());
      }
      try {
        await connection.writeFrame({
          'type': 'error',
          'message': 'تعذر إكمال الاقتران. تحقق من الدعوة والموافقة ثم أعد المحاولة.',
        }, maximumBytes: peerMaximumHandshakeBytes);
      } on Object {
        // The peer may already have closed its socket.
      }
      await connection.close();
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.error,
        message: 'فشل اتصال جهاز وارد: $error',
      ));
    }
  }

  Future<String> sendTaskProposal({
    required String deviceId,
    required String sourceTaskId,
  }) async {
    final device = await repository.get(deviceId);
    if (device == null || device.isBlocked) {
      throw const PeerProtocolException('الجهاز غير موجود أو محظور.');
    }
    if (device.capabilities['task_transfer'] != true ||
        device.capabilities['task_transfer_version'] != peerTaskTransferVersion) {
      throw const PeerProtocolException(
        'الجهاز المقابل لا يؤكد دعم نقل مقترحات المهام. أعد الاتصال وانتظر تحديث القدرات.',
      );
    }
    final task = await _taskRepository.get(sourceTaskId);
    if (task == null || task.status.name != 'planned') {
      throw const PeerProtocolException(
        'يمكن إرسال المهام المخططة فقط؛ لا تُنقل المهام الجارية أو المكتملة.',
      );
    }
    final transferId = _randomToken(24);
    final envelope = await PeerTaskProposalEnvelope.create(
      transferId: transferId,
      sourceTaskId: task.id,
      goal: task.goal,
      planJson: task.planJson,
      createdAtUnixMs: task.createdAtUnixMs,
    );
    await _transferRepository.createOutgoing(
      envelope: envelope,
      deviceId: deviceId,
    );
    await _deliverTaskProposal(deviceId, transferId);
    return transferId;
  }

  Future<List<RemoteTaskTransferRecord>> listTaskTransfers() =>
      _transferRepository.list();

  Future<void> reviewTaskTransfer(String transferId, {required bool keep}) =>
      _transferRepository.reviewIncoming(transferId, keep: keep);

  Future<void> retryQueuedTaskTransfers(String deviceId) =>
      _flushQueuedTaskTransfers(deviceId);

  Future<void> _flushQueuedTaskTransfers(String deviceId) async {
    if (_disposed || !_sessions.containsKey(deviceId)) return;
    final device = await repository.get(deviceId);
    if (device == null ||
        device.isBlocked ||
        device.capabilities['task_transfer'] != true ||
        device.capabilities['task_transfer_version'] != peerTaskTransferVersion) {
      return;
    }
    final queued = await _transferRepository.list(direction: 'outgoing');
    for (final transfer in queued.where(
      (item) => item.deviceId == deviceId && item.status == 'queued',
    )) {
      if (!_sessions.containsKey(deviceId)) return;
      try {
        await _deliverTaskProposal(deviceId, transfer.transferId);
      } on Object {
        // Keep the durable outbox queued for the next authenticated reconnect.
        return;
      }
    }
  }

  Future<void> _deliverTaskProposal(String deviceId, String transferId) async {
    final session = _sessions[deviceId];
    if (session == null || !_taskTransfersInFlight.add(transferId)) return;
    final record = await _transferRepository.get(transferId);
    if (record == null || record.direction != 'outgoing') {
      _taskTransfersInFlight.remove(transferId);
      throw const PeerTaskTransferException('مقترح الإرسال غير موجود.');
    }
    final envelope = await PeerTaskProposalEnvelope.create(
      transferId: record.transferId,
      sourceTaskId: record.sourceTaskId,
      goal: record.goal,
      planJson: record.planJson,
      createdAtUnixMs: record.createdAtUnixMs,
    );
    final completer = Completer<Map<String, Object?>>();
    _pendingTaskAcks[transferId] = completer;
    _pendingTaskAckDevices[transferId] = deviceId;
    var permanentlyRejected = false;
    try {
      await session.channel.send(envelope.toMessage());
      final acknowledgement = await completer.future.timeout(
        const Duration(seconds: 75),
      );
      if (acknowledgement['accepted'] != true) {
        final reason = acknowledgement['message'] is String
            ? acknowledgement['message']! as String
            : 'لم يؤكد الجهاز استلام مقترح المهمة.';
        final permanentFailure = acknowledgement['retryable'] != true;
        await _transferRepository.updateOutgoing(
          transferId: transferId,
          status: permanentFailure ? 'rejected' : 'queued',
          error: reason,
        );
        permanentlyRejected = permanentFailure;
        if (permanentFailure) {
          _events.add(DeviceNetworkEvent(
            type: DeviceNetworkEventType.taskProposalRejected,
            deviceId: deviceId,
            message: 'لم يقبل الجهاز المقابل مقترح المهمة: $reason',
          ));
        }
        throw PeerTaskTransferException(reason);
      }
      await _transferRepository.updateOutgoing(
        transferId: transferId,
        status: 'sent',
      );
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.taskProposalSent,
        deviceId: deviceId,
        message: 'تم تسليم مقترح المهمة إلى الجهاز الآخر وحفظ إقرار الاستلام.',
      ));
    } on Object catch (error) {
      if (!permanentlyRejected) {
        await _transferRepository.updateOutgoing(
          transferId: transferId,
          status: 'queued',
          error: error.toString(),
        );
      }
      rethrow;
    } finally {
      _pendingTaskAcks.remove(transferId);
      _pendingTaskAckDevices.remove(transferId);
      _taskTransfersInFlight.remove(transferId);
    }
  }

  Future<void> _handleIncomingTaskProposal(
    _PeerSession session,
    Map<String, Object?> message,
  ) async {
    final rawTransferId = message['transfer_id'];
    var promptClaimed = false;
    try {
      final pairedDevice = await repository.get(session.deviceId);
      if (pairedDevice == null || pairedDevice.isBlocked) {
        throw const PeerTaskTransferException(
          'الجهاز لم يعد مقترناً أو أصبح محظوراً؛ رُفض المقترح.',
        );
      }
      final envelope = await PeerTaskProposalEnvelope.fromMessage(message);
      final existing = await _transferRepository.get(envelope.transferId);
      if (existing != null) {
        if (existing.direction != 'incoming' ||
            existing.deviceId != session.deviceId ||
            existing.payloadSha256 != envelope.payloadSha256) {
          throw const PeerTaskTransferException(
            'تعارض في معرّف النقل؛ رُفضت الرسالة ولم تُستبدل البيانات السابقة.',
          );
        }
        final wasDeclined = existing.status == 'declined' ||
            existing.status == 'rejected';
        if (!wasDeclined && existing.status != 'kept') {
          throw const PeerTaskTransferException(
            'حالة مقترح قديمة أو غير معروفة؛ لم يُعتبر مستلماً.',
          );
        }
        await session.channel.send({
          'kind': 'task_proposal_ack',
          'transfer_id': envelope.transferId,
          'accepted': !wasDeclined,
          'rejected_by_user': wasDeclined,
          'retryable': false,
          'duplicate': true,
          'message': wasDeclined
              ? 'سبق أن رفض المستخدم هذا المقترح؛ لن يُعرض مجدداً.'
              : 'المقترح محفوظ مسبقاً؛ لم تُنشأ نسخة مكررة.',
        });
        return;
      }

      final requestHandler = onTaskProposalRequest;
      if (requestHandler == null) {
        await session.channel.send({
          'kind': 'task_proposal_ack',
          'transfer_id': envelope.transferId,
          'accepted': false,
          'retryable': true,
          'message': 'افتح شاشة الأجهزة على الجهاز المستلم للموافقة على حفظ المقترح.',
        });
        return;
      }
      if (!_pendingIncomingTaskPrompts.add(session.deviceId)) {
        await session.channel.send({
          'kind': 'task_proposal_ack',
          'transfer_id': envelope.transferId,
          'accepted': false,
          'retryable': true,
          'message': 'يوجد مقترح آخر قيد المراجعة لهذا الجهاز؛ أعد المحاولة لاحقاً.',
        });
        return;
      }
      promptClaimed = true;
      final plan = jsonDecode(envelope.planJson) as Map;
      final steps = plan['steps'] as List;
      final approved = await requestHandler(PeerTaskProposalRequest(
        transferId: envelope.transferId,
        deviceId: session.deviceId,
        displayName: session.displayName,
        goal: envelope.goal,
        planJson: envelope.planJson,
        stepCount: steps.length,
      )).timeout(
        const Duration(seconds: 60),
        onTimeout: () => null,
      );
      if (approved == null) {
        await session.channel.send({
          'kind': 'task_proposal_ack',
          'transfer_id': envelope.transferId,
          'accepted': false,
          'retryable': true,
          'message': 'لم يصل قرار من الجهاز المستلم؛ بقي المقترح في قائمة الإرسال.',
        });
        return;
      }

      final stillPaired = await repository.get(session.deviceId);
      if (stillPaired == null || stillPaired.isBlocked) {
        throw const PeerTaskTransferException(
          'أُزيل الاقتران أو حُظر الجهاز أثناء المراجعة؛ لم يُحفظ المقترح.',
        );
      }
      final inserted = await _transferRepository.storeIncoming(
        envelope: envelope,
        deviceId: session.deviceId,
        decision: approved ? 'kept' : 'declined',
      );
      if (!approved) {
        await session.channel.send({
          'kind': 'task_proposal_ack',
          'transfer_id': envelope.transferId,
          'accepted': false,
          'rejected_by_user': true,
          'retryable': false,
          'duplicate': !inserted,
          'message': 'رفض المستخدم حفظ مقترح المهمة؛ سُجل الرفض لمنع تكرار الطلب.',
        });
        if (inserted) {
          _events.add(DeviceNetworkEvent(
            type: DeviceNetworkEventType.taskProposalDeclined,
            deviceId: session.deviceId,
            message: 'تم رفض مقترح المهمة من ${session.displayName} وحفظ قرار الرفض.',
          ));
        }
        return;
      }

      await session.channel.send({
        'kind': 'task_proposal_ack',
        'transfer_id': envelope.transferId,
        'accepted': true,
        'duplicate': !inserted,
        'message': inserted
            ? 'وافق المستخدم وتم حفظ المقترح محلياً دون تشغيله.'
            : 'كان المقترح محفوظاً مسبقاً؛ لم تُنشأ نسخة مكررة.',
      });
      if (inserted) {
        _events.add(DeviceNetworkEvent(
          type: DeviceNetworkEventType.taskProposalReceived,
          deviceId: session.deviceId,
          message: 'وافق المستخدم على استلام مقترح من ${session.displayName}. لم يتم تشغيله.',
        ));
      }
    } on Object catch (error) {
      final permanentFailure = error is PeerTaskTransferException;
      await session.channel.send({
        'kind': 'task_proposal_ack',
        'transfer_id': rawTransferId is String ? rawTransferId : '',
        'accepted': false,
        'retryable': !permanentFailure,
        'message': permanentFailure
            ? error.message
            : 'تعذر التحقق من مقترح المهمة أو حفظه مؤقتاً؛ يمكن إعادة المحاولة.',
      });
    } finally {
      if (promptClaimed) _pendingIncomingTaskPrompts.remove(session.deviceId);
    }
  }

  void _installSession({
    required String deviceId,
    required String displayName,
    required PeerFrameConnection connection,
    required PeerSecureChannel channel,
  }) {
    _pendingConnections.remove(connection);
    final previous = _sessions.remove(deviceId);
    if (previous != null) unawaited(previous.connection.close());
    final session = _PeerSession(
      deviceId: deviceId,
      displayName: displayName,
      connection: connection,
      channel: channel,
    );
    _sessions[deviceId] = session;
    _events.add(DeviceNetworkEvent(
      type: DeviceNetworkEventType.peerConnected,
      deviceId: deviceId,
      message: 'اتصل الجهاز $displayName بنجاح.',
    ));
    unawaited(_consume(session));
    unawaited(_flushQueuedTaskTransfers(deviceId));
  }

  Future<void> _consume(_PeerSession session) async {
    try {
      while (!_disposed && identical(_sessions[session.deviceId], session)) {
        final message = await session.channel.receive();
        final kind = message['kind'];
        if (kind == 'capabilities') {
          final raw = message['value'];
          if (raw is Map) {
            final capabilities = raw.map(
              (key, value) => MapEntry(key.toString(), value),
            );
            await repository.updateCapabilities(session.deviceId, capabilities);
            if (capabilities['task_transfer'] == true &&
                capabilities['task_transfer_version'] == peerTaskTransferVersion) {
              unawaited(_flushQueuedTaskTransfers(session.deviceId));
            }
            _events.add(DeviceNetworkEvent(
              type: DeviceNetworkEventType.capabilitiesUpdated,
              deviceId: session.deviceId,
              message: 'تم تحديث قدرات ${session.displayName}.',
            ));
          }
        } else if (kind == 'ping') {
          await session.channel.send({
            'kind': 'pong',
            'sent_at_unix_ms': message['sent_at_unix_ms'],
          });
        } else if (kind == 'pong') {
          _events.add(DeviceNetworkEvent(
            type: DeviceNetworkEventType.message,
            deviceId: session.deviceId,
            message: 'استجاب ${session.displayName} لاختبار الاتصال.',
          ));
        } else if (kind == 'task_proposal') {
          await _handleIncomingTaskProposal(session, message);
        } else if (kind == 'task_proposal_ack') {
          final transferId = message['transfer_id'];
          if (transferId is String) {
            final completer = _pendingTaskAcks[transferId];
            final expectedDeviceId = _pendingTaskAckDevices[transferId];
            if (completer != null &&
                expectedDeviceId == session.deviceId &&
                !completer.isCompleted) {
              completer.complete(message);
            }
          }
        } else {
          _events.add(DeviceNetworkEvent(
            type: DeviceNetworkEventType.error,
            deviceId: session.deviceId,
            message: 'تم تجاهل نوع رسالة غير مسموح من ${session.displayName}.',
          ));
        }
      }
    } on Object catch (error) {
      if (!_disposed) {
        _events.add(DeviceNetworkEvent(
          type: DeviceNetworkEventType.error,
          deviceId: session.deviceId,
          message: 'انقطع الاتصال مع ${session.displayName}: $error',
        ));
      }
    } finally {
      if (identical(_sessions[session.deviceId], session)) {
        _sessions.remove(session.deviceId);
        for (final entry in _pendingTaskAcks.entries.toList()) {
          if (_pendingTaskAckDevices[entry.key] == session.deviceId &&
              !entry.value.isCompleted) {
            entry.value.completeError(
              const PeerProtocolException('انقطع الاتصال قبل تأكيد استلام مقترح المهمة.'),
            );
          }
        }
        await repository.updateLastSeen(session.deviceId);
        _events.add(DeviceNetworkEvent(
          type: DeviceNetworkEventType.peerDisconnected,
          deviceId: session.deviceId,
          message: 'انقطع الاتصال مع ${session.displayName}.',
        ));
      }
      await session.connection.close();
    }
  }

  Future<void> _sendCapabilities(String deviceId) async {
    final session = _sessions[deviceId];
    if (session == null) return;
    final snapshot = await _resourceMonitor.readSnapshot();
    await session.channel.send({
      'kind': 'capabilities',
      'value': {
        'platform': Platform.operatingSystem,
        'app_version': '2.6.2',
        'native_runtime': 'llama.cpp',
        'model_session_concurrency': 1,
        'available_memory_bytes': snapshot?.availableMemoryBytes,
        'total_memory_bytes': snapshot?.totalMemoryBytes,
        'protocol_version': peerProtocolVersion,
        'task_execution': false,
        'task_transfer': true,
        'task_transfer_version': peerTaskTransferVersion,
      },
    });
  }

  Future<void> ping(String deviceId) async {
    final session = _sessions[deviceId];
    if (session == null) throw const PeerProtocolException('الجهاز غير متصل.');
    await session.channel.send({
      'kind': 'ping',
      'sent_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<PairedDeviceRecord>> listDevices() => repository.list();

  bool isConnected(String deviceId) => _sessions.containsKey(deviceId);

  Future<void> setBlocked(String deviceId, bool blocked) async {
    if (blocked) {
      final session = _sessions.remove(deviceId);
      if (session != null) await session.connection.close();
    }
    await repository.setBlocked(deviceId, blocked);
    _events.add(DeviceNetworkEvent(
      type: DeviceNetworkEventType.message,
      deviceId: deviceId,
      message: blocked ? 'تم حظر الجهاز ومنع إعادة اتصاله.' : 'تم رفع الحظر عن الجهاز.',
    ));
  }

  Future<void> forget(String deviceId) async {
    final session = _sessions.remove(deviceId);
    if (session != null) await session.connection.close();
    await _secureStorage.delete(key: '$_secretPrefix$deviceId');
    await repository.remove(deviceId);
    _events.add(DeviceNetworkEvent(
      type: DeviceNetworkEventType.message,
      deviceId: deviceId,
      message: 'تم حذف الجهاز ومفتاح الاقتران المحلي.',
    ));
  }

  Future<void> startDiscovery({Duration duration = _discoveryWindow}) async {
    await initialize();
    if (_disposed) throw StateError('DeviceNetworkService disposed');
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'Must be positive');
    }
    _isDiscovering = true;
    try {
      await _ensureDiscoverySocket();
    } on Object {
      _isDiscovering = false;
      _syncNetworkWatcher();
      rethrow;
    }
    if (_disposed) {
      _isDiscovering = false;
      await _syncDiscoverySocket();
      throw StateError('DeviceNetworkService disposed');
    }
    _syncNetworkWatcher();
    _discoveredPeers.clear();
    _validDiscoveryNonces.clear();
    _discoveryStopTimer?.cancel();
    _discoveryProbeTimer?.cancel();
    await _sendDiscoveryProbe();
    _discoveryProbeTimer = Timer.periodic(_probeInterval, (_) {
      unawaited(_sendDiscoveryProbe());
    });
    _discoveryStopTimer = Timer(duration, () {
      unawaited(stopDiscovery());
    });
    _events.add(const DeviceNetworkEvent(
      type: DeviceNetworkEventType.discoveryStarted,
      message: 'جارٍ البحث عن أجهزة NEXUS التي تشارك دعوة اقتران فعّالة على الشبكة المحلية.',
    ));
  }

  Future<void> stopDiscovery() async {
    final wasDiscovering = _isDiscovering;
    _isDiscovering = false;
    _discoveryProbeTimer?.cancel();
    _discoveryProbeTimer = null;
    _discoveryStopTimer?.cancel();
    _discoveryStopTimer = null;
    _validDiscoveryNonces.clear();
    _pruneDiscoveryState();
    await _syncDiscoverySocket();
    _syncNetworkWatcher();
    if (wasDiscovering && !_disposed) {
      _events.add(const DeviceNetworkEvent(
        type: DeviceNetworkEventType.discoveryStopped,
        message: 'توقف البحث عن الأجهزة القريبة.',
      ));
    }
  }

  Future<PairingInvite?> refreshInvite() async {
    final active = _activeInvite;
    if (active == null || !active.expiresAt.isAfter(DateTime.now()) ||
        _inviteClaimed) {
      return null;
    }
    final addresses = await _localPrivateAddresses();
    if (addresses.isEmpty) return null;
    return PairingInvite(
      addresses: addresses,
      port: port,
      code: base64UrlEncode(active.secret).replaceAll('=', ''),
      expiresAt: active.expiresAt,
      deviceId: _localDeviceId!,
      displayName: _localDeviceName!,
      discoveryAvailable: _discoverySocket != null,
    );
  }

  Future<void> _ensureDiscoverySocket() async {
    if (_discoverySocket != null) return;
    final opening = _discoverySocketOpening;
    if (opening != null) {
      await opening;
      return;
    }
    late final Future<void> trackedOpening;
    trackedOpening = _bindDiscoverySocket().whenComplete(() {
      if (identical(_discoverySocketOpening, trackedOpening)) {
        _discoverySocketOpening = null;
      }
    });
    _discoverySocketOpening = trackedOpening;
    await trackedOpening;
  }

  Future<void> _bindDiscoverySocket() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: false,
      reusePort: false,
    );
    if (_disposed || (!_isDiscovering && !_isDiscoverableInvite(_activeInvite))) {
      socket.close();
      return;
    }
    socket.broadcastEnabled = true;
    _discoverySocket = socket;
    _discoverySubscription = socket.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          Datagram? datagram;
          do {
            datagram = socket.receive();
            if (datagram != null) _handleDiscoveryDatagram(datagram);
          } while (datagram != null);
        } else if (event == RawSocketEvent.closed &&
            identical(_discoverySocket, socket)) {
          // A delayed close event from a replaced socket must not clear the
          // reference to a newer socket bound after a network handover.
          _discoverySocket = null;
          _discoverySubscription = null;
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!_disposed) {
          _events.add(DeviceNetworkEvent(
            type: DeviceNetworkEventType.error,
            message: 'تعذر استخدام الاكتشاف المحلي؛ يمكنك الاقتران يدوياً أو عبر QR: $error',
          ));
        }
      },
      cancelOnError: false,
    );
  }

  Future<void> _syncDiscoverySocket() async {
    final inviteActive = _activeInvite != null &&
        !_inviteClaimed &&
        _activeInvite!.expiresAt.isAfter(DateTime.now()) &&
        isListening;
    if (_isDiscovering || inviteActive) {
      await _ensureDiscoverySocket();
      return;
    }
    final subscription = _discoverySubscription;
    _discoverySubscription = null;
    final socket = _discoverySocket;
    _discoverySocket = null;
    // Close the UDP port before awaiting subscription cancellation so a new
    // scan or invitation can safely rebind without racing the old socket.
    socket?.close();
    await subscription?.cancel();
  }

  void _handleDiscoveryDatagram(Datagram datagram) {
    if (datagram.data.length > peerDiscoveryPacketLimit ||
        !isPrivatePeerAddress(datagram.address.address)) {
      return;
    }
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map) return;
      final message = <String, Object?>{};
      decoded.forEach((key, value) {
        if (key is String) message[key] = value;
      });
      if (message['type'] == 'nexus_probe' &&
          message['version'] == peerDiscoveryVersion) {
        _answerDiscoveryProbe(message, datagram);
        return;
      }
      final peer = PeerDiscoveryProtocol.parseAdvertisement(
        message: message,
        sourceAddress: datagram.address,
        validNonces: _validDiscoveryNonces.keys.toSet(),
        localDeviceId: _localDeviceId ?? '',
      );
      if (peer != null && _isDiscovering) {
        _discoveredPeers[peer.deviceId] = peer;
        _pruneDiscoveryState();
        _events.add(const DeviceNetworkEvent(
          type: DeviceNetworkEventType.discoveryUpdated,
          message: 'تم تحديث قائمة الأجهزة الظاهرة على الشبكة. لم يتم توثيق الأجهزة المكتشفة بعد.',
        ));
      }
    } on FormatException {
      // Ignore malformed LAN discovery packets.
    } on Object {
      // Discovery is best-effort; malformed or unrelated packets are ignored.
    }
  }

  void _answerDiscoveryProbe(
    Map<String, Object?> message,
    Datagram datagram,
  ) {
    final invite = _activeInvite;
    final nonce = message['nonce'];
    final socket = _discoverySocket;
    final source = datagram.address.address;
    final now = DateTime.now();
    if (socket == null || !_isDiscoverableInvite(invite) ||
        nonce is! String || !RegExp(r'^[A-Za-z0-9_-]{16}$').hasMatch(nonce)) {
      return;
    }
    // Rate-limit responses per LAN source to avoid turning discovery into an
    // amplification path or allowing a noisy peer to monopolize the socket.
    final lastReply = _lastDiscoveryReplyAt[source];
    if (lastReply != null && now.difference(lastReply) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastDiscoveryReplyAt[source] = now;
    _lastDiscoveryReplyAt.removeWhere(
      (_, timestamp) => now.difference(timestamp) > const Duration(seconds: 30),
    );
    if (_lastDiscoveryReplyAt.length > 256) {
      final oldest = _lastDiscoveryReplyAt.entries.toList()
        ..sort((left, right) => left.value.compareTo(right.value));
      for (final entry in oldest.take(_lastDiscoveryReplyAt.length - 256)) {
        _lastDiscoveryReplyAt.remove(entry.key);
      }
    }
    final advertisement = PeerDiscoveryProtocol.createAdvertisement(
      nonce: nonce,
      deviceId: _localDeviceId!,
      displayName: _localDeviceName!,
      platform: Platform.operatingSystem,
      port: port,
    );
    final bytes = utf8.encode(jsonEncode(advertisement));
    if (bytes.length <= peerDiscoveryPacketLimit) {
      socket.send(bytes, datagram.address, datagram.port);
    }
  }

  bool _isDiscoverableInvite(_InviteState? invite) =>
      invite != null &&
      isListening &&
      !_inviteClaimed &&
      invite.expiresAt.isAfter(DateTime.now());

  Future<void> _sendDiscoveryProbe() async {
    final socket = _discoverySocket;
    if (!_isDiscovering || socket == null) return;
    final now = DateTime.now();
    _validDiscoveryNonces.removeWhere((_, expiry) => !expiry.isAfter(now));
    final nonce = _randomToken(12);
    _validDiscoveryNonces[nonce] = now.add(_nonceLifetime);
    final bytes = utf8.encode(jsonEncode(PeerDiscoveryProtocol.createProbe(nonce)));
    if (bytes.length > peerDiscoveryPacketLimit) return;
    try {
      socket.send(bytes, InternetAddress('255.255.255.255'), discoveryPort);
    } on Object catch (error) {
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.error,
        message: 'تعذر إرسال طلب اكتشاف إلى الشبكة المحلية: $error',
      ));
    }
    _pruneDiscoveryState();
  }

  void _pruneDiscoveryState() {
    final now = DateTime.now();
    _discoveredPeers.removeWhere((_, peer) =>
        now.difference(peer.lastSeenAt) > _peerStaleAfter);
    _validDiscoveryNonces.removeWhere((_, expiry) => !expiry.isAfter(now));
  }

  void _syncNetworkWatcher() {
    final shouldWatch = _isDiscovering || _isDiscoverableInvite(_activeInvite);
    if (!shouldWatch || _disposed) {
      _networkWatchTimer?.cancel();
      _networkWatchTimer = null;
      return;
    }
    _startNetworkWatcher();
  }

  void _startNetworkWatcher() {
    if (_networkWatchTimer != null || _disposed) return;
    unawaited(_refreshNetworkFingerprint(emitChange: false));
    _networkWatchTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      unawaited(_refreshNetworkFingerprint());
    });
  }

  Future<void> _refreshNetworkFingerprint({bool emitChange = true}) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: true,
      );
      final entries = <String>[];
      for (final networkInterface in interfaces) {
        final addresses = networkInterface.addresses
            .map((address) => address.address)
            .where((address) => isPrivatePeerAddress(address) ||
                address.startsWith('169.254.'))
            .toList()
          ..sort();
        if (addresses.isNotEmpty) {
          entries.add('${networkInterface.name}:${addresses.join(',')}');
        }
      }
      entries.sort();
      final fingerprint = entries.join('|');
      final previous = _networkFingerprint;
      _networkFingerprint = fingerprint;
      if (emitChange && previous != null && previous != fingerprint) {
        _discoveredPeers.clear();
        _validDiscoveryNonces.clear();
        _lastDiscoveryReplyAt.clear();
        final wasSocketActive = _discoverySocket != null;
        if (wasSocketActive) {
          final subscription = _discoverySubscription;
          _discoverySubscription = null;
          final socket = _discoverySocket;
          _discoverySocket = null;
          await subscription?.cancel();
          socket?.close();
        }
        if (_isDiscovering || _isDiscoverableInvite(_activeInvite)) {
          try {
            await _ensureDiscoverySocket();
            if (_isDiscovering) await _sendDiscoveryProbe();
          } on Object catch (error) {
            _events.add(DeviceNetworkEvent(
              type: DeviceNetworkEventType.error,
              message: 'تغيرت الشبكة وتعذر إعادة تشغيل الاكتشاف: $error',
            ));
          }
        }
        _events.add(const DeviceNetworkEvent(
          type: DeviceNetworkEventType.networkChanged,
          message: 'تغير اتصال الشبكة. تم تحديث حالة الاكتشاف؛ راجع عناوين الدعوة قبل مشاركة الرمز.',
        ));
      }
    } on Object {
      // Network interface enumeration can fail temporarily during handover.
    }
  }

  Future<List<String>> _localPrivateAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: true,
    );
    final addresses = <String>{};
    for (final networkInterface in interfaces) {
      for (final address in networkInterface.addresses) {
        if (isPrivatePeerAddress(address.address) ||
            address.address.startsWith('169.254.')) {
          addresses.add(address.address);
        }
      }
    }
    final result = addresses.toList();
    result.sort((left, right) {
      final leftLinkLocal = left.startsWith('169.254.');
      final rightLinkLocal = right.startsWith('169.254.');
      if (leftLinkLocal != rightLinkLocal) return leftLinkLocal ? 1 : -1;
      return left.compareTo(right);
    });
    // The versioned QR envelope accepts at most eight IPv4 endpoints.
    return result.take(8).toList(growable: false);
  }

  List<int> _decodePairingCode(String value) {
    try {
      final decoded = base64Url.decode(base64Url.normalize(value.trim()));
      if (decoded.length != 32) throw const FormatException();
      return decoded;
    } on FormatException {
      throw const PeerProtocolException(
        'رمز الاقتران غير صالح. يجب إدخال الرمز الكامل من الجهاز المستضيف.',
      );
    }
  }

  String _requiredString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty || value.length > 256) {
      throw PeerProtocolException('حقل $key مفقود أو غير صالح.');
    }
    return value;
  }

  List<int> _decodeBase64(String value) {
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      throw const PeerProtocolException('توقيع الاقتران غير صالح.');
    }
  }

  void _validatePeerMaterial(String publicKey, String nonce) {
    if (_decodeBase64(publicKey).length != 32 ||
        _decodeBase64(nonce).length != 24) {
      throw const PeerProtocolException(
        'بيانات المفتاح المؤقت أو التحدي العشوائي غير صالحة.',
      );
    }
  }

  List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256), growable: false);

  String _randomToken(int length) =>
      base64UrlEncode(_randomBytes(length)).replaceAll('=', '');

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _networkWatchTimer?.cancel();
    _networkWatchTimer = null;
    _inviteExpiryTimer?.cancel();
    _inviteExpiryTimer = null;
    await stopDiscovery();
    await stopListening();
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final completer in _pendingTaskAcks.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('DeviceNetworkService disposed'));
      }
    }
    _pendingTaskAcks.clear();
    _pendingTaskAckDevices.clear();
    for (final session in sessions) {
      await session.connection.close();
    }
    await _events.close();
  }
}

class _InviteState {
  const _InviteState({required this.secret, required this.expiresAt});
  final List<int> secret;
  final DateTime expiresAt;
}

class _PeerSession {
  const _PeerSession({
    required this.deviceId,
    required this.displayName,
    required this.connection,
    required this.channel,
  });

  final String deviceId;
  final String displayName;
  final PeerFrameConnection connection;
  final PeerSecureChannel channel;
}
