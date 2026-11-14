import 'package:material_ui/material_ui.dart';

import 'resource_settings.dart';

class ResourceSettingsPage extends StatefulWidget {
  const ResourceSettingsPage({super.key, this.repository});

  final ResourceSettingsRepository? repository;

  @override
  State<ResourceSettingsPage> createState() => _ResourceSettingsPageState();
}

class _ResourceSettingsPageState extends State<ResourceSettingsPage> {
  late final ResourceSettingsRepository _repository;
  ResourceMode? _selectedMode;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? ResourceSettingsRepository();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await _repository.load();
      if (!mounted) return;
      setState(() {
        _selectedMode = settings.mode;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'تعذّر تحميل تفضيلات الموارد: $error';
      });
    }
  }

  Future<void> _select(ResourceMode mode) async {
    if (_saving || mode == _selectedMode) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _repository.save(ResourceSettings(mode: mode));
      if (!mounted) return;
      setState(() => _selectedMode = mode);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم حفظ وضع الموارد: ${ResourceSettings(mode: mode).label}')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر حفظ الإعداد: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('إدارة الموارد')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                Text(
                  'اختر طريقة استخدام NEXUS لموارد جهازك',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'الإعداد يطبق على الاستيراد والبحث واستدعاءات الأدوات '
                  'في المهام الجديدة. لا يحتاج إلى اتصال بالإنترنت.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        height: 1.45,
                      ),
                ),
                const SizedBox(height: 16),
                for (final mode in ResourceMode.values)
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: RadioListTile<ResourceMode>(
                      value: mode,
                      groupValue: _selectedMode,
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value != null) _select(value);
                            },
                      title: Text(
                        ResourceSettings(mode: mode).label,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(ResourceSettings(mode: mode).description),
                      ),
                      secondary: Icon(switch (mode) {
                        ResourceMode.balanced => Icons.balance_rounded,
                        ResourceMode.performance => Icons.speed_rounded,
                        ResourceMode.unrestricted => Icons.all_inclusive_rounded,
                      }),
                    ),
                  ),
                if (_saving) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: colors.error)),
                ],
                const SizedBox(height: 12),
                Card(
                  color: colors.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.memory_rounded, color: colors.primary),
                            const SizedBox(width: 8),
                            const Text(
                              'ما الذي لا يمكن إلغاؤه؟',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'لا توجد حصة سحابية أو حد اشتراك. في الوضع المفتوح '
                          'تُزال السقوف البرمجية الثابتة، وتبقى سعة RAM والتخزين '
                          'ونافذة سياق النموذج وسرعة المعالج هي الحدود الفعلية. '
                          'قد يوقف Android التطبيق عند نفاد الذاكرة؛ لذلك تظل '
                          'مراقبة الموارد والإلغاء متاحين.',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'حماية الصلاحيات لا تتغير بتغيير الوضع: الأدوات المسجلة فقط '
                  'هي التي تعمل، والأدوات المعدّلة للبيانات أو المتصلة بخارج '
                  'الجهاز تحتاج موافقة صريحة.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        height: 1.45,
                      ),
                ),
              ],
            ),
    );
  }
}
