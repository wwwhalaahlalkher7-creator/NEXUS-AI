import 'package:material_ui/material_ui.dart';

import '../runtime/core_runtime_card.dart';
import '../runtime/core_runtime_service.dart';
import '../runtime/rust_core_runtime_service.dart';
import '../runtime/model_runtime_manager.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, this.runtimeService, this.runtimeManager});

  final CoreRuntimeService? runtimeService;
  final ModelRuntimeManager? runtimeManager;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'مرحباً بك في NEXUS',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          'منصة ذكاء اصطناعي محلية ومتعددة الأجهزة.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 24),
        const _StatusCard(),
        const SizedBox(height: 12),
        CoreRuntimeCard(service: runtimeService ?? RustCoreRuntimeService()),
        if (runtimeManager != null) ...[
          const SizedBox(height: 10),
          _ModelSessionSummary(manager: runtimeManager!),
        ],
        const SizedBox(height: 16),
        Text('مكونات المنصة', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        const _FeatureTile(
          icon: Icons.memory_outlined,
          title: 'محرك النماذج',
          description: 'تحميل GGUF ومعالجة Prompt وأخذ عينات وتوليد تدريجي مع إمكانية الإيقاف على Android ARM64.',
        ),
        const _FeatureTile(
          icon: Icons.hub_outlined,
          title: 'نظام الوكلاء',
          description: 'طبقة المجال قيد التأسيس، دون تنفيذ مهام AI بعد.',
        ),
        const _FeatureTile(
          icon: Icons.devices_outlined,
          title: 'شبكة الأجهزة',
          description: 'اكتشاف الأجهزة والاتصال الموزع ضمن مرحلة لاحقة.',
        ),
        const _FeatureTile(
          icon: Icons.shield_outlined,
          title: 'الأمان والخصوصية',
          description: 'لن تُنفّذ العمليات الحساسة دون صلاحية وموافقة واضحة.',
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(
            Icons.verified_outlined,
            size: 30,
            color: scheme.onPrimaryContainer,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'محرك llama.cpp الأصلي — Alpha 1.7',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'أضيف مسار توليد النص المحلي: Tokenization وPrompt Evaluation وSampling وتدفق الاستجابة والإيقاف. يلزم اختبار أول نموذج فعلياً على Android.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onPrimaryContainer,
                      ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: scheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'تحميل GGUF متاح · التوليد المحلي قيد التحقق على الجهاز',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
          child: Icon(icon),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(description),
        ),
      ),
    );
  }
}

class _ModelSessionSummary extends StatelessWidget {
  const _ModelSessionSummary({required this.manager});

  final ModelRuntimeManager manager;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final snapshot = manager.snapshot;
        final (icon, title, detail) = switch (snapshot.state) {
          ModelSessionState.loaded => (
              Icons.check_circle_outline,
              'نموذج محمّل فعلياً على CPU',
              'السياق: ${snapshot.contextTokens ?? 0} رمز · افتح المحادثة لتجربة التوليد المحلي.',
            ),
          ModelSessionState.loading => (
              Icons.downloading_outlined,
              'جارٍ تحميل النموذج',
              snapshot.message,
            ),
          ModelSessionState.unloading => (
              Icons.hourglass_bottom,
              'جارٍ تفريغ النموذج',
              snapshot.message,
            ),
          ModelSessionState.readyToLoad => (
              Icons.fact_check_outlined,
              'النموذج اجتاز فحص الجاهزية',
              'الأوزان لم تُحمّل بعد.',
            ),
          ModelSessionState.checking => (
              Icons.manage_search_outlined,
              'جارٍ فحص النموذج',
              snapshot.message,
            ),
          ModelSessionState.failed => (
              Icons.error_outline,
              'تعذر تجهيز النموذج',
              snapshot.message,
            ),
          ModelSessionState.idle => (
              Icons.memory_outlined,
              'لا يوجد نموذج محمّل',
              'أضف نموذج GGUF وافحص جاهزيته من مكتبة النماذج.',
            ),
        };
        return Card(
          child: ListTile(
            leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
            title: Text(title),
            subtitle: Text(detail),
            isThreeLine: detail.length > 56,
          ),
        );
      },
    );
  }
}
