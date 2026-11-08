import 'package:flutter/material.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

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
        const SizedBox(height: 16),
        Text('مكونات المنصة', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        const _FeatureTile(
          icon: Icons.memory_outlined,
          title: 'محرك النماذج',
          description: 'واجهة تعريفية فقط؛ لم يتم ربط llama.cpp بعد.',
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
                  'الأساس المحلي 0.5',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'مكتبة النماذج والتخزين المحلي قيد البناء — لا يوجد نموذج نشط حالياً.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onPrimaryContainer,
                      ),
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
