import 'package:flutter/foundation.dart';

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
    this.maxContextTokens = 4096,
    this.contextTokens = 2048,
    this.cpuThreads = 4,
  });

  /// File-size ceiling. Native loading also applies a live available-memory check.
  final int maxModelFileBytes;

  /// Maximum context NEXUS is willing to allocate on the first mobile runtime.
  final int maxContextTokens;

  /// Conservative default context for RAM-constrained Android devices.
  final int contextTokens;

  /// CPU threads used for prompt evaluation and token generation.
  final int cpuThreads;
}

class ModelSessionSnapshot {
  const ModelSessionSnapshot({
    required this.state,
    required this.message,
    this.modelId,
    this.modelFileBytes,
    this.contextTokens,
  });

  const ModelSessionSnapshot.idle()
      : state = ModelSessionState.idle,
        message = 'لا توجد جلسة نموذج نشطة.',
        modelId = null,
        modelFileBytes = null,
        contextTokens = null;

  final ModelSessionState state;
  final String message;
  final String? modelId;
  final int? modelFileBytes;
  final int? contextTokens;

  bool get isPrepared => state == ModelSessionState.readyToLoad;
  bool get isLoaded => state == ModelSessionState.loaded;
}

abstract interface class ModelRuntimeBackend {
  bool get isAvailable;

  Future<int> load(
    ModelRecord model, {
    required int contextTokens,
    required int threads,
  });

  Future<void> unload();
}

/// Used on unsupported platforms or when a native backend is not injected.
class UnavailableModelRuntimeBackend implements ModelRuntimeBackend {
  const UnavailableModelRuntimeBackend();

  @override
  bool get isAvailable => false;

  @override
  Future<int> load(
    ModelRecord model, {
    required int contextTokens,
    required int threads,
  }) =>
      Future<int>.error(
        UnsupportedError('تحميل GGUF الأصلي غير متاح على هذه المنصة.'),
      );

  @override
  Future<void> unload() => Future<void>.error(
        UnsupportedError('لا توجد جلسة محرك أصلية لتفريغها.'),
      );
}

/// Coordinates exactly one local model session and never equates preflight
/// validation with a successful native model load.
class ModelRuntimeManager extends ChangeNotifier {
  ModelRuntimeManager({
    required ModelFileVerifier verifier,
    ModelRuntimeBackend backend = const UnavailableModelRuntimeBackend(),
    ModelRuntimePolicy policy = const ModelRuntimePolicy(),
  })  : _verifier = verifier,
        _backend = backend,
        _policy = policy {
    if (_policy.maxModelFileBytes <= 0 ||
        _policy.maxContextTokens < 512 ||
        _policy.contextTokens < 512 ||
        _policy.contextTokens > _policy.maxContextTokens ||
        _policy.cpuThreads < 1 ||
        _policy.cpuThreads > 8) {
      throw ArgumentError('سياسة تشغيل النموذج تحتوي حدود موارد غير صالحة.');
    }
  }

  final ModelFileVerifier _verifier;
  final ModelRuntimeBackend _backend;
  final ModelRuntimePolicy _policy;

  ModelSessionSnapshot _snapshot = const ModelSessionSnapshot.idle();
  bool _operationInProgress = false;
  bool _disposed = false;

  ModelSessionSnapshot get snapshot => _snapshot;

