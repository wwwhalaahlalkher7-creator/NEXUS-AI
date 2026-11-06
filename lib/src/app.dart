import 'package:flutter/material.dart';

import 'features/dashboard/dashboard_page.dart';
import 'features/agents/agents_page.dart';

class NexusHomePage extends StatefulWidget {
  const NexusHomePage({super.key});

  @override
  State<NexusHomePage> createState() => _NexusHomePageState();
}

class _NexusHomePageState extends State<NexusHomePage> {
  int _selectedIndex = 0;

  static const _pages = <Widget>[
    DashboardPage(),
    _PlaceholderPage(
      title: 'النماذج',
      subtitle: 'إدارة النماذج المحلية ستُضاف في المرحلة التالية.',
      icon: Icons.memory_outlined,
    ),
    AgentsPage(),
    _PlaceholderPage(
      title: 'الأجهزة',
      subtitle: 'اكتشاف الأجهزة والاقتران لم يُفعّلا بعد.',
      icon: Icons.devices_outlined,
    ),
    _PlaceholderPage(
      title: 'الإعدادات',
      subtitle: 'إعدادات المنصة ستُبنى تدريجياً.',
      icon: Icons.settings_outlined,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.hub_rounded, color: Color(0xFF0D9488)),
            SizedBox(width: 10),
            Text('NEXUS AI', style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      ),
      body: SafeArea(child: _pages[_selectedIndex]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'الرئيسية',
          ),
          NavigationDestination(
            icon: Icon(Icons.memory_outlined),
            label: 'النماذج',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined),
            label: 'الوكلاء',
          ),
          NavigationDestination(
            icon: Icon(Icons.devices_outlined),
            label: 'الأجهزة',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'الإعدادات',
          ),
        ],
      ),
    );
  }
}

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(subtitle, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            const Chip(
              avatar: Icon(Icons.construction_outlined, size: 18),
              label: Text('قيد التطوير'),
            ),
          ],
        ),
      ),
    );
  }
}
