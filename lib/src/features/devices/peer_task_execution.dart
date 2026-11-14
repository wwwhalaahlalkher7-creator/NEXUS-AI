import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';

const peerTaskExecutionVersion = 1;
const peerTaskExecutionRequestLifetime = Duration(minutes: 15);
const peerTaskExecutionMaximumDependencies = 256;
const peerTaskExecutionMaximumBytes = 512 * 1024;

class PeerTaskExecutionException implements Exception {
  const PeerTaskExecutionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PeerTaskDependencyResult {
  const PeerTaskDependencyResult({
    required this.stepId,
    required this.agentName,
    required this.output,
  });

  final String stepId;
  final String agentName;
  final String output;

  Map<String, Object?> toMap() => {
        'step_id': stepId,
        'agent_name': agentName,
        'output': output,
      };

  factory PeerTaskDependencyResult.fromMap(Map value) {
    final stepId = value['step_id'];
    final agentName = value['agent_name'];
    final output = value['output'];
    if (stepId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(stepId) ||
        agentName is! String ||
        agentName.trim().isEmpty ||
        agentName.length > 128 ||
        output is! String ||
        output.length > 100000) {
      throw const PeerTaskExecutionException(
        'بيانات إحدى الاعتماديات غير صالحة.',
      );
    }
    return PeerTaskDependencyResult(
      stepId: stepId,
      agentName: agentName.trim(),
      output: output,
    );
  }
}

/// One-step execution request. The receiver maps the remote step to a local
/// ready agent and obtains local consent before invoking its local runtime.
/// The envelope is transported only over the authenticated peer channel.
class PeerTaskExecutionRequest {
  const PeerTaskExecutionRequest({
    required this.executionId,
    required this.sourceTaskId,
    required this.sourceStepId,
    required this.goal,
    required this.objective,
    required this.expectedOutput,
    required this.dependencies,
    required this.createdAtUnixMs,
    required this.expiresAtUnixMs,
    required this.payloadSha256,
  });

  final String executionId;
  final String sourceTaskId;
  final String sourceStepId;
  final String goal;
  final String objective;
  final String expectedOutput;
  final List<PeerTaskDependencyResult> dependencies;
  final int createdAtUnixMs;
  final int expiresAtUnixMs;
  final String payloadSha256;

  static Future<PeerTaskExecutionRequest> create({
    required String executionId,
    required String sourceTaskId,
    required String sourceStepId,
    required String goal,
    required String objective,
    required String expectedOutput,
    List<PeerTaskDependencyResult> dependencies = const [],
    required int createdAtUnixMs,
    required int expiresAtUnixMs,
  }) async {
    _validate(
      executionId: executionId,
      sourceTaskId: sourceTaskId,
      sourceStepId: sourceStepId,
      goal: goal,
      objective: objective,
      expectedOutput: expectedOutput,
      dependencies: dependencies,
      createdAtUnixMs: createdAtUnixMs,
      expiresAtUnixMs: expiresAtUnixMs,
    );
    final core = _coreMap(
      executionId: executionId,
      sourceTaskId: sourceTaskId,
      sourceStepId: sourceStepId,
      goal: goal,
      objective: objective,
      expectedOutput: expectedOutput,
      dependencies: dependencies,
      createdAtUnixMs: createdAtUnixMs,
      expiresAtUnixMs: expiresAtUnixMs,
    );
    final digest = await Sha256().hash(utf8.encode(jsonEncode(core)));
    final request = PeerTaskExecutionRequest(
      executionId: executionId,
      sourceTaskId: sourceTaskId,
      sourceStepId: sourceStepId,
      goal: goal.trim(),
      objective: objective.trim(),
      expectedOutput: expectedOutput.trim(),
      dependencies: List.unmodifiable(dependencies),
      createdAtUnixMs: createdAtUnixMs,
      expiresAtUnixMs: expiresAtUnixMs,
      payloadSha256: _hex(digest.bytes),
    );
    _validateWireSize(request.toMessage());
    return request;
  }

