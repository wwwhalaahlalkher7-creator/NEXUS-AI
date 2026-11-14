import 'dart:math';

import '../models/model_record.dart';
import '../resources/resource_settings.dart';
import '../runtime/core_runtime_service.dart';
import '../runtime/core_runtime_status.dart';
import '../runtime/model_runtime_manager.dart';
import '../runtime/rust_core_runtime_service.dart';
import 'benchmark_generation_port.dart';
import 'benchmark_metrics.dart';
import 'benchmark_repository.dart';
import 'benchmark_run_record.dart';

class BenchmarkEnvironmentSnapshot {
  const BenchmarkEnvironmentSnapshot({
    this.peakResidentBytes,
    this.thermalStatus,
    this.batteryLevelPercent,
    this.runtimeVersion,
  });

  final int? peakResidentBytes;
  final int? thermalStatus;
  final int? batteryLevelPercent;
  final String? runtimeVersion;
}

abstract interface class BenchmarkEnvironmentReader {
  Future<BenchmarkEnvironmentSnapshot> read();
}

class LocalBenchmarkEnvironmentReader implements BenchmarkEnvironmentReader {
  LocalBenchmarkEnvironmentReader({
    DeviceResourceMonitor? resourceMonitor,
    CoreRuntimeService? runtimeService,
  })  : _resourceMonitor = resourceMonitor ?? DeviceResourceMonitor(),
        _runtimeService = runtimeService ?? RustCoreRuntimeService();

  final DeviceResourceMonitor _resourceMonitor;
  final CoreRuntimeService _runtimeService;

  @override
  Future<BenchmarkEnvironmentSnapshot> read() async {
    ResourceSnapshot? resources;
    CoreRuntimeStatus? runtime;
    try {
      resources = await _resourceMonitor.readSnapshot(
        includeExtendedTelemetry: true,
      );
    } on Object {
      // Optional platform metrics remain unknown; never synthesize values.
    }
    try {
      runtime = await _runtimeService.inspect();
    } on Object {
      // Process-wide RSS is optional and independent from benchmark timings.
    }
    return BenchmarkEnvironmentSnapshot(
      peakResidentBytes: runtime?.nativeMemoryReadable == true
          ? runtime!.nativePeakResidentBytes
          : null,
      thermalStatus: resources?.thermalStatus,
      batteryLevelPercent: resources?.batteryLevelPercent,
      runtimeVersion: runtime?.nativeEngineVersion,
    );
  }
}

class BenchmarkRunResult {
  const BenchmarkRunResult({
    required this.record,
    required this.message,
  });

  final BenchmarkRunRecord record;
  final String message;
}

/// Executes a short, explicit local benchmark suite and persists provenance.
/// It never switches or unloads a model that was already active before the run.
class BenchmarkRunner {
  BenchmarkRunner({
    required ModelRuntimeManager runtimeManager,
    required BenchmarkGenerationPort generationPort,
    required BenchmarkEnvironmentReader environmentReader,
    required BenchmarkRunRepository repository,
    DateTime Function()? clock,
    Random? random,
  })  : _runtimeManager = runtimeManager,
        _generationPort = generationPort,
        _environmentReader = environmentReader,
        _repository = repository,
        _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  final ModelRuntimeManager _runtimeManager;
  final BenchmarkGenerationPort _generationPort;
  final BenchmarkEnvironmentReader _environmentReader;
  final BenchmarkRunRepository _repository;
  final DateTime Function() _clock;
  final Random _random;
  bool _nativeSessionMayStillBeActive = false;

  bool get isAvailable =>
      _runtimeManager.engineAvailable && _generationPort.isAvailable;

