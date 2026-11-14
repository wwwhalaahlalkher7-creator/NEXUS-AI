import '../agents/agent_record.dart';
import '../agents/agent_repository.dart';
import 'agent_task_plan.dart';
import 'agent_task_repository.dart';

class AgentTaskCancellationToken {
  bool _cancelled = false;
  void Function()? _onCancel;
  bool get isCancelled => _cancelled;

  void bind(void Function() onCancel) {
    _onCancel = onCancel;
    if (_cancelled) {
      onCancel();
    }
  }

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _onCancel?.call();
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw const AgentTaskCancelledException();
    }
  }
}

class AgentTaskCancelledException implements Exception {
  const AgentTaskCancelledException();
}

class AgentTaskDependencyOutput {
  const AgentTaskDependencyOutput({
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
}

class AgentTaskHandoff {
  const AgentTaskHandoff({
    required this.taskId,
    required this.goal,
    required this.stepId,
    required this.objective,
    required this.expectedOutput,
    required this.dependencies,
  });
  final String taskId;
  final String goal;
  final String stepId;
  final String objective;
  final String expectedOutput;
  final List<AgentTaskDependencyOutput> dependencies;
}

abstract interface class AgentTaskExecutor {
  Future<String> execute({
    required AgentRecord agent,
    required AgentTaskHandoff handoff,
    required AgentTaskCancellationToken cancellationToken,
  });
}

class AgentTaskRunReport {
  const AgentTaskRunReport({
    required this.succeeded,
    required this.failed,
    required this.blocked,
    required this.cancelled,
    required this.taskStatus,
  });
  final int succeeded;
  final int failed;
  final int blocked;
  final int cancelled;
  final AgentTaskStatus taskStatus;
}

/// Sequential Plan/Act/Observe executor. It never runs duplicate or dependent
/// steps out of order and never recursively delegates from a child handoff.
class AgentTaskOrchestrator {
  AgentTaskOrchestrator({
    required AgentTaskRepository repository,
    required AgentStore agents,
    required AgentTaskExecutor executor,
  })  : _repository = repository,
        _agents = agents,
        _executor = executor;

  final AgentTaskRepository _repository;
  final AgentStore _agents;
  final AgentTaskExecutor _executor;
  bool _running = false;

  Future<AgentTaskRunReport> execute(
    String taskId, {
    required AgentTaskCancellationToken cancellationToken,
    void Function()? onProgress,
  }) async {
    if (_running) {
      throw StateError('توجد خطة وكلاء أخرى قيد التنفيذ.');
    }
    _running = true;
    var succeeded = 0;
    var failed = 0;
    var blocked = 0;
    var cancelled = 0;
    try {
      final task = await _repository.get(taskId);
      if (task == null) {
        throw StateError('المهمة غير موجودة.');
      }
      if (task.status != AgentTaskStatus.planned &&
          task.status != AgentTaskStatus.interrupted &&
          task.status != AgentTaskStatus.cancelled) {
        throw StateError(
          'لا يمكن تشغيل المهمة من حالتها الحالية: ${task.status.name}.',
        );
      }
      final agentList = await _agents.list();
      final agentById = {for (final agent in agentList) agent.id: agent};
      final steps = await _repository.steps(taskId);
      final statusByKey = <String, AgentTaskStepStatus>{
        for (final step in steps) step.stepKey: step.status,
      };
      final outputByKey = <String, AgentTaskStepRecord>{
        for (final step in steps) step.stepKey: step,
      };
      await _repository.setTaskStatus(taskId, AgentTaskStatus.running);
      await _repository.appendEvent(
        taskId: taskId,
        eventType: 'execution_started',
        message: 'بدأ تنفيذ الخطة بالتتابع.',
      );
      onProgress?.call();

      for (final step in steps) {
        cancellationToken.throwIfCancelled();
        final priorStatus = statusByKey[step.stepKey]!;
        if (priorStatus == AgentTaskStepStatus.succeeded) {
          succeeded++;
          continue;
        }
        final failedDependency = step.dependsOn.any((dependency) {
          final state = statusByKey[dependency];
          return state == AgentTaskStepStatus.failed ||
              state == AgentTaskStepStatus.blocked ||
              state == AgentTaskStepStatus.cancelled;
        });
        final pendingDependency = step.dependsOn.any(
          (dependency) =>
              statusByKey[dependency] != AgentTaskStepStatus.succeeded,
        );
        if (failedDependency || pendingDependency) {
          await _repository.finishStep(
            taskId,
            step.stepKey,
            AgentTaskStepStatus.blocked,
            error: 'تعذّر تنفيذ الاعتمادية المطلوبة لهذه الخطوة.',
          );
          statusByKey[step.stepKey] = AgentTaskStepStatus.blocked;
          blocked++;
          await _repository.appendEvent(
            taskId: taskId,
            stepKey: step.stepKey,
            eventType: 'step_blocked',
            message: 'تم تجاوز الخطوة لعدم اكتمال اعتمادياتها.',
          );
          onProgress?.call();
          continue;
        }
        final agentId = step.agentId;
        final agent = agentId == null ? null : agentById[agentId];
        if (agent == null || agent.status != AgentRecordStatus.ready) {
          await _repository.finishStep(
            taskId,
            step.stepKey,
            AgentTaskStepStatus.failed,
            error: 'الوكيل غير متاح أو لم يعد جاهزاً.',
          );
          statusByKey[step.stepKey] = AgentTaskStepStatus.failed;
          failed++;
          await _repository.appendEvent(
            taskId: taskId,
            stepKey: step.stepKey,
            eventType: 'step_failed',
            message: 'توقف تنفيذ الخطوة لأن الوكيل لم يعد جاهزاً.',
          );
          onProgress?.call();
          continue;
        }
        if (!await _repository.startStep(taskId, step.stepKey)) {
          throw StateError(
            'تعذر حجز الخطوة ${step.stepKey}؛ ربما يجري تنفيذها بالفعل.',
          );
        }
        await _repository.appendEvent(
          taskId: taskId,
          stepKey: step.stepKey,
          eventType: 'step_started',
          message: 'بدأ الوكيل ${agent.name} تنفيذ الخطوة.',
        );
        onProgress?.call();
        final dependencyOutputs = <AgentTaskDependencyOutput>[];
        for (final dependency in step.dependsOn) {
          final dependencyStep = outputByKey[dependency];
          if (dependencyStep == null ||
              statusByKey[dependency] != AgentTaskStepStatus.succeeded) {
            continue;
          }
          final dependencyAgent = dependencyStep.agentId == null
              ? null
              : agentById[dependencyStep.agentId];
          dependencyOutputs.add(AgentTaskDependencyOutput(
            stepId: dependency,
            agentName: dependencyAgent?.name ?? 'وكيل سابق',
            output: dependencyStep.outputText,
          ));
        }
        try {
          final output = await _executor.execute(
            agent: agent,
            handoff: AgentTaskHandoff(
              taskId: taskId,
              goal: task.goal,
              stepId: step.stepKey,
              objective: step.objective,
              expectedOutput: step.expectedOutput,
              dependencies: List.unmodifiable(dependencyOutputs),
            ),
            cancellationToken: cancellationToken,
          );
          cancellationToken.throwIfCancelled();
          final normalized = output.trim();
          if (normalized.isEmpty) {
            throw StateError('لم ينتج الوكيل مخرجاً.');
          }
          await _repository.finishStep(
            taskId,
            step.stepKey,
            AgentTaskStepStatus.succeeded,
            output: normalized,
          );
          statusByKey[step.stepKey] = AgentTaskStepStatus.succeeded;
          outputByKey[step.stepKey] = AgentTaskStepRecord(
            id: step.id,
            taskId: step.taskId,
            stepKey: step.stepKey,
            ordinal: step.ordinal,
            agentId: step.agentId,
            objective: step.objective,
            expectedOutput: step.expectedOutput,
            dependsOn: step.dependsOn,
            status: AgentTaskStepStatus.succeeded,
            outputText: normalized,
          );
          succeeded++;
          await _repository.appendEvent(
            taskId: taskId,
            stepKey: step.stepKey,
            eventType: 'step_succeeded',
            message: 'اكتمل تنفيذ الخطوة بواسطة ${agent.name}.',
          );
        } on AgentTaskCancelledException {
          await _repository.finishStep(
            taskId,
            step.stepKey,
            AgentTaskStepStatus.interrupted,
            error: 'ألغى المستخدم التنفيذ.',
          );
          statusByKey[step.stepKey] = AgentTaskStepStatus.interrupted;
          cancelled++;
          await _repository.appendEvent(
            taskId: taskId,
            stepKey: step.stepKey,
            eventType: 'step_interrupted',
            message: 'أوقف المستخدم تنفيذ هذه الخطوة؛ يمكن استئنافها لاحقاً.',
          );
          onProgress?.call();
          break;
        } catch (error) {
          if (cancellationToken.isCancelled) {
            await _repository.finishStep(
              taskId,
              step.stepKey,
              AgentTaskStepStatus.interrupted,
              error: 'أُلغي التنفيذ أثناء انتظار المحرك: $error',
            );
            statusByKey[step.stepKey] = AgentTaskStepStatus.interrupted;
            cancelled++;
            await _repository.appendEvent(
              taskId: taskId,
              stepKey: step.stepKey,
              eventType: 'step_interrupted',
              message: 'أُلغي توليد الوكيل، وتم حفظ الخطوة للاستئناف.',
            );
            onProgress?.call();
            break;
          }
          await _repository.finishStep(
            taskId,
            step.stepKey,
            AgentTaskStepStatus.failed,
            error: error.toString(),
          );
          statusByKey[step.stepKey] = AgentTaskStepStatus.failed;
          failed++;
          await _repository.appendEvent(
            taskId: taskId,
            stepKey: step.stepKey,
            eventType: 'step_failed',
            message: 'فشل تنفيذ الخطوة: $error',
          );
        }
        onProgress?.call();
      }
      final wasCancelled = cancellationToken.isCancelled || cancelled > 0;
      final finalStatus = wasCancelled
          ? AgentTaskStatus.cancelled
          : failed > 0 || blocked > 0
              ? AgentTaskStatus.failed
              : AgentTaskStatus.completed;
      await _repository.setTaskStatus(taskId, finalStatus);
      await _repository.appendEvent(
        taskId: taskId,
        eventType: 'execution_finished',
        message: switch (finalStatus) {
          AgentTaskStatus.completed => 'اكتملت الخطة بنجاح.',
          AgentTaskStatus.cancelled => 'أُلغي تنفيذ الخطة.',
          _ => 'انتهت الخطة مع خطوات فاشلة أو متجاوزة.',
        },
        payload: {
          'succeeded': succeeded,
          'failed': failed,
          'blocked': blocked,
          'cancelled': cancelled,
        },
      );
      onProgress?.call();
      return AgentTaskRunReport(
        succeeded: succeeded,
        failed: failed,
        blocked: blocked,
        cancelled: cancelled,
        taskStatus: finalStatus,
      );
    } on AgentTaskCancelledException {
      await _repository.setTaskStatus(taskId, AgentTaskStatus.cancelled);
      await _repository.appendEvent(
        taskId: taskId,
        eventType: 'execution_cancelled',
        message: 'أُلغي التنفيذ قبل بدء الخطوة التالية.',
      );
      cancelled++;
      onProgress?.call();
      return AgentTaskRunReport(
        succeeded: succeeded,
        failed: failed,
        blocked: blocked,
        cancelled: cancelled,
        taskStatus: AgentTaskStatus.cancelled,
      );
    } finally {
      _running = false;
    }
  }
}


