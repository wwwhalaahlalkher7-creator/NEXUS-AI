import '../models/model_file_verifier.dart';
import '../models/model_record.dart';

enum ModelSessionState {
  idle,
  checking,
  readyToLoad,
  loading,
  loaded,
  unloading,
  failed,
}

class ModelRuntimePolicy {
  const ModelRuntimePolicy({
    this.maxModelFileBytes = 8 * 1024 * 1024 * 1024,
    this.maxContextTokens = 8192,
  });

  /// Policy ceiling for the model file, not a measurement of available RAM.
  final int maxModelFileBytes;

  /// Context ceiling used until device-specific memory telemetry is integrated.
  final int maxContextTokens;
}

class ModelSessionSnapshot {
  const ModelSessionSnapshot({
    required this.state,
    required this.message,
    this.modelId,
    this.modelFileBytes,
  });

  const ModelSessionSnapshot.idle()
      : state = ModelSessionState.idle,
        message = 'لا توجد جلسة نموذج نشطة.',
        modelId = null,
        modelFileBytes = null;

  final ModelSessionState state;
  final String message;
  final String? modelId;
  final int? modelFileBytes;

  bool get isPrepared => state == ModelSessionState.readyToLoad;
  bool get isLoaded => state == ModelSessionState.loaded;
}

abstract interface class ModelRuntimeBackend {
  bool get isAvailable;
  Future<void> load(ModelRecord model);
  Future<void> unload();
}

/// Placeholder until native GGUF model loading is wired into this manager.
class UnavailableModelRuntimeBackend implements ModelRuntimeBackend {
  const UnavailableModelRuntimeBackend();

  @override
  bool get isAvailable => false;

  @override
  Future<void> load(ModelRecord model) => Future<void>.error(
        UnsupportedError('مسار تحميل GGUF لم يُربط بعد بمدير جلسات النماذج.'),
      );

  @override
  Future<void> unload() => Future<void>.error(
        UnsupportedError('لا توجد جلسة محرك فعلية لتفريغها.'),
      );
}

/// Coordinates one local model session and keeps preparation separate from
/// actual engine loading. Runtime state is intentionally process-local.
class ModelRuntimeManager {
  ModelRuntimeManager({
    required ModelFileVerifier verifier,
    ModelRuntimeBackend backend = const UnavailableModelRuntimeBackend(),
    ModelRuntimePolicy policy = const ModelRuntimePolicy(),
  })  : _verifier = verifier,
        _backend = backend,
        _policy = policy;

  final ModelFileVerifier _verifier;
  final ModelRuntimeBackend _backend;
  final ModelRuntimePolicy _policy;

  ModelSessionSnapshot _snapshot = const ModelSessionSnapshot.idle();
  bool _operationInProgress = false;

  ModelSessionSnapshot get snapshot => _snapshot;
  bool get engineAvailable => _backend.isAvailable;

  Future<ModelSessionSnapshot> prepare(ModelRecord model) async {
    _beginOperation();
    final previousSnapshot = _snapshot;
    try {
      if (previousSnapshot.state == ModelSessionState.loaded) {
        if (previousSnapshot.modelId == model.id) {
          return previousSnapshot;
        }
        return previousSnapshot;
      }
      _snapshot = ModelSessionSnapshot(
        state: ModelSessionState.checking,
        message: 'جارٍ التحقق من ملف النموذج وسياسة الموارد…',
        modelId: model.id,
      );
      if (model.runtime != ModelRuntime.llamaCpp) {
        return _fail(model, 'هذا الإصدار يدعم تهيئة نماذج llama.cpp المحلية فقط.');
      }

      final verification = await _verifier.verify(model);
      if (!verification.isValid) {
        return _fail(model, verification.message);
      }

      final actualSize = verification.actualSizeBytes ?? model.sizeBytes;
      if (actualSize == null || actualSize <= 0) {
        return _fail(model, 'تعذر تحديد الحجم الفعلي لملف النموذج.');
      }
      if (actualSize > _policy.maxModelFileBytes) {
        return _fail(
          model,
          'حجم الملف يتجاوز حد السياسة الحالي (${_formatBytes(_policy.maxModelFileBytes)}).',
        );
      }
      final contextLength = model.contextLength;
      if (contextLength != null && contextLength > _policy.maxContextTokens) {
        return _fail(
          model,
          'سياق النموذج ($contextLength) يتجاوز حد السياسة الحالي (${_policy.maxContextTokens} رمز).',
        );
      }

      _snapshot = ModelSessionSnapshot(
        state: ModelSessionState.readyToLoad,
        message: _backend.isAvailable
            ? 'اجتاز النموذج فحوص الملف والسياسة. لم يبدأ التحميل بعد.'
            : 'اجتاز النموذج فحوص الملف والسياسة، لكن واجهة تحميل GGUF لم تُربط بعد.',
        modelId: model.id,
        modelFileBytes: actualSize,
      );
      return _snapshot;
    } catch (error) {
      return _fail(model, 'تعذر تهيئة النموذج: $error');
    } finally {
      _endOperation();
    }
  }

