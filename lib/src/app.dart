import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'features/dashboard/dashboard_page.dart';
import 'features/agents/agents_page.dart';
import 'features/models/models_page.dart';
import 'features/inference/inference_page.dart';
import 'features/knowledge/knowledge_page.dart';
import 'features/models/model_file_verifier.dart';
import 'features/runtime/core_runtime_service.dart';
import 'features/runtime/model_runtime_manager.dart';
import 'features/runtime/rust_model_runtime_backend.dart';
import 'features/resources/resource_settings_page.dart';
import 'features/devices/device_network_service.dart';
import 'features/devices/devices_page.dart';
import 'features/privacy/privacy_center_page.dart';

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
  late final DeviceNetworkService _deviceNetworkService;
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    // Keep the manager above tab pages: switching tabs disposes the visible
    // page, but the process-level native llama.cpp session remains alive.
    _modelFileVerifier = LocalModelFileVerifier();
    _deviceNetworkService = DeviceNetworkService();
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
      AgentsPage(runtimeManager: _modelRuntimeManager),
      const KnowledgePage(),
      InferencePage(runtimeManager: _modelRuntimeManager),
    ];
  }

  @override
  void dispose() {
    _modelRuntimeManager.dispose();
    unawaited(_deviceNetworkService.dispose());
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
        actions: [
          IconButton(
            tooltip: 'الأجهزة المتصلة',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DevicesPage(service: _deviceNetworkService, runtimeManager: _modelRuntimeManager),
                ),
              );
            },
            icon: const Icon(Icons.devices_other_rounded),
          ),
          IconButton(
            tooltip: 'الإعدادات',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ResourceSettingsPage(),
                ),
              );
            },
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'الخصوصية والبيانات المحلية',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PrivacyCenterPage(),
                ),
              );
            },
            icon: const Icon(Icons.privacy_tip_outlined),
          ),
        ],
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
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books_rounded),
            label: 'المعرفة',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'المحادثة',
          ),
        ],
      ),
    );
  }
}

