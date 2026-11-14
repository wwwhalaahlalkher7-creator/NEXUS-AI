import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import '../orchestration/agent_task_plan.dart';

const peerTaskTransferVersion = 1;
const peerTaskProposalMaximumBytes = 512 * 1024;

class PeerTaskTransferException implements Exception {
  const PeerTaskTransferException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PeerTaskProposalRequest {
  const PeerTaskProposalRequest({
    required this.transferId,
    required this.deviceId,
    required this.displayName,
    required this.goal,
    required this.planJson,
    required this.stepCount,
  });

  final String transferId;
  final String deviceId;
  final String displayName;
  final String goal;
  final String planJson;
  final int stepCount;
}

/// A proposal is data only. It is never executed by the receiving device.
class PeerTaskProposalEnvelope {
  const PeerTaskProposalEnvelope({
    required this.transferId,
    required this.sourceTaskId,
    required this.goal,
    required this.planJson,
    required this.createdAtUnixMs,
    required this.payloadSha256,
  });

  final String transferId;
  final String sourceTaskId;
  final String goal;
  final String planJson;
  final int createdAtUnixMs;
  final String payloadSha256;

  static Future<PeerTaskProposalEnvelope> create({
    required String transferId,
    required String sourceTaskId,
    required String goal,
    required String planJson,
    required int createdAtUnixMs,
  }) async {
    _validateContent(
      transferId: transferId,
      sourceTaskId: sourceTaskId,
      goal: goal,
      planJson: planJson,
      createdAtUnixMs: createdAtUnixMs,
    );
    final core = _coreMap(
      transferId: transferId,
      sourceTaskId: sourceTaskId,
      goal: goal,
      planJson: planJson,
      createdAtUnixMs: createdAtUnixMs,
    );
    final digest = await Sha256().hash(utf8.encode(jsonEncode(core)));
    final envelope = PeerTaskProposalEnvelope(
      transferId: transferId,
      sourceTaskId: sourceTaskId,
      goal: goal.trim(),
      planJson: planJson,
      createdAtUnixMs: createdAtUnixMs,
      payloadSha256: _hex(digest.bytes),
    );
    _validateWireSize(envelope);
    return envelope;
  }

  static Future<PeerTaskProposalEnvelope> fromMessage(
    Map<String, Object?> message,
  ) async {
    if (message['kind'] != 'task_proposal' ||
        message['version'] != peerTaskTransferVersion) {
      throw const PeerTaskTransferException('بروتوكول مقترح المهمة غير مدعوم.');
    }
    final transferId = message['transfer_id'];
    final sourceTaskId = message['source_task_id'];
    final goal = message['goal'];
    final planJson = message['plan_json'];
    final createdAt = message['created_at_unix_ms'];
    final suppliedHash = message['payload_sha256'];
    if (transferId is! String ||
        sourceTaskId is! String ||
        goal is! String ||
        planJson is! String ||
        createdAt is! int ||
        suppliedHash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(suppliedHash)) {
      throw const PeerTaskTransferException('حقول مقترح المهمة غير مكتملة أو غير صالحة.');
    }
    _validateContent(
      transferId: transferId,
      sourceTaskId: sourceTaskId,
      goal: goal,
      planJson: planJson,
      createdAtUnixMs: createdAt,
    );
    final core = _coreMap(
      transferId: transferId,
      sourceTaskId: sourceTaskId,
      goal: goal,
      planJson: planJson,
      createdAtUnixMs: createdAt,
    );
    final digest = await Sha256().hash(utf8.encode(jsonEncode(core)));
    final actualHash = _hex(digest.bytes);
    if (!_constantTimeStringEquals(actualHash, suppliedHash)) {
      throw const PeerTaskTransferException('فشل التحقق من سلامة مقترح المهمة.');
    }
    final envelope = PeerTaskProposalEnvelope(
      transferId: transferId,
      sourceTaskId: sourceTaskId,
      goal: goal.trim(),
      planJson: planJson,
      createdAtUnixMs: createdAt,
      payloadSha256: actualHash,
    );
    _validateWireSize(envelope);
    return envelope;
  }

