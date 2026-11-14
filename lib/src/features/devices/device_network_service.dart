import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import '../agents/agent_record.dart';
import '../agents/agent_repository.dart';
import '../models/model_repository.dart';
import '../resources/peer_model_profile.dart';
import '../orchestration/agent_task_orchestrator.dart';
import '../orchestration/agent_task_plan.dart';
import '../orchestration/agent_task_repository.dart';
import '../resources/resource_settings.dart';
import 'device_record.dart';
import 'device_repository.dart';
import 'peer_discovery.dart';
import 'peer_protocol.dart';
import 'peer_task_transfer.dart';
import 'peer_task_execution.dart';

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
  taskExecutionReceived,
  taskExecutionStarted,
  taskExecutionFinished,
  taskExecutionUpdated,
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


class PeerTaskExecutionApproval {
  const PeerTaskExecutionApproval({
    required this.accepted,
    this.localAgentId,
  });

  final bool accepted;
  final String? localAgentId;
}

class PeerTaskExecutionPrompt {
  const PeerTaskExecutionPrompt({
    required this.executionId,
    required this.deviceId,
    required this.displayName,
    required this.request,
  });

  final String executionId;
  final String deviceId;
  final String displayName;
  final PeerTaskExecutionRequest request;
}

class DeviceNetworkService {
  DeviceNetworkService({
    LocalDatabase? database,
    FlutterSecureStorage? secureStorage,
    PairedDeviceRepository? repository,
  })  : _database = database ?? LocalDatabase.instance,
        _secureStorage = secureStorage ?? FlutterSecureStorage(),
        repository = repository ?? PairedDeviceRepository(database: database),
        _agentRepository = AgentRepository(database: database),
        _modelRepository = ModelRepository(database: database),
        _transferRepository = RemoteTaskTransferRepository(database: database),
        _executionRepository = PeerTaskExecutionRepository(database: database);

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
  final AgentRepository _agentRepository;
  final ModelRepository _modelRepository;
  final RemoteTaskTransferRepository _transferRepository;
  final PeerTaskExecutionRepository _executionRepository;
  final AgentTaskRepository _taskRepository = AgentTaskRepository();
  final DeviceResourceMonitor _resourceMonitor = DeviceResourceMonitor();
  final StreamController<DeviceNetworkEvent> _events =
      StreamController<DeviceNetworkEvent>.broadcast();
  final Map<String, _PeerSession> _sessions = {};
  final Map<String, Completer<Map<String, Object?>>> _pendingTaskAcks = {};
  final Map<String, String> _pendingTaskAckDevices = {};
  final Set<String> _taskTransfersInFlight = {};
  final Set<String> _pendingIncomingTaskPrompts = {};
  final Set<String> _pendingIncomingExecutionPrompts = {};
  final Set<String> _pendingIncomingExecutionDevices = {};
  final Map<String, AgentTaskCancellationToken> _activePeerExecutionTokens = {};
  final Set<String> _cancelledIncomingExecutions = {};
  final Set<String> _peerExecutionsInFlight = {};
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
  ResourceSnapshot? _cachedResourceSnapshot;
  DateTime? _cachedResourceSnapshotAt;
  Future<ResourceSnapshot?>? _resourceSnapshotPending;
  Future<bool> Function(PeerPairingRequest request)? onPairingRequest;
  Future<bool?> Function(PeerTaskProposalRequest request)? onTaskProposalRequest;
  Future<PeerTaskExecutionApproval?> Function(PeerTaskExecutionPrompt request)?
      onPeerTaskExecutionApproval;
  Future<String> Function({
    required String localAgentId,
    required PeerTaskExecutionRequest request,
    required AgentTaskCancellationToken cancellationToken,
  })? onPeerTaskExecute;

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

  void configurePeerExecutionHandlers({
    required Future<PeerTaskExecutionApproval?> Function(
      PeerTaskExecutionPrompt request,
    ) approvalHandler,
    required Future<String> Function({
      required String localAgentId,
      required PeerTaskExecutionRequest request,
      required AgentTaskCancellationToken cancellationToken,
    }) executeHandler,
  }) {
    onPeerTaskExecutionApproval = approvalHandler;
    onPeerTaskExecute = executeHandler;
    for (final deviceId in _sessions.keys) {
      unawaited(_sendCapabilities(deviceId));
    }
  }

  void clearPeerExecutionHandlers() {
    onPeerTaskExecutionApproval = null;
    onPeerTaskExecute = null;
    for (final deviceId in _sessions.keys) {
      unawaited(_sendCapabilities(deviceId));
    }
  }

  Future<List<PeerTaskExecutionRecord>> listPeerTaskExecutions() =>
      _executionRepository.list();

  Future<void> cancelLocalPeerExecution(String executionId) async {
    final record = await _executionRepository.get(executionId);
    if (record == null || record.direction != 'incoming' ||
        record.status != PeerTaskExecutionStatus.running) {
      throw const PeerTaskExecutionException('لا يوجد تنفيذ محلي جارٍ بهذا المعرّف.');
    }
    final token = _activePeerExecutionTokens[executionId];
    if (token == null) {
      throw const PeerTaskExecutionException('لم يعد التنفيذ نشطاً أو أنه في طور الإنهاء.');
    }
    token.cancel();
  }

