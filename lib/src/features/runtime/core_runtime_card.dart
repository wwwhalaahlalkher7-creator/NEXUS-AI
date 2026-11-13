import 'package:material_ui/material_ui.dart';

import 'core_runtime_service.dart';
import 'core_runtime_status.dart';

class CoreRuntimeCard extends StatefulWidget {
  const CoreRuntimeCard({super.key, required this.service});

  final CoreRuntimeService service;

  @override
  State<CoreRuntimeCard> createState() => _CoreRuntimeCardState();
}

class _CoreRuntimeCardState extends State<CoreRuntimeCard> {
  late Future<CoreRuntimeStatus> _status;

  @override
  void initState() {
    super.initState();
    _status = widget.service.inspect();
  }

  void _retry() {
    setState(() => _status = widget.service.inspect());
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<CoreRuntimeStatus>(
          future: _status,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Expanded(child: Text('جارٍ فحص اتصال محرك Rust...')),
                ],
              );
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return _StatusContent(
                title: 'تعذر فحص المحرك',
                detail: 'لم تكتمل قراءة حالة نواة Rust.',
                color: colors.error,
                onRetry: _retry,
              );
            }

            final status = snapshot.data!;
            if (!status.bridgeConnected) {
              return _StatusContent(
                title: 'الجسر الأصلي غير متاح',
                detail: status.message ?? 'تعذر الوصول إلى نواة Rust.',
                color: colors.error,
                onRetry: _retry,
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.memory_rounded, color: colors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'نواة Rust متصلة',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                    ),
                    Icon(Icons.check_circle, color: Colors.green.shade700),
                  ],
                ),
                const SizedBox(height: 10),
                _InfoLine(label: 'الإصدار', value: status.coreVersion),
                _InfoLine(label: 'المرحلة', value: status.stage),
                _InfoLine(label: 'سجل النماذج', value: 'SQLite محلي في Flutter'),
                _InfoLine(label: 'سجل الوكلاء', value: 'ذاكرة Rust مؤقتة'),
                _InfoLine(
                  label: 'محرك llama.cpp',
                  value: status.nativeEngineAvailable
                      ? 'متصل ${status.nativeEngineVersion ?? ''}'
                      : 'غير متاح',
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    status.inferenceAvailable
                        ? 'الاستدلال متاح عبر محرك موصول.'
                        : status.nativeEngineAvailable
                            ? 'مكتبة llama.cpp موجودة وتمت تهيئة النواة الأصلية. لم يتم تحميل نموذج GGUF أو تفعيل توليد النصوص بعد.'
                            : status.nativeEngineMessage ??
                                'الاتصال ناجح، لكن مكتبة llama.cpp الأصلية غير متاحة في هذه الحزمة.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('إعادة الفحص'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StatusContent extends StatelessWidget {
  const _StatusContent({
    required this.title,
    required this.detail,
    required this.color,
    required this.onRetry,
  });

  final String title;
  final String detail;
  final Color color;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(detail),
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          ),
        ],
      );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            const SizedBox(width: 12),
            Flexible(
              child: Text(value, textAlign: TextAlign.end),
            ),
          ],
        ),
      );
}
