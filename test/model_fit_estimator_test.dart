import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/models/model_fit_estimator.dart';
import 'package:nexus_app/src/features/models/model_record.dart';
import 'package:nexus_app/src/features/models/rust_gguf_inspector.dart';

ModelRecord _model({
  String architecture = 'llama',
  int? blocks = 32,
  int? embedding = 4096,
  int? context = 8192,
  int? heads = 32,
  int? kvHeads = 8,
  int? keyLength = 128,
  int? valueLength = 128,
  ModelRuntime runtime = ModelRuntime.llamaCpp,
  ModelInstallStatus status = ModelInstallStatus.installed,
}) =>
    ModelRecord(
      id: 'model-a',
      displayName: 'Test model',
      runtime: runtime,
      status: status,
      sizeBytes: 1024 * 1024 * 1024,
      architecture: architecture,
      contextLength: context,
      blockCount: blocks,
      embeddingLength: embedding,
      attentionHeadCount: heads,
      attentionHeadCountKv: kvHeads,
      attentionKeyLength: keyLength,
      attentionValueLength: valueLength,
      createdAtUnixMs: 1,
      updatedAtUnixMs: 1,
    );

void main() {
  test('uses GGUF GQA dimensions for exact F16 KV cache planning', () {
    final result = ModelFitEstimator.estimate(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 4 * ModelFitEstimator.gib,
    );

    // 2048 * 32 layers * 8 KV heads * (128 K + 128 V) * 2 bytes.
    expect(result.kvCacheBytes, 268435456);
    expect(result.kvMethod, KvCacheEstimateMethod.ggufAttentionDimensions);
    expect(result.status, ModelFitStatus.likelyFits);
    expect(result.recommendedRequiredBytes, greaterThan(result.minimumRequiredBytes));
    expect(result.upperRequiredBytes, greaterThan(result.recommendedRequiredBytes));
  });

  test('uses full embedding width as conservative MHA fallback', () {
    final result = ModelFitEstimator.estimate(
      model: _model(
        kvHeads: null,
        heads: null,
        keyLength: null,
        valueLength: null,
      ),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 8 * ModelFitEstimator.gib,
    );

    // 2048 * 32 * 4096 * (K + V) * 2 bytes.
    expect(result.kvCacheBytes, 1073741824);
    expect(result.kvMethod, KvCacheEstimateMethod.fullEmbeddingUpperBound);
  });

  test('classifies insufficient and tight available-memory ranges', () {
    final base = ModelFitEstimator.estimate(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 0,
    );
    final belowMinimum = ModelFitEstimator.estimate(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: base.minimumRequiredBytes - 1,
    );
    final tight = ModelFitEstimator.estimate(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: base.recommendedRequiredBytes - 1,
    );

    expect(base.status, ModelFitStatus.unknown);
    expect(belowMinimum.status, ModelFitStatus.insufficient);
    expect(tight.status, ModelFitStatus.tight);
  });

  test('does not claim fit for unavailable memory telemetry', () {
    final result = ModelFitEstimator.estimate(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 0,
    );
    expect(result.status, ModelFitStatus.unknown);
    expect(result.hasKnownAvailability, isFalse);
    expect(result.recommendedRequiredBytes, greaterThan(0));
  });

  test('rejects unsupported state-space architectures instead of inventing KV', () {
    final result = ModelFitEstimator.estimate(
      model: _model(architecture: 'mamba'),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 8 * ModelFitEstimator.gib,
    );
    expect(result.status, ModelFitStatus.unknown);
    expect(result.reason, contains('غير مدعومة'));
  });

  test('rejects inconsistent GGUF KV head dimensions', () {
    final result = ModelFitEstimator.estimate(
      model: _model(kvHeads: 64),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 8 * ModelFitEstimator.gib,
    );
    expect(result.status, ModelFitStatus.unknown);
    expect(result.reason, contains('KV Cache'));
  });

  test('rejects context above the GGUF training context or native range', () {
    final aboveTraining = ModelFitEstimator.estimate(
      model: _model(context: 1024),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 8 * ModelFitEstimator.gib,
    );
    final aboveNative = ModelFitEstimator.estimate(
      model: _model(),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 8192,
      availableMemoryBytes: 8 * ModelFitEstimator.gib,
    );
    expect(aboveTraining.status, ModelFitStatus.unknown);
    expect(aboveNative.status, ModelFitStatus.unknown);
  });

  test('rejects unverified, uninstalled and external model inputs', () {
    final invalidFile = ModelFitEstimator.estimate(
      model: _model(),
      verifiedModelFileBytes: 0,
      contextTokens: 2048,
      availableMemoryBytes: 8 * ModelFitEstimator.gib,
    );
    final notInstalled = ModelFitEstimator.estimate(
      model: _model(status: ModelInstallStatus.registered),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 8 * ModelFitEstimator.gib,
    );
    final external = ModelFitEstimator.estimate(
      model: _model(runtime: ModelRuntime.external),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 8 * ModelFitEstimator.gib,
    );
    expect(invalidFile.status, ModelFitStatus.unknown);
    expect(notInstalled.status, ModelFitStatus.unknown);
    expect(external.status, ModelFitStatus.unknown);
  });


  test('fresh GGUF inspection overrides stale cached model metadata', () {
    final staleModel = _model(
      architecture: 'mamba',
      blocks: 1,
      embedding: 64,
      context: 1024,
      heads: null,
      kvHeads: null,
      keyLength: null,
      valueLength: null,
    );
    const fresh = GgufInspection(
      validHeader: true,
      fileName: 'fresh.gguf',
      sizeBytes: 1024 * 1024 * 1024,
      formatVersion: 3,
      tensorCount: 10,
      metadataCount: 20,
      architecture: 'llama',
      contextLength: 4096,
      blockCount: 32,
      embeddingLength: 4096,
      attentionHeadCount: 32,
      attentionHeadCountKv: 8,
      attentionKeyLength: 128,
      attentionValueLength: 128,
      message: 'verified',
    );

    final result = ModelFitEstimator.estimate(
      model: staleModel,
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 8 * ModelFitEstimator.gib,
      freshInspection: fresh,
    );

    expect(result.status, ModelFitStatus.likelyFits);
    expect(result.kvCacheBytes, 268435456);
    expect(result.kvMethod, KvCacheEstimateMethod.ggufAttentionDimensions);
    expect(result.assumptions, contains('استُخدمت أبعاد رؤوس K/V المسجلة في GGUF.'));
  });

  test('uses legacy full-width layout when only head count is available', () {
    final result = ModelFitEstimator.estimate(
      model: _model(kvHeads: null, keyLength: null, valueLength: null),
      verifiedModelFileBytes: 1024 * 1024 * 1024,
      contextTokens: 2048,
      availableMemoryBytes: 8 * ModelFitEstimator.gib,
    );
    expect(result.status, ModelFitStatus.likelyFits);
    expect(result.kvMethod, KvCacheEstimateMethod.fullEmbeddingUpperBound);
  });
}