  Future<void> sendTaskStepForRemoteExecution({
    required String deviceId,
    required String taskId,
    required String stepKey,
  }) async {
    final device = await repository.get(deviceId);
    if (device == null || device.isBlocked) {
      throw const PeerProtocolException('الجهاز غير موجود أو محظور.');
    }
    if (device.capabilities['task_execution'] != true ||
        device.capabilities['task_execution_version'] != peerTaskExecutionVersion) {
      throw const PeerProtocolException(
        'الجهاز المقابل لا يؤكد دعم تنفيذ الخطوات. افتح شاشة الأجهزة على الطرفين ثم أعد الاتصال.',
      );
    }
    final task = await _taskRepository.get(taskId);
    if (task == null || !{'planned', 'interrupted'}.contains(task.status.name)) {
      throw const PeerTaskExecutionException(
        'يمكن إرسال خطوة من مهمة مخططة أو متوقفة فقط.',
      );
    }
    final steps = await _taskRepository.steps(taskId);
    AgentTaskStepRecord? selected;
    for (final step in steps) {
      if (step.stepKey == stepKey) {
        selected = step;
      }
    }
    if (selected == null ||
        !{'pending', 'interrupted'}.contains(selected.status.name)) {
      throw const PeerTaskExecutionException(
        'الخطوة غير موجودة أو ليست جاهزة للإرسال.',
      );
    }
    final byKey = {for (final step in steps) step.stepKey: step};
    final localAgents = await AgentRepository().list();
    final agentNames = {for (final agent in localAgents) agent.id: agent.name};
    final dependencies = <PeerTaskDependencyResult>[];
    for (final dependencyId in selected.dependsOn) {
      final dependency = byKey[dependencyId];
      if (dependency == null || dependency.status != AgentTaskStepStatus.succeeded) {
        throw const PeerTaskExecutionException(
          'لا يمكن إرسال الخطوة قبل اكتمال جميع اعتمادياتها محلياً.',
        );
      }
      dependencies.add(PeerTaskDependencyResult(
        stepId: dependency.stepKey,
        agentName: agentNames[dependency.agentId] ?? 'وكيل محلي سابق',
        output: dependency.outputText,
      ));
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final request = await PeerTaskExecutionRequest.create(
      executionId: _randomToken(24),
      sourceTaskId: task.id,
      sourceStepId: selected.stepKey,
      goal: task.goal,
      objective: selected.objective,
      expectedOutput: selected.expectedOutput,
      dependencies: dependencies,
      createdAtUnixMs: now,
      expiresAtUnixMs: now + peerTaskExecutionRequestLifetime.inMilliseconds,
    );
    await _executionRepository.createOutgoing(
      deviceId: deviceId,
      request: request,
      sourceTaskId: task.id,
      sourceStepKey: selected.stepKey,
    );
    if (_sessions.containsKey(deviceId)) {
      await _deliverPeerExecution(deviceId, request.executionId);
    }
    _events.add(DeviceNetworkEvent(
      type: DeviceNetworkEventType.taskExecutionUpdated,
      deviceId: deviceId,
      message: 'حُفظ طلب تنفيذ الخطوة في سجل الإرسال.',
    ));
  }

  Future<void> cancelRemoteExecution(String executionId) async {
    final record = await _executionRepository.get(executionId);
    if (record == null || record.direction != 'outgoing') {
      throw const PeerTaskExecutionException('طلب التنفيذ الصادر غير موجود.');
    }
    final session = _sessions[record.deviceId];
    if (record.status == PeerTaskExecutionStatus.queued) {
      await _executionRepository.transition(
        executionId: executionId,
        from: PeerTaskExecutionStatus.queued,
        to: PeerTaskExecutionStatus.cancelled,
        error: 'ألغى المستخدم الطلب قبل إرساله.',
      );
      _events.add(const DeviceNetworkEvent(
        type: DeviceNetworkEventType.taskExecutionUpdated,
        message: 'أُلغي طلب التنفيذ قبل إرساله.',
      ));
      return;
    }
    if (session == null) {
      throw const PeerProtocolException('اتصل بالجهاز المقابل لإرسال طلب الإلغاء.');
    }
    await session.channel.send({
      'kind': 'task_execution_cancel',
      'version': peerTaskExecutionVersion,
      'execution_id': executionId,
    });
  }

  Future<void> initialize() async {
    await (_initialization ??= _loadIdentity().then<void>((_) async {
      await _executionRepository.recoverRunningAsInterrupted();
      await _reconcileStoredRemoteResults();
    }));
  }

  Future<String> _loadIdentity() async {
    final db = await _database.database;
    final existingId = await _readSetting(db, _identityKey);
    final id = existingId ?? _randomToken(18);
    if (existingId == null) {
      await _writeSetting(db, _identityKey, id);
    }
    final existingName = await _readSetting(db, _nameKey);
    final name = existingName ?? 'NEXUS-${id.substring(0, 6).toUpperCase()}';
    if (existingName == null) {
      await _writeSetting(db, _nameKey, name);
    }
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
    if (_server != null) {
      return;
    }
    if (_disposed) {
      throw StateError('DeviceNetworkService disposed');
    }
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
    if (activeStop != null) {
      return activeStop;
    }
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
    if (lastError != null) {
      throw lastError;
    }
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

  Future<String> importTaskProposal({
    required String transferId,
    required AgentTaskPlan locallyMappedPlan,
  }) => _transferRepository.importIncomingAsLocalTask(
        transferId: transferId,
        plan: locallyMappedPlan,
      );

  Future<void> reviewTaskTransfer(String transferId, {required bool keep}) =>
      _transferRepository.reviewIncoming(transferId, keep: keep);

  Future<void> retryQueuedTaskTransfers(String deviceId) =>
      _flushQueuedTaskTransfers(deviceId);

  Future<void> _flushQueuedTaskTransfers(String deviceId) async {
    if (_disposed || !_sessions.containsKey(deviceId)) {
      return;
    }
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
      if (!_sessions.containsKey(deviceId)) {
        return;
      }
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
    if (session == null || !_taskTransfersInFlight.add(transferId)) {
      return;
    }
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
      if (promptClaimed) {
        _pendingIncomingTaskPrompts.remove(session.deviceId);
      }
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
    if (previous != null) {
      unawaited(previous.connection.close());
    }
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
    unawaited(_flushQueuedPeerExecutions(deviceId));
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
            if (capabilities['task_execution'] == true &&
                capabilities['task_execution_version'] == peerTaskExecutionVersion) {
              unawaited(_flushQueuedPeerExecutions(session.deviceId));
            }
            if (capabilities['task_execution_version'] == peerTaskExecutionVersion) {
              unawaited(_flushPeerExecutionResults(session.deviceId));
            }
            _events.add(DeviceNetworkEvent(
              type: DeviceNetworkEventType.capabilitiesUpdated,
              deviceId: session.deviceId,
              message: 'تم تحديث قدرات ${session.displayName}.',
            ));
          }
        } else if (kind == 'ping') {
          await _sendCapabilities(session.deviceId);
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
        } else if (kind == 'task_execution_request') {
          unawaited(_handleIncomingPeerExecution(session, message));
        } else if (kind == 'task_execution_ack') {
          await _handlePeerExecutionAck(session, message);
        } else if (kind == 'task_execution_result') {
          await _handlePeerExecutionResult(session, message);
        } else if (kind == 'task_execution_result_ack') {
          await _handlePeerExecutionResultAck(session, message);
        } else if (kind == 'task_execution_cancel') {
          await _handlePeerExecutionCancel(session, message);
        } else if (kind == 'task_execution_cancel_ack') {
          await _handlePeerExecutionCancelAck(session, message);
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

  Future<void> _flushQueuedPeerExecutions(String deviceId) async {
    if (_disposed || !_sessions.containsKey(deviceId) ||
        !_peerExecutionsInFlight.add('flush:$deviceId')) {
      return;
    }
    try {
      final device = await repository.get(deviceId);
      if (device == null || device.isBlocked ||
          device.capabilities['task_execution'] != true ||
          device.capabilities['task_execution_version'] != peerTaskExecutionVersion) {
        return;
      }
      final records = await _executionRepository.list(
        direction: 'outgoing',
        deviceId: deviceId,
      );
      for (final record in records.where(
        (item) => item.status == PeerTaskExecutionStatus.queued ||
            item.status == PeerTaskExecutionStatus.awaitingApproval,
      )) {
        if (!_sessions.containsKey(deviceId)) {
          return;
        }
        try {
          await _deliverPeerExecution(deviceId, record.executionId);
        } on Object catch (error) {
          _events.add(DeviceNetworkEvent(
            type: DeviceNetworkEventType.error,
            deviceId: deviceId,
            message: 'تعذر إعادة إرسال طلب التنفيذ المحفوظ: $error',
          ));
          return;
        }
      }
    } finally {
      _peerExecutionsInFlight.remove('flush:$deviceId');
    }
  }

  Future<void> _deliverPeerExecution(String deviceId, String executionId) async {
    final session = _sessions[deviceId];
    if (session == null || !_peerExecutionsInFlight.add(executionId)) {
      return;
    }
    try {
      final record = await _executionRepository.get(executionId);
      if (record == null || record.direction != 'outgoing' ||
          (record.status != PeerTaskExecutionStatus.queued &&
              record.status != PeerTaskExecutionStatus.awaitingApproval)) {
        return;
      }
      late final PeerTaskExecutionRequest request;
      try {
        request = await PeerTaskExecutionRequest.fromMessage(
          (jsonDecode(record.requestJson) as Map).cast<String, Object?>(),
        );
      } on Object catch (error) {
        final current = await _executionRepository.get(executionId);
        final from = current?.status;
        if (from == PeerTaskExecutionStatus.queued ||
            from == PeerTaskExecutionStatus.awaitingApproval) {
          await _executionRepository.transition(
            executionId: executionId,
            from: from!,
            to: PeerTaskExecutionStatus.rejected,
            error: 'انتهت صلاحية الطلب أو تعذر التحقق منه: $error',
          );
        }
        _events.add(DeviceNetworkEvent(
          type: DeviceNetworkEventType.taskExecutionUpdated,
          deviceId: deviceId,
          message: 'لم يُرسل طلب التنفيذ لأن صلاحيته انتهت أو بياناته غير صالحة.',
        ));
        return;
      }
      if (record.status == PeerTaskExecutionStatus.queued) {
        await _executionRepository.transition(
          executionId: executionId,
          from: PeerTaskExecutionStatus.queued,
          to: PeerTaskExecutionStatus.awaitingApproval,
        );
      }
      try {
        await session.channel.send(request.toMessage());
        _events.add(DeviceNetworkEvent(
          type: DeviceNetworkEventType.taskExecutionUpdated,
          deviceId: deviceId,
          message: 'أُرسل طلب تنفيذ ${record.sourceStepKey} وينتظر موافقة الجهاز الآخر.',
        ));
      } on Object catch (error) {
        final current = await _executionRepository.get(executionId);
        if (current?.status == PeerTaskExecutionStatus.awaitingApproval) {
          await _executionRepository.transition(
            executionId: executionId,
            from: PeerTaskExecutionStatus.awaitingApproval,
            to: PeerTaskExecutionStatus.queued,
            error: error.toString(),
          );
        }
        rethrow;
      }
    } finally {
      _peerExecutionsInFlight.remove(executionId);
    }
  }

  Future<void> _handleIncomingPeerExecution(
    _PeerSession session,
    Map<String, Object?> message,
  ) async {
    final rawId = message['execution_id'];
    try {
      final paired = await repository.get(session.deviceId);
      if (paired == null || paired.isBlocked) {
        throw const PeerTaskExecutionException('الجهاز غير مقترن أو محظور.');
      }
      final peerCapabilities = paired.capabilities;
      if (peerCapabilities['task_execution'] != true ||
          peerCapabilities['task_execution_version'] != peerTaskExecutionVersion) {
        throw const PeerTaskExecutionException('الجهاز المرسل لا يعلن دعم بروتوكول التنفيذ.');
      }
      final request = await PeerTaskExecutionRequest.fromMessage(message);
      final inserted = await _executionRepository.storeIncoming(
        deviceId: session.deviceId,
        request: request,
      );
      if (inserted) {
        _events.add(DeviceNetworkEvent(
          type: DeviceNetworkEventType.taskExecutionReceived,
          deviceId: session.deviceId,
          message: 'وصل طلب تنفيذ خطوة من ${session.displayName} وينتظر قرارك.',
        ));
      }
      var record = await _executionRepository.get(request.executionId);
      if (record == null) {
        throw const PeerTaskExecutionException('تعذر حفظ طلب التنفيذ.');
      }
      if (!inserted) {
        if (record.status == PeerTaskExecutionStatus.rejected ||
            record.status == PeerTaskExecutionStatus.interrupted ||
            (record.status == PeerTaskExecutionStatus.cancelled &&
                record.resultJson == null)) {
          await _sendExecutionAck(
            session,
            request.executionId,
            accepted: false,
            retryable: false,
            message: record.error ?? 'سبق إنهاء طلب التنفيذ؛ أنشئ طلباً جديداً عند الحاجة.',
          );
          return;
        }
        if (record.status == PeerTaskExecutionStatus.running ||
            record.status == PeerTaskExecutionStatus.approved) {
          await _sendExecutionAck(
            session,
            request.executionId,
            accepted: true,
            retryable: false,
            status: record.status.wireName,
            message: 'طلب التنفيذ محفوظ ويجري التعامل معه بالفعل.',
          );
          return;
        }
        if (record.status == PeerTaskExecutionStatus.succeeded ||
            record.status == PeerTaskExecutionStatus.failed ||
            record.status == PeerTaskExecutionStatus.cancelled) {
          if (record.resultJson != null) {
            await _sendExecutionAck(
              session,
              request.executionId,
              accepted: true,
              retryable: false,
              status: record.status.wireName,
              message: 'سبق التعامل مع طلب التنفيذ؛ النتيجة النهائية محفوظة على الجهاز.',
            );
            if (record.resultAcknowledgedAtUnixMs == null) {
              try {
                await _sendStoredExecutionResult(session, record);
              } on Object catch (error) {
                _events.add(DeviceNetworkEvent(
                  type: DeviceNetworkEventType.taskExecutionUpdated,
                  deviceId: session.deviceId,
                  message: 'تعذر إعادة إرسال النتيجة المحفوظة؛ ستتم المحاولة عند إعادة الاتصال: $error',
                ));
              }
            }
          } else {
            await _sendExecutionAck(
              session,
              request.executionId,
              accepted: false,
              retryable: false,
              message: record.error ?? 'سبق إنهاء طلب التنفيذ دون نتيجة قابلة للاستعادة.',
            );
          }
          return;
        }
      }
      if (!_pendingIncomingExecutionPrompts.add(request.executionId)) {
        await _sendExecutionAck(
          session,
          request.executionId,
          accepted: false,
          retryable: true,
          message: 'طلب التنفيذ قيد المراجعة بالفعل.',
        );
        return;
      }
      // This app currently owns one llama.cpp model session. Serialize the
      // whole approval + execution lifecycle across all peers, not merely per
      // peer, so two devices cannot race the same native runtime.
      if (_pendingIncomingExecutionDevices.isNotEmpty ||
          !_pendingIncomingExecutionDevices.add(session.deviceId)) {
        _pendingIncomingExecutionPrompts.remove(request.executionId);
        await _sendExecutionAckBestEffort(
          session,
          request.executionId,
          accepted: false,
          retryable: true,
          message: 'المحرك المحلي مشغول بطلب آخر؛ أعد المحاولة لاحقاً.',
        );
        return;
      }
      _refreshConnectedPeerCapabilities();
      try {
        final approvalHandler = onPeerTaskExecutionApproval;
        final executeHandler = onPeerTaskExecute;
        if (approvalHandler == null || executeHandler == null) {
          await _sendExecutionAck(
            session,
            request.executionId,
            accepted: false,
            retryable: true,
            message: 'افتح شاشة الأجهزة على الجهاز المستلم للموافقة على التنفيذ.',
          );
          return;
        }
        final decision = await approvalHandler(PeerTaskExecutionPrompt(
          executionId: request.executionId,
          deviceId: session.deviceId,
          displayName: session.displayName,
          request: request,
        )).timeout(const Duration(seconds: 60), onTimeout: () => null);
        final latestRecord = await _executionRepository.get(request.executionId);
        if (latestRecord == null ||
            latestRecord.status != PeerTaskExecutionStatus.awaitingApproval) {
          await _sendExecutionAckBestEffort(
            session,
            request.executionId,
            accepted: false,
            retryable: false,
            message: 'أُلغي الطلب أو تغيرت حالته قبل الموافقة.',
          );
          return;
        }
        if (decision == null) {
          await _sendExecutionAckBestEffort(
            session,
            request.executionId,
            accepted: false,
            retryable: true,
            message: 'انتهت مهلة انتظار الموافقة؛ لم يبدأ التنفيذ.',
          );
          return;
        }
        if (!decision.accepted) {
          await _executionRepository.transition(
            executionId: request.executionId,
            from: PeerTaskExecutionStatus.awaitingApproval,
            to: PeerTaskExecutionStatus.rejected,
            error: 'رفض المستخدم تنفيذ الخطوة على هذا الجهاز.',
          );
          await _sendExecutionAckBestEffort(
            session,
            request.executionId,
            accepted: false,
            retryable: false,
            message: 'رفض المستخدم تنفيذ الخطوة.',
          );
          _events.add(DeviceNetworkEvent(
            type: DeviceNetworkEventType.taskExecutionUpdated,
            deviceId: session.deviceId,
            message: 'رفض المستخدم طلب التنفيذ الوارد.',
          ));
          return;
        }
        final localAgentId = decision.localAgentId;
        if (localAgentId == null || localAgentId.trim().isEmpty) {
          throw const PeerTaskExecutionException('لم يتم اختيار وكيل محلي لتنفيذ الخطوة.');
        }
        final stillPaired = await repository.get(session.deviceId);
        if (stillPaired == null || stillPaired.isBlocked ||
            !identical(_sessions[session.deviceId], session)) {
          throw const PeerTaskExecutionException('تغيرت حالة الجهاز قبل بدء التنفيذ.');
        }
        await _executionRepository.transition(
          executionId: request.executionId,
          from: PeerTaskExecutionStatus.awaitingApproval,
          to: PeerTaskExecutionStatus.approved,
          localAgentId: localAgentId,
        );
        await _executionRepository.transition(
          executionId: request.executionId,
          from: PeerTaskExecutionStatus.approved,
          to: PeerTaskExecutionStatus.running,
        );
        final cancellation = AgentTaskCancellationToken();
        _activePeerExecutionTokens[request.executionId] = cancellation;
        // An authenticated cancel can arrive in the small interval between
        // the durable running transition and token registration.
        if (_cancelledIncomingExecutions.remove(request.executionId)) {
          cancellation.cancel();
        }
        await _sendExecutionAckBestEffort(
          session,
          request.executionId,
          accepted: true,
          retryable: false,
          status: 'running',
          message: 'وافق المستخدم واختار وكيلاً محلياً؛ بدأ التنفيذ على هذا الجهاز.',
        );
        _events.add(DeviceNetworkEvent(
          type: DeviceNetworkEventType.taskExecutionStarted,
          deviceId: session.deviceId,
          message: 'بدأ تنفيذ خطوة واردة باستخدام وكيل محلي.',
        ));

        PeerTaskExecutionResult result;
        try {
          cancellation.throwIfCancelled();
          final output = await executeHandler(
            localAgentId: localAgentId,
            request: request,
            cancellationToken: cancellation,
          );
          cancellation.throwIfCancelled();
          result = await PeerTaskExecutionResult.create(
            executionId: request.executionId,
            outcome: 'succeeded',
            outputText: output,
            completedAtUnixMs: DateTime.now().millisecondsSinceEpoch,
          );
        } on AgentTaskCancelledException {
          result = await PeerTaskExecutionResult.create(
            executionId: request.executionId,
            outcome: 'cancelled',
            outputText: '',
            error: 'أُلغي التنفيذ من الجهاز المنسّق أو المستخدم المحلي.',
            completedAtUnixMs: DateTime.now().millisecondsSinceEpoch,
          );
        } on Object catch (error) {
          final wasCancelled = cancellation.isCancelled;
          result = await PeerTaskExecutionResult.create(
            executionId: request.executionId,
            outcome: wasCancelled ? 'cancelled' : 'failed',
            outputText: '',
            error: wasCancelled
                ? 'أُلغي التنفيذ قبل اكتمال استجابة المحرك.'
                : _boundedExecutionError(error),
            completedAtUnixMs: DateTime.now().millisecondsSinceEpoch,
          );
        }
        // Persist the terminal result before attempting network delivery. A
        // send failure must never be misreported as a model-execution failure
        // or overwrite the already committed result with a different digest.
        await _executionRepository.storeResult(result: result);
        await _sendExecutionResultBestEffort(session, result);
        _events.add(DeviceNetworkEvent(
          type: DeviceNetworkEventType.taskExecutionFinished,
          deviceId: session.deviceId,
          message: switch (result.outcome) {
            'succeeded' => 'اكتمل التنفيذ المحلي وحُفظت النتيجة لإرسالها بأمان.',
            'cancelled' => 'أُلغي التنفيذ المحلي وحُفظت حالة الإلغاء.',
            _ => 'فشل التنفيذ المحلي وحُفظ سبب الفشل.',
          },
        ));
        _activePeerExecutionTokens.remove(request.executionId);
        _cancelledIncomingExecutions.remove(request.executionId);
      } finally {
        _activePeerExecutionTokens.remove(request.executionId);
        _cancelledIncomingExecutions.remove(request.executionId);
        _pendingIncomingExecutionPrompts.remove(request.executionId);
        _pendingIncomingExecutionDevices.remove(session.deviceId);
        _refreshConnectedPeerCapabilities();
      }
    } on Object catch (error) {
      try {
        await _sendExecutionAck(
          session,
          rawId is String ? rawId : '',
          accepted: false,
          retryable: error is! PeerTaskExecutionException,
          message: error.toString(),
        );
      } on Object {
        // The session may have closed while the request was being validated.
      }
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.error,
        deviceId: session.deviceId,
        message: 'رُفض طلب تنفيذ وارد: $error',
      ));
    }
  }