  Future<ModelSessionSnapshot> loadPrepared(ModelRecord model) async {
    _beginOperation();
    try {
      if (_snapshot.state != ModelSessionState.readyToLoad ||
          _snapshot.modelId != model.id) {
        return _fail(model, 'يجب اجتياز فحص الجاهزية لهذا النموذج أولاً.');
      }
      if (!_backend.isAvailable) {
        // Keep the honest prepared state: no engine call was made and no model
        // is reported as loaded.
        _snapshot = ModelSessionSnapshot(
          state: ModelSessionState.readyToLoad,
          message: 'النموذج اجتاز الفحص، لكن مسار تحميل GGUF لم يُربط بعد بمدير جلسات النماذج.',
          modelId: model.id,
          modelFileBytes: _snapshot.modelFileBytes,
        );
        return _snapshot;
      }

      _snapshot = ModelSessionSnapshot(
        state: ModelSessionState.loading,
        message: 'جارٍ تحميل النموذج عبر محرك التشغيل…',
        modelId: model.id,
        modelFileBytes: _snapshot.modelFileBytes,
      );
      await _backend.load(model);
      _snapshot = ModelSessionSnapshot(
        state: ModelSessionState.loaded,
        message: 'تم تحميل النموذج بواسطة محرك التشغيل.',
        modelId: model.id,
        modelFileBytes: _snapshot.modelFileBytes,
      );
      return _snapshot;
    } catch (error) {
      return _fail(model, 'فشل تحميل النموذج: $error');
    } finally {
      _endOperation();
    }
  }

  Future<ModelSessionSnapshot> unload() async {
    _beginOperation();
    try {
      if (_snapshot.state != ModelSessionState.loaded) {
        return _snapshot;
      }
      _snapshot = ModelSessionSnapshot(
        state: ModelSessionState.unloading,
        message: 'جارٍ تفريغ النموذج…',
        modelId: _snapshot.modelId,
        modelFileBytes: _snapshot.modelFileBytes,
      );
      await _backend.unload();
      _snapshot = const ModelSessionSnapshot.idle();
      return _snapshot;
    } catch (error) {
      _snapshot = ModelSessionSnapshot(
        state: ModelSessionState.failed,
        message: 'تعذر تفريغ النموذج: $error',
        modelId: _snapshot.modelId,
        modelFileBytes: _snapshot.modelFileBytes,
      );
      return _snapshot;
    } finally {
      _endOperation();
    }
  }

  void resetPreparation() {
    if (_operationInProgress || _snapshot.state == ModelSessionState.loaded) {
      return;
    }
    _snapshot = const ModelSessionSnapshot.idle();
  }

  ModelSessionSnapshot _fail(ModelRecord model, String message) {
    _snapshot = ModelSessionSnapshot(
      state: ModelSessionState.failed,
      message: message,
      modelId: model.id,
      modelFileBytes: null,
    );
    return _snapshot;
  }

  void _beginOperation() {
    if (_operationInProgress) {
      throw StateError('يوجد إجراء آخر لإدارة النموذج قيد التنفيذ.');
    }
    _operationInProgress = true;
  }

  void _endOperation() => _operationInProgress = false;

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '$bytes B';
  }
}
