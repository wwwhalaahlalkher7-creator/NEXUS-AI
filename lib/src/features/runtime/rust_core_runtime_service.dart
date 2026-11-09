import 'dart:convert';
import 'dart:io';

import '../../rust/api.dart' as rust_api;
import '../../rust/frb_generated.dart';
import 'core_runtime_service.dart';
import 'core_runtime_status.dart';

class RustCoreRuntimeService implements CoreRuntimeService {
  static Future<void>? _initialization;

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
      _initialization ??= RustLib.init();
      await _initialization;
      final payload = await rust_api.runtimeDiagnosticsJson();
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      return CoreRuntimeStatus.fromJson(decoded);
    } catch (error) {
      // Keep diagnostics visible without crashing the dashboard.
      return CoreRuntimeStatus.unavailable('تعذر الاتصال بمحرك Rust: $error');
    }
  }
}
