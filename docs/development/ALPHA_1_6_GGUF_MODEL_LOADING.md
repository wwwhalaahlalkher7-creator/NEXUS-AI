# Alpha 1.6.0 — Real GGUF loading and CPU session lifecycle

## Scope

This milestone connects the model library to the existing Android ARM64 llama.cpp
adapter. It loads GGUF weights and creates one CPU context. It does not implement
prompt tokenization, prompt evaluation, sampling, text generation, or token streams.
`inference_available` therefore remains false.

## Native lifecycle

- `nexus_llama_load_model(path, context_tokens, threads, actual_context)` loads
  one model via `llama_model_load_from_file` and creates a context via
  `llama_init_from_model`.
- Context is restricted to a requested 512–4096 tokens, CPU-only placement,
  one sequence, batches of 128, and 1–8 CPU threads. The returned context size
  is obtained from `llama_n_ctx`, not assumed from the requested value.
- A second model cannot replace the active session. Loading the same path and
  context is idempotent.
- `nexus_llama_unload_model` frees context before model.
- The preflight checks `/proc/meminfo` `MemAvailable` against model file size,
  a 12.5% margin, a 384 MiB base reserve, and 128 MiB per 2k context. If the
  value cannot be read or the estimate is not met, loading is rejected. This
  is a conservative heuristic, not a guarantee against Android low-memory kills.

## Flutter/Rust bridge

- `load_gguf_model(path, context_tokens, threads)` and `unload_gguf_model()`
  return a typed `ModelRuntimeOperationDto`.
- Rust dynamically loads the NEXUS adapter and serializes calls through one
  process-level backend lock. Failed library initialization can be retried.
- `RuntimeDiagnosticsDto` reports `model_loaded` and `model_context_tokens`
  from the native adapter. It never equates an initialized backend with a loaded model.
- The model page and dashboard share one app-scoped session manager, expose
  actual load/unload states, and prevent deletion or replacement of the active
  model file.

## Validation

The host contract test compiles `llama_probe.cpp` against a fake llama API. It
checks the exported C ABI, load/unload, idempotent load, second-model rejection,
invalid inputs, missing/corrupt fixture errors, context allocation failure,
and the low-memory rejection path. It is not a test of the pinned upstream
llama.cpp implementation.

CI must still compile the adapter against the pinned upstream llama.cpp commit
with Android NDK, verify all seven exports in the ARM64 shared object, verify
generated FRB methods/DTOs, and complete Rust + Flutter gates before creating
the Debug APK. After install, a physical-device test must import a compatible
GGUF, load it, confirm native status/context, unload it, and verify the app
remains responsive.

## Known limitations / next work

- No prompt/token generation yet.
- The available-memory check is heuristic and cannot fully predict Android
  per-process memory pressure.
- No load progress callback or cancellation yet.
- Only one model and one CPU context are supported.
- Release signing/build remains deferred until feature development and final
  device validation are complete. The final delivery target is a signed APK,
  not AAB.