  Future<BenchmarkRunResult> run(
    ModelRecord model, {
    required int contextTokens,
    required int cpuThreads,
  }) async {
    if (_nativeSessionMayStillBeActive) {
      throw StateError('جلسة قياس سابقة لم تؤكد انتهاء التوليد الأصلي. أعد تشغيل التطبيق قبل أي قياس جديد.');
    }
    if (!isAvailable) {
      throw UnsupportedError('قياس أداء محرك GGUF متاح على Android فقط.');
    }
    if (model.status != ModelInstallStatus.installed ||
        model.runtime != ModelRuntime.llamaCpp ||
        model.localPath == null ||
        model.localPath!.isEmpty) {
      throw StateError('اختر نموذج GGUF محلياً ومثبتاً أولاً.');
    }
    if (_runtimeManager.isBusy ||
        _runtimeManager.isGenerating ||
        _runtimeManager.snapshot.isLoaded ||
        _runtimeManager.snapshot.needsRecovery) {
      throw StateError(
        'أفرغ جلسة النموذج الحالية وأوقف أي توليد قبل بدء القياس؛ '
        'لن يغيّر الاختبار جلسة نشطة.',
      );
    }
    if (contextTokens < 512 || contextTokens > 4096 ||
        cpuThreads < 1 || cpuThreads > 8) {
      throw ArgumentError('إعدادات اختبار الأداء خارج حدود المحرك.');
    }

    final startedAt = _clock();
    final startedAtMs = startedAt.millisecondsSinceEpoch;
    final id = _newId(model.id, startedAtMs);
    BenchmarkEnvironmentSnapshot? startEnvironment;
    BenchmarkEnvironmentSnapshot? afterFirstLoad;
    BenchmarkEnvironmentSnapshot? afterRepeatLoad;
    BenchmarkEnvironmentSnapshot? afterGeneration;
    BenchmarkEnvironmentSnapshot? endEnvironment;
    final telemetrySamples = <BenchmarkEnvironmentSnapshot>[];
    var actualContextTokens = contextTokens;
    var actualCpuThreads = cpuThreads;
    int? firstLoadMs;
    int? repeatLoadMs;
    int? generationElapsedMs;
    int generatedTokens = 0;
    int? cancelLatencyMs;
    var cancellationObserved = false;
    var status = 'failed';
    String? error;
    String? runtimeVersion;

    try {
      startEnvironment = await _safeEnvironmentRead();
      telemetrySamples.add(startEnvironment);
      runtimeVersion = startEnvironment.runtimeVersion;

      var prepared = await _runtimeManager.prepare(
        model,
        contextTokens: contextTokens,
        cpuThreads: cpuThreads,
      );
      if (!prepared.isPrepared) {
        throw StateError(prepared.message);
      }

      var loadWatch = Stopwatch()..start();
      var loaded = await _runtimeManager.loadPrepared(model);
      loadWatch.stop();
      if (!loaded.isLoaded) throw StateError(loaded.message);
      firstLoadMs = loadWatch.elapsedMilliseconds;
      actualContextTokens = loaded.contextTokens ??
          (throw StateError('لم يُرجع المحرك حجم السياق الفعلي بعد التحميل الأول.'));
      actualCpuThreads = loaded.cpuThreads ?? cpuThreads;
      afterFirstLoad = await _safeEnvironmentRead();
      telemetrySamples.add(afterFirstLoad);
      runtimeVersion ??= afterFirstLoad.runtimeVersion;

      // This is a repeat load while the OS page cache may be warm. The app
      // cannot flush Linux file cache without root, so it is not labelled a
      // guaranteed cold-cache measurement.
      final unloaded = await _runtimeManager.unload();
      if (unloaded.state != ModelSessionState.idle) {
        throw StateError('تعذر تفريغ النموذج قبل قياس إعادة التحميل: ${unloaded.message}');
      }
      prepared = await _runtimeManager.prepare(
        model,
        contextTokens: contextTokens,
        cpuThreads: cpuThreads,
      );
      if (!prepared.isPrepared) throw StateError(prepared.message);
      loadWatch = Stopwatch()..start();
      loaded = await _runtimeManager.loadPrepared(model);
      loadWatch.stop();
      if (!loaded.isLoaded) throw StateError(loaded.message);
      final repeatedContextTokens = loaded.contextTokens;
      final repeatedCpuThreads = loaded.cpuThreads ?? cpuThreads;
      if (repeatedContextTokens != actualContextTokens ||
          repeatedCpuThreads != actualCpuThreads) {
        throw StateError('تغيّرت إعدادات الجلسة الفعلية بين التحميلين؛ لا يمكن مقارنة القياسين.');
      }
      repeatLoadMs = loadWatch.elapsedMilliseconds;
      afterRepeatLoad = await _safeEnvironmentRead();
      telemetrySamples.add(afterRepeatLoad);
      runtimeVersion ??= afterRepeatLoad.runtimeVersion;

      // One short warm-up is excluded from throughput figures, but it must
      // still complete successfully before measured samples can be trusted.
      final warmup = await _generateMeasured(
        prompt: _benchmarkPrompt,
        maxTokens: 16,
      );
      if (!warmup.completed || warmup.generatedTokens <= 0) {
        throw StateError(warmup.error ?? 'فشل إحماء النموذج قبل القياس.');
      }

      var totalGenerationMilliseconds = 0;
      for (var sampleIndex = 0; sampleIndex < 2; sampleIndex++) {
        final sample = await _generateMeasured(
          prompt: _benchmarkPrompt,
          maxTokens: 96,
        );
        if (!sample.completed || sample.generatedTokens <= 0) {
          throw StateError(sample.error ?? 'فشل اختبار التوليد رقم ${sampleIndex + 1}.');
        }
        totalGenerationMilliseconds += sample.elapsedMilliseconds;
        generatedTokens += sample.generatedTokens;
        afterGeneration = await _safeEnvironmentRead();
        telemetrySamples.add(afterGeneration);
        runtimeVersion ??= afterGeneration.runtimeVersion;
      }
      generationElapsedMs = totalGenerationMilliseconds;

      // Cancellation is measured separately from throughput. If the model
      // finishes before the cancellation timer, latency remains unavailable.
      final cancellationSample = await _generateMeasured(
        prompt: _cancellationPrompt,
        maxTokens: 1024,
        cancelAfter: const Duration(milliseconds: 200),
      );
      cancellationObserved = cancellationSample.cancelled &&
          cancellationSample.cancellationLatencyMilliseconds != null;
      cancelLatencyMs = cancellationSample.cancellationLatencyMilliseconds;
      if (cancellationSample.error != null && !cancellationSample.cancelled) {
        throw StateError(cancellationSample.error!);
      }
      endEnvironment = await _safeEnvironmentRead();
      telemetrySamples.add(endEnvironment);
      runtimeVersion ??= endEnvironment.runtimeVersion;
      status = 'completed';
    } on Object catch (caught) {
      error = caught.toString();
      status = firstLoadMs == null ? 'failed' : 'partial';
    } finally {
      if (_nativeSessionMayStillBeActive) {
        const safetyError = 'لم يصل حدث نهائي من التوليد الأصلي بعد طلب الإلغاء؛ '
            'احتفظ NEXUS بقفل جلسة النموذج ولم يحاول تفريغها. أعد تشغيل التطبيق لاستعادة المحرك.';
        error = error == null ? safetyError : '$error\n$safetyError';
        status = status == 'failed' ? 'failed' : 'partial';
      } else {
        if (_runtimeManager.isGenerating) {
          _runtimeManager.endGeneration();
        }
        final snapshot = _runtimeManager.snapshot;
        if (snapshot.isLoaded || snapshot.needsRecovery) {
          final cleanup = await _runtimeManager.unload();
          if (cleanup.state != ModelSessionState.idle) {
            final cleanupError = 'تعذر تأكيد تفريغ النموذج بعد القياس: ${cleanup.message}';
            error = error == null ? cleanupError : '$error\n$cleanupError';
            status = status == 'failed' ? 'failed' : 'partial';
          }
        }
      }
    }

    endEnvironment ??= _nativeSessionMayStillBeActive
        ? (telemetrySamples.isEmpty ? const BenchmarkEnvironmentSnapshot() : telemetrySamples.last)
        : await _safeEnvironmentRead();
    telemetrySamples.add(endEnvironment);
    final peakBytes = BenchmarkMetrics.maximumKnown(
      telemetrySamples.map((value) => value.peakResidentBytes),
    );
    final peakThermal = BenchmarkMetrics.maximumThermalStatus(
      telemetrySamples.map((value) => value.thermalStatus),
    );
    final record = BenchmarkRunRecord(
      id: id,
      modelId: model.id,
      modelName: model.displayName,
      modelArchitecture: model.architecture,
      modelFileBytes: model.sizeBytes,
      contextTokens: actualContextTokens,
      cpuThreads: actualCpuThreads,
      startedAtUnixMs: startedAtMs,
      completedAtUnixMs: _clock().millisecondsSinceEpoch,
      firstLoadMs: firstLoadMs,
      repeatLoadMs: repeatLoadMs,
      generationElapsedMs: generationElapsedMs,
      generatedTokens: generatedTokens,
      tokensPerSecond: BenchmarkMetrics.tokensPerSecond(
        generatedTokens: generatedTokens,
        elapsedMilliseconds: generationElapsedMs ?? 0,
      ),
      peakResidentBytes: peakBytes,
      cancelLatencyMs: cancelLatencyMs,
      cancellationObserved: cancellationObserved,
      startingThermalStatus: startEnvironment?.thermalStatus,
      endingThermalStatus: endEnvironment.thermalStatus,
      peakThermalStatus: peakThermal,
      startingBatteryPercent: startEnvironment?.batteryLevelPercent,
      endingBatteryPercent: endEnvironment.batteryLevelPercent,
      runtimeVersion: runtimeVersion,
      status: status,
      error: error,
    );
    await _repository.insert(record);
    return BenchmarkRunResult(
      record: record,
      message: _nativeSessionMayStillBeActive
          ? 'لم يؤكد المحرك توقف التوليد؛ أُبقيت جلسة النموذج محجوزة ومنع NEXUS تفريغها. أعد تشغيل التطبيق قبل متابعة الاستخدام.'
          : status == 'completed'
              ? 'اكتمل قياس الأداء وحُفظت نتائجه.'
              : status == 'partial'
                  ? 'اكتمل جزء من القياس؛ حُفظت النتائج المتاحة مع سبب التوقف.'
                  : 'فشل القياس؛ حُفظ سجل الفشل للتشخيص.',
    );
  }

