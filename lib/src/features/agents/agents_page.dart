import 'package:flutter/material.dart';

import 'agent_record.dart';
import 'agent_repository.dart';

class AgentsPage extends StatefulWidget {
  const AgentsPage({super.key});

  @override
  State<AgentsPage> createState() => _AgentsPageState();
}

class _AgentsPageState extends State<AgentsPage> {
  final _repository = AgentRepository();
  late Future<List<AgentRecord>> _agents;

  @override
  void initState() {
    super.initState();
    _agents = _repository.list();
  }

  void _refresh() {
    setState(() => _agents = _repository.list());
  }

  Future<void> _createAgent() async {
    final nameController = TextEditingController();
    final descriptionController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إنشاء وكيل'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'اسم الوكيل'),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'أدخل اسماً للوكيل';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(labelText: 'الوصف (اختياري)'),
                minLines: 1,
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('إنشاء'),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = 'agent-$now';
      await _repository.create(
        AgentRecord(
          id: id,
          name: nameController.text.trim(),
          description: descriptionController.text.trim(),
          status: AgentRecordStatus.draft,
          createdAtUnixMs: now,
        ),
      );
      _refresh();
    }
    nameController.dispose();
    descriptionController.dispose();
  }

  Future<void> _deleteAgent(AgentRecord agent) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف الوكيل؟'),
        content: Text('سيتم حذف "${agent.name}" من هذا الجهاز.'),
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
    if (confirmed == true) {
      await _repository.delete(agent.id);
      _refresh();
    }
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
                child: Text('تعذر تحميل الوكلاء: ${snapshot.error}'),
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
                    Text('لا توجد وكلاء بعد',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 6),
                    const Text('أنشئ أول وكيل لحفظه محلياً على هذا الجهاز.'),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _createAgent,
                      icon: const Icon(Icons.add),
                      label: const Text('إنشاء وكيل'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: agents.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final agent = agents[index];
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.hub_outlined)),
                  title: Text(agent.name),
                  subtitle: Text(
                    agent.description.isEmpty
                        ? 'مسودة · محفوظ محلياً'
                        : '${agent.description}\nمسودة · محفوظ محلياً',
                  ),
                  isThreeLine: agent.description.isNotEmpty,
                  trailing: IconButton(
                    tooltip: 'حذف الوكيل',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteAgent(agent),
                  ),
                ),
              );
            },
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
}
