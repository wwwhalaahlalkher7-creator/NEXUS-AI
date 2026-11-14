import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/benchmarks/benchmark_metrics.dart';
import 'package:nexus_app/src/features/benchmarks/benchmark_run_record.dart';

void main() {
  test('tokens per second uses elapsed wall time and actual output tokens', () {
    expect(
      BenchmarkMetrics.tokensPerSecond(
        generatedTokens: 120,
        elapsedMilliseconds: 2000,
      ),
      60,
    );
  });

  test('tokens per second is unknown for empty output or invalid duration', () {
    expect(
      BenchmarkMetrics.tokensPerSecond(
        generatedTokens: 0,
        elapsedMilliseconds: 2000,
      ),
      isNull,
    );
    expect(
      BenchmarkMetrics.tokensPerSecond(
        generatedTokens: 10,
        elapsedMilliseconds: 0,
      ),
      isNull,
    );
  });

  test('maximumKnown ignores missing readings without inventing values', () {
    expect(BenchmarkMetrics.maximumKnown([null, 10, 7, null]), 10);
    expect(BenchmarkMetrics.maximumKnown([null, null]), isNull);
  });

  test('benchmark records round-trip optional telemetry and cancellation', () {
    const record = BenchmarkRunRecord(
      id: 'bench-1',
      modelId: 'model-1',
      modelName: 'Model',
      modelArchitecture: 'llama',
      modelFileBytes: 1024,
      contextTokens: 2048,
      cpuThreads: 4,
      startedAtUnixMs: 100,
      completedAtUnixMs: 200,
      firstLoadMs: 400,
      repeatLoadMs: 250,
      generationElapsedMs: 2000,
      generatedTokens: 120,
      tokensPerSecond: 60,
      peakResidentBytes: 1024 * 1024,
      cancelLatencyMs: 35,
      cancellationObserved: true,
      startingThermalStatus: 1,
      endingThermalStatus: 2,
      peakThermalStatus: 2,
      startingBatteryPercent: 80,
      endingBatteryPercent: 77,
      runtimeVersion: 'llama-test',
      status: 'completed',
    );
    final restored = BenchmarkRunRecord.fromMap(record.toMap());
    expect(restored.id, record.id);
    expect(restored.tokensPerSecond, record.tokensPerSecond);
    expect(restored.cancellationObserved, isTrue);
    expect(restored.peakThermalStatus, 2);
    expect(restored.runtimeVersion, 'llama-test');
  });
}