  static Future<PeerTaskExecutionRequest> fromMessage(
    Map<String, Object?> message, {
    DateTime? now,
  }) async {
    if (message['kind'] != 'task_execution_request' ||
        message['version'] != peerTaskExecutionVersion) {
      throw const PeerTaskExecutionException(
        'إصدار طلب التنفيذ الموزّع غير مدعوم.',
      );
    }
    final executionId = message['execution_id'];
    final sourceTaskId = message['source_task_id'];
    final sourceStepId = message['source_step_id'];
    final goal = message['goal'];
    final objective = message['objective'];
    final expectedOutput = message['expected_output'];
    final rawDependencies = message['dependencies'];
    final createdAt = message['created_at_unix_ms'];
    final expiresAt = message['expires_at_unix_ms'];
    final suppliedHash = message['payload_sha256'];
    if (executionId is! String ||
        sourceTaskId is! String ||
        sourceStepId is! String ||
        goal is! String ||
        objective is! String ||
        expectedOutput is! String ||
        rawDependencies is! List ||
        createdAt is! int ||
        expiresAt is! int ||
        suppliedHash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(suppliedHash)) {
      throw const PeerTaskExecutionException(
        'حقول طلب التنفيذ غير مكتملة أو غير صالحة.',
      );
    }
    final dependencies = <PeerTaskDependencyResult>[];
    for (final raw in rawDependencies) {
      if (raw is! Map) {
        throw const PeerTaskExecutionException(
          'بنية إحدى الاعتماديات غير صالحة.',
        );
      }
      dependencies.add(PeerTaskDependencyResult.fromMap(raw));
    }
    _validate(
      executionId: executionId,
      sourceTaskId: sourceTaskId,
      sourceStepId: sourceStepId,
      goal: goal,
      objective: objective,
      expectedOutput: expectedOutput,
      dependencies: dependencies,
      createdAtUnixMs: createdAt,
      expiresAtUnixMs: expiresAt,
    );
    final core = _coreMap(
      executionId: executionId,
      sourceTaskId: sourceTaskId,
      sourceStepId: sourceStepId,
      goal: goal,
      objective: objective,
      expectedOutput: expectedOutput,
      dependencies: dependencies,
      createdAtUnixMs: createdAt,
      expiresAtUnixMs: expiresAt,
    );
    final digest = await Sha256().hash(utf8.encode(jsonEncode(core)));
    final actualHash = _hex(digest.bytes);
    if (!_constantTimeEquals(actualHash, suppliedHash)) {
      throw const PeerTaskExecutionException(
        'فشل التحقق من بصمة طلب التنفيذ.',
      );
    }
    final currentTime = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (expiresAt <= currentTime) {
      throw const PeerTaskExecutionException('انتهت صلاحية طلب التنفيذ.');
    }
    if (createdAt >
        currentTime + const Duration(minutes: 2).inMilliseconds) {
      throw const PeerTaskExecutionException(
        'وقت إنشاء طلب التنفيذ يتجاوز الانحراف الزمني المسموح.',
      );
    }
    final request = PeerTaskExecutionRequest(
      executionId: executionId,
      sourceTaskId: sourceTaskId,
      sourceStepId: sourceStepId,
      goal: goal.trim(),
      objective: objective.trim(),
      expectedOutput: expectedOutput.trim(),
      dependencies: List.unmodifiable(dependencies),
      createdAtUnixMs: createdAt,
      expiresAtUnixMs: expiresAt,
      payloadSha256: actualHash,
    );
    _validateWireSize(request.toMessage());
    return request;
  }

  Map<String, Object?> toMessage() => {
        'kind': 'task_execution_request',
        'version': peerTaskExecutionVersion,
        'execution_id': executionId,
        'source_task_id': sourceTaskId,
        'source_step_id': sourceStepId,
        'goal': goal,
        'objective': objective,
        'expected_output': expectedOutput,
        'dependencies': dependencies.map((item) => item.toMap()).toList(),
        'created_at_unix_ms': createdAtUnixMs,
        'expires_at_unix_ms': expiresAtUnixMs,
        'payload_sha256': payloadSha256,
      };

