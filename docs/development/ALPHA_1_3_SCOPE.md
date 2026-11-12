# NEXUS AI Alpha 1.3 — Model Runtime Lifecycle

## Scope

Alpha 1.3 introduces a process-local model session coordinator. It separates file preflight from actual engine loading and provides explicit lifecycle states: idle, checking, ready-to-load, loading, loaded, unloading, and failed.

## Delivered

- Local GGUF file verification before a model can enter the prepared state.
- Policy ceilings for model-file size and context length. These are policy checks, not available-RAM measurements or guarantees that a device can run a model.
- A single-session coordinator that rejects overlapping operations.
- A backend contract for load/unload operations and an explicit unavailable production adapter until llama.cpp is integrated.
- UI feedback in the model library for preflight readiness.
- Protection against replacing or deleting a model while its runtime session is actually loaded.
- Tests for successful preflight, unavailable engine behavior, lifecycle transitions through a test backend, policy rejection, runtime-type rejection, and overlapping operations.

## Explicit limitations

- No llama.cpp inference backend is integrated in this stage.
- The default backend cannot load or unload a real model.
- No device RAM telemetry, KV-cache estimation, token generation, or persistent runtime session is implemented.
- `readyToLoad` means only that the bounded file checks and configured policy passed; it does not guarantee memory fit or successful inference.

## Verification

Run the repository GitHub Actions workflow. Flutter and Rust toolchains are not available in the editing environment, so no local Flutter test, Rust test, or APK build result is claimed.
