import 'package:material_ui/material_ui.dart';

import 'knowledge_document.dart';
import 'knowledge_import_service.dart';
import 'knowledge_repository.dart';

class KnowledgePage extends StatefulWidget {
  const KnowledgePage({
    super.key,
    this.repository,
    this.importService,
  });

  final KnowledgeRepository? repository;
  final KnowledgeImportService? importService;

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  late final KnowledgeRepository _repository;
  late final KnowledgeImportService _importService;
  late Future<List<KnowledgeDocument>> _documentsFuture;
  final TextEditingController _filterController = TextEditingController();
  bool _importing = false;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? KnowledgeRepository();
    _importService = widget.importService ?? KnowledgeImportService();
    _documentsFuture = _repository.listDocuments();
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() => _documentsFuture = _repository.listDocuments());
  }

  Future<void> _importDocument() async {
    if (_importing) {
      return;
    }
    setState(() => _importing = true);
    try {
      final imported = await _importService.pickAndImport(_repository);
      if (!mounted || imported == null) {
        return;
      }
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'أُضيفت «${imported.title}» إلى المكتبة المعرفية.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر استيراد الوثيقة: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  Future<void> _deleteDocument(KnowledgeDocument document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف الوثيقة؟'),
        content: Text(
          'سيُحذف «${document.title}» وجميع المقاطع المفهرسة التابعة لها '
          'من هذا الجهاز.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await _repository.deleteDocument(document.id);
      if (!mounted) {
        return;
      }
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حُذفت الوثيقة ومقاطعها المفهرسة.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر حذف الوثيقة: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        Text(
          'المكتبة المعرفية',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 5),
        Text(
          'أضف مراجعك المحلية ليبحث NEXUS داخلها أثناء المحادثة.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        Card(
          color: colors.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.shield_outlined, color: colors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'تخزين وبحث على الجهاز',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'لا تُرفع الملفات إلى خادم. تُخزّن المقاطع النصية '
                            'وفهرس البحث داخل قاعدة NEXUS المحلية.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                  height: 1.4,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _importing ? null : _importDocument,
                    icon: _importing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.note_add_outlined),
                    label: Text(
                      _importing ? 'جارٍ فهرسة الوثيقة…' : 'استيراد وثيقة',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'لا يوجد سقف ثابت لعدد الوثائق أو المقاطع. يقدّر NEXUS ميزانية الاستيراد من الذاكرة المتاحة ووضع الموارد.',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _filterController,
          onChanged: (value) =>
              setState(() => _filter = value.trim().toLowerCase()),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: 'ابحث في أسماء الوثائق…',
            filled: true,
            fillColor: colors.surfaceContainerLow,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: colors.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: colors.outlineVariant),
            ),
            suffixIcon: _filter.isEmpty
                ? null
                : IconButton(
                    tooltip: 'مسح البحث',
                    onPressed: () {
                      _filterController.clear();
                      setState(() => _filter = '');
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<KnowledgeDocument>>(
          future: _documentsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _KnowledgeEmptyState(
                icon: Icons.error_outline_rounded,
                title: 'تعذّر تحميل المكتبة',
                subtitle: '${snapshot.error}',
                action: TextButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('إعادة المحاولة'),
                ),
              );
            }
            final allDocuments = snapshot.data ?? const [];
            final documents = allDocuments.where((document) {
              if (_filter.isEmpty) {
                return true;
              }
              return document.title.toLowerCase().contains(_filter) ||
                  document.fileName.toLowerCase().contains(_filter);
            }).toList(growable: false);
            if (allDocuments.isEmpty) {
              return const _KnowledgeEmptyState(
                icon: Icons.library_books_outlined,
                title: 'مكتبتك فارغة حالياً',
                subtitle:
                    'استورد ملفاً نصياً أو Markdown لتبدأ الاسترجاع المحلي.',
              );
            }
            if (documents.isEmpty) {
              return const _KnowledgeEmptyState(
                icon: Icons.search_off_rounded,
                title: 'لا توجد نتائج',
                subtitle: 'جرّب البحث باسم مختلف.',
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'الوثائق',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const Spacer(),
                    Text(
                      '${documents.length} من ${allDocuments.length}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final document in documents)
                  _KnowledgeDocumentCard(
                    document: document,
                    onDelete: () => _deleteDocument(document),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _KnowledgeDocumentCard extends StatelessWidget {
  const _KnowledgeDocumentCard({
    required this.document,
    required this.onDelete,
  });

  final KnowledgeDocument document;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final imported = DateTime.fromMillisecondsSinceEpoch(
      document.importedAtUnixMs,
    );
    final dateLabel =
        '${imported.year.toString().padLeft(4, '0')}/'
        '${imported.month.toString().padLeft(2, '0')}/'
        '${imported.day.toString().padLeft(2, '0')}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 6, 10),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.description_outlined, color: colors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    document.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${document.fileName} · ${document.chunkCount} مقطع · '
                    '${document.charCount} حرف',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'أُضيفت في $dateLabel',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'حذف الوثيقة',
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline_rounded, color: colors.error),
            ),
          ],
        ),
      ),
    );
  }
}

class _KnowledgeEmptyState extends StatelessWidget {
  const _KnowledgeEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: Column(
        children: [
          Icon(icon, size: 38, color: colors.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 5),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.4,
                ),
          ),
          if (action != null) ...[
            const SizedBox(height: 8),
            action!,
          ],
        ],
      ),
    );
  }
}