  Map<String, Object?> toMessage() => {
        'kind': 'task_proposal',
        'version': peerTaskTransferVersion,
        'transfer_id': transferId,
        'source_task_id': sourceTaskId,
        'goal': goal,
        'plan_json': planJson,
        'created_at_unix_ms': createdAtUnixMs,
        'payload_sha256': payloadSha256,
      };

  static void _validateWireSize(PeerTaskProposalEnvelope envelope) {
    final wireBytes = utf8.encode(jsonEncode(envelope.toMessage())).length;
    if (wireBytes > peerTaskProposalMaximumBytes) {
      throw const PeerTaskTransferException(
        'مقترح المهمة يتجاوز ميزانية إطار النقل بعد ترميز JSON؛ قلّص نص الخطة.',
      );
    }
  }

  static Map<String, Object?> _coreMap({
    required String transferId,
    required String sourceTaskId,
    required String goal,
    required String planJson,
    required int createdAtUnixMs,
  }) => {
        'version': peerTaskTransferVersion,
        'transfer_id': transferId,
        'source_task_id': sourceTaskId,
        'goal': goal.trim(),
        'plan_json': planJson,
        'created_at_unix_ms': createdAtUnixMs,
      };

  static void _validateContent({
    required String transferId,
    required String sourceTaskId,
    required String goal,
    required String planJson,
    required int createdAtUnixMs,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,96}$').hasMatch(transferId) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(sourceTaskId)) {
      throw const PeerTaskTransferException('معرّف النقل أو المهمة غير صالح.');
    }
    if (goal.trim().isEmpty || goal.length > 100000 || planJson.isEmpty) {
      throw const PeerTaskTransferException('هدف المهمة أو مخططها فارغ أو أكبر من المسموح للنقل.');
    }
    if (createdAtUnixMs <= 0) {
      throw const PeerTaskTransferException('وقت إنشاء المهمة غير صالح.');
    }
    final bytes = utf8.encode(planJson).length + utf8.encode(goal).length;
    if (bytes > peerTaskProposalMaximumBytes) {
      throw const PeerTaskTransferException(
        'مقترح المهمة أكبر من إطار النقل الحالي. أرسل خطة أصغر؛ نقل المرفقات المجزأ سيضاف لاحقاً.',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(planJson);
    } on FormatException {
      throw const PeerTaskTransferException('مخطط المهمة ليس JSON صالحاً.');
    }
    if (decoded is! Map ||
        decoded['schema_version'] != 1 ||
        decoded['goal'] is! String ||
        (decoded['goal'] as String).trim() != goal.trim() ||
        decoded['steps'] is! List ||
        (decoded['steps'] as List).isEmpty) {
      throw const PeerTaskTransferException('بنية مخطط المهمة غير متوافقة.');
    }
    final ids = <String>{};
    final dependencies = <String, List<String>>{};
    for (final raw in decoded['steps'] as List) {
      if (raw is! Map) {
        throw const PeerTaskTransferException('إحدى خطوات المهمة غير صالحة.');
      }
      final id = raw['id'];
      final agentId = raw['agent_id'];
      final objective = raw['objective'];
      final expected = raw['expected_output'];
      final rawDependencies = raw['depends_on'] ?? const <Object?>[];
      if (id is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id) ||
          !ids.add(id) ||
          agentId is! String ||
          agentId.isEmpty ||
          agentId.length > 128 ||
          objective is! String ||
          objective.trim().isEmpty ||
          objective.length > 100000 ||
          expected is! String ||
          expected.length > 100000 ||
          rawDependencies is! List ||
          rawDependencies.any((value) => value is! String)) {
        throw const PeerTaskTransferException('حقول إحدى خطوات المهمة غير صالحة.');
      }
      final deps = rawDependencies.cast<String>();
      if (deps.toSet().length != deps.length || deps.contains(id)) {
        throw const PeerTaskTransferException('اعتماديات إحدى الخطوات مكررة أو ذاتية.');
      }
      dependencies[id] = deps;
    }
    for (final entry in dependencies.entries) {
      if (entry.value.any((id) => !ids.contains(id))) {
        throw const PeerTaskTransferException('المهمة تشير إلى اعتماد غير موجود.');
      }
    }
    // Iterative Kahn traversal avoids deep recursive stacks for untrusted plans.
    final remainingDependencies = <String, int>{
      for (final id in ids) id: dependencies[id]!.length,
    };
    final dependents = <String, List<String>>{
      for (final id in ids) id: <String>[],
    };
    for (final entry in dependencies.entries) {
      for (final dependency in entry.value) {
        dependents[dependency]!.add(entry.key);
      }
    }
    final ready = <String>[
      for (final entry in remainingDependencies.entries)
        if (entry.value == 0) entry.key,
    ];
    var visitedCount = 0;
    while (ready.isNotEmpty) {
      final id = ready.removeLast();
      visitedCount++;
      for (final dependent in dependents[id]!) {
        final remaining = remainingDependencies[dependent]! - 1;
        remainingDependencies[dependent] = remaining;
        if (remaining == 0) ready.add(dependent);
      }
    }
    if (visitedCount != ids.length) {
      throw const PeerTaskTransferException('مخطط المهمة يحتوي دورة اعتماد.');
    }
  }
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

bool _constantTimeStringEquals(String left, String right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
  }
  return difference == 0;
}