  void _publish(ModelSessionSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool get engineAvailable => _backend.isAvailable;
  bool get isBusy => _operationInProgress;

  Future<ModelSessionSnapshot> prepare(ModelRecord model) async {
    _beginOperation();
    try {
      if (_snapshot.state == ModelSessionState.loaded) {
        if (_snapshot.modelId == model.id) {
          return _snapshot;
        }
        throw StateError('يوجد نموذج آخر محمّل. أفرغه قبل تجهيز نموذج مختلف.');
      }

      _publish(ModelSessionSnapshot(
        state: ModelSessionState.checking,
        message: 'جارٍ التحقق من ملف النموذج وسياسة الموارد…',
        modelId: model.id,
      ));
      if (model.runtime != ModelRuntime.llamaCpp) {
        return _fail(model, 'هذا الإصدار يدعم تشغيل نماذج llama.cpp المحلية فقط.');
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

      final requestedContext = _effectiveContextTokens(model);
      if (requestedContext < 512) {
        return _fail(model, 'السياق الأقصى المعلن للنموذج أقل من الحد الأدنى المدعوم (512 رمزاً).');
      }
      if (requestedContext > _policy.maxContextTokens) {
        return _fail(
          model,
          'حجم السياق المطلوب ($requestedContext) يتجاوز حد السياسة الحالي (${_policy.maxContextTokens}) رمزاً.',
        );
      }

      _publish(ModelSessionSnapshot(
        state: ModelSessionState.readyToLoad,
        message: _backend.isAvailable
            ? 'اجتاز الملف الفحص. سيُحمّل على CPU بسياق $requestedContext رمزاً بعد فحص الذاكرة المتاحة.'
            : 'اجتاز الملف الفحص، لكن محرك llama.cpp الأصلي غير متاح على هذه المنصة.',
        modelId: model.id,
        modelFileBytes: actualSize,
        contextTokens: requestedContext,
      ));
      return _snapshot;
    } catch (error) {
      if (_snapshot.state == ModelSessionState.loaded &&
          _snapshot.modelId != model.id) {
        rethrow;
      }
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
        _publish(ModelSessionSnapshot(
          state: ModelSessionState.readyToLoad,
          message: 'النموذج اجتاز الفحص، لكن محرك التحميل الأصلي غير متاح.',
          modelId: model.id,
          modelFileBytes: _snapshot.modelFileBytes,
          contextTokens: _snapshot.contextTokens,
        ));
        return _snapshot;
      }

      final requestedContext = _snapshot.contextTokens ?? _policy.contextTokens;
      _publish(ModelSessionSnapshot(
        state: ModelSessionState.loading,
        message: 'جارٍ تحميل الأوزان وإنشاء سياق CPU…',
        modelId: model.id,
        modelFileBytes: _snapshot.modelFileBytes,
        contextTokens: requestedContext,
      ));
      final actualContext = await _backend.load(
        model,
        contextTokens: requestedContext,
        threads: _policy.cpuThreads,
      );
      if (actualContext < 512 || actualContext > _policy.maxContextTokens) {
        // A backend that returns an impossible context is not trusted. Try to
        // release it before reporting failure to the UI. If release fails,
        // preserve the loaded state rather than claiming memory was freed.
        try {
          await _backend.unload();
        } catch (releaseError) {
          _publish(ModelSessionSnapshot(
            state: ModelSessionState.loaded,
            message: 'أعاد المحرك سياقاً خارج السياسة وتعذر تفريغه؛ ما زالت الجلسة محمّلة. أعد محاولة التفريغ: $releaseError',
            modelId: model.id,
            modelFileBytes: _snapshot.modelFileBytes,
            contextTokens: actualContext,
          ));
          return _snapshot;
        }
        return _fail(model, 'أعاد المحرك حجم سياق غير صالح بعد التحميل.');
      }
      _publish(ModelSessionSnapshot(
        state: ModelSessionState.loaded,
        message: 'تم تحميل النموذج فعلياً وإنشاء سياق CPU بحجم $actualContext رمزاً. افتح صفحة المحادثة لتجربة التوليد المحلي.',
        modelId: model.id,
        modelFileBytes: _snapshot.modelFileBytes,
        contextTokens: actualContext,
      ));
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
      _publish(ModelSessionSnapshot(
        state: ModelSessionState.unloading,
        message: 'جارٍ تحرير سياق CPU وأوزان النموذج…',
        modelId: _snapshot.modelId,
        modelFileBytes: _snapshot.modelFileBytes,
        contextTokens: _snapshot.contextTokens,
      ));
      await _backend.unload();
      _publish(const ModelSessionSnapshot.idle());
      return _snapshot;
    } catch (error) {
      // Keep the loaded state so the user can retry unloading. Never make the
      // UI believe native model memory was released when it was not.
      _publish(ModelSessionSnapshot(
        state: ModelSessionState.loaded,
        message: 'تعذر تفريغ النموذج؛ ما زالت الجلسة محمّلة. حاول التفريغ مجدداً: $error',
        modelId: _snapshot.modelId,
        modelFileBytes: _snapshot.modelFileBytes,
        contextTokens: _snapshot.contextTokens,
      ));
      return _snapshot;
    } finally {
      _endOperation();
    }
  }

  void resetPreparation() {
    if (_operationInProgress || _snapshot.state == ModelSessionState.loaded) {
      return;
    }
    _publish(const ModelSessionSnapshot.idle());
  }

  int _effectiveContextTokens(ModelRecord model) {
    final modelLimit = model.contextLength;
    if (modelLimit == null || modelLimit <= 0) {
      return _policy.contextTokens;
    }
    return modelLimit < _policy.contextTokens
        ? modelLimit
        : _policy.contextTokens;
  }

  ModelSessionSnapshot _fail(ModelRecord model, String message) {
    _publish(ModelSessionSnapshot(
      state: ModelSessionState.failed,
      message: message,
      modelId: model.id,
    ));
    return _snapshot;
  }

  void _beginOperation() {
    if (_disposed) {
      throw StateError('مدير جلسة النموذج لم يعد نشطاً.');
    }
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