  static void _validate({
    required String executionId,
    required String sourceTaskId,
    required String sourceStepId,
    required String goal,
    required String objective,
    required String expectedOutput,
    required List<PeerTaskDependencyResult> dependencies,
    required int createdAtUnixMs,
    required int expiresAtUnixMs,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,96}$').hasMatch(executionId) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(sourceTaskId) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(sourceStepId)) {
      throw const PeerTaskExecutionException('معرّفات طلب التنفيذ غير صالحة.');
    }
    if (goal.trim().isEmpty ||
        goal.length > 100000 ||
        objective.trim().isEmpty ||
        objective.length > 100000 ||
        expectedOutput.length > 100000) {
      throw const PeerTaskExecutionException(
        'الهدف أو وصف الخطوة أو المخرج المتوقع غير صالح.',
      );
    }
    if (createdAtUnixMs <= 0 ||
        expiresAtUnixMs <= createdAtUnixMs ||
        expiresAtUnixMs - createdAtUnixMs >
            peerTaskExecutionRequestLifetime.inMilliseconds) {
      throw const PeerTaskExecutionException(
        'نافذة صلاحية طلب التنفيذ غير صالحة.',
      );
    }
    if (dependencies.length > peerTaskExecutionMaximumDependencies) {
      throw const PeerTaskExecutionException(
        'عدد مخرجات الاعتماديات يتجاوز حد الرسالة.',
      );
    }
    final dependencyIds = <String>{};
    for (final dependency in dependencies) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(dependency.stepId) ||
          !dependencyIds.add(dependency.stepId) ||
          dependency.agentName.trim().isEmpty ||
          dependency.agentName.length > 128 ||
          dependency.output.length > 100000) {
        throw const PeerTaskExecutionException(
          'تحتوي مخرجات الاعتماديات على معرّف مكرر أو محتوى غير صالح.',
        );
      }
    }
  }

  static Map<String, Object?> _coreMap({
    required String executionId,
    required String sourceTaskId,
    required String sourceStepId,
    required String goal,
    required String objective,
    required String expectedOutput,
    required List<PeerTaskDependencyResult> dependencies,
    required int createdAtUnixMs,
    required int expiresAtUnixMs,
  }) => {
        'version': peerTaskExecutionVersion,
        'execution_id': executionId,
        'source_task_id': sourceTaskId,
        'source_step_id': sourceStepId,
        'goal': goal.trim(),
        'objective': objective.trim(),
        'expected_output': expectedOutput.trim(),
        'dependencies': dependencies.map((item) => item.toMap()).toList(),
        'created_at_unix_ms': createdAtUnixMs,
        'expires_at_unix_ms': expiresAtUnixMs,
      };

  static void _validateWireSize(Map<String, Object?> message) {
    if (utf8.encode(jsonEncode(message)).length > peerTaskExecutionMaximumBytes) {
      throw const PeerTaskExecutionException(
        'طلب التنفيذ أكبر من ميزانية إطار النقل الآمن.',
      );
    }
  }
}

class PeerTaskExecutionResult {
  const PeerTaskExecutionResult({
    required this.executionId,
    required this.outcome,
    required this.outputText,
    required this.completedAtUnixMs,
    required this.payloadSha256,
    this.error,
  });

  final String executionId;
  final String outcome;
  final String outputText;
  final String? error;
  final int completedAtUnixMs;
  final String payloadSha256;

  static Future<PeerTaskExecutionResult> create({
    required String executionId,
    required String outcome,
    required String outputText,
    String? error,
    required int completedAtUnixMs,
  }) async {
    _validate(
      executionId: executionId,
      outcome: outcome,
      outputText: outputText,
      error: error,
      completedAtUnixMs: completedAtUnixMs,
    );
    final core = _coreMap(
      executionId: executionId,
      outcome: outcome,
      outputText: outputText,
      error: error,
      completedAtUnixMs: completedAtUnixMs,
    );
    final digest = await Sha256().hash(utf8.encode(jsonEncode(core)));
    final result = PeerTaskExecutionResult(
      executionId: executionId,
      outcome: outcome,
      outputText: outputText,
      error: error,
      completedAtUnixMs: completedAtUnixMs,
      payloadSha256: _hex(digest.bytes),
    );
    _validateWireSize(result.toMessage());
    return result;
  }