class RemoteTaskTransferRecord {
  const RemoteTaskTransferRecord({
    required this.transferId,
    required this.deviceId,
    required this.direction,
    required this.status,
    required this.sourceTaskId,
    required this.goal,
    required this.planJson,
    required this.payloadSha256,
    required this.createdAtUnixMs,
    required this.updatedAtUnixMs,
    this.lastError,
    this.importedTaskId,
  });

  final String transferId;
  final String deviceId;
  final String direction;
  final String status;
  final String sourceTaskId;
  final String goal;
  final String planJson;
  final String payloadSha256;
  final int createdAtUnixMs;
  final int updatedAtUnixMs;
  final String? lastError;
  final String? importedTaskId;

  factory RemoteTaskTransferRecord.fromMap(Map<String, Object?> row) =>
      RemoteTaskTransferRecord(
        transferId: row['transfer_id']! as String,
        deviceId: row['device_id']! as String,
        direction: row['direction']! as String,
        status: row['status']! as String,
        sourceTaskId: row['source_task_id']! as String,
        goal: row['goal']! as String,
        planJson: row['plan_json']! as String,
        payloadSha256: row['payload_sha256']! as String,
        createdAtUnixMs: row['created_at_unix_ms']! as int,
        updatedAtUnixMs: row['updated_at_unix_ms']! as int,
        lastError: row['last_error'] as String?,
        importedTaskId: row['imported_task_id'] as String?,
      );

  int get stepCount {
    try {
      final decoded = jsonDecode(planJson);
      return decoded is Map && decoded['steps'] is List
          ? (decoded['steps'] as List).length
          : 0;
    } on FormatException {
      return 0;
    }
  }
}

/// Rewrites foreign agent identifiers to explicitly selected local agents.
/// It preserves the untrusted plan content; AgentTaskPlanParser performs the
/// authoritative local-agent and dependency validation afterwards.
class RemoteTaskPlanRemapper {
  const RemoteTaskPlanRemapper._();

  static String remap(
    String sourcePlanJson,
    Map<String, String> localAgentByRemoteId,
  ) {
    Object? decoded;
    try {
      decoded = jsonDecode(sourcePlanJson);
    } on FormatException {
      throw const PeerTaskTransferException('مخطط المهمة المستلمة ليس JSON صالحاً.');
    }
    if (decoded is! Map || decoded['steps'] is! List) {
      throw const PeerTaskTransferException('بنية المخطط المستلم غير صالحة للاستيراد.');
    }
    final remappedSteps = <Map<String, Object?>>[];
    for (final raw in decoded['steps'] as List) {
      if (raw is! Map || raw['agent_id'] is! String) {
        throw const PeerTaskTransferException('تعذر تحديد وكيل إحدى الخطوات المستلمة.');
      }
      final remoteAgentId = raw['agent_id']! as String;
      final localAgentId = localAgentByRemoteId[remoteAgentId];
      if (localAgentId == null || localAgentId.trim().isEmpty) {
        throw PeerTaskTransferException('لم يتم تعيين وكيل محلي للوكيل المستلم "$remoteAgentId".');
      }
      remappedSteps.add({
        for (final entry in raw.entries) entry.key.toString(): entry.value,
        'agent_id': localAgentId,
      });
    }
    return jsonEncode({
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
      'steps': remappedSteps,
    });
  }
}