  String _boundedExecutionError(Object error) {
    final runes = error.toString().runes;
    return String.fromCharCodes(runes.take(4000));
  }

  Future<void> _sendExecutionAckBestEffort(
    _PeerSession session,
    String executionId, {
    required bool accepted,
    required bool retryable,
    String? status,
    required String message,
  }) async {
    if (!identical(_sessions[session.deviceId], session)) {
      return;
    }
    try {
      await _sendExecutionAck(
        session,
        executionId,
        accepted: accepted,
        retryable: retryable,
        status: status,
        message: message,
      );
    } on Object {
      // The sender retries the same durable execution ID after reconnect.
    }
  }

  Future<void> _sendExecutionResultBestEffort(
    _PeerSession session,
    PeerTaskExecutionResult result,
  ) async {
    if (!identical(_sessions[session.deviceId], session)) {
      return;
    }
    try {
      await session.channel.send(result.toMessage());
    } on Object catch (error) {
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.taskExecutionUpdated,
        deviceId: session.deviceId,
        message: 'حُفظت النتيجة محلياً، وسيُعاد إرسالها عند عودة الاتصال: $error',
      ));
    }
  }

  Future<void> _sendExecutionAck(
    _PeerSession session,
    String executionId, {
    required bool accepted,
    required bool retryable,
    String? status,
    required String message,
  }) => session.channel.send({
        'kind': 'task_execution_ack',
        'version': peerTaskExecutionVersion,
        'execution_id': executionId,
        'accepted': accepted,
        'retryable': retryable,
        'status': status,
        'message': message,
      });

  Future<void> _handlePeerExecutionAck(
    _PeerSession session,
    Map<String, Object?> message,
  ) async {
    final executionId = message['execution_id'];
    if (message['version'] != peerTaskExecutionVersion || executionId is! String) {
      return;
    }
    final record = await _executionRepository.get(executionId);
    if (record == null || record.direction != 'outgoing' ||
        record.deviceId != session.deviceId ||
        (record.status != PeerTaskExecutionStatus.awaitingApproval &&
            record.status != PeerTaskExecutionStatus.queued)) {
      return;
    }
    var status = record.status;
    if (message['accepted'] == true) {
      if (status == PeerTaskExecutionStatus.queued) {
        await _executionRepository.transition(
          executionId: executionId,
          from: PeerTaskExecutionStatus.queued,
          to: PeerTaskExecutionStatus.awaitingApproval,
        );
        status = PeerTaskExecutionStatus.awaitingApproval;
      }
      await _executionRepository.transition(
        executionId: executionId,
        from: status,
        to: PeerTaskExecutionStatus.approved,
      );
      await _executionRepository.transition(
        executionId: executionId,
        from: PeerTaskExecutionStatus.approved,
        to: PeerTaskExecutionStatus.running,
      );
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.taskExecutionUpdated,
        deviceId: session.deviceId,
        message: 'وافق الجهاز المقابل على التنفيذ وبدأ تشغيل الخطوة.',
      ));
    } else if (message['retryable'] == true) {
      if (status == PeerTaskExecutionStatus.awaitingApproval) {
        await _executionRepository.transition(
          executionId: executionId,
          from: PeerTaskExecutionStatus.awaitingApproval,
          to: PeerTaskExecutionStatus.queued,
          error: message['message'] as String? ?? 'ينتظر الجهاز المستلم فتح شاشة الأجهزة.',
        );
      }
    } else {
      await _executionRepository.transition(
        executionId: executionId,
        from: status,
        to: PeerTaskExecutionStatus.rejected,
        error: message['message'] as String? ?? 'رفض الجهاز المقابل التنفيذ.',
      );
    }
    _events.add(DeviceNetworkEvent(
      type: DeviceNetworkEventType.taskExecutionUpdated,
      deviceId: session.deviceId,
      message: message['message'] as String? ?? 'تم تحديث حالة طلب التنفيذ.',
    ));
  }

  Future<void> _handlePeerExecutionResult(
    _PeerSession session,
    Map<String, Object?> message,
  ) async {
    final result = await PeerTaskExecutionResult.fromMessage(message);
    final record = await _executionRepository.get(result.executionId);
    if (record == null || record.direction != 'outgoing' ||
        record.deviceId != session.deviceId) {
      throw const PeerTaskExecutionException('نتيجة التنفيذ لا تطابق جهازاً وطلباً صادرين.');
    }
    if (record.status == PeerTaskExecutionStatus.queued ||
        record.status == PeerTaskExecutionStatus.awaitingApproval) {
      var current = record.status;
      if (current == PeerTaskExecutionStatus.queued) {
        await _executionRepository.transition(
          executionId: result.executionId,
          from: PeerTaskExecutionStatus.queued,
          to: PeerTaskExecutionStatus.awaitingApproval,
        );
        current = PeerTaskExecutionStatus.awaitingApproval;
      }
      await _executionRepository.transition(
        executionId: result.executionId,
        from: current,
        to: PeerTaskExecutionStatus.approved,
      );
      await _executionRepository.transition(
        executionId: result.executionId,
        from: PeerTaskExecutionStatus.approved,
        to: PeerTaskExecutionStatus.running,
      );
    }
    final inserted = await _executionRepository.storeResult(result: result);
    await _applyRemoteStepResult(record, result);
    await _sendExecutionResultAckBestEffort(session, result);
    if (inserted) {
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.taskExecutionFinished,
        deviceId: session.deviceId,
        message: switch (result.outcome) {
          'succeeded' => 'وصلت نتيجة الخطوة من الجهاز الآخر بنجاح.',
          'cancelled' => 'أُلغيت خطوة التنفيذ على الجهاز الآخر.',
          _ => 'فشل تنفيذ الخطوة على الجهاز الآخر: ${result.error}',
        },
      ));
    }
  }

  Future<void> _applyRemoteStepResult(
    PeerTaskExecutionRecord record,
    PeerTaskExecutionResult result,
  ) async {
    final task = await _taskRepository.get(record.sourceTaskId);
    if (task == null) {
      return;
    }
    final steps = await _taskRepository.steps(record.sourceTaskId);
    AgentTaskStepRecord? step;
    for (final item in steps) {
      if (item.stepKey == record.sourceStepKey) {
        step = item;
      }
    }
    if (step == null) {
      return;
    }
    final nextStatus = switch (result.outcome) {
      'succeeded' => AgentTaskStepStatus.succeeded,
      'cancelled' => AgentTaskStepStatus.interrupted,
      _ => AgentTaskStepStatus.failed,
    };
    if (step.status == nextStatus &&
        (nextStatus != AgentTaskStepStatus.succeeded ||
            step.outputText == result.outputText) &&
        (nextStatus != AgentTaskStepStatus.failed ||
            step.error == result.error)) {
      return;
    }
    if (step.status != AgentTaskStepStatus.pending &&
        step.status != AgentTaskStepStatus.interrupted) {
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.taskExecutionUpdated,
        deviceId: record.deviceId,
        message: 'وصلت نتيجة بعيدة، لكن حالة الخطوة تغيّرت محلياً؛ لم أستبدل نتيجتها.',
      ));
      return;
    }
    await _taskRepository.finishStep(
      record.sourceTaskId,
      record.sourceStepKey,
      nextStatus,
      output: result.outcome == 'succeeded' ? result.outputText : '',
      error: result.error,
    );
    await _taskRepository.appendEvent(
      taskId: record.sourceTaskId,
      stepKey: record.sourceStepKey,
      eventType: 'remote_step_${result.outcome}',
      message: switch (result.outcome) {
        'succeeded' => 'اكتمل تنفيذ الخطوة على جهاز مقترن، وحُفظ الناتج محلياً.',
        'cancelled' => 'أُلغيت الخطوة على الجهاز الآخر؛ يمكن استئنافها محلياً.',
        _ => 'فشل تنفيذ الخطوة على الجهاز الآخر: ${result.error}',
      },
      payload: {
        'execution_id': record.executionId,
        'device_id': record.deviceId,
        'outcome': result.outcome,
        'result_sha256': result.payloadSha256,
      },
    );
  }

  Future<void> _reconcileStoredRemoteResults() async {
    final records = await _executionRepository.list(direction: 'outgoing');
    for (final record in records) {
      if (record.resultJson == null) {
        continue;
      }
      try {
        final decoded = jsonDecode(record.resultJson!);
        if (decoded is! Map) {
          continue;
        }
        final result = await PeerTaskExecutionResult.fromMessage(
          decoded.cast<String, Object?>(),
        );
        await _applyRemoteStepResult(record, result);
      } on Object {
        // Keep the execution record for inspection; never overwrite local work.
      }
    }
  }

  Future<void> _sendExecutionResultAckBestEffort(
    _PeerSession session,
    PeerTaskExecutionResult result,
  ) async {
    if (!identical(_sessions[session.deviceId], session)) {
      return;
    }
    try {
      await session.channel.send({
        'kind': 'task_execution_result_ack',
        'version': peerTaskExecutionVersion,
        'execution_id': result.executionId,
        'result_sha256': result.payloadSha256,
      });
    } on Object {
      // The sender has stored the result; the receiver will replay it after reconnect.
    }
  }

  Future<void> _handlePeerExecutionResultAck(
    _PeerSession session,
    Map<String, Object?> message,
  ) async {
    final executionId = message['execution_id'];
    final digest = message['result_sha256'];
    if (message['version'] != peerTaskExecutionVersion ||
        executionId is! String || digest is! String) {
      return;
    }
    final record = await _executionRepository.get(executionId);
    if (record == null ||
        record.direction != 'incoming' ||
        record.deviceId != session.deviceId ||
        record.resultJson == null ||
        record.resultSha256 != digest) {
      return;
    }
    final marked = await _executionRepository.markResultAcknowledged(
      executionId: executionId,
      deviceId: session.deviceId,
      resultSha256: digest,
    );
    if (marked) {
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.taskExecutionUpdated,
        deviceId: session.deviceId,
        message: 'أكد الجهاز المنسّق حفظ النتيجة؛ أُوقف تكرار إرسالها.',
      ));
    }
  }

  Future<void> _handlePeerExecutionCancel(
    _PeerSession session,
    Map<String, Object?> message,
  ) async {
    final executionId = message['execution_id'];
    if (message['version'] != peerTaskExecutionVersion || executionId is! String) {
      return;
    }
    final record = await _executionRepository.get(executionId);
    if (record == null || record.direction != 'incoming' ||
        record.deviceId != session.deviceId) {
      return;
    }
    if (record.status == PeerTaskExecutionStatus.awaitingApproval) {
      _cancelledIncomingExecutions.add(executionId);
      await _executionRepository.transition(
        executionId: executionId,
        from: PeerTaskExecutionStatus.awaitingApproval,
        to: PeerTaskExecutionStatus.cancelled,
        error: 'ألغى الجهاز المنسّق الطلب قبل الموافقة.',
      );
    } else if (record.status == PeerTaskExecutionStatus.approved) {
      _cancelledIncomingExecutions.add(executionId);
    } else if (record.status == PeerTaskExecutionStatus.running) {
      final token = _activePeerExecutionTokens[executionId];
      if (token == null) {
        _cancelledIncomingExecutions.add(executionId);
      } else {
        token.cancel();
      }
    }
    await session.channel.send({
      'kind': 'task_execution_cancel_ack',
      'version': peerTaskExecutionVersion,
      'execution_id': executionId,
      'accepted': true,
    });
  }

  Future<void> _handlePeerExecutionCancelAck(
    _PeerSession session,
    Map<String, Object?> message,
  ) async {
    final executionId = message['execution_id'];
    if (executionId is! String || message['version'] != peerTaskExecutionVersion) {
      return;
    }
    final record = await _executionRepository.get(executionId);
    if (record == null || record.direction != 'outgoing' ||
        record.deviceId != session.deviceId || message['accepted'] != true) {
      return;
    }
    if (record.status == PeerTaskExecutionStatus.awaitingApproval) {
      await _executionRepository.transition(
        executionId: executionId,
        from: PeerTaskExecutionStatus.awaitingApproval,
        to: PeerTaskExecutionStatus.cancelled,
        error: 'أُرسل طلب إلغاء التنفيذ.',
      );
    } else if (record.status == PeerTaskExecutionStatus.running) {
      // The remote result remains authoritative if cancellation raced completion.
      _events.add(DeviceNetworkEvent(
        type: DeviceNetworkEventType.taskExecutionUpdated,
        deviceId: session.deviceId,
        message: 'استلم الجهاز الآخر طلب الإلغاء؛ ننتظر النتيجة النهائية.',
      ));
    }
  }

  Future<void> _sendStoredExecutionResult(
    _PeerSession session,
    PeerTaskExecutionRecord record,
  ) async {
    final resultJson = record.resultJson;
    if (resultJson == null || !identical(_sessions[session.deviceId], session)) {
      return;
    }
    final decoded = jsonDecode(resultJson);
    if (decoded is! Map) {
      throw const PeerTaskExecutionException('النتيجة المحفوظة ليست كائن JSON.');
    }
    await session.channel.send(decoded.cast<String, Object?>());
  }

  Future<void> _flushPeerExecutionResults(String deviceId) async {
    if (_disposed || !_sessions.containsKey(deviceId)) {
      return;
    }
    final records = await _executionRepository.list(
      direction: 'incoming',
      deviceId: deviceId,
    );
    final session = _sessions[deviceId];
    if (session == null) {
      return;
    }
    for (final record in records) {
      if (record.resultJson == null ||
          record.resultAcknowledgedAtUnixMs != null ||
          !{
            PeerTaskExecutionStatus.succeeded,
            PeerTaskExecutionStatus.failed,
            PeerTaskExecutionStatus.cancelled,
          }.contains(record.status)) {
        continue;
      }
      try {
        final decoded = jsonDecode(record.resultJson!);
        if (decoded is! Map) {
          continue;
        }
        await session.channel.send(decoded.cast<String, Object?>());
      } on Object {
        return;
      }
    }
  }

  void _refreshConnectedPeerCapabilities() {
    for (final deviceId in _sessions.keys.toList(growable: false)) {
      unawaited(_sendCapabilities(deviceId).catchError((Object _) {}));
    }
  }

  Future<void> _sendCapabilities(String deviceId) async {
    final session = _sessions[deviceId];
    if (session == null) {
      return;
    }
    final snapshot = await _readResourceSnapshotForCapabilities();
    final now = DateTime.now().millisecondsSinceEpoch;
    final activePeerExecutions = _pendingIncomingExecutionDevices.length;
    final availableMemory = snapshot?.availableMemoryBytes;
    final totalMemory = snapshot?.totalMemoryBytes;
    final readyModelProfiles = await _readReadyAgentModelProfiles();
    await session.channel.send({
      'kind': 'capabilities',
      'value': {
        'platform': Platform.operatingSystem,
        'app_version': '2.8.1',
        'native_runtime': 'llama.cpp',
        'model_session_concurrency': 1,
        'available_memory_bytes': availableMemory != null && availableMemory > 0
            ? availableMemory
            : null,
        'total_memory_bytes': totalMemory != null && totalMemory > 0
            ? totalMemory
            : null,
        'cpu_logical_cores': snapshot?.cpuLogicalCores ??
            Platform.numberOfProcessors.clamp(1, 256).toInt(),
        'cpu_utilization_percent': snapshot?.cpuUtilizationPercent,
        'battery_level_percent': snapshot?.batteryLevelPercent,
        'is_charging': snapshot?.isCharging,
        'thermal_status': snapshot?.thermalStatus,
        'active_peer_executions': activePeerExecutions,
        'execution_busy': activePeerExecutions > 0,
        'resource_profile_version': 1,
        'resource_profile_updated_at_unix_ms': now,
        'ready_model_profiles_version': peerModelProfileInventoryVersion,
        'ready_model_profile_signatures': readyModelProfiles,
        'protocol_version': peerProtocolVersion,
        'task_execution': onPeerTaskExecutionApproval != null &&
            onPeerTaskExecute != null,
        'task_execution_version': peerTaskExecutionVersion,
        'task_transfer': true,
        'task_transfer_version': peerTaskTransferVersion,
      },
    });
  }

  /// Advertises only model metadata profiles assigned to ready local agents.
  /// No local model IDs, display names, paths, or file contents are disclosed.
  /// The signature is a compatibility key for GGUF metadata, not a content hash.
  Future<List<String>> _readReadyAgentModelProfiles() async {
    final agents = await _agentRepository.list();
    final readyModelIds = agents
        .where((agent) => agent.status == AgentRecordStatus.ready)
        .map((agent) => agent.modelId)
        .whereType<String>()
        .toSet();
    if (readyModelIds.isEmpty) {
      return const [];
    }

    final models = await _modelRepository.list();
    final signatures = <String>{};
    for (final model in models) {
      if (!readyModelIds.contains(model.id)) {
        continue;
      }
      final profile = PeerInstalledModelProfile.fromModel(model);
      if (profile == null || model.localPath == null || model.localPath!.isEmpty) {
        continue;
      }
      final file = File(model.localPath!);
      if (!await file.exists() || await file.length() != model.sizeBytes) {
        continue;
      }
      signatures.add(profile.signature);
    }
    final result = signatures.toList()..sort();
    return List.unmodifiable(result);
  }

  Future<ResourceSnapshot?> _readResourceSnapshotForCapabilities() async {
    final now = DateTime.now();
    final cachedAt = _cachedResourceSnapshotAt;
    if (_cachedResourceSnapshot != null &&
        cachedAt != null &&
        now.difference(cachedAt) < const Duration(seconds: 10)) {
      return _cachedResourceSnapshot;
    }
    final pending = _resourceSnapshotPending;
    if (pending != null) {
      return pending;
    }
    final future = _resourceMonitor.readSnapshot(includeExtendedTelemetry: true);
    _resourceSnapshotPending = future;
    try {
      final snapshot = await future;
      _cachedResourceSnapshot = snapshot;
      _cachedResourceSnapshotAt = DateTime.now();
      return snapshot;
    } finally {
      if (identical(_resourceSnapshotPending, future)) {
        _resourceSnapshotPending = null;
      }
    }
  }

  Future<void> ping(String deviceId) async {
    final session = _sessions[deviceId];
    if (session == null) {
      throw const PeerProtocolException('الجهاز غير متصل.');
    }
    await _sendCapabilities(deviceId);
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
      if (session != null) {
        await session.connection.close();
      }
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
    if (session != null) {
      await session.connection.close();
    }
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
    if (_disposed) {
      throw StateError('DeviceNetworkService disposed');
    }
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
    if (addresses.isEmpty) {
      return null;
    }
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
    if (_discoverySocket != null) {
      return;
    }
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
            if (datagram != null) {
              _handleDiscoveryDatagram(datagram);
            }
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
      if (decoded is! Map) {
        return;
      }
      final message = <String, Object?>{};
      decoded.forEach((key, value) {
        if (key is String) {
          message[key] = value;
        }
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
    if (!_isDiscovering || socket == null) {
      return;
    }
    final now = DateTime.now();
    _validDiscoveryNonces.removeWhere((_, expiry) => !expiry.isAfter(now));
    final nonce = _randomToken(12);
    _validDiscoveryNonces[nonce] = now.add(_nonceLifetime);
    final bytes = utf8.encode(jsonEncode(PeerDiscoveryProtocol.createProbe(nonce)));
    if (bytes.length > peerDiscoveryPacketLimit) {
      return;
    }
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
    if (_networkWatchTimer != null || _disposed) {
      return;
    }
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
            if (_isDiscovering) {
              await _sendDiscoveryProbe();
            }
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
      if (leftLinkLocal != rightLinkLocal) {
        return leftLinkLocal ? 1 : -1;
      }
      return left.compareTo(right);
    });
    // The versioned QR envelope accepts at most eight IPv4 endpoints.
    return result.take(8).toList(growable: false);
  }

  List<int> _decodePairingCode(String value) {
    try {
      final decoded = base64Url.decode(base64Url.normalize(value.trim()));
      if (decoded.length != 32) {
        throw const FormatException();
      }
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
    if (_disposed) {
      return;
    }
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
    for (final token in _activePeerExecutionTokens.values) {
      token.cancel();
    }
    _activePeerExecutionTokens.clear();
    _pendingIncomingExecutionPrompts.clear();
    _pendingIncomingExecutionDevices.clear();
    _cancelledIncomingExecutions.clear();
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
