import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import 'agent_task_plan.dart';

class AgentTaskRecord {
  const AgentTaskRecord({
    required this.id,
    required this.goal,
    required this.status,
    required this.planJson,
    required this.createdAtUnixMs,
    required this.updatedAtUnixMs,
    this.plannerAgentId,
    this.error,
  });

  final String id;
  final String goal;
  final AgentTaskStatus status;
  final String planJson;
  final int createdAtUnixMs;
  final int updatedAtUnixMs;
  final String? plannerAgentId;
  final String? error;

  factory AgentTaskRecord.fromMap(Map<String, Object?> map) => AgentTaskRecord(
        id: map['id']! as String,
        goal: map['goal']! as String,
        status: AgentTaskStatus.values.byName(map['status']! as String),
        planJson: map['plan_json']! as String,
        createdAtUnixMs: map['created_at_unix_ms']! as int,
        updatedAtUnixMs: map['updated_at_unix_ms']! as int,
        plannerAgentId: map['planner_agent_id'] as String?,
        error: map['error'] as String?,
      );
}

class AgentTaskStepRecord {
  const AgentTaskStepRecord({
    required this.id,
    required this.taskId,
    required this.stepKey,
    required this.ordinal,
    required this.objective,
    required this.expectedOutput,
    required this.dependsOn,
    required this.status,
    required this.outputText,
    this.agentId,
    this.error,
    this.startedAtUnixMs,
    this.finishedAtUnixMs,
  });

  final String id;
  final String taskId;
  final String stepKey;
  final int ordinal;
  final String? agentId;
  final String objective;
  final String expectedOutput;
  final List<String> dependsOn;
  final AgentTaskStepStatus status;
  final String outputText;
  final String? error;
  final int? startedAtUnixMs;
  final int? finishedAtUnixMs;

  factory AgentTaskStepRecord.fromMap(Map<String, Object?> map) =>
      AgentTaskStepRecord(
        id: map['id']! as String,
        taskId: map['task_id']! as String,
        stepKey: map['step_key']! as String,
        ordinal: map['ordinal']! as int,
        agentId: map['agent_id'] as String?,
        objective: map['objective']! as String,
        expectedOutput: map['expected_output']! as String,
        dependsOn: (jsonDecode(map['depends_on_json']! as String) as List)
            .cast<String>(),
        status: AgentTaskStepStatus.values.byName(map['status']! as String),
        outputText: map['output_text']! as String,
        error: map['error'] as String?,
        startedAtUnixMs: map['started_at_unix_ms'] as int?,
        finishedAtUnixMs: map['finished_at_unix_ms'] as int?,
      );
}

class AgentTaskEventRecord {
  const AgentTaskEventRecord({
    required this.id,
    required this.taskId,
    required this.eventType,
    required this.message,
    required this.payloadJson,
    required this.createdAtUnixMs,
    this.stepKey,
  });

  final String id;
  final String taskId;
  final String? stepKey;
  final String eventType;
  final String message;
  final String payloadJson;
  final int createdAtUnixMs;

  factory AgentTaskEventRecord.fromMap(Map<String, Object?> map) =>
      AgentTaskEventRecord(
        id: map['id']! as String,
        taskId: map['task_id']! as String,
        stepKey: map['step_key'] as String?,
        eventType: map['event_type']! as String,
        message: map['message']! as String,
        payloadJson: map['payload_json']! as String,
        createdAtUnixMs: map['created_at_unix_ms']! as int,
      );
}

