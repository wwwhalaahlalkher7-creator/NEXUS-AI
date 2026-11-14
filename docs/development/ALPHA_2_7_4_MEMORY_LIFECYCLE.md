# Alpha 2.7.4 — Native memory lifecycle (`2.7.4+56`)

## Scope

This milestone makes the existing CPU-first llama.cpp memory lifecycle observable and adds a safe, explicit KV maintenance operation. It does not claim that process RSS is a direct measurement of model-only memory or that `free()` must immediately reduce RSS.

## Native lifecycle invariants

- Every generation owns a `ContextMemoryReset` scope. The guard clears the active llama memory before prompt evaluation and again on every exit path. Cancellation, template errors, tokenization failures, decode errors, callback rejection and successful generation all leave the transient KV state cleared before the session mutex is released.
- Session teardown clears KV while the context is still alive, then frees `llama_context`, then frees `llama_model`.
- Model/context loaded flags and successful load/unload counters are process atomics. KV clear count records calls to `llama_memory_clear` requested through the NEXUS adapter; it is not a byte count.
- `nexus_llama_clear_context_memory` is additive to the C ABI. It checks generation state, uses `try_lock`, refuses if the model session is busy or no context is loaded, and clears only KV/sequence memory. It does not unload model weights or the context.

## Memory diagnostics

The additive `nexus_llama_memory_snapshot` symbol reports:

- model/context loaded state and active generation flag;
- successful model load/unload counts and KV clear count;
- `VmRSS`, `VmHWM`, and `VmSize` from `/proc/self/status` when readable.

The three memory values describe the **whole NEXUS process**, including Flutter, Rust, and other native libraries. They are not llama.cpp-only values. A successful free of model/context objects may not lower RSS because the system allocator may retain pages for reuse. Therefore, RSS decrease is not used as the criterion for successful cleanup; session state and deterministic native lifecycle counters are the observable signals.

## Flutter behaviour

The dashboard runtime card shows RSS, peak RSS, and virtual size when the OS metrics are readable. Session state and lifecycle counters remain visible when `/proc/self/status` cannot be read. A user can request a KV-only clear only while the native context is loaded, through a confirmation dialog; the control is disabled while generation is reported active. The operation result is shown in a snackbar and diagnostics are refreshed. Model weights and the context remain loaded after a KV-only clear.

## Compatibility

- Flutter package version: `2.7.4+56`.
- Rust workspace version remains `2.6.2`.
- SQLite remains schema v14; no migration is needed.
- No third-party package was added.
- No existing C ABI signature was changed; two new symbols were added and must be present in the rebuilt adapter.

## Verification included

- Extended host C++ fake-llama contract tests for process memory snapshot, KV clearing while idle, refusal during generation, KV cleanup after cancellation/generation, context/model unloaded flags, and idempotent unload counters.
- Python source contract checks for C/Rust FFI field layout, cleanup order, `try_lock`, FRB exposure, UI consent and generation gating.
- Flutter widget test for displayed process memory values and explicit KV clear confirmation.

## Still required

Flutter/Dart formatter, analyzer and widget tests; Rust formatting, workspace tests and Clippy; FRB binding regeneration; pinned llama.cpp Android NDK compilation; Debug APK packaging; and physical-device tests that repeatedly load, generate, cancel, clear KV, unload, and inspect memory under pressure. The host fake llama API contract does not replace these checks.
