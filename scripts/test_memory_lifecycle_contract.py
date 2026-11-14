#!/usr/bin/env python3
"""Contract checks for native memory lifecycle, telemetry and explicit KV clearing."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
cpp = (ROOT / "native/llama/src/llama_probe.cpp").read_text(encoding="utf-8")
rust = (ROOT / "core/runtime/src/native/engine.rs").read_text(encoding="utf-8")
bridge = (ROOT / "core/bridge/src/api/simple.rs").read_text(encoding="utf-8")
status = (ROOT / "lib/src/features/runtime/core_runtime_status.dart").read_text(encoding="utf-8")
card = (ROOT / "lib/src/features/runtime/core_runtime_card.dart").read_text(encoding="utf-8")
tests = (ROOT / "test/core_runtime_card_test.dart").read_text(encoding="utf-8")

release = cpp.split("void release_session_locked()", 1)[1].split("bool read_process_memory", 1)[0]
clear_api = cpp.split("nexus_llama_clear_context_memory() noexcept", 1)[1].split("nexus_llama_unload_model() noexcept", 1)[0]

checks = {
    "generation owns a scoped KV reset guard": "ContextMemoryReset memory_reset(session.context);" in cpp,
    "KV state is cleared both on guard entry and exit": cpp.count("clear_context_memory(context);") >= 2,
    "session release clears context memory before freeing the context": "clear_context_memory(session.context);" in release and release.index("clear_context_memory(session.context);") < release.index("llama_free(session.context);") ,
    "context is freed before its owning model": release.index("llama_free(session.context);") < release.index("llama_model_free(session.model);") ,
    "native memory diagnostics expose RSS, peak and virtual size": all(x in cpp for x in ["VmRSS:", "VmHWM:", "VmSize:", "nexus_llama_memory_snapshot"]),
    "native memory diagnostics identify process-wide measurements": "whole process" in cpp and "allocator may retain" in cpp,
    "KV maintenance refuses while generation is active": clear_api.index("generation_active.load") < clear_api.index("std::unique_lock<std::mutex>"),
    "KV maintenance uses a non-blocking session lock": "std::try_to_lock" in clear_api,
    "model and KV lifecycle counters are atomic": all(x in cpp for x in ["kv_cache_clear_count", "model_load_count", "model_unload_count"]),
    "Rust FFI snapshot layout mirrors the C ABI fields": all(x in rust for x in ["struct MemorySnapshotFfi", "resident_bytes: u64", "peak_resident_bytes: u64", "kv_cache_clear_count: u64"]),
    "Rust exposes a host-safe unavailable memory snapshot": "NativeMemorySnapshot::unavailable()" in rust,
    "FRB diagnostics carry memory lifecycle data": all(x in bridge for x in ["native_memory_readable", "native_resident_bytes", "native_kv_cache_clear_count", "clear_native_context_memory"]),
    "Flutter labels RSS as process-wide and caveats allocator retention": "تشمل العملية كاملة" in card and "قد لا تنخفض فور تحرير النموذج" in card,
    "Flutter asks for confirmation before clearing transient KV": "showDialog<bool>" in card and "ستظل أوزان النموذج وسياق التشغيل محمّلين" in card,
    "Flutter disables clearing unless the model context is loaded": "status.nativeContextLoaded" in card and "status.modelLoaded" in card,
    "Flutter disables clearing during generation": "status.nativeGenerationActive" in card and "التوليد نشط؛ التفريغ غير متاح" in card,
    "Flutter retains lifecycle flags when process memory metrics are unavailable": "قياسات RSS غير متاحة على هذا الجهاز" in card and "حالة السياق الأصلي" in card,
    "Flutter status stores native generation and memory counters": all(x in status for x in ["nativeGenerationActive", "nativeResidentBytes", "nativeKvCacheClearCount"]),
    "widget test verifies native memory metrics and explicit clear confirmation": "shows native memory metrics and clears only KV cache on confirmation" in tests,
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Memory lifecycle contract failures: " + ", ".join(failed))
print(f"Memory lifecycle contract PASS: {len(checks)} checks")