class AgentTaskRepository {
  AgentTaskRepository({LocalDatabase? database})
      : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<AgentTaskRecord> createPlanned({
    required AgentTaskPlan plan,
    String? plannerAgentId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'task-${DateTime.now().microsecondsSinceEpoch}';
    final task = AgentTaskRecord(
      id: id,
      goal: plan.goal,
      status: AgentTaskStatus.planned,
      planJson: plan.toJson(),
      plannerAgentId: plannerAgentId,
      createdAtUnixMs: now,
      updatedAtUnixMs: now,
    );
    await db.transaction((txn) async {
      await txn.insert('agent_tasks', {
        'id': task.id,
        'goal': task.goal,
        'planner_agent_id': task.plannerAgentId,
        'status': task.status.name,
        'plan_json': task.planJson,
        'error': null,
        'created_at_unix_ms': now,
        'updated_at_unix_ms': now,
      });
      for (var index = 0; index < plan.steps.length; index++) {
        final step = plan.steps[index];
        await txn.insert('agent_task_steps', {
          'id': '$id-${step.id}',
          'task_id': id,
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
      await _insertEvent(
        txn,
        taskId: id,
        eventType: 'plan_created',
        message: 'تم حفظ خطة المهمة محلياً.',
        payload: {'step_count': plan.steps.length},
      );
    });
    return task;
  }

  Future<List<AgentTaskRecord>> list() async {
    final db = await _database.database;
    final rows = await db.query(
      'agent_tasks',
      orderBy: 'updated_at_unix_ms DESC, id DESC',
    );
    return rows.map(AgentTaskRecord.fromMap).toList(growable: false);
  }

  Future<AgentTaskRecord?> get(String id) async {
    final db = await _database.database;
    final rows = await db.query(
      'agent_tasks',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : AgentTaskRecord.fromMap(rows.single);
  }

  Future<List<AgentTaskStepRecord>> steps(String taskId) async {
    final db = await _database.database;
    final rows = await db.query(
      'agent_task_steps',
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: 'ordinal ASC',
    );
    return rows.map(AgentTaskStepRecord.fromMap).toList(growable: false);
  }

  Future<List<AgentTaskEventRecord>> events(String taskId) async {
    final db = await _database.database;
    final rows = await db.query(
      'agent_task_events',
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: 'created_at_unix_ms ASC, id ASC',
    );
    return rows.map(AgentTaskEventRecord.fromMap).toList(growable: false);
  }

  /// Atomically reserves a local task run only when no outbound peer step is
  /// waiting, approved, or executing. The peer outbox and task rows share this
  /// SQLite database, so this transaction serializes against remote dispatch.
  Future<bool> beginTaskRun(String taskId) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final remoteRows = await txn.query(
        'peer_task_executions',
        columns: ['execution_id'],
        where: 'direction = ? AND source_task_id = ? AND status IN (?, ?, ?, ?)',
        whereArgs: [
          'outgoing',
          taskId,
          'queued',
          'awaiting_approval',
          'approved',
          'running',
        ],
        limit: 1,
      );
      if (remoteRows.isNotEmpty) return false;
      final now = DateTime.now().millisecondsSinceEpoch;
      final changed = await txn.update(
        'agent_tasks',
        {
          'status': AgentTaskStatus.running.name,
          'error': null,
          'updated_at_unix_ms': now,
        },
        where: 'id = ? AND status IN (?, ?, ?)',
        whereArgs: [
          taskId,
          AgentTaskStatus.planned.name,
          AgentTaskStatus.interrupted.name,
          AgentTaskStatus.cancelled.name,
        ],
      );
      return changed == 1;
    });
  }

  Future<void> setTaskStatus(
    String taskId,
    AgentTaskStatus status, {
    String? error,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'agent_tasks',
      {
        'status': status.name,
        'error': error,
        'updated_at_unix_ms': now,
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  Future<bool> startStep(String taskId, String stepKey) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final changed = await db.update(
      'agent_task_steps',
      {
        'status': AgentTaskStepStatus.running.name,
        'started_at_unix_ms': now,
        'finished_at_unix_ms': null,
        'error': null,
      },
      where: 'task_id = ? AND step_key = ? AND status IN (?, ?)',
      whereArgs: [
        taskId,
        stepKey,
        AgentTaskStepStatus.pending.name,
        AgentTaskStepStatus.interrupted.name,
      ],
    );
    return changed == 1;
  }

  Future<void> finishStep(
    String taskId,
    String stepKey,
    AgentTaskStepStatus status, {
    String output = '',
    String? error,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'agent_task_steps',
      {
        'status': status.name,
        'output_text': output,
        'error': error,
        'finished_at_unix_ms': now,
      },
      where: 'task_id = ? AND step_key = ?',
      whereArgs: [taskId, stepKey],
    );
  }

  Future<void> appendEvent({
    required String taskId,
    String? stepKey,
    required String eventType,
    required String message,
    Map<String, Object?> payload = const {},
  }) async {
    final db = await _database.database;
    await db.transaction(
      (txn) => _insertEvent(
        txn,
        taskId: taskId,
        stepKey: stepKey,
        eventType: eventType,
        message: message,
        payload: payload,
      ),
    );
  }

  Future<void> recoverInterruptedTasks() async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final running = await txn.query(
        'agent_tasks',
        columns: ['id'],
        where: 'status = ?',
        whereArgs: [AgentTaskStatus.running.name],
      );
      for (final row in running) {
        final taskId = row['id']! as String;
        await txn.update(
          'agent_task_steps',
          {
            'status': AgentTaskStepStatus.interrupted.name,
            'error': 'توقفت العملية عند إغلاق التطبيق أو إنهاء العملية.',
            'finished_at_unix_ms': now,
          },
          where: 'task_id = ? AND status = ?',
          whereArgs: [taskId, AgentTaskStepStatus.running.name],
        );
        await txn.update(
          'agent_tasks',
          {
            'status': AgentTaskStatus.interrupted.name,
            'updated_at_unix_ms': now,
          },
          where: 'id = ?',
          whereArgs: [taskId],
        );
        await _insertEvent(
          txn,
          taskId: taskId,
          eventType: 'interrupted',
          message: 'اكتُشف انقطاع سابق. يمكن استئناف الخطوات غير المكتملة يدوياً.',
        );
      }
    });
  }

  Future<void> delete(String taskId) async {
    final db = await _database.database;
    await db.delete('agent_tasks', where: 'id = ?', whereArgs: [taskId]);
  }

  Future<void> _insertEvent(
    Transaction txn, {
    required String taskId,
    String? stepKey,
    required String eventType,
    required String message,
    Map<String, Object?> payload = const {},
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await txn.insert('agent_task_events', {
      'id': 'event-${now}-${DateTime.now().microsecondsSinceEpoch}',
      'task_id': taskId,
      'step_key': stepKey,
      'event_type': eventType,
      'message': message,
      'payload_json': jsonEncode(payload),
      'created_at_unix_ms': now,
    });
  }
}
