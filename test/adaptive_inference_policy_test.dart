import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/models/model_record.dart';
import 'package:nexus_app/src/features/models/rust_gguf_inspector.dart';
import 'package:nexus_app/src/features/resources/adaptive_inference_policy.dart';
import 'package:nexus_app/src/features/resources/resource_settings.dart';

ModelRecord _model() => ModelRecord(
      id: 'adaptive-model',
      displayName: 'Adaptive test model',
      runtime: ModelRuntime.llamaCpp,
      status: ModelInstallStatus.installed,
      sizeBytes: 1024 * 1024 * 1024,
      architecture: 'llama',
      contextLength: 8192,
      blockCount: 32,
      embeddingLength: 4096,
      attentionHeadCount: 32,
      attentionHeadCountKv: 8,
      attentionKeyLength: 128,
      attentionValueLength: 128,
      createdAtUnixMs: 1,
      updatedAtUnixMs: 1,
    );

void main() {
  test('balanced mode prefers a fitting context no greater than 2048', () {
    final result = AdaptiveInferencePolicy.recommend(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      resources: const ResourceSnapshot(
        availableMemoryBytes: 12 * ModelFitEstimatorTestValues.gib,
        cpuLogicalCores: 8,
      ),
      settings: const ResourceSettings(mode: ResourceMode.balanced),
    );

    expect(result.contextTokens, 2048);
    expect(result.cpuThreads, 4);
    expect(result.estimate.status.name, 'likelyFits');
  });

  test('performance mode can recommend the largest fitting context and cores', () {
    final result = AdaptiveInferencePolicy.recommend(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      resources: const ResourceSnapshot(
        availableMemoryBytes: 12 * ModelFitEstimatorTestValues.gib,
        cpuLogicalCores: 6,
      ),
      settings: const ResourceSettings(mode: ResourceMode.performance),
    );

    expect(result.contextTokens, 4096);
    expect(result.cpuThreads, 6);
  });

  test('thermal and CPU pressure reduce threads outside unrestricted mode', () {
    final result = AdaptiveInferencePolicy.recommend(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      resources: const ResourceSnapshot(
        availableMemoryBytes: 12 * ModelFitEstimatorTestValues.gib,
        cpuLogicalCores: 8,
        cpuUtilizationPercent: 94,
        thermalStatus: 4,
      ),
      settings: const ResourceSettings(mode: ResourceMode.performance),
    );

    expect(result.cpuThreads, 1);
    expect(result.reasons.any((reason) => reason.contains('حرارية')), isTrue);
  });

  test('low battery caps balanced threads when the device is not charging', () {
    final result = AdaptiveInferencePolicy.recommend(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      resources: const ResourceSnapshot(
        availableMemoryBytes: 12 * ModelFitEstimatorTestValues.gib,
        cpuLogicalCores: 8,
        batteryLevelPercent: 10,
        isCharging: false,
      ),
      settings: const ResourceSettings(mode: ResourceMode.balanced),
    );

    expect(result.cpuThreads, 2);
    expect(result.reasons.any((reason) => reason.contains('البطارية')), isTrue);
  });

  test('unrestricted mode does not silently throttle but explains native ceiling', () {
    final result = AdaptiveInferencePolicy.recommend(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      resources: const ResourceSnapshot(
        availableMemoryBytes: 12 * ModelFitEstimatorTestValues.gib,
        cpuLogicalCores: 16,
        cpuUtilizationPercent: 99,
        batteryLevelPercent: 5,
        isCharging: false,
        thermalStatus: 5,
      ),
      settings: const ResourceSettings(mode: ResourceMode.unrestricted),
    );

    expect(result.contextTokens, 4096);
    expect(result.cpuThreads, 8);
    expect(result.warnings.any((warning) => warning.contains('حد واجهة المحرك')), isTrue);
    expect(result.warnings.any((warning) => warning.contains('توجد إشارة')), isTrue);
  });

  test('unrestricted mode keeps maximum context even when RAM is insufficient', () {
    final result = AdaptiveInferencePolicy.recommend(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      resources: const ResourceSnapshot(
        availableMemoryBytes: 512 * 1024 * 1024,
        cpuLogicalCores: 8,
      ),
      settings: const ResourceSettings(mode: ResourceMode.unrestricted),
    );

    expect(result.contextTokens, 4096);
    expect(result.estimate.status.name, 'insufficient');
    expect(result.warnings.any((warning) => warning.contains('RAM المتاحة')), isTrue);
  });

  test('unknown memory does not pretend that the model is known to fit', () {
    final result = AdaptiveInferencePolicy.recommend(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      resources: const ResourceSnapshot(
        availableMemoryBytes: 0,
        cpuLogicalCores: 4,
      ),
      settings: const ResourceSettings(mode: ResourceMode.balanced),
    );

    expect(result.contextTokens, 2048);
    expect(result.estimate.status.name, 'unknown');
    expect(result.warnings.any((warning) => warning.contains('RAM')), isTrue);
  });
  test('fresh GGUF context metadata overrides a larger stale catalog value', () {
    const fresh = GgufInspection(
      validHeader: true,
      fileName: 'fresh.gguf',
      sizeBytes: 1024 * 1024 * 1024,
      formatVersion: 3,
      tensorCount: 10,
      metadataCount: 20,
      architecture: 'llama',
      contextLength: 1024,
      blockCount: 32,
      embeddingLength: 4096,
      attentionHeadCount: 32,
      attentionHeadCountKv: 8,
      attentionKeyLength: 128,
      attentionValueLength: 128,
      message: 'fresh',
    );
    final result = AdaptiveInferencePolicy.recommend(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      resources: const ResourceSnapshot(
        availableMemoryBytes: 12 * ModelFitEstimatorTestValues.gib,
        cpuLogicalCores: 8,
      ),
      settings: const ResourceSettings(mode: ResourceMode.performance),
      freshInspection: fresh,
    );

    expect(result.contextOptions, [512, 1024]);
    expect(result.contextTokens, 1024);
  });

}

abstract final class ModelFitEstimatorTestValues {
  static const int gib = 1024 * 1024 * 1024;
}