class RemoteTaskTransferRepository {
  RemoteTaskTransferRepository({LocalDatabase? database})
      : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<List<RemoteTaskTransferRecord>> list({String? direction}) async {
    final db = await _database.database;
    final rows = await db.query(
      'remote_task_transfers',
      where: direction == null ? null : 'direction = ?',
      whereArgs: direction == null ? null : [direction],
      orderBy: 'updated_at_unix_ms DESC, transfer_id DESC',
    );
    return rows.map(RemoteTaskTransferRecord.fromMap).toList(growable: false);
  }

  Future<RemoteTaskTransferRecord?> get(String transferId) async {
    final db = await _database.database;
    final rows = await db.query(
      'remote_task_transfers',
      where: 'transfer_id = ?',
      whereArgs: [transferId],
      limit: 1,
    );
    return rows.isEmpty ? null : RemoteTaskTransferRecord.fromMap(rows.single);
  }

  Future<void> createOutgoing({
    required PeerTaskProposalEnvelope envelope,
    required String deviceId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('remote_task_transfers', {
      'transfer_id': envelope.transferId,
      'device_id': deviceId,
      'direction': 'outgoing',
      'status': 'queued',
      'source_task_id': envelope.sourceTaskId,
      'goal': envelope.goal,
      'plan_json': envelope.planJson,
      'payload_sha256': envelope.payloadSha256,
      'created_at_unix_ms': envelope.createdAtUnixMs,
      'updated_at_unix_ms': now,
      'last_error': null,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  /// Returns true when newly stored, false for an exact duplicate delivery.
  Future<bool> storeIncoming({
    required PeerTaskProposalEnvelope envelope,
    required String deviceId,
    String decision = 'kept',
  }) async {
    if (!const {'kept', 'declined'}.contains(decision)) {
      throw ArgumentError.value(decision, 'decision');
    }
    final db = await _database.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'remote_task_transfers',
        where: 'transfer_id = ?',
        whereArgs: [envelope.transferId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final existing = rows.single;
        if (existing['direction'] != 'incoming' ||
            existing['device_id'] != deviceId ||
            existing['payload_sha256'] != envelope.payloadSha256 ||
            existing['status'] != decision) {
          throw const PeerTaskTransferException(
            'تعارض في معرّف النقل؛ رُفضت الرسالة ولم تُستبدل البيانات السابقة.',
          );
        }
        return false;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.insert('remote_task_transfers', {
        'transfer_id': envelope.transferId,
        'device_id': deviceId,
        'direction': 'incoming',
        'status': decision,
        'source_task_id': envelope.sourceTaskId,
        'goal': envelope.goal,
        'plan_json': envelope.planJson,
        'payload_sha256': envelope.payloadSha256,
        'created_at_unix_ms': envelope.createdAtUnixMs,
        'updated_at_unix_ms': now,
        'last_error': null,
      });
      return true;
    });
  }

  /// Atomically converts a kept incoming proposal to a local planned task.
  /// Repeated imports return the same task ID. Every mapped agent must still
  /// exist and be ready at commit time.
  Future<String> importIncomingAsLocalTask({
    required String transferId,
    required AgentTaskPlan plan,
    String? plannerAgentId,
  }) async {
    if (plan.goal.trim().isEmpty || plan.steps.isEmpty) {
      throw const PeerTaskTransferException('الخطة المحلية غير صالحة للاستيراد.');
    }
    final db = await _database.database;
    return db.transaction((txn) async {
      final transferRows = await txn.query(
        'remote_task_transfers',
        where: 'transfer_id = ?',
        whereArgs: [transferId],
        limit: 1,
      );
      if (transferRows.isEmpty) {
        throw const PeerTaskTransferException('مقترح المهمة المستلم غير موجود.');
      }
      final transfer = transferRows.single;
      if (transfer['direction'] != 'incoming' || transfer['status'] != 'kept') {
        throw const PeerTaskTransferException('يمكن استيراد المقترحات الواردة المحفوظة فقط.');
      }
      if (transfer['goal'] != plan.goal.trim()) {
        throw const PeerTaskTransferException('هدف الخطة المحلية لا يطابق المقترح الأصلي.');
      }
      final importedTaskId = transfer['imported_task_id'] as String?;
      if (importedTaskId != null) {
        final existingTask = await txn.query(
          'agent_tasks',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [importedTaskId],
          limit: 1,
        );
        if (existingTask.isNotEmpty) return importedTaskId;
        throw const PeerTaskTransferException('مرجع الاستيراد السابق غير متسق؛ احذف المقترح وأعد مراجعته.');
      }

      final mappedAgentIds = plan.steps.map((step) => step.agentId).toSet().toList();
      final readyAgentRows = await txn.query(
        'agents',
        columns: ['id'],
        where: 'status = ?',
        whereArgs: ['ready'],
      );
      final readyAgentIds = readyAgentRows
          .map((row) => row['id']! as String)
          .toSet();
      if (mappedAgentIds.any((id) => !readyAgentIds.contains(id))) {
        throw const PeerTaskTransferException('أحد الوكلاء المحليين لم يعد جاهزاً؛ راجع التعيينات وأعد المحاولة.');
      }
      if (plannerAgentId != null) {
        final planner = await txn.query(
          'agents', columns: ['id'], where: 'id = ? AND status = ?',
          whereArgs: [plannerAgentId, 'ready'], limit: 1,
        );
        if (planner.isEmpty) {
          throw const PeerTaskTransferException('الوكيل المحلي المحدد للتخطيط لم يعد جاهزاً.');
        }
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = 'peer-import-$transferId';
      await txn.insert('agent_tasks', {
        'id': taskId,
        'goal': plan.goal.trim(),
        'planner_agent_id': plannerAgentId,
        'status': AgentTaskStatus.planned.name,
        'plan_json': plan.toJson(),
        'error': null,
        'created_at_unix_ms': now,
        'updated_at_unix_ms': now,
      });
      for (var index = 0; index < plan.steps.length; index++) {
        final step = plan.steps[index];
        await txn.insert('agent_task_steps', {
          'id': '$taskId-${step.id}',
          'task_id': taskId,
          'step_key': step.id,
          'ordinal': index,
          'agent_id': step.agentId,
          'objective': step.objective,
          'expected_output': step.expectedOutput,
          'depends_on_json': jsonEncode(step.dependsOn),
          'status': AgentTaskStepStatus.pending.name,
          'output_text': '',
          'error': null,
          'started_at_unix_ms': null,
          'finished_at_unix_ms': null,
        });
      }
      await txn.insert('agent_task_events', {
        'id': 'event-$now-${DateTime.now().microsecondsSinceEpoch}',
        'task_id': taskId,
        'step_key': null,
        'event_type': 'peer_proposal_imported',
        'message': 'استُورد مقترح جهاز مقترن بعد إعادة تعيين الوكلاء محلياً. لم يبدأ التنفيذ.',
        'payload_json': jsonEncode({
          'transfer_id': transferId,
          'source_device_id': transfer['device_id'],
          'source_task_id': transfer['source_task_id'],
        }),
        'created_at_unix_ms': now,
      });
      final changed = await txn.update(
        'remote_task_transfers',
        {'imported_task_id': taskId, 'updated_at_unix_ms': now},
        where: 'transfer_id = ? AND imported_task_id IS NULL AND status = ?',
        whereArgs: [transferId, 'kept'],
      );
      if (changed != 1) {
        throw const PeerTaskTransferException('تغيرت حالة المقترح أثناء الاستيراد؛ لم يتم تثبيت المهمة.');
      }
      return taskId;
    });
  }

  Future<void> updateOutgoing({
    required String transferId,
    required String status,
    String? error,
  }) async {
    if (!const {'queued', 'sent', 'rejected'}.contains(status)) {
      throw ArgumentError.value(status, 'status');
    }
    final db = await _database.database;
    await db.update(
      'remote_task_transfers',
      {
        'status': status,
        'last_error': error,
        'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: "transfer_id = ? AND direction = 'outgoing'",
      whereArgs: [transferId],
    );
  }

  Future<void> reviewIncoming(String transferId, {required bool keep}) async {
    final db = await _database.database;
    await db.update(
      'remote_task_transfers',
      {
        'status': keep ? 'kept' : 'declined',
        'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: "transfer_id = ? AND direction = 'incoming' AND status = 'pending_review'",
      whereArgs: [transferId],
    );
  }
}
