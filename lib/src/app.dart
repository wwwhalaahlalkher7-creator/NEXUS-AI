import 'package:material_ui/material_ui.dart';

import 'features/dashboard/dashboard_page.dart';
import 'features/agents/agents_page.dart';
import 'features/models/models_page.dart';
import 'features/inference/inference_page.dart';
import 'features/models/model_file_verifier.dart';
import 'features/runtime/core_runtime_service.dart';
import 'features/runtime/model_runtime_manager.dart';
import 'features/runtime/rust_model_runtime_backend.dart';

class NexusHomePage extends StatefulWidget {
  const NexusHomePage({super.key, this.runtimeService});

  final CoreRuntimeService? runtimeService;

  @override
  State<NexusHomePage> createState() => _NexusHomePageState();
}

class _NexusHomePageState extends State<NexusHomePage> {
  int _selectedIndex = 0;
  late final ModelFileVerifier _modelFileVerifier;
  late final ModelRuntimeManager _modelRuntimeManager;
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    // Keep the manager above tab pages: switching tabs disposes the visible
    // page, but the process-level native llama.cpp session remains alive.
    _modelFileVerifier = LocalModelFileVerifier();
    _modelRuntimeManager = ModelRuntimeManager(
      verifier: _modelFileVerifier,
      backend: const RustModelRuntimeBackend(),
    );
    _pages = [
      DashboardPage(
        runtimeService: widget.runtimeService,
        runtimeManager: _modelRuntimeManager,
      ),
      ModelsPage(
        fileVerifier: _modelFileVerifier,
        runtimeManager: _modelRuntimeManager,
      ),
      const AgentsPage(),
      InferencePage(runtimeManager: _modelRuntimeManager),
      const _SettingsPage(),
    ];
  }

  @override
  void dispose() {
    _modelRuntimeManager.dispose();
    super.dispose();
  }

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
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'المحادثة',
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

class _SettingsPage extends StatelessWidget {
  const _SettingsPage();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('الإعدادات', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'إعدادات NEXUS AI وإدارة موارد الجهاز ستُفعّل تدريجياً.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.devices_outlined),
            title: const Text('الأجهزة'),
            subtitle: const Text('اكتشاف الأجهزة والاقتران لم يُفعّلا بعد.'),
            trailing: const Icon(Icons.lock_outline_rounded),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('تفضيلات المنصة'),
            subtitle: const Text('إعدادات المظهر والموارد قيد التطوير.'),
            trailing: const Icon(Icons.construction_outlined),
          ),
        ),
      ],
    );
  }
}
