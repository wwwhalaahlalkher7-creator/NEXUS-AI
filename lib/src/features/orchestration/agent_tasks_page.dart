import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../agents/agent_record.dart';
import '../agents/agent_repository.dart';
import '../models/model_repository.dart';
import '../resources/resource_settings.dart';
import '../runtime/model_runtime_manager.dart';
import 'agent_task_orchestrator.dart';
import 'agent_task_plan.dart';
import 'agent_task_repository.dart';
import 'local_llama_agent_executor.dart';

class AgentTasksPage extends StatefulWidget {
  const AgentTasksPage({
    super.key,
    required this.runtimeManager,
    this.agentRepository,
    this.taskRepository,
    this.modelRepository,
  });

  final ModelRuntimeManager runtimeManager;
  final AgentStore? agentRepository;
  final AgentTaskRepository? taskRepository;
  final ModelStore? modelRepository;

  @override
  State<AgentTasksPage> createState() => _AgentTasksPageState();
}

class _AgentTasksPageState extends State<AgentTasksPage> {
  final TextEditingController _goalController = TextEditingController();
  late final AgentStore _agentsRepository;
  late final AgentTaskRepository _tasksRepository;
  late final ModelStore _modelsRepository;
  late final ResourceSettingsRepository _settingsRepository;
  List<AgentRecord> _agents = const [];
  List<AgentTaskRecord> _tasks = const [];
  final Map<String, Future<List<AgentTaskStepRecord>>> _stepFutures = {};
  final Map<String, Future<List<AgentTaskEventRecord>>> _eventFutures = {};
  ResourceSettings _settings = const ResourceSettings();
  AgentTaskPlan? _draftPlan;
  String? _plannerId;
  String? _lastPlanError;
  String? _activeTaskId;
  AgentTaskCancellationToken? _cancellationToken;
  bool _loading = true;
  bool _planning = false;
  bool _saving = false;
  bool _executing = false;

  @override
  void initState() {
    super.initState();
    _agentsRepository = widget.agentRepository ?? AgentRepository();
    _tasksRepository = widget.taskRepository ?? AgentTaskRepository();
    _modelsRepository = widget.modelRepository ?? ModelRepository();
    _settingsRepository = ResourceSettingsRepository();
    _load();
  }

