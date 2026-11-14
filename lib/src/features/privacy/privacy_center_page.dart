import 'package:material_ui/material_ui.dart';

import 'local_data_privacy_service.dart';

class PrivacyCenterPage extends StatefulWidget {
  const PrivacyCenterPage({super.key, this.service});

  final LocalDataPrivacyService? service;

  @override
  State<PrivacyCenterPage> createState() => _PrivacyCenterPageState();
}

class _PrivacyCenterPageState extends State<PrivacyCenterPage> {
  late final LocalDataPrivacyService _service;
  bool _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? LocalDataPrivacyService();
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final saved = await _service.exportToUserSelectedFile();
      if (!mounted) return;
      if (saved == null) {
        _showMessage('تم إلغاء التصدير. لم يُحذف أي شيء.');
      } else {
        _showMessage('تم إنشاء نسخة البيانات المحلية بنجاح.');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر تصدير البيانات: $error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _confirmDelete({
    required String title,
    required String description,
    required String actionLabel,
    required Future<int> Function() action,
    required String successLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final removed = await action();
      if (!mounted) return;
      _showMessage('$successLabel: $removed');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'لم يتم الحذف: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _deleteCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String description,
    required String actionLabel,
    required Future<int> Function() action,
    required String successLabel,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: colors.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(description),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: OutlinedButton.icon(
                onPressed: () => _confirmDelete(
                  title: title,
                  description: 'هذا الإجراء لا يمكن التراجع عنه. $description',
                  actionLabel: actionLabel,
                  action: action,
                  successLabel: successLabel,
                ),
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(actionLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('الخصوصية والبيانات المحلية')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Text(
            'بياناتك تبقى على جهازك',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'من هنا يمكنك إنشاء نسخة JSON من بياناتك أو حذف أقسام محددة. '
            'لا ترسل NEXUS هذه البيانات إلى خادم خارجي.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.45,
                ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.file_download_outlined),
                      SizedBox(width: 10),
                      Text(
                        'تصدير نسخة من بياناتي',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'يتضمن المحادثات والرسائل وتعليمات الوكلاء وخطط المهام '
                    'ومحتوى مكتبة المعرفة وسجل القياسات وبيانات النماذج الوصفية. '
                    'لا يتضمن ملفات GGUF أو مساراتها أو أسرار الاقتران أو '
                    'عناوين الأجهزة وبصماتها. ملف JSON غير مشفر ويجب حفظه '
                    'في موقع موثوق. يُجهّز التصدير داخل ذاكرة التطبيق مؤقتاً؛ '
                    'قد يكون تصدير قواعد كبيرة جداً صعباً على الأجهزة محدودة الذاكرة.',
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _exporting ? null : _export,
                      icon: _exporting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_alt_rounded),
                      label: Text(_exporting ? 'جارٍ تجهيز النسخة...' : 'تصدير JSON'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'إدارة البيانات وحذفها',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 8),
          _deleteCard(
            context: context,
            icon: Icons.chat_bubble_outline_rounded,
            title: 'سجل المحادثات',
            description: 'يحذف المحادثات ورسائلها. يُرفض الحذف إذا كان هناك توليد جارٍ.',
            actionLabel: 'حذف المحادثات',
            action: _service.clearConversationHistory,
            successLabel: 'عدد المحادثات المحذوفة',
          ),
          _deleteCard(
            context: context,
            icon: Icons.library_books_outlined,
            title: 'مكتبة المعرفة',
            description: 'يحذف فهرس TXT وMarkdown والمقاطع النصية المخزنة. لا يحذف ملفاتك الأصلية.',
            actionLabel: 'مسح المكتبة',
            action: _service.clearKnowledgeLibrary,
            successLabel: 'عدد الوثائق المحذوفة',
          ),
          _deleteCard(
            context: context,
            icon: Icons.account_tree_outlined,
            title: 'سجل المهام والنقل بين الأجهزة',
            description: 'يحذف خطط المهام وسجل التنفيذ والنقل المحلي. يُرفض الحذف عند وجود مهمة نشطة أو نقل مقترح لم يكتمل أو موافقة معلقة.',
            actionLabel: 'حذف سجل المهام',
            action: _service.clearTaskHistory,
            successLabel: 'عدد السجلات المحذوفة',
          ),
          _deleteCard(
            context: context,
            icon: Icons.speed_outlined,
            title: 'سجل قياسات الأداء',
            description: 'يحذف نتائج Benchmark المحفوظة فقط، ولا يحذف النماذج أو نتائجها الأصلية على جهازك.',
            actionLabel: 'حذف القياسات',
            action: _service.clearBenchmarkHistory,
            successLabel: 'عدد القياسات المحذوفة',
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: colors.error)),
          ],
          const SizedBox(height: 12),
          Card(
            color: colors.surfaceContainerLow,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'الحذف هنا لا يمسح ملفات النماذج GGUF أو إعدادات الوكلاء '
                'أو مفاتيح الأجهزة المقترنة أو تفضيلات الموارد. لإلغاء الثقة '
                'بجهاز آخر استخدم صفحة الأجهزة ثم أزل الاقتران منه. '
                'نسخة JSON قد تحتوي على محادثاتك وتعليمات وكلائك ووثائقك؛ '
                'احفظها في مكان موثوق.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
