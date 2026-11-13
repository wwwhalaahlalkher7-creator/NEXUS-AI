import 'dart:io';

import 'package:nexus_app/src/features/models/model_record.dart';
import '../../rust/api/simple.dart' as rust_api;
import 'rust_bridge_initializer.dart';
import 'model_runtime_manager.dart';

/// Calls the real Android ARM64 llama.cpp adapter through the typed Rust bridge.
class RustModelRuntimeBackend implements ModelRuntimeBackend {
  const RustModelRuntimeBackend();

  @override
  bool get isAvailable => Platform.isAndroid;

  @override
  Future<int> load(
    ModelRecord model, {
    required int contextTokens,
    required int threads,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('تحميل GGUF الأصلي متاح على Android ARM64 فقط.');
    }
    final path = model.localPath;
    if (path == null || path.isEmpty) {
      throw StateError('لا يوجد مسار محلي لملف GGUF.');
    }

    await RustBridgeInitializer.ensureInitialized();
    final result = await rust_api.loadGgufModel(
      path: path,
      contextTokens: contextTokens,
      threads: threads,
    );
    if (!result.success || !result.modelLoaded) {
      throw StateError(result.message);
    }
    // The ModelRuntimeManager validates the returned context and owns cleanup
    // when the native engine reports a value outside the active policy.
    return result.contextTokens;
  }

  @override
  Future<void> unload() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('تفريغ GGUF الأصلي متاح على Android ARM64 فقط.');
    }
    await RustBridgeInitializer.ensureInitialized();
    final result = await rust_api.unloadGgufModel();
    if (!result.success || result.modelLoaded) {
      throw StateError(result.message);
    }
  }
}