  static Future<PeerTaskExecutionResult> fromMessage(
    Map<String, Object?> message,
  ) async {
    if (message['kind'] != 'task_execution_result' ||
        message['version'] != peerTaskExecutionVersion) {
      throw const PeerTaskExecutionException(
        'إصدار نتيجة التنفيذ الموزّع غير مدعوم.',
      );
    }
    final executionId = message['execution_id'];
    final outcome = message['outcome'];
    final outputText = message['output_text'];
    final error = message['error'];
    final completedAt = message['completed_at_unix_ms'];
    final suppliedHash = message['payload_sha256'];
    if (executionId is! String ||
        outcome is! String ||
        outputText is! String ||
        (error != null && error is! String) ||
        completedAt is! int ||
        suppliedHash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(suppliedHash)) {
      throw const PeerTaskExecutionException(
        'حقول نتيجة التنفيذ غير مكتملة أو غير صالحة.',
      );
    }
    _validate(
      executionId: executionId,
      outcome: outcome,
      outputText: outputText,
      error: error as String?,
      completedAtUnixMs: completedAt,
    );
    final core = _coreMap(
      executionId: executionId,
      outcome: outcome,
      outputText: outputText,
      error: error as String?,
      completedAtUnixMs: completedAt,
    );
    final digest = await Sha256().hash(utf8.encode(jsonEncode(core)));
    final actualHash = _hex(digest.bytes);
    if (!_constantTimeEquals(actualHash, suppliedHash)) {
      throw const PeerTaskExecutionException(
        'فشل التحقق من بصمة نتيجة التنفيذ.',
      );
    }
    final result = PeerTaskExecutionResult(
      executionId: executionId,
      outcome: outcome,
      outputText: outputText,
      error: error as String?,
      completedAtUnixMs: completedAt,
      payloadSha256: actualHash,
    );
    _validateWireSize(result.toMessage());
    return result;
  }

  Map<String, Object?> toMessage() => {
        'kind': 'task_execution_result',
        'version': peerTaskExecutionVersion,
        'execution_id': executionId,
        'outcome': outcome,
        'output_text': outputText,
        'error': error,
        'completed_at_unix_ms': completedAtUnixMs,
        'payload_sha256': payloadSha256,
      };

  static void _validate({
    required String executionId,
    required String outcome,
    required String outputText,
    required String? error,
    required int completedAtUnixMs,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,96}$').hasMatch(executionId) ||
        !const {'succeeded', 'failed', 'cancelled'}.contains(outcome) ||
        completedAtUnixMs <= 0 ||
        outputText.length > 450000 ||
        (error?.length ?? 0) > 12000 ||
        (outcome == 'succeeded' &&
            (outputText.trim().isEmpty || error != null)) ||
        (outcome != 'succeeded' && (error == null || error.trim().isEmpty))) {
      throw const PeerTaskExecutionException('بيانات نتيجة التنفيذ غير صالحة.');
    }
  }

  static Map<String, Object?> _coreMap({
    required String executionId,
    required String outcome,
    required String outputText,
    required String? error,
    required int completedAtUnixMs,
  }) => {
        'version': peerTaskExecutionVersion,
        'execution_id': executionId,
        'outcome': outcome,
        'output_text': outputText,
        'error': error,
        'completed_at_unix_ms': completedAtUnixMs,
      };

  static void _validateWireSize(Map<String, Object?> message) {
    if (utf8.encode(jsonEncode(message)).length > peerTaskExecutionMaximumBytes) {
      throw const PeerTaskExecutionException(
        'نتيجة التنفيذ أكبر من ميزانية إطار النقل الآمن.',
      );
    }
  }
}

enum PeerTaskExecutionStatus {
  queued,
  awaitingApproval,
  approved,
  running,
  succeeded,
  failed,
  cancelled,
  rejected,
  interrupted,
}

