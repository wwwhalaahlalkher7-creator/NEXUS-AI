import 'package:flutter/material.dart';

import 'model_record.dart';
import 'model_repository.dart';

class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key, this.store});

  final ModelStore? store;

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  late final ModelStore _store;
  late Future<List<ModelRecord>> _modelsFuture;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? ModelRepository();
    _modelsFuture = _store.list();
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
    if (model == null) return;

    try {
      await _store.register(model);
      if (!mounted) return;
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تمت إضافة النموذج إلى المكتبة المحلية')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذرت إضافة النموذج: $error')),
      );
    }
  }

  Future<void> _deleteModel(ModelRecord model) async {
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
    if (confirmed != true) return;

    try {
      await _store.delete(model.id);
      if (!mounted) return;
      _reload();
    } catch (error) {
      if (!mounted) return;
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
                  '${models.length} سجل محلي · لا يوجد نموذج نشط حالياً',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                for (final model in models)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      contentPadding: const EdgeInsetsDirectional.only(
                        start: 16,
                        end: 8,
                        top: 6,
                        bottom: 6,
                      ),
                      leading: CircleAvatar(
                        backgroundColor:
                            Theme.of(context).colorScheme.secondaryContainer,
                        child: const Icon(Icons.memory_outlined),
                      ),
                      title: Text(
                        model.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${_runtimeLabel(model.runtime)} · مُسجّل فقط، غير مثبت',
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: 'حذف السجل',
                        onPressed: () => _deleteModel(model),
                        icon: const Icon(Icons.delete_outline),
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

  String _runtimeLabel(ModelRuntime runtime) {
    return switch (runtime) {
      ModelRuntime.llamaCpp => 'llama.cpp',
      ModelRuntime.external => 'مصدر خارجي',
    };
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
    if (!_formKey.currentState!.validate()) return;
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
                if (value != null) setState(() => _runtime = value);
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
