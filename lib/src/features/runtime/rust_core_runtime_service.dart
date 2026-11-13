import 'dart:io';

import '../../rust/api/simple.dart' as rust_api;
import 'rust_bridge_initializer.dart';
import 'core_runtime_service.dart';
import 'core_runtime_status.dart';

class RustCoreRuntimeService implements CoreRuntimeService {
  @override
  Future<CoreRuntimeStatus> inspect() async {
    // The first native target is Android. Avoid loading a Rust dynamic library
    // in Flutter widget tests and unsupported desktop targets.
    if (!Platform.isAndroid) {
      return CoreRuntimeStatus.unavailable(
        'فحص الجسر الأصلي متاح حالياً على Android فقط.',
      );
    }

    try {
      await RustBridgeInitializer.ensureInitialized();
      final health = await rust_api.healthCheck();
      if (health != 'NEXUS Rust bridge is reachable') {
        return CoreRuntimeStatus.unavailable(
          'استجاب جسر Rust برسالة صحة غير متوقعة.',
        );
      }

      final diagnostics = await rust_api.runtimeDiagnostics();
      return CoreRuntimeStatus(
        coreName: diagnostics.coreName,
        coreVersion: diagnostics.coreVersion,
        stage: diagnostics.stage,
        bridgeConnected: diagnostics.bridgeConnected,
        runtimeEngine: diagnostics.runtimeEngine,
        inferenceAvailable: diagnostics.inferenceAvailable,
        modelLoaded: diagnostics.modelLoaded,
        modelRegistry: diagnostics.modelRegistry,
        agentRegistry: diagnostics.agentRegistry,
        nativeEngineAvailable: diagnostics.nativeEngineAvailable,
        nativeEngineVersion: diagnostics.nativeEngineVersion,
        nativeEngineMessage: diagnostics.nativeEngineMessage,
        modelContextTokens: diagnostics.modelContextTokens,
      );
    } catch (error) {
      // Keep diagnostics visible without crashing the dashboard.
      return CoreRuntimeStatus.unavailable('تعذر الاتصال بمحرك Rust: $error');
    }
  }
}