extension PeerTaskExecutionStatusWire on PeerTaskExecutionStatus {
  String get wireName => switch (this) {
        PeerTaskExecutionStatus.queued => 'queued',
        PeerTaskExecutionStatus.awaitingApproval => 'awaiting_approval',
        PeerTaskExecutionStatus.approved => 'approved',
        PeerTaskExecutionStatus.running => 'running',
        PeerTaskExecutionStatus.succeeded => 'succeeded',
        PeerTaskExecutionStatus.failed => 'failed',
        PeerTaskExecutionStatus.cancelled => 'cancelled',
        PeerTaskExecutionStatus.rejected => 'rejected',
        PeerTaskExecutionStatus.interrupted => 'interrupted',
      };
}

PeerTaskExecutionStatus parsePeerTaskExecutionStatus(String value) =>
    switch (value) {
      'queued' => PeerTaskExecutionStatus.queued,
      'awaiting_approval' => PeerTaskExecutionStatus.awaitingApproval,
      'approved' => PeerTaskExecutionStatus.approved,
      'running' => PeerTaskExecutionStatus.running,
      'succeeded' => PeerTaskExecutionStatus.succeeded,
      'failed' => PeerTaskExecutionStatus.failed,
      'cancelled' => PeerTaskExecutionStatus.cancelled,
      'rejected' => PeerTaskExecutionStatus.rejected,
      'interrupted' => PeerTaskExecutionStatus.interrupted,
      _ => throw PeerTaskExecutionException('حالة تنفيذ غير معروفة: $value'),
    };

bool canTransitionPeerTaskExecution(
  PeerTaskExecutionStatus from,
  PeerTaskExecutionStatus to,
) {
  const allowed = <PeerTaskExecutionStatus, Set<PeerTaskExecutionStatus>>{
    PeerTaskExecutionStatus.queued: {
      PeerTaskExecutionStatus.awaitingApproval,
      PeerTaskExecutionStatus.rejected,
      PeerTaskExecutionStatus.interrupted,
      PeerTaskExecutionStatus.cancelled,
    },
    PeerTaskExecutionStatus.awaitingApproval: {
      PeerTaskExecutionStatus.approved,
      PeerTaskExecutionStatus.rejected,
      PeerTaskExecutionStatus.interrupted,
      PeerTaskExecutionStatus.queued,
      PeerTaskExecutionStatus.cancelled,
    },
    PeerTaskExecutionStatus.approved: {
      PeerTaskExecutionStatus.running,
      PeerTaskExecutionStatus.cancelled,
      PeerTaskExecutionStatus.interrupted,
    },
    PeerTaskExecutionStatus.running: {
      PeerTaskExecutionStatus.succeeded,
      PeerTaskExecutionStatus.failed,
      PeerTaskExecutionStatus.cancelled,
      PeerTaskExecutionStatus.interrupted,
    },
    PeerTaskExecutionStatus.interrupted: {
      PeerTaskExecutionStatus.queued,
      PeerTaskExecutionStatus.approved,
      PeerTaskExecutionStatus.failed,
      PeerTaskExecutionStatus.cancelled,
    },
  };
  return allowed[from]?.contains(to) ?? false;
}

class PeerTaskExecutionRecord {
  const PeerTaskExecutionRecord({
    required this.executionId,
    required this.deviceId,
    required this.direction,
    required this.status,
    required this.sourceTaskId,
    required this.sourceStepKey,
    required this.requestJson,
    required this.requestSha256,
    required this.createdAtUnixMs,
    required this.updatedAtUnixMs,
    required this.expiresAtUnixMs,
    this.localAgentId,
    this.resultJson,
    this.resultSha256,
    this.resultAcknowledgedAtUnixMs,
    this.error,
  });

  final String executionId;
  final String deviceId;
  final String direction;
  final PeerTaskExecutionStatus status;
  final String sourceTaskId;
  final String sourceStepKey;
  final String? localAgentId;
  final String requestJson;
  final String requestSha256;
  final String? resultJson;
  final String? resultSha256;
  final int? resultAcknowledgedAtUnixMs;
  final String? error;
  final int createdAtUnixMs;
  final int updatedAtUnixMs;
  final int expiresAtUnixMs;

