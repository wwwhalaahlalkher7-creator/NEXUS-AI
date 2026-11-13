# Alpha 1.5.0 — Typed Flutter ↔ Rust runtime bridge

## Goal

Replace the manually serialized runtime diagnostics JSON payload with a
strongly typed DTO crossing the generated Flutter Rust Bridge boundary, and
exercise a deterministic bridge health endpoint from Flutter before reading
runtime capabilities.

## Changes

- Add `RuntimeDiagnosticsDto` to the Rust bridge API.
- Return native engine availability, version and diagnostic message as typed
  fields alongside core identity and explicit capability flags.
- Replace `runtime_diagnostics_json()` with `runtime_diagnostics()`.
- Have Flutter call `health_check()` and validate its exact response before
  requesting typed diagnostics.
- Map the typed DTO into `CoreRuntimeStatus`; preserve unavailable/error states.
- Keep `inference_available` and `model_loaded` false.
- Keep GGUF inspection as its existing separate typed bridge operation.
- Bump Flutter package to `1.5.0+22` and Rust workspace to `1.5.0`.

## Explicitly excluded

- GGUF tensor/model loading and inference context creation.
- Tokenization, generation, streaming, cancellation or sampling.
- GPU acceleration, multiple sessions or model sharding.
- Changes to the current Debug APK workflow.

## Acceptance criteria

1. `cargo fmt --all -- --check` passes.
2. `cargo test --workspace` passes.
3. `cargo clippy --workspace --all-targets -- -D warnings` passes.
4. FRB code generation produces `runtimeDiagnostics()` and `healthCheck()`
   Dart APIs with the DTO fields; CI explicitly checks all three generated
   symbols (`healthCheck`, `runtimeDiagnostics`, and `RuntimeDiagnosticsDto`).
5. `dart format --output=none --set-exit-if-changed lib test` passes.
6. `flutter analyze --no-pub` and `flutter test --no-pub` both pass.
7. ARM64 Debug APK builds and packages the same native libraries as Alpha 1.4.
8. A physical Android device reports bridge connected and the real native
   adapter status, without claiming a model is loaded or inference is active.

## Validation boundary

The source archive is statically inspected here. Flutter, Dart, Rust/Cargo and
Android NDK toolchains are not installed in this environment, so GitHub Actions
and a physical ARM64 Android smoke test remain required.
