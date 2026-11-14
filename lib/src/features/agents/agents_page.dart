import 'package:material_ui/material_ui.dart';

import '../models/model_file_verifier.dart';
import '../models/model_record.dart';
import '../models/model_repository.dart';
import '../orchestration/agent_tasks_page.dart';
import '../runtime/model_runtime_manager.dart';
import 'agent_record.dart';
import 'agent_repository.dart';

class AgentsPage extends StatefulWidget {
  const AgentsPage({
    super.key,
    this.repository,
    this.modelRepository,
    this.modelFileVerifier,
    this.runtimeManager,
  });

  final AgentStore? repository;
  final ModelStore? modelRepository;
  final ModelFileVerifier? modelFileVerifier;
  final ModelRuntimeManager? runtimeManager;

  @override
  State<AgentsPage> createState() => _AgentsPageState();
}

class _AgentsPageState extends State<AgentsPage> {
  late final AgentStore _repository;
  late final ModelStore _modelRepository;
  late final ModelFileVerifier _modelFileVerifier;
  late Future<List<AgentRecord>> _agents;
  final Set<String> _updatingIds = <String>{};
  final Set<String> _deletingIds = <String>{};

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? AgentRepository();
    _modelRepository = widget.modelRepository ?? ModelRepository();
    _modelFileVerifier = widget.modelFileVerifier ?? LocalModelFileVerifier();
    _agents = _repository.list();
  }

  void _refresh() {
    setState(() {
      _agents = _repository.list();
    });
  }

  Future<void> _createAgent() async {
    // The dialog owns its controllers. showDialog completes when the route is
    // popped, before its reverse transition necessarily finishes, so disposing
    // controllers here can race the still-mounted TextFormField subtree.
    final draft = await showDialog<_AgentDraft>(
      context: context,
      builder: (_) => const _CreateAgentDialog(),
    );
    if (draft == null || !mounted) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'agent-${DateTime.now().microsecondsSinceEpoch}';
    try {
      await _repository.create(
        AgentRecord(
          id: id,
          name: draft.name,
          description: draft.description,
          systemPrompt: draft.systemPrompt,
          status: AgentRecordStatus.draft,
          createdAtUnixMs: now,
        ),
      );
      if (mounted) {
        _refresh();
        _showMessage('تم حفظ الوكيل كمسودة محلية.');
      }
    } catch (error) {
      if (mounted) {
        _showMessage('تعذر إنشاء الوكيل: $error');
      }
    }
  }

  Future<void> _editInstructions(AgentRecord agent) async {
    final prompt = await showDialog<String>(
      context: context,
      builder: (_) => _AgentInstructionsDialog(
        initialValue: agent.systemPrompt,
      ),
    );
    if (prompt == null || !mounted) {
      return;
    }
    setState(() => _updatingIds.add(agent.id));
    try {
      await _repository.updateSystemPrompt(agent.id, prompt);
      if (mounted) {
        _refresh();
        _showMessage('تم حفظ تعليمات «${agent.name}».');
      }
    } catch (error) {
      if (mounted) {
        _showMessage('تعذر حفظ التعليمات: $error');
      }
    } finally {
      if (mounted) setState(() => _updatingIds.remove(agent.id));
    }
  }

  Future<void> _changeStatus(
    AgentRecord agent,
    AgentRecordStatus status,
  ) async {
    if (_updatingIds.contains(agent.id) || agent.status == status) {
      return;
    }
    setState(() {
      _updatingIds.add(agent.id);
    });
    try {
      await _repository.updateStatus(agent.id, status);
      if (mounted) {
        _refresh();
        _showMessage('تم تحديث حالة «${agent.name}».');
      }
    } catch (error) {
      if (mounted) {
        _showMessage('تعذر تحديث الحالة: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _updatingIds.remove(agent.id);
        });
      }
    }
  }

  Future<void> _assignModel(AgentRecord agent) async {
    List<ModelRecord> available;
    try {
      final models = await _modelRepository.list();
      available = models
          .where((model) =>
              model.runtime == ModelRuntime.llamaCpp &&
              model.status == ModelInstallStatus.installed &&
              (model.localPath?.trim().isNotEmpty ?? false))
          .toList(growable: false);
    } catch (error) {
      if (mounted) {
        _showMessage('تعذر تحميل النماذج المحلية: $error');
      }
      return;
    }
    if (!mounted) {
      return;
    }
    final selected = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ربط نموذج بالوكيل'),
        content: available.isEmpty
            ? const Text('لا توجد نماذج محلية مثبتة وصالحة للربط حالياً.')
            : SizedBox(
                width: double.maxFinite,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: RadioGroup<String>(
                    groupValue: agent.modelId,
                    onChanged: (value) {
                      if (value != null) {
                        Navigator.pop(dialogContext, value);
                      }
                    },
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final model in available)
                          RadioListTile<String>(
                            value: model.id,
                            title: Text(model.displayName),
                            subtitle: Text(_modelDetails(model)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
        actions: [
          if (agent.modelId != null)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, ''),
              child: const Text('إزالة الربط'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final modelId = selected.isEmpty ? null : selected;
    setState(() => _updatingIds.add(agent.id));
    try {
      if (modelId != null) {
        final model = available.firstWhere((item) => item.id == modelId);
        final verification = await _modelFileVerifier.verify(model);
        if (!verification.isValid) {
          if (mounted) {
            _showMessage(
              'لم يتم الربط؛ فشل التحقق من ملف النموذج: ${verification.message}',
            );
          }
          return;
        }
      }
      await _repository.updateModel(agent.id, modelId);
      if (mounted) {
        _refresh();
        _showMessage(modelId == null
            ? 'تمت إزالة النموذج من الوكيل.'
            : 'اجتاز الملف فحص السلامة المحدود وتم ربطه بالوكيل.');
      }
    } catch (error) {
      if (mounted) {
        _showMessage('تعذر ربط النموذج: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _updatingIds.remove(agent.id));
      }
    }
  }

  String _modelDetails(ModelRecord model) {
    final contextLength = model.contextLength;
    if (contextLength == null || contextLength <= 0) {
      return 'نموذج محلي مثبت';
    }
    return 'نموذج محلي مثبت · سياق $contextLength';
  }

  Future<void> _deleteAgent(AgentRecord agent) async {
    if (_deletingIds.contains(agent.id)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف الوكيل؟'),
        content: Text('سيتم حذف «${agent.name}» من هذا الجهاز.'),
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
    setState(() {
      _deletingIds.add(agent.id);
    });
    try {
      await _repository.delete(agent.id);
      if (mounted) {
        _refresh();
        _showMessage('تم حذف الوكيل من هذا الجهاز.');
      }
    } catch (error) {
      if (mounted) {
        _showMessage('تعذر حذف الوكيل: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _deletingIds.remove(agent.id);
        });
      }
    }
  }

  Future<void> _openTaskOrchestration() async {
    final runtimeManager = widget.runtimeManager;
    if (runtimeManager == null) {
      _showMessage('إدارة جلسة النموذج غير متاحة في هذه الشاشة.');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentTasksPage(
          runtimeManager: runtimeManager,
          agentRepository: _repository,
          modelRepository: _modelRepository,
        ),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<List<AgentRecord>>(
        future: _agents,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('تعذر تحميل الوكلاء: ${snapshot.error}'),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              ),
            );
          }
          final agents = snapshot.data ?? const <AgentRecord>[];
          if (agents.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.hub_outlined, size: 52),
                    const SizedBox(height: 12),
                    Text(
                      'لا توجد وكلاء بعد',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    const Text('أنشئ أول وكيل لحفظه محلياً على هذا الجهاز.'),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _createAgent,
                      icon: const Icon(Icons.add),
                      label: const Text('إنشاء وكيل'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: widget.runtimeManager == null
                          ? null
                          : _openTaskOrchestration,
                      icon: const Icon(Icons.account_tree_outlined),
                      label: const Text('تنسيق المهام'),
                    ),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              _refresh();
              await _agents;
            },
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: agents.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                if (index == 0) {
                  final readyCount = agents
                      .where((agent) => agent.status == AgentRecordStatus.ready)
                      .length;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${agents.length} وكيل محفوظ · $readyCount بحالة جاهز',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: widget.runtimeManager == null
                          ? null
                          : _openTaskOrchestration,
                          icon: const Icon(Icons.account_tree_outlined, size: 18),
                          label: const Text('المهام'),
                        ),
                      ],
                    ),
                  );
                }
                final agent = agents[index - 1];
                final isBusy = _updatingIds.contains(agent.id) ||
                    _deletingIds.contains(agent.id);
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsetsDirectional.only(
                      start: 12,
                      end: 4,
                      top: 4,
                      bottom: 4,
                    ),
                    leading: CircleAvatar(
                      backgroundColor:
                          Theme.of(context).colorScheme.secondaryContainer,
                      child: const Icon(Icons.hub_outlined),
                    ),
                    title: Text(
                      agent.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (agent.description.isNotEmpty)
                            Text(
                              agent.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (agent.systemPrompt.trim().isNotEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 3),
                              child: Text(
                                'له تعليمات مخصصة',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          const SizedBox(height: 4),
                          _AgentStatusLabel(status: agent.status),
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              agent.modelId == null
                                  ? 'لم يتم ربط نموذج'
                                  : 'مرتبط بنموذج محلي',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          if (agent.status == AgentRecordStatus.ready)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'يمكن استخدام تعليماته في المحادثة عند اختياره.',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                    isThreeLine: agent.description.isNotEmpty,
                    trailing: PopupMenuButton<String>(
                      enabled: !isBusy,
                      tooltip: 'إجراءات الوكيل',
                      onSelected: (value) {
                        if (value == 'delete') {
                          _deleteAgent(agent);
                        } else if (value == 'assign_model') {
                          _assignModel(agent);
                        } else if (value == 'instructions') {
                          _editInstructions(agent);
                        } else {
                          _changeStatus(
                            agent,
                            AgentRecordStatus.values.byName(value),
                          );
                        }
                      },
                      itemBuilder: (context) => [
                        for (final status in AgentRecordStatus.values)
                          PopupMenuItem<String>(
                            value: status.name,
                            enabled: status != agent.status,
                            child: Text(_statusLabel(status)),
                          ),
                        const PopupMenuItem<String>(
                          value: 'assign_model',
                          child: Text('ربط نموذج محلي'),
                        ),
                        const PopupMenuItem<String>(
                          value: 'instructions',
                          child: Text('تعليمات الوكيل'),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('حذف الوكيل'),
                        ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: isBusy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.more_vert),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createAgent,
        icon: const Icon(Icons.add),
        label: const Text('وكيل جديد'),
      ),
    );
  }

  String _statusLabel(AgentRecordStatus status) {
    return switch (status) {
      AgentRecordStatus.draft => 'تحويل إلى مسودة',
      AgentRecordStatus.ready => 'تحديد كجاهز',
      AgentRecordStatus.paused => 'إيقاف مؤقت',
    };
  }
}

class _AgentDraft {
  const _AgentDraft({
    required this.name,
    required this.description,
    required this.systemPrompt,
  });

  final String name;
  final String description;
  final String systemPrompt;
}

class _CreateAgentDialog extends StatefulWidget {
  const _CreateAgentDialog();

  @override
  State<_CreateAgentDialog> createState() => _CreateAgentDialogState();
}

class _CreateAgentDialogState extends State<_CreateAgentDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _systemPromptController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(
      _AgentDraft(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        systemPrompt: _systemPromptController.text.trim(),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _systemPromptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('إنشاء وكيل'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _nameController,
              maxLength: 48,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'اسم الوكيل'),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'أدخل اسماً للوكيل';
                }
                if (value.trim().length > 48) {
                  return 'الاسم أطول من الحد المسموح';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descriptionController,
              maxLength: 240,
              decoration: const InputDecoration(labelText: 'الوصف (اختياري)'),
              minLines: 1,
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _systemPromptController,
              maxLength: 3000,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'تعليمات الوكيل (اختياري)',
                hintText: 'حدد دوره وطريقة إجابته وحدود عمله…',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('إنشاء'),
        ),
      ],
    );
  }
}

class _AgentStatusLabel extends StatelessWidget {
  const _AgentStatusLabel({required this.status});

  final AgentRecordStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      AgentRecordStatus.draft => Theme.of(context).colorScheme.secondary,
      AgentRecordStatus.ready => Theme.of(context).colorScheme.primary,
      AgentRecordStatus.paused => Theme.of(context).colorScheme.error,
    };
    final label = switch (status) {
      AgentRecordStatus.draft => 'مسودة',
      AgentRecordStatus.ready => 'جاهز',
      AgentRecordStatus.paused => 'متوقف مؤقتاً',
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
        ),
      ),
    );
  }
}

class _AgentInstructionsDialog extends StatefulWidget {
  const _AgentInstructionsDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_AgentInstructionsDialog> createState() =>
      _AgentInstructionsDialogState();
}

class _AgentInstructionsDialogState extends State<_AgentInstructionsDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('تعليمات الوكيل'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 5,
        maxLines: 10,
        maxLength: 3000,
        decoration: const InputDecoration(
          hintText: 'اكتب الدور والسلوك المطلوب وحدود الاستجابة…',
          border: OutlineInputBorder(),
          alignLabelWithHint: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('حفظ التعليمات'),
        ),
      ],
    );
  }
}
