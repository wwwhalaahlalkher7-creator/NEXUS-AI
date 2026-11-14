#!/usr/bin/env python3
"""Source-level contract checks for the adaptive inference policy."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
policy = (ROOT / "lib/src/features/resources/adaptive_inference_policy.dart").read_text()
manager = (ROOT / "lib/src/features/runtime/model_runtime_manager.dart").read_text()
models_page = (ROOT / "lib/src/features/models/models_page.dart").read_text()
unit_tests = (ROOT / "test/adaptive_inference_policy_test.dart").read_text()
manager_tests = (ROOT / "test/model_runtime_manager_test.dart").read_text()

required_policy = [
    "class AdaptiveInferencePolicy",
    "ResourceMode.balanced",
    "ResourceMode.performance",
    "ResourceMode.unrestricted",
    "ModelFitStatus.likelyFits",
    "ModelFitStatus.tight",
    "ModelFitStatus.insufficient",
    "thermalStatus",
    "cpuUtilizationPercent",
    "batteryLevelPercent",
    "nativeMaxCpuThreads = 8",
    "List.unmodifiable(reasons)",
    "List.unmodifiable(warnings)",
]
for token in required_policy:
    assert token in policy, f"Adaptive inference policy is missing: {token}"

assert "Future<ModelSessionSnapshot> prepare(" in manager
assert "int? contextTokens" in manager and "int? cpuThreads" in manager
assert "_preparedCpuThreads ?? _policy.cpuThreads" in manager
assert "threads: targetThreads" in manager
assert "previousThreads" in manager and "threads: previousThreads" in manager
assert "cpuThreads: cpuThreads" in manager
assert "requestedContextTokens: contextTokens" in manager
assert "useCatalogFallback: verification.inspection == null" in manager

assert "DeviceResourceMonitor().readSnapshot(" in models_page
assert "includeExtendedTelemetry: true" in models_page
assert "ResourceSettingsRepository().load()" in models_page
assert "AdaptiveInferencePolicy.recommend(" in models_page
assert "_AdaptiveInferenceDialog(" in models_page
assert "InferenceRuntimeSelection" in models_page
assert "_runtimeManager.switchTo(" in models_page
assert "_runtimeManager.prepare(" in models_page
assert "اعتماد الإعداد وفحص الجاهزية" in models_page

for expected in [
    "balanced mode prefers a fitting context",
    "performance mode can recommend",
    "thermal and CPU pressure reduce threads",
    "low battery caps balanced threads",
    "unrestricted mode does not silently throttle",
    "unknown memory does not pretend",
    "fresh GGUF context metadata overrides",
    "unrestricted mode keeps maximum context even when RAM is insufficient",
]:
    assert expected in unit_tests, f"Missing Dart policy test: {expected}"

for expected in [
    "prepared adaptive context and CPU threads",
    "adaptive runtime overrides reject values",
    "switch restores previous CPU thread selection",
    "explicitly reload the active model",
    "fresh GGUF without context metadata does not reuse a stale catalog limit",
]:
    assert expected in manager_tests, f"Missing runtime manager test: {expected}"

print("Adaptive inference policy source contracts passed.")