  @override
  void dispose() {
    _cancellationToken?.cancel();
    _goalController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await _tasksRepository.recoverInterruptedTasks();
      final agents = await _agentsRepository.list();
      final tasks = await _tasksRepository.list();
      final settings = await _settingsRepository.load();
      if (!mounted) {
        return;
      }
      setState(() {
        _agents = agents;
        _tasks = tasks;
        _settings = settings;
        final readyAgents = agents
            .where((agent) => agent.status == AgentRecordStatus.ready);
        _plannerId = readyAgents.isEmpty ? null : readyAgents.first.id;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _lastPlanError = 'تعذر تحميل بيانات تنسيق المهام: $error';
      });
    }
  }

  Future<void> _refreshTasks({String? invalidateTaskId}) async {
    if (invalidateTaskId == null) {
      _stepFutures.clear();
      _eventFutures.clear();
    } else {
      _stepFutures.remove(invalidateTaskId);
      _eventFutures.remove(invalidateTaskId);
    }
    final tasks = await _tasksRepository.list();
    if (mounted) {
      setState(() => _tasks = tasks);
    }
  }

  Future<List<AgentTaskStepRecord>> _stepsFuture(String taskId) =>
      _stepFutures.putIfAbsent(taskId, () => _tasksRepository.steps(taskId));

  Future<List<AgentTaskEventRecord>> _eventsFuture(String taskId) =>
      _eventFutures.putIfAbsent(taskId, () => _tasksRepository.events(taskId));

  AgentRecord? get _planner {
    for (final agent in _agents) {
      if (agent.id == _plannerId && agent.status == AgentRecordStatus.ready) {
        return agent;
      }
    }
    return null;
  }

  Future<void> _createPlan() async {
    if (_planning || _executing) {
      return;
    }
    final goal = _goalController.text.trim();
    final planner = _planner;
    final readyAgents = _agents
        .where((agent) => agent.status == AgentRecordStatus.ready)
        .toList(growable: false);
    if (goal.isEmpty || planner == null || readyAgents.isEmpty) {
      setState(() {
        _lastPlanError = 'أدخل هدفاً واختر وكيلاً جاهزاً للتخطيط.';
      });
      return;
    }
    if (!Platform.isAndroid) {
      setState(() {
        _lastPlanError =
            'تخطيط المهام بالنموذج المحلي متاح على Android فقط حالياً.';
      });
      return;
    }
    setState(() {
      _planning = true;
      _lastPlanError = null;
      _draftPlan = null;
    });
    final cancellation = AgentTaskCancellationToken();
    _cancellationToken = cancellation;
    LocalLlamaAgentExecutor? executor;
    try {
      executor = LocalLlamaAgentExecutor(
        runtimeManager: widget.runtimeManager,
        modelStore: _modelsRepository,
        settings: _settings,
      );
      final response = await executor.createPlan(
        planner: planner,
        goal: goal,
        agents: readyAgents,
        maxSteps: _settings.maxAgentPlanSteps,
        cancellationToken: cancellation,
      );
      final plan = AgentTaskPlanParser.parse(
        response,
        agents: readyAgents,
        maxSteps: _settings.maxAgentPlanSteps,
        expectedGoal: goal,
      );
      if (!mounted) {
        return;
      }
      setState(() => _draftPlan = plan);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _lastPlanError = cancellation.isCancelled
            ? 'تم إيقاف التخطيط بناءً على طلبك.'
            : 'تعذر إنشاء خطة صالحة: $error';
      });
    } finally {
      if (executor != null) {
        try {
          await executor.restorePreviousSession();
        } catch (restoreError) {
          if (mounted) {
            setState(() {
              final previousError = _lastPlanError;
              final restoreMessage =
                  'تعذرت استعادة النموذج السابق بعد التخطيط: $restoreError';
              _lastPlanError = previousError == null
                  ? restoreMessage
                  : '$previousError\n$restoreMessage';
            });
          }
        }
      }
      _cancellationToken = null;
      if (mounted) {
        setState(() => _planning = false);
      }
    }
  }

  Future<void> _savePlan() async {
    final plan = _draftPlan;
    if (plan == null || _saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      await _tasksRepository.createPlanned(
        plan: plan,
        plannerAgentId: _plannerId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _draftPlan = null;
        _goalController.clear();
      });
      await _refreshTasks();
      _message('تم حفظ الخطة محلياً. راجعها ثم اختر تنفيذها.');
    } catch (error) {
      if (mounted) {
        _message('تعذر حفظ الخطة: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _runTask(AgentTaskRecord task) async {
    if (_executing || _planning) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تنفيذ خطة الوكلاء؟'),
        content: Text(
          'سيتم تشغيل خطوات «${task.goal}» بالتتابع. قد يتغير النموذج النشط عند الانتقال بين الوكلاء المرتبطين بنماذج مختلفة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('تنفيذ'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _executing = true;
      _activeTaskId = task.id;
    });
    final cancellation = AgentTaskCancellationToken();
    _cancellationToken = cancellation;
    LocalLlamaAgentExecutor? executor;
    try {
      executor = LocalLlamaAgentExecutor(
        runtimeManager: widget.runtimeManager,
        modelStore: _modelsRepository,
        settings: _settings,
      );
      final orchestrator = AgentTaskOrchestrator(
        repository: _tasksRepository,
        agents: _agentsRepository,
        executor: executor,
      );
      final report = await orchestrator.execute(
        task.id,
        cancellationToken: cancellation,
        onProgress: () {
          if (mounted) {
            setState(() {});
          }
          unawaited(_refreshTasks(invalidateTaskId: task.id));
        },
      );
      await _refreshTasks();
      if (mounted) {
        _message(switch (report.taskStatus) {
          AgentTaskStatus.completed => 'اكتملت الخطة بنجاح.',
          AgentTaskStatus.cancelled => 'أُلغي التنفيذ. يمكنك استئناف الخطوات المتبقية.',
          _ => 'انتهى التنفيذ: ${report.succeeded} ناجحة، ${report.failed} فاشلة، ${report.blocked} متجاوزة.',
        });
      }
    } catch (error) {
      if (mounted) {
        _message('تعذر تنفيذ الخطة: $error');
      }
      await _refreshTasks();
    } finally {
      if (executor != null) {
        try {
          await executor.restorePreviousSession();
        } catch (restoreError) {
          if (mounted) {
            _message('انتهت المهمة، لكن تعذرت استعادة النموذج السابق: $restoreError');
          }
        }
      }
      _cancellationToken = null;
      if (mounted) {
        setState(() {
          _executing = false;
          _activeTaskId = null;
        });
      }
    }
  }

  Future<void> _deleteTask(AgentTaskRecord task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف المهمة؟'),
        content: const Text('سيتم حذف الخطة وخطواتها وسجل تنفيذها من هذا الجهاز.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _tasksRepository.delete(task.id);
    await _refreshTasks();
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  String _statusLabel(AgentTaskStatus status) => switch (status) {
        AgentTaskStatus.planned => 'جاهزة',
        AgentTaskStatus.running => 'قيد التنفيذ',
        AgentTaskStatus.completed => 'مكتملة',
        AgentTaskStatus.failed => 'تحتاج مراجعة',
        AgentTaskStatus.cancelled => 'أُلغيت',
        AgentTaskStatus.interrupted => 'انقطع التنفيذ',
      };

  String _stepStatusLabel(AgentTaskStepStatus status) => switch (status) {
        AgentTaskStepStatus.pending => 'بانتظار التنفيذ',
        AgentTaskStepStatus.running => 'تعمل',
        AgentTaskStepStatus.succeeded => 'اكتملت',
        AgentTaskStepStatus.failed => 'فشلت',
        AgentTaskStepStatus.blocked => 'متجاوزة بسبب اعتماد سابق',
        AgentTaskStepStatus.cancelled => 'أُلغيت',
        AgentTaskStepStatus.interrupted => 'انقطعت ويمكن استئنافها',
      };

  IconData _stepStatusIcon(AgentTaskStepStatus status) => switch (status) {
        AgentTaskStepStatus.pending => Icons.radio_button_unchecked,
        AgentTaskStepStatus.running => Icons.autorenew,
        AgentTaskStepStatus.succeeded => Icons.check_circle_outline,
        AgentTaskStepStatus.failed => Icons.error_outline,
        AgentTaskStepStatus.blocked => Icons.block_outlined,
        AgentTaskStepStatus.cancelled => Icons.cancel_outlined,
        AgentTaskStepStatus.interrupted => Icons.pause_circle_outline,
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final readyAgents = _agents
        .where((agent) => agent.status == AgentRecordStatus.ready)
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Text(
          'تنسيق الوكلاء والمهام',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          'حوّل الهدف إلى خطة، راجع توزيع الأدوار، ثم نفّذها محلياً بواسطة '
          'وكلائك بالتتابع.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'مهمة جديدة',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _goalController,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'الهدف الرئيسي',
                    hintText: 'مثال: إعداد خطة بحث ومقارنة المصادر...',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _plannerId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'وكيل التخطيط',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final agent in readyAgents)
                      DropdownMenuItem(
                      value: agent.id,
                      child: Text(agent.name),
                    ),
                  ],
                  onChanged: _planning || readyAgents.isEmpty
                      ? null
                      : (value) => setState(() => _plannerId = value),
                ),
                const SizedBox(height: 10),
                Text(
                  'وضع الموارد: ${_settings.label} · الحد التخطيطي: '
                  '${_settings.maxAgentPlanSteps?.toString() ?? 'مفتوح'} خطوة',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _planning || _executing || readyAgents.isEmpty
                      ? null
                      : _createPlan,
                  icon: _planning
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.account_tree_outlined),
                  label: Text(
                    _planning ? 'جارٍ إنشاء الخطة...' : 'إنشاء خطة بواسطة الوكيل',
                  ),
                ),
                if (_planning)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      onPressed: () => _cancellationToken?.cancel(),
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('إيقاف التخطيط'),
                    ),
                  ),
                if (readyAgents.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'أنشئ وكيلاً واحداً على الأقل واجعله جاهزاً قبل التخطيط.',
                    ),
                  ),
                if (_lastPlanError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _lastPlanError!,
                      style: TextStyle(color: colors.error),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_draftPlan != null) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.fact_check_outlined),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'مراجعة الخطة',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_draftPlan!.goal),
                  const SizedBox(height: 8),
                  for (var index = 0; index < _draftPlan!.steps.length; index++)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(child: Text('${index + 1}')),
                      title: Text(_draftPlan!.steps[index].objective),
                      subtitle: Text(
                        '${_agentName(_draftPlan!.steps[index].agentId)}'
                        '${_draftPlan!.steps[index].dependsOn.isEmpty ? '' : ' · يعتمد على: ${_draftPlan!.steps[index].dependsOn.join(', ')}'}',
                      ),
                    ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _saving ? null : _savePlan,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(
                      _saving ? 'جارٍ الحفظ...' : 'حفظ الخطة محلياً',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                'سجل المهام',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'تحديث',
              onPressed: _refreshTasks,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_tasks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('لا توجد مهام محفوظة بعد.')),
          ),
        for (final task in _tasks)
          Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              title: Text(
                task.goal,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_statusLabel(task.status)} · '
                '${DateTime.fromMillisecondsSinceEpoch(task.updatedAtUnixMs).toLocal()}',
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: [
                FutureBuilder<List<AgentTaskStepRecord>>(
                  future: _stepsFuture(task.id),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.all(12),
                        child: LinearProgressIndicator(),
                      );
                    }
                    if (snapshot.hasError) {
                      return Text('تعذر قراءة الخطوات: ${snapshot.error}');
                    }
                    final steps = snapshot.data ?? const <AgentTaskStepRecord>[];
                    return Column(
                      children: [
                        for (final step in steps)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(_stepStatusIcon(step.status)),
                            title: Text(step.objective),
                            subtitle: Text(
                              '${_agentName(step.agentId)} · '
                              '${_stepStatusLabel(step.status)}',
                            ),
                            isThreeLine: step.outputText.isNotEmpty || step.error != null,
                          ),
                        if (steps.any((step) => step.outputText.isNotEmpty))
                          for (final step in steps.where(
                            (item) => item.outputText.isNotEmpty,
                          ))
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: SelectableText('${step.stepKey}: ${step.outputText}'),
                              ),
                            ),
                      ],
                    );
                  },
                ),
                FutureBuilder<List<AgentTaskEventRecord>>(
                  future: _eventsFuture(task.id),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const LinearProgressIndicator();
                    }
                    if (snapshot.hasError) {
                      return Text('تعذر قراءة سجل التنفيذ: ${snapshot.error}');
                    }
                    final events =
                        snapshot.data ?? const <AgentTaskEventRecord>[];
                    return ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text('سجل التنفيذ (${events.length})'),
                      children: [
                        if (events.isEmpty)
                          const ListTile(
                            title: Text('لم يبدأ تنفيذ هذه المهمة بعد.'),
                          ),
                        for (final event in events)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.history, size: 18),
                            title: Text(event.message),
                            subtitle: Text(
                              '${event.eventType} · ${DateTime.fromMillisecondsSinceEpoch(event.createdAtUnixMs).toLocal()}',
                            ),
                          ),
                      ],
                    );
                  },
                ),
                if (task.status == AgentTaskStatus.planned ||
                    task.status == AgentTaskStatus.interrupted ||
                    task.status == AgentTaskStatus.cancelled)
                  FilledButton.icon(
                    onPressed: _executing || _planning ? null : () => _runTask(task),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(
                      task.status == AgentTaskStatus.planned
                          ? 'تنفيذ الخطة'
                          : 'استئناف الخطوات المتبقية',
                    ),
                  ),
                if (_activeTaskId == task.id && _executing)
                  OutlinedButton.icon(
                    onPressed: () => _cancellationToken?.cancel(),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('إيقاف التنفيذ'),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    onPressed: _executing && _activeTaskId == task.id
                        ? null
                        : () => _deleteTask(task),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('حذف'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _agentName(String? id) {
    if (id == null) {
      return 'وكيل محذوف';
    }
    for (final agent in _agents) {
      if (agent.id == id) {
        return agent.name;
      }
    }
    return 'وكيل غير متاح';
  }
}
