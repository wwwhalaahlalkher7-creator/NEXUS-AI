#!/usr/bin/env python3
"""Source contracts for the local benchmark harness and its measurement caveats."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
runner = (ROOT / "lib/src/features/benchmarks/benchmark_runner.dart").read_text(encoding="utf-8")
port = (ROOT / "lib/src/features/benchmarks/benchmark_generation_port.dart").read_text(encoding="utf-8")
record = (ROOT / "lib/src/features/benchmarks/benchmark_run_record.dart").read_text(encoding="utf-8")
page = (ROOT / "lib/src/features/benchmarks/benchmark_page.dart").read_text(encoding="utf-8")
models = (ROOT / "lib/src/features/models/models_page.dart").read_text(encoding="utf-8")
metrics = (ROOT / "lib/src/features/benchmarks/benchmark_metrics.dart").read_text(encoding="utf-8")
readme = (ROOT / "README.md").read_text(encoding="utf-8")

checks = {
    "benchmark refuses an active or recovery-required model session": "snapshot.isLoaded" in runner and "snapshot.needsRecovery" in runner,
    "benchmark measures first and repeat loads separately": "firstLoadMs" in runner and "repeatLoadMs" in runner,
    "repeat load is not falsely described as guaranteed cold-cache": "cannot flush Linux file cache" in runner,
    "benchmark excludes warm-up generation and rejects a failed warm-up": "One short warm-up is excluded" in runner and "if (!warmup.completed || warmup.generatedTokens <= 0)" in runner,
    "throughput uses actual generated tokens and measured elapsed time": "BenchmarkMetrics.tokensPerSecond" in runner and "event.generatedTokens" in port,
    "cancellation latency is only reported when cancellation was accepted": "cancelAccepted ? cancellationWatch?.elapsedMilliseconds : null" in port,
    "generation lease is released after terminal completion": "finally" in runner and "_runtimeManager.endGeneration()" in runner,
    "native timeout drains to terminal before unload and retains lease if still active": "terminal.future.timeout(const Duration(seconds: 30))" in port and "BenchmarkNativeGenerationStuck" in port and "_nativeSessionMayStillBeActive" in runner and "احتفظ NEXUS بقفل جلسة النموذج" in runner,
    "benchmark cleans up its model session after measurement": "await _runtimeManager.unload()" in runner,
    "RSS is explicitly process-wide lifetime high-water telemetry": "process-wide vmhwm" in record.lower() and "nativePeakResidentBytes" in runner and "منذ بدء التطبيق" in page,
    "thermal and battery values remain optional": "int? thermalStatus" in runner and "int? batteryLevelPercent" in runner,
    "benchmark provenance persists actual loaded context and threads": "actualContextTokens = loaded.contextTokens" in runner and "actualCpuThreads = loaded.cpuThreads" in runner and "contextTokens: actualContextTokens" in runner and "cpuThreads: actualCpuThreads" in runner,
    "repeat load must match first effective settings": "تغيّرت إعدادات الجلسة الفعلية بين التحميلين" in runner,
    "benchmark provenance persists model context threads runtime and status": all(value in record for value in ["modelId", "contextTokens", "cpuThreads", "runtimeVersion", "startedAtUnixMs", "status"]),
    "benchmark UI warns about heat and battery before execution": "قد يستهلك الاختبار البطارية ويرفع حرارة الجهاز" in page and "showDialog<bool>" in page,
    "benchmark UI is reachable from the model library": "BenchmarkPage(" in models,
    "benchmark remains documented and roadmap advances after privacy center": "Exact remaining work after Alpha 2.8.0" in readme and "Alpha 2.7.6 — Explainable peer placement" in readme and "Alpha 2.8.0 — Local privacy center" in readme,
    "benchmark page explains unavailable cancellation measurements": "لم يُقَس" in page,
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Benchmark contract failures: " + ", ".join(failed))
print(f"Benchmark contract PASS: {len(checks)} checks")