  factory PeerTaskExecutionRecord.fromMap(Map<String, Object?> row) =>
      PeerTaskExecutionRecord(
        executionId: row['execution_id']! as String,
        deviceId: row['device_id']! as String,
        direction: row['direction']! as String,
        status: parsePeerTaskExecutionStatus(row['status']! as String),
        sourceTaskId: row['source_task_id']! as String,
        sourceStepKey: row['source_step_key']! as String,
        localAgentId: row['local_agent_id'] as String?,
        requestJson: row['request_json']! as String,
        requestSha256: row['request_sha256']! as String,
        resultJson: row['result_json'] as String?,
        resultSha256: row['result_sha256'] as String?,
        resultAcknowledgedAtUnixMs: row['result_acknowledged_at_unix_ms'] as int?,
        error: row['error'] as String?,
        createdAtUnixMs: row['created_at_unix_ms']! as int,
        updatedAtUnixMs: row['updated_at_unix_ms']! as int,
        expiresAtUnixMs: row['expires_at_unix_ms']! as int,
      );
}

class PeerTaskExecutionRepository {
  PeerTaskExecutionRepository({LocalDatabase? database})
      : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<List<PeerTaskExecutionRecord>> list({
    String? direction,
    String? deviceId,
  }) async {
    final db = await _database.database;
    final where = <String>[];
    final args = <Object?>[];
    if (direction != null) {
      where.add('direction = ?');
      args.add(direction);
    }
    if (deviceId != null) {
      where.add('device_id = ?');
      args.add(deviceId);
    }
    final rows = await db.query(
      'peer_task_executions',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: where.isEmpty ? null : args,
      orderBy: 'updated_at_unix_ms DESC, execution_id DESC',
    );
    return rows.map(PeerTaskExecutionRecord.fromMap).toList(growable: false);
  }

  Future<PeerTaskExecutionRecord?> get(String executionId) async {
    final db = await _database.database;
    final rows = await db.query(
      'peer_task_executions',
      where: 'execution_id = ?',
      whereArgs: [executionId],
      limit: 1,
    );
    return rows.isEmpty ? null : PeerTaskExecutionRecord.fromMap(rows.single);
  }

  Future<void> createOutgoing({
    required String deviceId,
    required PeerTaskExecutionRequest request,
    required String sourceTaskId,
    required String sourceStepKey,
  }) async {
    if (request.sourceTaskId != sourceTaskId ||
        request.sourceStepId != sourceStepKey ||
        deviceId.trim().isEmpty) {
      throw const PeerTaskExecutionException(
        'بيانات سجل الإرسال لا تطابق طلب التنفيذ أو الجهاز المقصود.',
      );
    }
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final taskRows = await txn.query(
        'agent_tasks',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [sourceTaskId],
        limit: 1,
      );
      if (taskRows.isEmpty ||
          !{'planned', 'interrupted'}.contains(taskRows.single['status'])) {
        throw const PeerTaskExecutionException(
          'تغيّرت حالة المهمة؛ لا يمكن حجز خطوة بعيدة الآن.',
        );
      }
      final stepRows = await txn.query(
        'agent_task_steps',
        columns: ['status'],
        where: 'task_id = ? AND step_key = ?',
        whereArgs: [sourceTaskId, sourceStepKey],
        limit: 1,
      );
      if (stepRows.isEmpty ||
          !{'pending', 'interrupted'}.contains(stepRows.single['status'])) {
        throw const PeerTaskExecutionException(
          'الخطوة لم تعد متاحة للحجز البعيد.',
        );
      }
      final activeRows = await txn.query(
        'peer_task_executions',
        columns: ['execution_id'],
        where: "direction = ? AND source_task_id = ? AND source_step_key = ? AND status IN (?, ?, ?, ?)",
        whereArgs: [
          'outgoing',
          sourceTaskId,
          sourceStepKey,
          PeerTaskExecutionStatus.queued.wireName,
          PeerTaskExecutionStatus.awaitingApproval.wireName,
          PeerTaskExecutionStatus.approved.wireName,
          PeerTaskExecutionStatus.running.wireName,
        ],
        limit: 1,
      );
      if (activeRows.isNotEmpty) {
        throw const PeerTaskExecutionException(
          'هذه الخطوة لها طلب تنفيذ بعيد نشط بالفعل؛ لن تُرسل إلى جهاز ثانٍ.',
        );
      }
      await txn.insert('peer_task_executions', {
        'execution_id': request.executionId,
        'device_id': deviceId,
        'direction': 'outgoing',
        'status': PeerTaskExecutionStatus.queued.wireName,
        'source_task_id': sourceTaskId,
        'source_step_key': sourceStepKey,
        'local_agent_id': null,
        'request_json': jsonEncode(request.toMessage()),
        'request_sha256': request.payloadSha256,
        'result_json': null,
        'result_sha256': null,
        'error': null,
        'created_at_unix_ms': request.createdAtUnixMs,
        'updated_at_unix_ms': now,
        'expires_at_unix_ms': request.expiresAtUnixMs,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
    });
  }