  Future<BenchmarkGenerationSample> _generateMeasured({
    required String prompt,
    required int maxTokens,
    Duration? cancelAfter,
  }) async {
    _runtimeManager.beginGeneration();
    try {
      return await _generationPort.generate(
        prompt: prompt,
        maxTokens: maxTokens,
        cancelAfter: cancelAfter,
      );
    } on BenchmarkNativeGenerationStuck {
      _nativeSessionMayStillBeActive = true;
      rethrow;
    } finally {
      if (!_nativeSessionMayStillBeActive) {
        _runtimeManager.endGeneration();
      }
    }
  }

  Future<BenchmarkEnvironmentSnapshot> _safeEnvironmentRead() async {
    try {
      return await _environmentReader.read();
    } on Object {
      return const BenchmarkEnvironmentSnapshot();
    }
  }

  String _newId(String modelId, int timestamp) {
    final suffix = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final safeModel = modelId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'bench_${timestamp}_${safeModel}_$suffix';
  }

  static const String _benchmarkPrompt =
      'اكتب شرحاً موجزاً ومنظماً عن الفرق بين الذاكرة العشوائية وذاكرة التخزين، '
      'ثم اذكر مثالاً عملياً يوضح أثر كل منهما على تشغيل نموذج ذكاء اصطناعي محلي.';
  static const String _cancellationPrompt =
      'اكتب تقريراً تفصيلياً مطولاً عن تصميم نظام ذكاء اصطناعي محلي متعدد الوكلاء، '
      'واشرح إدارة الموارد والذاكرة والسياق والتنسيق بين الأجهزة، مع أمثلة وخطوات تنفيذية.';
}
