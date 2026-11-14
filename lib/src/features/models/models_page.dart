// The remaining `if` forms in this file are collection elements, not statements.
// ignore_for_file: curly_braces_in_flow_control_structures

import 'package:material_ui/material_ui.dart';

import 'model_record.dart';
import 'model_repository.dart';
import 'model_import_service.dart';
import 'model_file_verifier.dart';
import '../runtime/model_runtime_manager.dart';
import '../runtime/rust_model_runtime_backend.dart';

class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key, this.store, this.importService, this.fileVerifier, this.runtimeManager});

  final ModelStore? store;
  final ModelImportService? importService;
  final ModelFileVerifier? fileVerifier;
  final ModelRuntimeManager? runtimeManager;

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  late final ModelStore _store;
  late final ModelImportService _importService;
  late final ModelFileVerifier _fileVerifier;
  late final ModelRuntimeManager _runtimeManager;
  late final bool _ownsRuntimeManager;
  ModelSessionSnapshot? _runtimeSnapshot;
  late Future<List<ModelRecord>> _modelsFuture;
  final Set<String> _importingModelIds = {};
  final Set<String> _verifyingModelIds = {};
  final Set<String> _loadingModelIds = {};
  final Set<String> _switchingModelIds = {};
  bool _unloadingRuntime = false;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? ModelRepository();
    _importService = widget.importService ?? LocalGgufModelImportService();
    _fileVerifier = widget.fileVerifier ?? LocalModelFileVerifier();
    _ownsRuntimeManager = widget.runtimeManager == null;
    _runtimeManager = widget.runtimeManager ??
        ModelRuntimeManager(
          verifier: _fileVerifier,
          backend: const RustModelRuntimeBackend(),
        );
    // The manager may outlive this tab and retain an active native session.
    _runtimeSnapshot = _runtimeManager.snapshot;
    _runtimeManager.addListener(_handleRuntimeChanged);
    _modelsFuture = _store.list();
  }

  @override
  void dispose() {
    _runtimeManager.removeListener(_handleRuntimeChanged);
    if (_ownsRuntimeManager) {
      _runtimeManager.dispose();
    }
    super.dispose();
  }

  void _handleRuntimeChanged() {
    if (mounted) {
      setState(() => _runtimeSnapshot = _runtimeManager.snapshot);
    }
  }

  void _reload() {
    setState(() {
      _modelsFuture = _store.list();
    });
  }

  Future<void> _addModel() async {
    final model = await showDialog<ModelRecord>(
      context: context,
      builder: (_) => const _AddModelDialog(),
    );
    if (model == null) {
      return;
    }

    try {
      await _store.register(model);
      if (!mounted) {
        return;
      }
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تمت إضافة النموذج إلى المكتبة المحلية')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذرت إضافة النموذج: $error')),
      );
    }
  }

  Future<void> _importModel(ModelRecord model) async {
    if (_importingModelIds.contains(model.id)) {
      return;
    }
    if (_runtimeManager.snapshot.modelId == model.id &&
        (_runtimeManager.isBusy ||
            _runtimeManager.snapshot.isLoaded ||
            _runtimeManager.snapshot.needsRecovery)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أوقف جلسة النموذج أولاً قبل استبدال ملفه.')),
      );
      return;
    }
    setState(() => _importingModelIds.add(model.id));
    try {
      final imported = await _importService.importGguf(model);
      if (imported == null || !mounted) {
        return;
      }
      await _store.updateInstallState(
        model.id,
        status: ModelInstallStatus.installed,
        localPath: imported.path,
        sizeBytes: imported.sizeBytes,
        architecture: imported.inspection.architecture,
        ggufModelName: imported.inspection.modelName,
        tokenizerModel: imported.inspection.tokenizerModel,
        contextLength: imported.inspection.contextLength,
        blockCount: imported.inspection.blockCount,
        embeddingLength: imported.inspection.embeddingLength,
        fileType: imported.inspection.fileType,
        parameterCount: imported.inspection.parameterCount,
      );
      _runtimeManager.resetPreparation();
      if (_runtimeSnapshot?.modelId == model.id) {
        _runtimeSnapshot = null;
      }
      if (!mounted) {
        return;
      }
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم استيراد الملف وتحليل بياناته الوصفية. النموذج غير محمّل بعد.'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر استيراد النموذج: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _importingModelIds.remove(model.id));
      }
    }
  }

  Future<void> _verifyModel(ModelRecord model) async {
    if (_verifyingModelIds.contains(model.id)) {
      return;
    }
    setState(() => _verifyingModelIds.add(model.id));
    try {
      final result = await _fileVerifier.verify(model);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تعذر فحص الملف: $error'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _verifyingModelIds.remove(model.id));
      }
    }
  }

  Future<void> _prepareRuntime(ModelRecord model) async {
    try {
      final result = await _runtimeManager.prepare(model);
      if (!mounted) {
        return;
      }
      setState(() => _runtimeSnapshot = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تقييم جاهزية التشغيل: $error')),
      );
    }
  }

  Future<void> _loadPreparedModel(ModelRecord model) async {
    if (_loadingModelIds.contains(model.id)) {
      return;
    }
    setState(() => _loadingModelIds.add(model.id));
    try {
      final result = await _runtimeManager.loadPrepared(model);
      if (!mounted) {
        return;
      }
      setState(() => _runtimeSnapshot = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل النموذج: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _loadingModelIds.remove(model.id));
      }
    }
  }

  Future<void> _switchRuntimeModel(ModelRecord model) async {
    if (_switchingModelIds.contains(model.id) ||
        _runtimeManager.isBusy ||
        _runtimeManager.isGenerating) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تبديل النموذج النشط؟'),
        content: Text(
          'سيتم تفريغ النموذج الحالي ثم تحميل «${model.displayName}». '
          'إذا فشل التحميل سيحاول المحرك استعادة النموذج السابق.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('تأكيد التبديل'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _switchingModelIds.add(model.id));
    try {
      final result = await _runtimeManager.switchTo(model);
      if (!mounted) return;
      setState(() => _runtimeSnapshot = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تبديل النموذج: $error')),
      );
    } finally {
      if (mounted) setState(() => _switchingModelIds.remove(model.id));
    }
  }

  Future<void> _unloadRuntime() async {
    if (_unloadingRuntime) {
      return;
    }
    setState(() => _unloadingRuntime = true);
    try {
      final result = await _runtimeManager.unload();
      if (!mounted) {
        return;
      }
      setState(() => _runtimeSnapshot = result);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تفريغ النموذج: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _unloadingRuntime = false);
      }
    }
  }

  Future<void> _deleteModel(ModelRecord model) async {
    if (_runtimeManager.snapshot.modelId == model.id &&
        (_runtimeManager.isBusy ||
            _runtimeManager.snapshot.isLoaded ||
            _runtimeManager.snapshot.needsRecovery)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أوقف جلسة النموذج أولاً قبل حذف سجله.')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف النموذج من المكتبة؟'),
        content: Text('سيُحذف سجل «${model.displayName}» المحلي فقط.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف السجل'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    try {
      if (_runtimeSnapshot?.modelId == model.id) {
        _runtimeManager.resetPreparation();
        _runtimeSnapshot = null;
      }
      await _store.delete(model.id);
      if (!mounted) {
        return;
      }
      _reload();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر حذف السجل: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addModel,
        icon: const Icon(Icons.add),
        label: const Text('إضافة نموذج'),
      ),
      body: FutureBuilder<List<ModelRecord>>(
        future: _modelsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _MessageState(
              icon: Icons.error_outline,
              title: 'تعذر تحميل مكتبة النماذج',
              message: '${snapshot.error}',
              action: TextButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
            );
          }

          final models = snapshot.data ?? const <ModelRecord>[];
          if (models.isEmpty) {
            return _MessageState(
              icon: Icons.memory_outlined,
              title: 'مكتبة النماذج فارغة',
              message:
                  'أضف سجلاً لنموذج تريد إدارته. الإضافة هنا تحفظ بياناته فقط؛ '
                  'ولا تعني تنزيل ملف النموذج أو تشغيله.',
              action: FilledButton.icon(
                onPressed: _addModel,
                icon: const Icon(Icons.add),
                label: const Text('إضافة أول نموذج'),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Text(
                  'مكتبة النماذج',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  '${models.length} سجل محلي · '
                  '${_runtimeManager.snapshot.isLoaded ? 'يوجد نموذج نشط على CPU' : 'لا يوجد نموذج نشط حالياً'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                for (final model in models)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                              child: const Icon(Icons.memory_outlined),
                            ),
                            title: Text(
                              model.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(_modelStatusLabel(model)),
                            ),
                            trailing: IconButton(
                              tooltip: 'حذف السجل',
                              onPressed: () => _deleteModel(model),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ),
                          if (model.runtime == ModelRuntime.llamaCpp)
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: TextButton.icon(
                                onPressed: _importingModelIds.contains(model.id)
                                    ? null
                                    : () => _importModel(model),
                                icon: _importingModelIds.contains(model.id)
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.file_open_outlined),
                                label: Text(
                                  _importingModelIds.contains(model.id)
                                      ? 'جارٍ فحص واستيراد الملف…'
                                      : model.status == ModelInstallStatus.installed
                                          ? 'استبدال ملف النموذج'
                                          : 'اختيار ملف GGUF',
                                ),
                              ),
                            ),
                          if (model.status == ModelInstallStatus.installed &&
                              model.runtime == ModelRuntime.llamaCpp)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 8),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  TextButton.icon(
                                    onPressed: _runtimeManager.isBusy ||
                                            _runtimeManager.isGenerating
                                        ? null
                                        : () => _prepareRuntime(model),
                                    icon: const Icon(Icons.play_circle_outline),
                                    label: const Text('تقييم جاهزية التشغيل'),
                                  ),
                                  if (_runtimeSnapshot?.state == ModelSessionState.loaded &&
                                      _runtimeSnapshot?.modelId != model.id)
                                    FilledButton.tonalIcon(
                                      onPressed: _runtimeManager.isBusy ||
                                              _runtimeManager.isGenerating ||
                                              _switchingModelIds.contains(model.id)
                                          ? null
                                          : () => _switchRuntimeModel(model),
                                      icon: _switchingModelIds.contains(model.id)
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            )
                                          : const Icon(Icons.swap_horiz_rounded),
                                      label: Text(
                                        _switchingModelIds.contains(model.id)
                                            ? 'جارٍ التبديل…'
                                            : 'التبديل إلى هذا النموذج',
                                      ),
                                    ),
                                  if (_runtimeManager.engineAvailable &&
                                      _runtimeSnapshot?.state == ModelSessionState.readyToLoad &&
                                      _runtimeSnapshot?.modelId == model.id)
                                    FilledButton.tonalIcon(
                                      onPressed: _runtimeManager.isBusy ||
                                              _runtimeManager.isGenerating ||
                                              _loadingModelIds.contains(model.id)
                                          ? null
                                          : () => _loadPreparedModel(model),
                                      icon: _loadingModelIds.contains(model.id)
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            )
                                          : const Icon(Icons.play_arrow),
                                      label: Text(
                                        _loadingModelIds.contains(model.id)
                                            ? 'جارٍ تحميل الأوزان…'
                                            : 'تحميل النموذج',
                                      ),
                                    ),
                                  if ((_runtimeSnapshot?.state == ModelSessionState.loaded ||
                                          _runtimeSnapshot?.needsRecovery == true) &&
                                      _runtimeSnapshot?.modelId == model.id)
                                    TextButton.icon(
                                      onPressed: _unloadingRuntime ||
                                              _runtimeManager.isBusy ||
                                              _runtimeManager.isGenerating
                                          ? null
                                          : _unloadRuntime,
                                      icon: _unloadingRuntime
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            )
                                          : const Icon(Icons.stop_circle_outlined),
                                      label: Text(
                                        _unloadingRuntime
                                            ? 'جارٍ التفريغ…'
                                            : _runtimeSnapshot?.needsRecovery == true
                                                ? 'استعادة المحرك (تفريغ)'
                                                : 'تفريغ النموذج',
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (_runtimeSnapshot?.modelId == model.id)
                            Padding(
                              padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
                              child: Text(
                                _runtimeSnapshot!.message,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          if (model.status == ModelInstallStatus.installed)
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: TextButton.icon(
                                onPressed: _verifyingModelIds.contains(model.id)
                                    ? null
                                    : () => _verifyModel(model),
                                icon: _verifyingModelIds.contains(model.id)
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.fact_check_outlined),
                                label: Text(
                                  _verifyingModelIds.contains(model.id)
                                      ? 'جارٍ فحص الملف…'
                                      : 'فحص سلامة الملف',
                                ),
                              ),
                            ),
                          if (model.status == ModelInstallStatus.installed && model.sizeBytes != null)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 12, end: 8, bottom: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${_formatBytes(model.sizeBytes!)} · مثبت محلياً${_runtimeSnapshot?.state == ModelSessionState.loaded && _runtimeSnapshot?.modelId == model.id ? ' · محمّل على CPU' : ' · غير محمّل'}',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                  if (model.architecture != null || model.contextLength != null || model.blockCount != null) ...[
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        if (model.architecture != null)
                                          _MetadataChip(label: 'المعمارية: ${model.architecture}'),
                                        if (model.contextLength != null)
                                          _MetadataChip(label: 'السياق: ${_formatCount(model.contextLength!)}'),
                                        if (model.blockCount != null)
                                          _MetadataChip(label: 'الطبقات: ${model.blockCount}'),
                                        if (model.embeddingLength != null)
                                          _MetadataChip(label: 'Embedding: ${model.embeddingLength}'),
                                        if (model.parameterCount != null)
                                          _MetadataChip(label: 'المعاملات: ${_formatCount(model.parameterCount!)}'),
                                      ],
                                    ),
                                  ],
                                  if (model.ggufModelName != null || model.tokenizerModel != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      [model.ggufModelName, model.tokenizerModel]
                                          .whereType<String>()
                                          .join(' · '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _modelStatusLabel(ModelRecord model) {
    final runtime = _runtimeLabel(model.runtime);
    return switch (model.status) {
      ModelInstallStatus.registered => '$runtime · مُسجّل فقط، لا يوجد ملف محلي',
      ModelInstallStatus.installed => '$runtime · ملف GGUF موجود، غير محمّل',
      ModelInstallStatus.unavailable => '$runtime · الملف غير متاح',
    };
  }

  String _formatCount(int value) {
    if (value >= 1000000000) {
      return '${(value / 1000000000).toStringAsFixed(1)}B';
    }
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    return '$value';
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  String _runtimeLabel(ModelRuntime runtime) {
    return switch (runtime) {
      ModelRuntime.llamaCpp => 'llama.cpp',
      ModelRuntime.external => 'مصدر خارجي',
    };
  }
}

class _MetadataChip extends StatelessWidget {
  const _MetadataChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(label),
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: 18),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _AddModelDialog extends StatefulWidget {
  const _AddModelDialog();

  @override
  State<_AddModelDialog> createState() => _AddModelDialogState();
}

class _AddModelDialogState extends State<_AddModelDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  ModelRuntime _runtime = ModelRuntime.llamaCpp;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'model-${DateTime.now().microsecondsSinceEpoch}';
    Navigator.pop(
      context,
      ModelRecord(
        id: id,
        displayName: _nameController.text.trim(),
        runtime: _runtime,
        status: ModelInstallStatus.registered,
        createdAtUnixMs: now,
        updatedAtUnixMs: now,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة نموذج إلى المكتبة'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'اسم النموذج',
                hintText: 'مثال: Qwen 2.5 3B',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'أدخل اسم النموذج';
                }
                return null;
              },
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<ModelRuntime>(
              value: _runtime,
              decoration: const InputDecoration(
                labelText: 'نوع التشغيل',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: ModelRuntime.llamaCpp,
                  child: Text('محلي – llama.cpp'),
                ),
                DropdownMenuItem(
                  value: ModelRuntime.external,
                  child: Text('مصدر خارجي'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _runtime = value);
                }
              },
            ),
            const SizedBox(height: 10),
            Text(
              'هذه الخطوة تسجل بيانات النموذج فقط. إدارة الملفات والتنزيل '
              'والتشغيل ستأتي في مرحلة منفصلة.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}
