import 'package:flutter/foundation.dart';

import '../models/model_file_verifier.dart';
import '../models/model_record.dart';

enum ModelSessionState {
  idle,
  checking,
  readyToLoad,
  loading,
  loaded,
  switching,
  unloading,
  recoveryRequired,
  failed,
}

class ModelRuntimePolicy {
  const ModelRuntimePolicy({
    this.maxModelFileBytes,
    this.maxContextTokens = 4096,
    this.contextTokens = 2048,
    this.cpuThreads = 4,
  });

  final int? maxModelFileBytes;
  final int maxContextTokens;
  final int contextTokens;
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
  bool get needsRecovery => state == ModelSessionState.recoveryRequired;

  ModelSessionSnapshot withMessage(String value) => ModelSessionSnapshot(
        state: state,
        message: value,
        modelId: modelId,
        modelFileBytes: modelFileBytes,
        contextTokens: contextTokens,
      );
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

/// Owns the single native model session and serializes all lifecycle changes.
/// A generation lease prevents unload/switch while native inference is active.
class ModelRuntimeManager extends ChangeNotifier {
  ModelRuntimeManager({
    required ModelFileVerifier verifier,
    ModelRuntimeBackend backend = const UnavailableModelRuntimeBackend(),
    ModelRuntimePolicy policy = const ModelRuntimePolicy(),
  })  : _verifier = verifier,
        _backend = backend,
        _policy = policy {
    if ((_policy.maxModelFileBytes != null &&
            _policy.maxModelFileBytes! <= 0) ||
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
  ModelRecord? _activeModel;
  bool _operationInProgress = false;
  bool _generationInProgress = false;
  bool _disposed = false;

  ModelSessionSnapshot get snapshot => _snapshot;
  bool get engineAvailable => _backend.isAvailable;
  bool get isBusy => _operationInProgress;
  bool get isGenerating => _generationInProgress;

  void _publish(ModelSessionSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Acquire synchronously before the first await in a generation turn.
  /// Throws when a lifecycle operation is active or no model is loaded.
  void beginGeneration() {
    if (_disposed) {
      throw StateError('مدير جلسة النموذج لم يعد نشطاً.');
    }
    if (_operationInProgress) {
      throw StateError('انتظر انتهاء إجراء إدارة النموذج قبل التوليد.');
    }
    if (_generationInProgress) {
      throw StateError('يوجد توليد آخر قيد التنفيذ.');
    }
    if (!_snapshot.isLoaded) {
      throw StateError('لا يوجد نموذج محمّل لبدء التوليد.');
    }
    _generationInProgress = true;
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Releases the generation lease. Safe to call more than once.
  void endGeneration() {
    if (!_generationInProgress) {
      return;
    }
    _generationInProgress = false;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<ModelSessionSnapshot> prepare(ModelRecord model) async {
    _beginOperation();
    try {
      if (_snapshot.needsRecovery) {
        throw StateError('يجب استعادة المحرك بتفريغه قبل تجهيز نموذج آخر.');
      }
      if (_snapshot.state == ModelSessionState.loaded) {
        if (_snapshot.modelId == model.id) {
          return _snapshot;
        }
        throw StateError('يوجد نموذج آخر محمّل. استخدم التبديل الصريح للنموذج.');
      }
      _publish(ModelSessionSnapshot(
        state: ModelSessionState.checking,
        message: 'جارٍ التحقق من ملف النموذج وسياسة الموارد…',
        modelId: model.id,
      ));
      final result = await _inspectModel(model);
      _publish(result);
      return result;
    } catch (error) {
      if (_snapshot.needsRecovery ||
          (_snapshot.state == ModelSessionState.loaded &&
              _snapshot.modelId != model.id)) {
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
      if (_snapshot.needsRecovery) {
        throw StateError('يجب استعادة المحرك بتفريغه قبل تحميل نموذج آخر.');
      }
      if (_snapshot.state != ModelSessionState.readyToLoad ||
          _snapshot.modelId != model.id) {
        return _fail(model, 'يجب اجتياز فحص الجاهزية لهذا النموذج أولاً.');
      }
      if (!_backend.isAvailable) {
        _publish(_snapshot.withMessage(
          'النموذج اجتاز الفحص، لكن محرك التحميل الأصلي غير متاح.',
        ));
        return _snapshot;
      }
      final context = _snapshot.contextTokens ?? _policy.contextTokens;
      _publish(ModelSessionSnapshot(
        state: ModelSessionState.loading,
        message: 'جارٍ تحميل الأوزان وإنشاء سياق CPU…',
        modelId: model.id,
        modelFileBytes: _snapshot.modelFileBytes,
        contextTokens: context,
      ));
      final actualContext = await _backend.load(
        model,
        contextTokens: context,
        threads: _policy.cpuThreads,
      );
      if (!_isValidReturnedContext(actualContext)) {
        return await _recoverInvalidLoad(model, actualContext);
      }
      _activeModel = model;
      _publish(_loadedSnapshot(
        model,
        actualContext,
        'تم تحميل النموذج فعلياً وإنشاء سياق CPU بحجم $actualContext رمزاً.',
        fileBytes: _snapshot.modelFileBytes,
      ));
      return _snapshot;
    } catch (error) {
      if (_snapshot.needsRecovery) {
        rethrow;
      }
      _activeModel = null;
      return _fail(model, 'فشل تحميل النموذج: $error');
    } finally {
      _endOperation();
    }
  }

  /// Explicitly replaces the active model. The target is verified before the
  /// current session is unloaded. If target loading fails, the previous model
  /// is restored when possible; otherwise the manager enters recoveryRequired.
  Future<ModelSessionSnapshot> switchTo(ModelRecord target) async {
    _beginOperation();
    final previousSnapshot = _snapshot;
    final previousModel = _activeModel;
    var previousUnloaded = false;
    var targetLoadAttempted = false;
    var targetLoaded = false;

    try {
      if (previousSnapshot.isLoaded && previousSnapshot.modelId == target.id) {
        return previousSnapshot;
      }

      _publish(ModelSessionSnapshot(
        state: ModelSessionState.checking,
        message: 'جارٍ فحص النموذج الجديد قبل تغيير الجلسة الحالية…',
        modelId: target.id,
      ));
      final prepared = await _inspectModel(target);
      if (!prepared.isPrepared) {
        final message = 'لم يبدأ التبديل: ${prepared.message}';
        _publish(previousSnapshot.withMessage(message));
        return _snapshot;
      }
      if (!_backend.isAvailable) {
        if (previousSnapshot.isLoaded) {
          _publish(previousSnapshot.withMessage(
            'لم يبدأ التبديل؛ محرك التشغيل الأصلي غير متاح على هذه المنصة.',
          ));
        } else {
          _publish(prepared.withMessage(
            'اجتاز النموذج الفحص، لكن محرك التحميل الأصلي غير متاح.',
          ));
        }
        return _snapshot;
      }

      if (previousSnapshot.isLoaded || previousSnapshot.needsRecovery) {
        _publish(ModelSessionSnapshot(
          state: ModelSessionState.switching,
          message: 'جارٍ تفريغ الجلسة الحالية تمهيداً لتحميل النموذج الجديد…',
          modelId: target.id,
          modelFileBytes: prepared.modelFileBytes,
          contextTokens: prepared.contextTokens,
        ));
        try {
          await _backend.unload();
          previousUnloaded = true;
          _activeModel = null;
        } catch (error) {
          _publish(previousSnapshot.withMessage(
            'تعذر تفريغ النموذج الحالي؛ لم يتم تحميل النموذج الجديد: $error',
          ));
          return _snapshot;
        }
      }

      _publish(ModelSessionSnapshot(
        state: ModelSessionState.loading,
        message: 'تم تحرير الجلسة السابقة. جارٍ تحميل النموذج الجديد…',
        modelId: target.id,
        modelFileBytes: prepared.modelFileBytes,
        contextTokens: prepared.contextTokens,
      ));
      targetLoadAttempted = true;
      final actualContext = await _backend.load(
        target,
        contextTokens: prepared.contextTokens ?? _policy.contextTokens,
        threads: _policy.cpuThreads,
      );
      targetLoaded = true;
      if (!_isValidReturnedContext(actualContext)) {
        throw StateError('أعاد المحرك حجم سياق خارج حدود السياسة: $actualContext.');
      }

      _activeModel = target;
      _publish(_loadedSnapshot(
        target,
        actualContext,
        'اكتمل التبديل وحُمّل النموذج الجديد على CPU بسياق $actualContext رمزاً.',
        fileBytes: prepared.modelFileBytes,
      ));
      return _snapshot;
    } catch (error) {
      if (previousUnloaded && previousModel != null) {
        try {
          if (targetLoaded) {
            await _backend.unload();
          }
          final restoredContext = await _backend.load(
            previousModel,
            contextTokens:
                previousSnapshot.contextTokens ?? _policy.contextTokens,
            threads: _policy.cpuThreads,
          );
          if (!_isValidReturnedContext(restoredContext)) {
            throw StateError('أعاد المحرك سياقاً غير صالح أثناء استعادة النموذج السابق.');
          }
          _activeModel = previousModel;
          _publish(_loadedSnapshot(
            previousModel,
            restoredContext,
            'فشل تحميل النموذج الجديد ($error)، وتمت استعادة النموذج السابق بنجاح.',
            fileBytes: previousSnapshot.modelFileBytes,
          ));
          return _snapshot;
        } catch (restoreError) {
          _activeModel = null;
          _publish(ModelSessionSnapshot(
            state: ModelSessionState.recoveryRequired,
            message: 'فشل التبديل ($error) وتعذرت استعادة النموذج السابق ($restoreError). '
                'لا تبدأ التوليد؛ نفّذ التفريغ لإعادة المحرك إلى حالة آمنة.',
            modelId: target.id,
            modelFileBytes: previousSnapshot.modelFileBytes,
            contextTokens: null,
          ));
          return _snapshot;
        }
      }

      if (previousSnapshot.isLoaded && !previousUnloaded) {
        _publish(previousSnapshot.withMessage('لم يتم تغيير الجلسة الحالية: $error'));
        return _snapshot;
      }

      if (targetLoadAttempted && targetLoaded) {
        try {
          await _backend.unload();
        } catch (cleanupError) {
          _activeModel = null;
          _publish(ModelSessionSnapshot(
            state: ModelSessionState.recoveryRequired,
            message: 'فشل تحميل النموذج وتعذر التأكد من تحرير موارده ($cleanupError). '
                'نفّذ التفريغ قبل أي محاولة أخرى.',
            modelId: target.id,
          ));
          return _snapshot;
        }
      }
      _activeModel = null;
      return _fail(target, 'فشل تبديل النموذج: $error');
    } finally {
      _endOperation();
    }
  }

  Future<ModelSessionSnapshot> unload() async {
    _beginOperation();
    try {
      if (_snapshot.state != ModelSessionState.loaded &&
          !_snapshot.needsRecovery) {
        return _snapshot;
      }
      final previous = _snapshot;
      _publish(ModelSessionSnapshot(
        state: ModelSessionState.unloading,
        message: previous.needsRecovery
            ? 'جارٍ إعادة المحرك إلى حالة آمنة…'
            : 'جارٍ تحرير سياق CPU وأوزان النموذج…',
        modelId: previous.modelId,
        modelFileBytes: previous.modelFileBytes,
        contextTokens: previous.contextTokens,
      ));
      await _backend.unload();
      _activeModel = null;
      _publish(const ModelSessionSnapshot.idle());
      return _snapshot;
    } catch (error) {
      final wasRecovery = _snapshot.state == ModelSessionState.unloading &&
          _activeModel == null;
      _publish(ModelSessionSnapshot(
        state: wasRecovery
            ? ModelSessionState.recoveryRequired
            : ModelSessionState.loaded,
        message: 'تعذر تفريغ النموذج؛ لم يتم تأكيد تحرير موارد المحرك: $error',
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
    if (_operationInProgress ||
        _generationInProgress ||
        _snapshot.state == ModelSessionState.loaded ||
        _snapshot.needsRecovery) {
      return;
    }
    _publish(const ModelSessionSnapshot.idle());
  }

  Future<ModelSessionSnapshot> _inspectModel(ModelRecord model) async {
    if (model.runtime != ModelRuntime.llamaCpp) {
      return _failedSnapshot(model, 'هذا الإصدار يدعم تشغيل نماذج llama.cpp المحلية فقط.');
    }
    final verification = await _verifier.verify(model);
    if (!verification.isValid) {
      return _failedSnapshot(model, verification.message);
    }
    final actualSize = verification.actualSizeBytes ?? model.sizeBytes;
    if (actualSize == null || actualSize <= 0) {
      return _failedSnapshot(model, 'تعذر تحديد الحجم الفعلي لملف النموذج.');
    }
    final fileByteCeiling = _policy.maxModelFileBytes;
    if (fileByteCeiling != null && actualSize > fileByteCeiling) {
      return _failedSnapshot(
        model,
        'حجم الملف يتجاوز حد السياسة المخصص (${_formatBytes(fileByteCeiling)}).',
      );
    }
    final requestedContext = _effectiveContextTokens(model);
    if (requestedContext < 512) {
      return _failedSnapshot(
        model,
        'السياق الأقصى المعلن للنموذج أقل من الحد الأدنى المدعوم (512 رمزاً).',
      );
    }
    if (requestedContext > _policy.maxContextTokens) {
      return _failedSnapshot(
        model,
        'حجم السياق المطلوب ($requestedContext) يتجاوز حد السياسة الحالي '
        '(${_policy.maxContextTokens}) رمزاً.',
      );
    }
    return ModelSessionSnapshot(
      state: ModelSessionState.readyToLoad,
      message: _backend.isAvailable
          ? 'اجتاز الملف الفحص. سيُحمّل على CPU بسياق $requestedContext '
              'رمزاً بعد فحص الذاكرة المتاحة.'
          : 'اجتاز الملف الفحص، لكن محرك llama.cpp الأصلي غير متاح على هذه المنصة.',
      modelId: model.id,
      modelFileBytes: actualSize,
      contextTokens: requestedContext,
    );
  }

  Future<ModelSessionSnapshot> _recoverInvalidLoad(
    ModelRecord model,
    int actualContext,
  ) async {
    try {
      await _backend.unload();
    } catch (releaseError) {
      _activeModel = model;
      _publish(ModelSessionSnapshot(
        state: ModelSessionState.loaded,
        message: 'أعاد المحرك سياقاً خارج السياسة وتعذر تفريغه؛ ما زالت الجلسة محمّلة. '
            'أعد محاولة التفريغ: $releaseError',
        modelId: model.id,
        modelFileBytes: _snapshot.modelFileBytes,
        contextTokens: actualContext,
      ));
      return _snapshot;
    }
    _activeModel = null;
    return _fail(model, 'أعاد المحرك حجم سياق غير صالح بعد التحميل.');
  }

  ModelSessionSnapshot _loadedSnapshot(
    ModelRecord model,
    int contextTokens,
    String message, {
    int? fileBytes,
  }) =>
      ModelSessionSnapshot(
        state: ModelSessionState.loaded,
        message: message,
        modelId: model.id,
        modelFileBytes: fileBytes ?? model.sizeBytes,
        contextTokens: contextTokens,
      );

  bool _isValidReturnedContext(int value) =>
      value >= 512 && value <= _policy.maxContextTokens;

  int _effectiveContextTokens(ModelRecord model) {
    final modelLimit = model.contextLength;
    if (modelLimit == null || modelLimit <= 0) {
      return _policy.contextTokens;
    }
    return modelLimit < _policy.contextTokens
        ? modelLimit
        : _policy.contextTokens;
  }

  ModelSessionSnapshot _failedSnapshot(ModelRecord model, String message) =>
      ModelSessionSnapshot(
        state: ModelSessionState.failed,
        message: message,
        modelId: model.id,
      );

  ModelSessionSnapshot _fail(ModelRecord model, String message) {
    _publish(_failedSnapshot(model, message));
    return _snapshot;
  }

  void _beginOperation() {
    if (_disposed) {
      throw StateError('مدير جلسة النموذج لم يعد نشطاً.');
    }
    if (_generationInProgress) {
      throw StateError('لا يمكن إدارة النموذج أثناء التوليد. أوقف التوليد أولاً.');
    }
    if (_operationInProgress) {
      throw StateError('يوجد إجراء آخر لإدارة النموذج قيد التنفيذ.');
    }
    _operationInProgress = true;
  }

  void _endOperation() {
    if (!_operationInProgress) {
      return;
    }
    _operationInProgress = false;
    if (!_disposed) {
      notifyListeners();
    }
  }

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