  /// Store an authenticated incoming request before prompting the user. Exact
  /// retransmissions are idempotent; any ID reuse with changed content fails.
  Future<bool> storeIncoming({
    required String deviceId,
    required PeerTaskExecutionRequest request,
  }) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'peer_task_executions',
        where: 'execution_id = ?',
        whereArgs: [request.executionId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final existing = rows.single;
        if (existing['direction'] != 'incoming' ||
            existing['device_id'] != deviceId ||
            existing['request_sha256'] != request.payloadSha256) {
          throw const PeerTaskExecutionException(
            'تعارض في معرّف طلب التنفيذ؛ رُفضت إعادة استخدامه بمحتوى مختلف.',
          );
        }
        return false;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.insert('peer_task_executions', {
        'execution_id': request.executionId,
        'device_id': deviceId,
        'direction': 'incoming',
        'status': PeerTaskExecutionStatus.awaitingApproval.wireName,
        'source_task_id': request.sourceTaskId,
        'source_step_key': request.sourceStepId,
        'local_agent_id': null,
        'request_json': jsonEncode(request.toMessage()),
        'request_sha256': request.payloadSha256,
        'result_json': null,
        'result_sha256': null,
        'error': null,
        'created_at_unix_ms': request.createdAtUnixMs,
        'updated_at_unix_ms': now,
        'expires_at_unix_ms': request.expiresAtUnixMs,
      });
      return true;
    });
  }

  Future<void> transition({
    required String executionId,
    required PeerTaskExecutionStatus from,
    required PeerTaskExecutionStatus to,
    String? localAgentId,
    String? error,
  }) async {
    if (!canTransitionPeerTaskExecution(from, to)) {
      throw PeerTaskExecutionException(
        'انتقال حالة التنفيذ غير مسموح: ${from.wireName} → ${to.wireName}.',
      );
    }
    final db = await _database.database;
    final values = <String, Object?>{
      'status': to.wireName,
      'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      'error': error,
    };
    if (localAgentId != null) values['local_agent_id'] = localAgentId;
    final changed = await db.update(
      'peer_task_executions',
      values,
      where: 'execution_id = ? AND status = ?',
      whereArgs: [executionId, from.wireName],
    );
    if (changed != 1) {
      throw const PeerTaskExecutionException(
        'تغيّرت حالة طلب التنفيذ أو لم يعد موجوداً؛ لم يُطبق الانتقال.',
      );
    }
  }

  /// Persists a terminal result once. A duplicate identical result is safe;
  /// a different result for the same execution ID is treated as a conflict.
  Future<bool> storeResult({
    required PeerTaskExecutionResult result,
  }) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'peer_task_executions',
        where: 'execution_id = ?',
        whereArgs: [result.executionId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw const PeerTaskExecutionException('طلب التنفيذ غير موجود.');
      }
      final existing = rows.single;
      final status = parsePeerTaskExecutionStatus(existing['status']! as String);
      final priorHash = existing['result_sha256'] as String?;
      if (priorHash != null) {
        if (priorHash != result.payloadSha256) {
          throw const PeerTaskExecutionException(
            'وصلت نتيجة مختلفة لمعرف تنفيذ اكتملت معالجته مسبقاً.',
          );
        }
        return false;
      }
      if (status != PeerTaskExecutionStatus.running &&
          status != PeerTaskExecutionStatus.interrupted) {
        throw const PeerTaskExecutionException(
          'لا يمكن حفظ نتيجة لطلب لم يصل إلى حالة التنفيذ.',
        );
      }
      final nextStatus = switch (result.outcome) {
        'succeeded' => PeerTaskExecutionStatus.succeeded,
        'failed' => PeerTaskExecutionStatus.failed,
        'cancelled' => PeerTaskExecutionStatus.cancelled,
        _ => throw const PeerTaskExecutionException('نتيجة التنفيذ غير مدعومة.'),
      };
      await txn.update(
        'peer_task_executions',
        {
          'status': nextStatus.wireName,
          'result_json': jsonEncode(result.toMessage()),
          'result_sha256': result.payloadSha256,
          'error': result.error,
          'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'execution_id = ? AND result_sha256 IS NULL',
        whereArgs: [result.executionId],
      );
      return true;
    });
  }

  /// Marks a terminal incoming result as durably acknowledged by the exact
  /// paired sender. Duplicate acknowledgements are harmless.
  Future<bool> markResultAcknowledged({
    required String executionId,
    required String deviceId,
    required String resultSha256,
  }) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'peer_task_executions',
        where: 'execution_id = ? AND device_id = ? AND direction = ?',
        whereArgs: [executionId, deviceId, 'incoming'],
        limit: 1,
      );
      if (rows.isEmpty) {
        return false;
      }
      final row = rows.single;
      final status = parsePeerTaskExecutionStatus(row['status']! as String);
      if (row['result_json'] == null ||
          row['result_sha256'] != resultSha256 ||
          !{
            PeerTaskExecutionStatus.succeeded,
            PeerTaskExecutionStatus.failed,
            PeerTaskExecutionStatus.cancelled,
          }.contains(status)) {
        throw const PeerTaskExecutionException(
          'إقرار النتيجة لا يطابق نتيجة نهائية محفوظة لهذا الجهاز.',
        );
      }
      if (row['result_acknowledged_at_unix_ms'] != null) {
        return false;
      }
      final changed = await txn.update(
        'peer_task_executions',
        {
          'result_acknowledged_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'execution_id = ? AND device_id = ? AND direction = ? AND result_sha256 = ? AND result_acknowledged_at_unix_ms IS NULL',
        whereArgs: [executionId, deviceId, 'incoming', resultSha256],
      );
      return changed == 1;
    });
  }

  Future<int> recoverRunningAsInterrupted() async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final interrupted = await txn.update(
        'peer_task_executions',
        {
          'status': PeerTaskExecutionStatus.interrupted.wireName,
          'error': 'انقطع التطبيق أثناء تنفيذ مهمة موزعة؛ لن تُعاد تلقائياً لتجنب التكرار.',
          'updated_at_unix_ms': now,
        },
        where: 'status IN (?, ?)',
        whereArgs: [
          PeerTaskExecutionStatus.running.wireName,
          PeerTaskExecutionStatus.approved.wireName,
        ],
      );
      // A request in the sender's outbox may have been persisted as awaiting
      // approval immediately before process death. Re-send the exact same ID;
      // receiver-side idempotency prevents a second execution.
      await txn.update(
        'peer_task_executions',
        {
          'status': PeerTaskExecutionStatus.queued.wireName,
          'error': 'أُعيد وضع طلب الإرسال في قائمة الانتظار بعد إعادة تشغيل التطبيق.',
          'updated_at_unix_ms': now,
        },
        where: 'direction = ? AND status = ?',
        whereArgs: [
          'outgoing',
          PeerTaskExecutionStatus.awaitingApproval.wireName,
        ],
      );
      return interrupted;
    });
  }
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

bool _constantTimeEquals(String left, String right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
  }
  return difference == 0;
}
