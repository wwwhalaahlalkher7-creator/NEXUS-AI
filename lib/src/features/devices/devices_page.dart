import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

import '../agents/agent_record.dart';
import '../agents/agent_repository.dart';
import '../models/model_record.dart';
import '../models/model_repository.dart';
import '../models/model_file_verifier.dart';
import '../orchestration/agent_task_orchestrator.dart';
import '../orchestration/agent_task_plan.dart';
import '../orchestration/local_llama_agent_executor.dart';
import '../resources/resource_settings.dart';
import '../resources/peer_resource_advisor.dart';
import '../resources/peer_model_profile.dart';
import '../runtime/model_runtime_manager.dart';
import '../orchestration/agent_task_repository.dart';
import 'device_network_service.dart';
import 'device_record.dart';
import 'pairing_qr_scanner_page.dart';
import 'peer_discovery.dart';
import 'peer_task_transfer.dart';
import 'peer_task_execution.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.service,
    required this.runtimeManager,
  });

  final DeviceNetworkService service;
  final ModelRuntimeManager runtimeManager;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final _addressController = TextEditingController();
  final _codeController = TextEditingController();
  final _portController = TextEditingController(text: '47831');
  StreamSubscription<DeviceNetworkEvent>? _eventsSubscription;
  List<PairedDeviceRecord> _devices = const [];
  List<RemoteTaskTransferRecord> _transfers = const [];
  List<PeerTaskExecutionRecord> _executions = const [];
  List<DiscoveredPeer> _nearbyDevices = const [];
  PairingInvite? _invite;
  bool _loading = true;
  bool _scanningNearby = false;
  bool _busy = false;
  late final ModelRuntimeManager _runtimeManager;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _runtimeManager = widget.runtimeManager;
    widget.service.onPairingRequest = _confirmPairing;
    widget.service.onTaskProposalRequest = _confirmIncomingTaskProposal;
    widget.service.configurePeerExecutionHandlers(
      approvalHandler: _approvePeerTaskExecution,
      executeHandler: _executePeerTaskOnLocalAgent,
    );
    _eventsSubscription = widget.service.events.listen(_handleEvent);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await widget.service.initialize();
      await _reload();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _handleEvent(DeviceNetworkEvent event) {
    if (!mounted) {
      return;
    }
    setState(() {
      _status = event.message;
      if (event.type == DeviceNetworkEventType.error) {
        _error = event.message;
      }
      if (event.type == DeviceNetworkEventType.discoveryUpdated) {
        _nearbyDevices = widget.service.discoveredPeers;
      }
      if (event.type == DeviceNetworkEventType.discoveryStarted) {
        _scanningNearby = true;
      }
      if (event.type == DeviceNetworkEventType.discoveryStopped) {
        _scanningNearby = false;
        _nearbyDevices = widget.service.discoveredPeers;
      }
      if (event.type == DeviceNetworkEventType.networkChanged) {
        _nearbyDevices = widget.service.discoveredPeers;
      }
      if (event.type == DeviceNetworkEventType.inviteExpired ||
          event.type == DeviceNetworkEventType.inviteConsumed) {
        _invite = null;
      }
    });
    if (event.type == DeviceNetworkEventType.networkChanged) {
      unawaited(_refreshInviteAfterNetworkChange());
    }
    if (event.type == DeviceNetworkEventType.capabilitiesUpdated ||
        event.type == DeviceNetworkEventType.peerConnected ||
        event.type == DeviceNetworkEventType.peerDisconnected ||
        event.type == DeviceNetworkEventType.taskProposalReceived ||
        event.type == DeviceNetworkEventType.taskProposalSent ||
        event.type == DeviceNetworkEventType.taskProposalDeclined ||
        event.type == DeviceNetworkEventType.taskProposalRejected ||
        event.type == DeviceNetworkEventType.taskExecutionReceived ||
        event.type == DeviceNetworkEventType.taskExecutionStarted ||
        event.type == DeviceNetworkEventType.taskExecutionFinished ||
        event.type == DeviceNetworkEventType.taskExecutionUpdated) {
      unawaited(_reload());
    }
  }

  Future<bool> _confirmPairing(PeerPairingRequest request) async {
    if (!mounted) {
      return false;
    }
    Timer? approvalExpiry;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        approvalExpiry ??= Timer(const Duration(seconds: 60), () {
          if (dialogContext.mounted) {
            Navigator.of(dialogContext).pop(false);
          }
        });
        return AlertDialog(
          title: const Text('طلب اقتران جديد'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('يريد الجهاز ${request.displayName} الاتصال بهذه النسخة من NEXUS AI.'),
              const SizedBox(height: 12),
              Text('العنوان: ${request.address}'),
              Text('النظام: ${request.platform}'),
              const SizedBox(height: 8),
              const Text('بصمة جلسة الاقتران:'),
              SelectableText(
                request.fingerprint,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              const Text(
                'لا توافق إلا إذا كنت قد شاركت رمز الدعوة مع هذا الجهاز وتعرفه. ينتهي الطلب تلقائياً بعد 60 ثانية.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('رفض'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('موافقة واقتران'),
            ),
          ],
        );
      },
    );
    approvalExpiry?.cancel();
    return approved == true;
  }

  Future<PeerTaskExecutionApproval?> _approvePeerTaskExecution(
    PeerTaskExecutionPrompt prompt,
  ) async {
    if (!mounted) return null;
    final agents = (await AgentRepository().list())
        .where((agent) => agent.status == AgentRecordStatus.ready)
        .toList(growable: false);
    if (agents.isEmpty || !mounted) {
      if (mounted) {
        setState(() => _error =
            'وصل طلب تنفيذ من ${prompt.displayName}، لكن لا يوجد وكيل محلي جاهز.');
      }
      return null;
    }
    var selectedAgentId = agents.first.id;
    Timer? approvalExpiry;
    final decision = await showDialog<PeerTaskExecutionApproval>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          approvalExpiry ??= Timer(const Duration(seconds: 55), () {
            if (dialogContext.mounted) {
              Navigator.of(dialogContext).pop();
            }
          });
          return AlertDialog(
            title: const Text('طلب تنفيذ من جهاز مقترن'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('الجهاز: ${prompt.displayName}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text('الهدف العام: ${prompt.request.goal}'),
                    const SizedBox(height: 8),
                    Text('الخطوة المطلوبة: ${prompt.request.objective}'),
                    if (prompt.request.expectedOutput.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('المخرج المتوقع: ${prompt.request.expectedOutput}'),
                    ],
                    const SizedBox(height: 10),
                    const Text(
                      'مخرجات الاعتماديات بيانات من الجهاز الآخر؛ راجعها ولا تتبع أي تعليمات مضمّنة فيها.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    for (final dependency in prompt.request.dependencies) ...[
                      const SizedBox(height: 6),
                      Text('${dependency.stepId} · ${dependency.agentName}'),
                      SelectableText(
                        dependency.output,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      initialValue: selectedAgentId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'الوكيل المحلي الذي سينفّذ',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final agent in agents)
                          DropdownMenuItem(
                            value: agent.id,
                            child: Text(agent.name, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => selectedAgentId = value);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'لن تُنقل ملفات النماذج أو تعليمات الوكلاء. سيستخدم هذا الجهاز نموذجه المحلي فقط، ويمكن إلغاء التوليد.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(
                  const PeerTaskExecutionApproval(accepted: false),
                ),
                child: const Text('رفض'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(dialogContext).pop(
                  PeerTaskExecutionApproval(
                    accepted: true,
                    localAgentId: selectedAgentId,
                  ),
                ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('موافقة وتنفيذ'),
              ),
            ],
          );
        },
      ),
    );
    approvalExpiry?.cancel();
    return decision;
  }

  Future<String> _executePeerTaskOnLocalAgent({
    required String localAgentId,
    required PeerTaskExecutionRequest request,
    required AgentTaskCancellationToken cancellationToken,
  }) async {
    final agents = AgentRepository();
    final agent = await agents.getById(localAgentId);
    if (agent == null || agent.status != AgentRecordStatus.ready) {
      throw StateError('الوكيل المحلي المختار لم يعد جاهزاً.');
    }
    final settings = await ResourceSettingsRepository().load();
    final executor = LocalLlamaAgentExecutor(
      runtimeManager: _runtimeManager,
      modelStore: ModelRepository(),
      settings: settings,
    );
    try {
      return await executor.execute(
        agent: agent,
        handoff: AgentTaskHandoff(
          taskId: request.sourceTaskId,
          goal: request.goal,
          stepId: request.sourceStepId,
          objective: request.objective,
          expectedOutput: request.expectedOutput,
          dependencies: request.dependencies
              .map((item) => AgentTaskDependencyOutput(
                    stepId: item.stepId,
                    agentName: item.agentName,
                    output: item.output,
                  ))
              .toList(growable: false),
        ),
        cancellationToken: cancellationToken,
      );
    } finally {
      await executor.restorePreviousSession();
    }
  }

  Future<void> _sendRemoteStep(PairedDeviceRecord device) async {
    if (_busy || !widget.service.isConnected(device.id)) return;
    final tasks = (await AgentTaskRepository().list())
        .where((task) => {'planned', 'interrupted'}.contains(task.status.name))
        .toList(growable: false);
    if (tasks.isEmpty || !mounted) {
      if (mounted) {
        setState(() => _status = 'لا توجد مهام مخططة أو متوقفة لإرسال خطوة منها.');
      }
      return;
    }
    final task = await showDialog<AgentTaskRecord>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('اختر المهمة'),
        children: [
          for (final item in tasks)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(item),
              child: Text(item.goal, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
    if (task == null || !mounted) return;
    final steps = await AgentTaskRepository().steps(task.id);
    final byKey = {for (final step in steps) step.stepKey: step};
    final candidates = steps.where((step) =>
        {'pending', 'interrupted'}.contains(step.status.name) &&
        step.dependsOn.every((id) => byKey[id]?.status == AgentTaskStepStatus.succeeded)
    ).toList(growable: false);
    if (candidates.isEmpty || !mounted) {
      if (mounted) {
        setState(() => _error = 'لا توجد خطوة جاهزة للإرسال؛ أكمل اعتماديات الخطوات أولاً.');
      }
      return;
    }
    final step = await showDialog<AgentTaskStepRecord>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('اختر الخطوة لإرسالها'),
        children: [
          for (final item in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(item),
              child: Text('${item.stepKey} · ${item.objective}', maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
    if (step == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ إرسال خطوة مشفّرة إلى ${device.displayName}...';
    });
    try {
      await widget.service.sendTaskStepForRemoteExecution(
        deviceId: device.id,
        taskId: task.id,
        stepKey: step.stepKey,
      );
      await _reload();
      if (mounted) {
        setState(() => _status = 'أُرسل الطلب؛ لن يبدأ التنفيذ إلا بعد موافقة الجهاز المستلم.');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _executionStatusLabel(PeerTaskExecutionRecord record) => switch (record.status) {
        PeerTaskExecutionStatus.queued => 'في قائمة الإرسال',
        PeerTaskExecutionStatus.awaitingApproval => 'ينتظر الموافقة',
        PeerTaskExecutionStatus.approved => 'تمت الموافقة',
        PeerTaskExecutionStatus.running => 'قيد التنفيذ',
        PeerTaskExecutionStatus.succeeded => 'اكتمل بنجاح',
        PeerTaskExecutionStatus.failed => 'فشل',
        PeerTaskExecutionStatus.cancelled => 'أُلغي',
        PeerTaskExecutionStatus.rejected => 'مرفوض',
        PeerTaskExecutionStatus.interrupted => 'انقطع التنفيذ',
      };

  String _executionGoal(PeerTaskExecutionRecord record) {
    try {
      final decoded = jsonDecode(record.requestJson) as Map;
      final value = decoded['objective'];
      return value is String ? value : record.sourceStepKey;
    } on Object {
      return record.sourceStepKey;
    }
  }

  Future<void> _cancelRemoteExecution(PeerTaskExecutionRecord record) async {
    try {
      await widget.service.cancelRemoteExecution(record.executionId);
      if (mounted) {
        setState(() => _status = 'أُرسل طلب إلغاء التنفيذ إلى الجهاز المقابل.');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  Widget _peerTaskExecutionsSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('تنفيذ الخطوات بين الأجهزة',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            ),
            IconButton(onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
          ],
        ),
        if (_executions.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Center(child: Text('لا توجد طلبات تنفيذ موزّعة بعد.')),
            ),
          )
        else
          for (final record in _executions)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(record.direction == 'incoming' ? Icons.move_to_inbox_rounded : Icons.outbox_rounded),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_executionGoal(record), maxLines: 3, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700))),
                        Text(_executionStatusLabel(record),
                            style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('${record.direction == 'incoming' ? 'وارد من' : 'مُرسل إلى'} ${record.deviceId} · ${record.sourceStepKey}',
                        style: Theme.of(context).textTheme.bodySmall),
                    if (record.error != null && record.error!.isNotEmpty)
                      Text(record.error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                    if (record.resultJson != null) ...[
                      const SizedBox(height: 6),
                      Builder(builder: (context) {
                        try {
                          final result = jsonDecode(record.resultJson!) as Map;
                          final output = result['output_text'];
                          if (output is String && output.isNotEmpty) {
                            return SelectableText(output, maxLines: 8);
                          }
                        } on Object {
                          return const Text('تعذر عرض النتيجة المحفوظة.');
                        }
                        return const SizedBox.shrink();
                      }),
                    ],
                    if (record.direction == 'outgoing' &&
                        (record.status == PeerTaskExecutionStatus.queued ||
                         record.status == PeerTaskExecutionStatus.awaitingApproval ||
                         record.status == PeerTaskExecutionStatus.running))
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton.icon(
                          onPressed: () => _cancelRemoteExecution(record),
                          icon: const Icon(Icons.cancel_outlined, size: 18),
                          label: const Text('طلب الإلغاء'),
                        ),
                      ),
                    if (record.direction == 'incoming' &&
                        record.status == PeerTaskExecutionStatus.running)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton.icon(
                          onPressed: () async {
                            try {
                              await widget.service.cancelLocalPeerExecution(record.executionId);
                              if (mounted) {
                                setState(() => _status = 'أُرسل إلغاء التوليد المحلي.');
                              }
                            } on Object catch (error) {
                              if (mounted) {
        setState(() => _error = error.toString());
      }
                            }
                          },
                          icon: const Icon(Icons.stop_circle_outlined, size: 18),
                          label: const Text('إيقاف التنفيذ المحلي'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _reload() async {
    final devices = await widget.service.listDevices();
    final transfers = await widget.service.listTaskTransfers();
    final executions = await widget.service.listPeerTaskExecutions();
    if (mounted) {
      setState(() {
        _devices = devices;
        _transfers = transfers;
        _executions = executions;
      });
    }
  }

  Future<void> _shareTaskProposal(PairedDeviceRecord device) async {
    final tasks = await AgentTaskRepository().list();
    final candidates = tasks.where((task) => task.status.name == 'planned').toList();
    if (!mounted) {
      return;
    }
    if (candidates.isEmpty) {
      setState(() => _status = 'لا توجد مهام مخططة جاهزة للإرسال. أنشئ خطة في صفحة تنسيق المهام أولاً.');
      return;
    }
    final selected = await showDialog<AgentTaskRecord>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('إرسال مقترح مهمة'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 10),
            child: Text('سيتم إرسال الخطة كبيانات غير موثوقة للمراجعة فقط؛ لن تُنفّذ على الجهاز الآخر.'),
          ),
          for (final task in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(task),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(task.goal, maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ تجهيز مقترح المهمة لقناة الجهاز الآمنة...';
    });
    try {
      await widget.service.sendTaskProposal(
        deviceId: device.id,
        sourceTaskId: selected.id,
      );
      await _reload();
      if (mounted) {
        setState(() => _status = widget.service.isConnected(device.id)
            ? 'أُضيف المقترح إلى النقل؛ سيظهر كعنصر محفوظ بعد تأكيد الجهاز المستلم.'
            : 'حُفظ المقترح في قائمة الإرسال وسيُرسل عند إعادة اتصال الجهاز.');
      }
    } on Object catch (error) {
      await _reload();
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _importTaskTransfer(RemoteTaskTransferRecord transfer) async {
    if (_busy || transfer.direction != 'incoming' || transfer.status != 'kept') {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ تجهيز استيراد المقترح وربط الوكلاء المحليين...';
    });
    try {
      final localAgents = (await AgentRepository().list())
          .where((agent) => agent.status == AgentRecordStatus.ready)
          .toList(growable: false);
      if (localAgents.isEmpty) {
        throw StateError('أنشئ وكيلاً محلياً واحداً على الأقل واجعله جاهزاً قبل استيراد المهمة.');
      }
      final decoded = jsonDecode(transfer.planJson) as Map<String, dynamic>;
      final sourceSteps = decoded['steps'] as List<dynamic>;
      final remoteAgentIds = sourceSteps
          .map((step) => (step as Map<String, dynamic>)['agent_id'] as String)
          .toSet()
          .toList(growable: false);
      final mapping = await _chooseLocalAgentMappings(
        remoteAgentIds: remoteAgentIds,
        localAgents: localAgents,
      );
      if (mapping == null || !mounted) {
        return;
      }
      final mappedJson = RemoteTaskPlanRemapper.remap(transfer.planJson, mapping);
      final plan = AgentTaskPlanParser.parse(
        mappedJson,
        agents: localAgents,
        expectedGoal: transfer.goal,
      );
      final taskId = await widget.service.importTaskProposal(
        transferId: transfer.transferId,
        locallyMappedPlan: plan,
      );
      await _reload();
      if (mounted) {
        setState(() => _status =
            'استُورد المقترح كمهمة محلية ($taskId). افتح الوكلاء ثم المهام لمراجعته وتشغيله يدوياً.');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<Map<String, String>?> _chooseLocalAgentMappings({
    required List<String> remoteAgentIds,
    required List<AgentRecord> localAgents,
  }) async {
    final selected = <String, String?>{};
    return showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final allSelected = remoteAgentIds.every((id) => selected[id] != null);
          return AlertDialog(
            title: const Text('تعيين الوكلاء المحليين'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'معرّفات الوكلاء المرسلة تخص الجهاز الآخر. اختر وكيلاً محلياً جاهزاً لكل معرّف؛ لن تُستورد شخصية الوكيل أو تعليماته تلقائياً.',
                    ),
                    const SizedBox(height: 14),
                    for (final remoteId in remoteAgentIds) ...[
                      Text('الوكيل المرسل: $remoteId',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 5),
                      DropdownButtonFormField<String>(
                        initialValue: selected[remoteId],
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'الوكيل المحلي',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final agent in localAgents)
                            DropdownMenuItem(
                              value: agent.id,
                              child: Text(agent.name, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (value) => setDialogState(() {
                          selected[remoteId] = value;
                        }),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: allSelected
                    ? () => Navigator.of(dialogContext).pop({
                        for (final id in remoteAgentIds) id: selected[id]!,
                      })
                    : null,
                child: const Text('تأكيد التعيين والاستيراد'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool?> _confirmIncomingTaskProposal(
    PeerTaskProposalRequest request,
  ) async {
    if (!mounted) {
      return null;
    }
    final decoded = jsonDecode(request.planJson);
    final prettyPlan = const JsonEncoder.withIndent('  ').convert(decoded);
    final planPreview = prettyPlan.length > 12000
        ? '${prettyPlan.substring(0, 12000)}\n… تم اختصار المعاينة؛ سيُحفظ المحتوى الكامل بعد الموافقة.'
        : prettyPlan;
    Timer? approvalExpiry;
    final approved = await showDialog<bool?>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        approvalExpiry ??= Timer(const Duration(seconds: 60), () {
          if (dialogContext.mounted) {
            Navigator.of(dialogContext).pop(null);
          }
        });
        return AlertDialog(
          title: const Text('طلب استلام مقترح مهمة'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('من الجهاز: ${request.displayName}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text(request.goal),
                  const SizedBox(height: 8),
                  Text('هوية الجهاز: ${request.deviceId}'),
                  Text('${request.stepCount} خطوات · معرّف النقل ${request.transferId}'),
                  const SizedBox(height: 12),
                  SelectableText(planPreview, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                  const SizedBox(height: 12),
                  const Text('الموافقة تحفظ الخطة فقط كبيانات غير موثوقة. لا يتم استيراد الوكلاء أو تشغيل الخطوات. ينتهي الطلب تلقائياً بعد 60 ثانية.'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('رفض الاستلام'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('موافقة وحفظ المقترح'),
            ),
          ],
        );
      },
    );
    approvalExpiry?.cancel();
    return approved;
  }

  Future<void> _viewTaskTransfer(RemoteTaskTransferRecord transfer) async {
    final decoded = jsonDecode(transfer.planJson);
    final prettyPlan = const JsonEncoder.withIndent('  ').convert(decoded);
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مقترح محفوظ'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(transfer.goal, style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text('${transfer.stepCount} خطوات · من الجهاز ${transfer.deviceId}'),
                const SizedBox(height: 12),
                SelectableText(prettyPlan, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                const SizedBox(height: 12),
                const Text('المقترح محفوظ محلياً فقط. لا يتم تشغيل أي خطوة أو استيراد أي وكيل تلقائياً.'),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('إغلاق'))],
      ),
    );
  }

  Future<void> _createInvite() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ تشغيل الاستقبال المحلي وإنشاء رمز اقتران...';
    });
    try {
      final invite = await widget.service.createInvite();
      if (!mounted) {
        return;
      }
      setState(() {
        _invite = invite;
        _status = invite.discoveryAvailable
            ? 'الاستقبال يعمل. شارك رمز QR مع جهازك الآخر فقط.'
            : 'الاستقبال يعمل؛ الاكتشاف التلقائي غير متاح حالياً، لكن QR والإدخال اليدوي يعملان.';
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _stopHosting() async {
    await widget.service.stopListening();
    if (mounted) {
      setState(() {
        _invite = null;
        _status = 'تم إيقاف الاستقبال.';
      });
    }
  }

  Future<void> _refreshInviteAfterNetworkChange() async {
    try {
      final hadInvite = _invite != null;
      final refreshed = await widget.service.refreshInvite();
      if (mounted) {
        setState(() {
          _invite = refreshed;
          if (hadInvite && refreshed == null) {
            _error = 'لا يوجد عنوان محلي صالح حالياً. أعد الاتصال بالشبكة وأنشئ دعوة جديدة.';
          }
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'تعذر تحديث عناوين الدعوة: $error');
      }
    }
  }

  Future<void> _scanQrInvite() async {
    final invite = await Navigator.of(context).push<PairingInvitePayload>(
      MaterialPageRoute<PairingInvitePayload>(
        builder: (_) => const PairingQrScannerPage(),
      ),
    );
    if (!mounted || invite == null) {
      return;
    }
    await _confirmAndConnectInvite(invite);
  }

  Future<void> _pasteQrInvite() async {
    try {
      final clipboard = await Clipboard.getData('text/plain');
      final raw = clipboard?.text?.trim();
      if (raw == null || raw.isEmpty) {
        throw const FormatException('لا توجد دعوة منسوخة في الحافظة. انسخ بيانات QR من الجهاز المستضيف أولاً.');
      }
      final invite = PairingInvitePayload.decode(raw);
      if (!mounted) {
        return;
      }
      await _confirmAndConnectInvite(invite);
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'تعذر قراءة دعوة الحافظة: $error');
      }
    }
  }

  Future<void> _confirmAndConnectInvite(PairingInvitePayload invite) async {
    if (!mounted) {
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مراجعة دعوة الاقتران'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('الجهاز: ${invite.displayName}',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('المعرّف: ${invite.deviceId}'),
            Text('العناوين: ${invite.addresses.join('، ')}'),
            Text('المنفذ: ${invite.port}'),
            Text('تنتهي الدعوة: ${invite.expiresAt.toLocal().toString().substring(0, 16)}'),
            const SizedBox(height: 10),
            const Text(
              'لن يتم حفظ الجهاز إلا بعد نجاح التحقق وموافقة الجهاز المستضيف. لا توافق على دعوة من مصدر لا تعرفه.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('متابعة والاتصال'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ التحقق من هوية ${invite.displayName} والاتصال...';
    });
    try {
      await widget.service.connectWithInvite(invite);
      await _reload();
      if (mounted) {
        setState(() => _status = 'تم الاقتران الآمن مع ${invite.displayName}.');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _toggleDiscovery() async {
    if (_scanningNearby) {
      await widget.service.stopDiscovery();
      return;
    }
    setState(() {
      _error = null;
      _nearbyDevices = const [];
    });
    try {
      await widget.service.startDiscovery();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _connectDiscovered(DiscoveredPeer peer) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ التحقق من الجهاز المقترن ${peer.displayName} على العنوان الجديد...';
    });
    try {
      await widget.service.connectToDiscoveredPeer(peer);
      await _reload();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _connect() async {
    final address = _addressController.text.trim();
    final code = _codeController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (address.isEmpty || code.isEmpty || port == null) {
      setState(() => _error = 'أدخل عنوان الجهاز والمنفذ ورمز الاقتران.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ الاتصال والتحقق من رمز الاقتران...';
    });
    try {
      await widget.service.connect(
        address: address,
        port: port,
        pairingCode: code,
      );
      _codeController.clear();
      await _reload();
      if (mounted) {
        setState(() => _status = 'تم الاقتران والاتصال بنجاح.');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _connectKnown(PairedDeviceRecord device) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ إعادة الاتصال بـ ${device.displayName}...';
    });
    try {
      await widget.service.connectToPairedDevice(device.id);
      await _reload();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _ping(PairedDeviceRecord device) async {
    try {
      await widget.service.ping(device.id);
      if (mounted) {
        setState(() => _status = 'أُرسل اختبار اتصال إلى ${device.displayName}.');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _toggleBlock(PairedDeviceRecord device) async {
    if (!device.isBlocked) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('حظر الجهاز'),
          content: Text(
            'سيتم قطع اتصال ${device.displayName} ومنع اتصالاته القادمة. يمكنك رفع الحظر لاحقاً دون إعادة الاقتران.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('حظر الجهاز'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }
    await widget.service.setBlocked(device.id, !device.isBlocked);
    await _reload();
  }

  Future<void> _forget(PairedDeviceRecord device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إزالة الجهاز'),
        content: Text(
          'سيتم حذف ${device.displayName} ومفتاحه المحلي. ستحتاج إلى رمز اقتران جديد للاتصال به لاحقاً.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('إزالة'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.service.forget(device.id);
    await _reload();
  }

  Future<void> _copyInvite() async {
    final invite = _invite;
    if (invite == null) {
      return;
    }
    final text = invite.qrPayload;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      setState(() => _status = 'تم نسخ بيانات الدعوة. أرسلها عبر قناة موثوقة.');
    }
  }

  @override
  void dispose() {
    widget.service.onPairingRequest = null;
    widget.service.onTaskProposalRequest = null;
    widget.service.clearPeerExecutionHandlers();
    // Leaving this screen stops accepting new devices; established sessions remain alive.
    if (widget.service.isDiscovering) {
      unawaited(widget.service.stopDiscovery());
    }
    if (widget.service.isListening) {
      unawaited(widget.service.stopListening());
    }
    unawaited(_eventsSubscription?.cancel());
    _addressController.dispose();
    _codeController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الأجهزة المتصلة'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  _introCard(context),
                  const SizedBox(height: 14),
                  _hostingCard(context),
                  const SizedBox(height: 14),
                  _connectCard(context),
                  const SizedBox(height: 14),
                  _nearbyDevicesSection(context),
                  const SizedBox(height: 18),
                  _pairedDevicesSection(context),
                  const SizedBox(height: 18),
                  _taskTransfersSection(context),
                  const SizedBox(height: 18),
                  _peerTaskExecutionsSection(context),
                  if (_status != null) ...[
                    const SizedBox(height: 12),
                    _notice(_status!, isError: false),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    _notice(_error!, isError: true),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _introCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.devices_rounded, color: colors.primary, size: 28),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'أجهزة NEXUS المتصلة',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Text(
                    '${widget.service.connectedDeviceIds.length} متصل',
                    style: TextStyle(color: colors.onPrimaryContainer, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'اربط هاتفين أو أكثر على الشبكة المحلية لتبادل معلومات الاتصال والقدرات بأمان. لا يُرسل أي نموذج أو ملف أو مهمة تلقائياً.',
              style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: 8),
            Text(
              'المعرّف المحلي: ${widget.service.localDeviceId ?? 'جارٍ التهيئة'}',
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hostingCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('استقبال جهاز آخر', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 6),
            const Text('أنشئ دعوة مؤقتة. يجب أن يكون الجهازان على الشبكة المحلية نفسها.'),
            const SizedBox(height: 12),
            if (_invite != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Column(
                        children: [
                          const Text('امسح الرمز من الجهاز الآخر',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: SizedBox.square(
                              dimension: 220,
                              child: CustomPaint(
                                painter: _PairingQrPainter(_invite!.qrPayload),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'الرمز يحتوي سر الاقتران؛ اعرضه للشخص أو الجهاز المقصود فقط.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text('عناوين الاتصال', style: TextStyle(fontWeight: FontWeight.w700)),
                    for (final address in _invite!.addresses)
                      SelectableText('$address:${_invite!.port}'),
                    const SizedBox(height: 10),
                    const Text('رمز الاقتران — سري لمرة واحدة', style: TextStyle(fontWeight: FontWeight.w700)),
                    SelectableText(
                      _invite!.code,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'تنتهي الدعوة ${_invite!.expiresAt.toLocal().toString().substring(0, 16)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _copyInvite,
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('نسخ بيانات الدعوة'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _createInvite,
                  icon: const Icon(Icons.add_link_rounded),
                  label: const Text('إنشاء دعوة'),
                ),
                if (widget.service.isListening)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _stopHosting,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('إيقاف الاستقبال'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _connectCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('الاقتران بجهاز آخر', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 10),
            TextField(
              controller: _addressController,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                labelText: 'عنوان IPv4 المحلي',
                hintText: '192.168.1.20',
                prefixIcon: Icon(Icons.lan_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'المنفذ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 5,
                  child: TextField(
                    controller: _codeController,
                    decoration: const InputDecoration(
                      labelText: 'رمز الاقتران',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _scanQrInvite,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('مسح دعوة QR من الجهاز الآخر'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pasteQrInvite,
                icon: const Icon(Icons.content_paste_rounded),
                label: const Text('لصق دعوة من الحافظة دون كاميرا'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _connect,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link_rounded),
                label: const Text('تحقق واقرن الجهاز'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nearbyDevicesSection(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('اكتشاف الأجهزة القريبة',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _toggleDiscovery,
                  icon: Icon(_scanningNearby ? Icons.stop_circle_outlined : Icons.radar_rounded),
                  label: Text(_scanningNearby ? 'إيقاف البحث' : 'بحث لمدة 30 ثانية'),
                ),
              ],
            ),
            const Text(
              'يعرض البحث الأجهزة التي تستضيف دعوة اقتران فعّالة فقط. لا يتضمن الإعلان سر الدعوة ولا يثبت هوية الجهاز.',
              style: TextStyle(fontSize: 12),
            ),
            if (_scanningNearby && _nearbyDevices.isEmpty) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('جارٍ البحث على الشبكة المحلية...'),
            ],
            if (!_scanningNearby && _nearbyDevices.isEmpty) ...[
              const SizedBox(height: 12),
              const Text('لا توجد أجهزة ظاهرة حالياً. اطلب من الجهاز الآخر إنشاء دعوة أولاً.'),
            ],
            for (final peer in _nearbyDevices) ...[
              const Divider(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.devices_other_rounded),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(peer.displayName,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${peer.platform} · ${peer.address}:${peer.port}'),
                        const Text('ظاهر على الشبكة — الهوية غير موثقة',
                            style: TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                  if (_devices.any((device) => device.id == peer.deviceId && !device.isBlocked))
                    TextButton(
                      onPressed: _busy ? null : () => _connectDiscovered(peer),
                      child: const Text('إعادة الاتصال'),
                    )
                  else
                    const Icon(Icons.qr_code_2_rounded, size: 20),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pairedDevicesSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('الأجهزة المقترنة', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            ),
            TextButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('تحديث'),
            ),
          ],
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonalIcon(
            onPressed: _busy ? null : _showModelPlacementAdvisor,
            icon: const Icon(Icons.device_hub_outlined, size: 18),
            label: const Text('ترشيح جهاز حسب نموذج GGUF'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 8),
          child: Text(
            'يمكن ترتيب الأجهزة وفق ملاءمة نموذج وسياق محددين. يعتمد الترشيح على بيانات موارد حديثة ووجود وكيل جاهز بملف مواصفات GGUF متوافق؛ لا يُرسل أي طلب تلقائياً.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        if (_devices.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: Text('لا توجد أجهزة مقترنة بعد.')),
            ),
          )
        else
          for (final placement in PeerExecutionPlacementAdvisor.rank(
            devices: _devices,
            connectedDeviceIds: widget.service.connectedDeviceIds,
          ))
            _deviceCard(context, placement),
      ],
    );
  }

  Future<void> _showModelPlacementAdvisor() async {
    if (_busy) return;
    final models = (await ModelRepository().list())
        .where((model) =>
            model.runtime == ModelRuntime.llamaCpp &&
            model.status == ModelInstallStatus.installed &&
            model.sizeBytes != null &&
            model.sizeBytes! > 0 &&
            PeerInstalledModelProfile.fromModel(model) != null)
        .toList(growable: false);
    if (!mounted) {
      return;
    }
    if (models.isEmpty) {
      setState(() => _status =
          'لا يوجد نموذج GGUF مثبت ببيانات كافية لترشيح الأجهزة.');
      return;
    }

    final selectedModel = await showDialog<ModelRecord>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('اختر نموذج GGUF'),
        children: [
          for (final model in models)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(model),
              child: Text(
                '${model.displayName} · ${model.architecture ?? 'معمارية غير معروفة'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
    if (selectedModel == null || !mounted) return;

    final contexts = [512, 1024, 2048, 4096]
        .where((value) => selectedModel.contextLength == null ||
            value <= selectedModel.contextLength!)
        .toList(growable: false);
    if (contexts.isEmpty) {
      setState(() => _error = 'نافذة السياق المسجلة في GGUF لا تدعم الخيارات الحالية.');
      return;
    }
    final selectedContext = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('اختر حجم السياق'),
        children: [
          for (final value in contexts)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(value),
              child: Text('$value رمز'),
            ),
        ],
      ),
    );
    if (selectedContext == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ التحقق من ملف النموذج وحساب ملاءمة الأجهزة...';
    });
    try {
      final verification = await LocalModelFileVerifier().verify(selectedModel);
      if (!verification.isValid) {
        throw StateError(verification.message);
      }
      final ranked = PeerExecutionPlacementAdvisor.rankForModel(
        devices: _devices,
        connectedDeviceIds: widget.service.connectedDeviceIds,
        model: selectedModel,
        verifiedModelFileBytes:
            verification.actualSizeBytes ?? selectedModel.sizeBytes!,
        contextTokens: selectedContext,
      );
      if (!mounted) {
      return;
    }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('ترشيح الأجهزة · ${selectedModel.displayName}'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('السياق: $selectedContext رمز'),
                  const SizedBox(height: 8),
                  const Text(
                    'الترشيح لا ينفذ المهمة. يعتمد على تطابق مواصفات GGUF المعلنة، وليس بصمة محتوى الأوزان. سيظل على الجهاز المستلم اختيار الوكيل ومراجعة طلب التنفيذ.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  if (ranked.isEmpty)
                    const Text('لا توجد أجهزة مقترنة للترشيح.'),
                  for (var index = 0; index < ranked.length; index++) ...[
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${index + 1}. ${ranked[index].device.displayName}',
                                    style: const TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                ),
                                Chip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(ranked[index].label),
                                ),
                              ],
                            ),
                            Text(ranked[index].resourceSummary,
                                style: Theme.of(context).textTheme.bodySmall),
                            if (ranked[index].modelFit != null) ...[
                              const SizedBox(height: 4),
                              Text(ranked[index].modelFit!.statusLabel,
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(
                                'الموصى به: ${(ranked[index].modelFit!.recommendedRequiredBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB · المتاح: ${(ranked[index].modelFit!.availableMemoryBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                            for (final reason in ranked[index].explanation.take(4))
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text('• $reason',
                                    style: Theme.of(context).textTheme.bodySmall),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'تعذر حساب ترشيح الأجهزة: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _taskTransfersSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('نقل مقترحات المهام', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            ),
            TextButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('تحديث'),
            ),
          ],
        ),
        if (_transfers.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Center(child: Text('لا توجد مقترحات مهام مرسلة أو واردة.')),
            ),
          )
        else
          for (final transfer in _transfers)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(transfer.direction == 'incoming' ? Icons.move_to_inbox_rounded : Icons.outbox_rounded),
                        const SizedBox(width: 8),
                        Expanded(child: Text(transfer.goal, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                        Text(_transferStatusLabel(transfer), style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text('${transfer.direction == 'incoming' ? 'وارد من' : 'مرسل إلى'} ${transfer.deviceId} · ${transfer.stepCount} خطوات', style: Theme.of(context).textTheme.bodySmall),
                    if (transfer.lastError != null && transfer.lastError!.isNotEmpty)
                      Text(transfer.lastError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                    if (transfer.direction == 'incoming' && transfer.status == 'kept')
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          TextButton.icon(
                            onPressed: () => _viewTaskTransfer(transfer),
                            icon: const Icon(Icons.visibility_outlined, size: 18),
                            label: const Text('عرض المقترح'),
                          ),
                          if (transfer.importedTaskId == null)
                            FilledButton.tonalIcon(
                              onPressed: _busy ? null : () => _importTaskTransfer(transfer),
                              icon: const Icon(Icons.move_to_inbox_outlined, size: 18),
                              label: const Text('استيراد كمهمة محلية'),
                            )
                          else
                            TextButton.icon(
                              onPressed: null,
                              icon: const Icon(Icons.task_alt_rounded, size: 18),
                              label: const Text('مستورد محلياً'),
                            ),
                        ],
                      ),
                    if (transfer.direction == 'outgoing' && transfer.status == 'queued')
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton.icon(
                          onPressed: () async {
                            try {
                              await widget.service.retryQueuedTaskTransfers(transfer.deviceId);
                              await _reload();
                            } on Object catch (error) {
                              if (mounted) {
                                setState(() => _error = error.toString());
                              }
                            }
                          },
                          icon: const Icon(Icons.sync_rounded, size: 18),
                          label: const Text('إعادة المحاولة'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  String _transferStatusLabel(RemoteTaskTransferRecord transfer) {
    if (transfer.importedTaskId != null) return 'مستورد كمهمة محلية';
    switch (transfer.status) {
      case 'queued': return 'بانتظار الإرسال';
      case 'sent': return 'تم الاستلام';
      case 'pending_review': return 'بانتظار المراجعة';
      case 'kept': return 'محفوظ';
      case 'declined': return 'مرفوض';
      case 'rejected': return 'رفضه الجهاز المستلم';
      default: return transfer.status;
    }
  }

  Widget _deviceCard(
    BuildContext context,
    PeerPlacementAssessment placement,
  ) {
    final device = placement.device;
    final connected = widget.service.isConnected(device.id);
    final colors = Theme.of(context).colorScheme;
    final placementColor = switch (placement.status) {
      PeerPlacementStatus.recommended => colors.primary,
      PeerPlacementStatus.eligible => colors.secondary,
      PeerPlacementStatus.busy => colors.tertiary,
      PeerPlacementStatus.blocked => colors.error,
      _ => colors.onSurfaceVariant,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  connected ? Icons.devices_rounded : Icons.devices_other_rounded,
                  color: connected ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    device.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  device.isBlocked ? 'محظور' : connected ? 'متصل' : 'غير متصل',
                  style: TextStyle(
                    color: device.isBlocked
                        ? colors.error
                        : connected
                            ? colors.primary
                            : colors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('${device.platform} · ${device.lastAddress}:${device.lastPort}'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    placement.label,
                    style: TextStyle(color: placementColor, fontSize: 11),
                  ),
                  side: BorderSide(color: placementColor.withValues(alpha: 0.35)),
                  backgroundColor: placementColor.withValues(alpha: 0.07),
                ),
              ],
            ),
            Text(
              placement.resourceSummary,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'بصمة الجلسة: ${device.fingerprint}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (!connected && !device.isBlocked)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _connectKnown(device),
                    icon: const Icon(Icons.sync_rounded, size: 18),
                    label: const Text('إعادة الاتصال'),
                  ),
                if (connected)
                  TextButton.icon(
                    onPressed: () => _ping(device),
                    icon: const Icon(Icons.memory_rounded, size: 18),
                    label: const Text('تحديث الموارد والاتصال'),
                  ),
                if (!device.isBlocked)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _shareTaskProposal(device),
                    icon: const Icon(Icons.outbox_rounded, size: 18),
                    label: const Text('إرسال مقترح مهمة'),
                  ),
                if (connected && !device.isBlocked &&
                    device.capabilities['task_execution'] == true &&
                    device.capabilities['task_execution_version'] == peerTaskExecutionVersion)
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _sendRemoteStep(device),
                    icon: const Icon(Icons.play_circle_outline_rounded, size: 18),
                    label: const Text('تنفيذ خطوة على الجهاز'),
                  ),
                TextButton.icon(
                  onPressed: () => _toggleBlock(device),
                  icon: Icon(
                    device.isBlocked ? Icons.lock_open_rounded : Icons.block_rounded,
                    size: 18,
                  ),
                  label: Text(device.isBlocked ? 'رفع الحظر' : 'حظر'),
                ),
                TextButton.icon(
                  onPressed: () => _forget(device),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('إزالة'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _notice(String text, {required bool isError}) {
    final color = isError ? Colors.red : Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}


class _PairingQrPainter extends CustomPainter {
  _PairingQrPainter(String payload)
      : _payload = payload,
        _image = QrImage(
          QrCode(
            payload: QrPayload.fromString(payload),
            errorCorrectLevel: QrErrorCorrectLevel.medium,
          ),
        );

  final String _payload;
  final QrImage _image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.white, BlendMode.src);
    final modules = _image.moduleCount;
    const quietZone = 4.0;
    final cell = size.shortestSide / (modules + quietZone * 2);
    final offsetX = (size.width - (modules + quietZone * 2) * cell) / 2;
    final offsetY = (size.height - (modules + quietZone * 2) * cell) / 2;
    final paint = Paint()..color = const Color(0xFF101828);
    for (var y = 0; y < modules; y++) {
      for (var x = 0; x < modules; x++) {
        if (_image.isDark(x, y)) {
          canvas.drawRect(
            Rect.fromLTWH(
              offsetX + (x + quietZone) * cell,
              offsetY + (y + quietZone) * cell,
              cell + 0.15,
              cell + 0.15,
            ),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PairingQrPainter oldDelegate) =>
      _payload != oldDelegate._payload;
}
