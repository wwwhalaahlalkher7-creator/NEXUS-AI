# Flutter ↔ Rust bridge

## Selected bridge
`flutter_rust_bridge` is pinned to 2.13.0 in Dart and Rust. The Flutter project is
at the repository root; `flutter_rust_bridge.yaml` therefore also lives at the root.
The dedicated `core/bridge` crate depends on `core/runtime`.

## Initial exported API
- `get_core_info_for_app()` returns the compiled Rust core identity and stage.
- `health_check()` returns a deterministic bridge reachability response.

These calls establish a native boundary before moving agent orchestration or model
execution across it. They do not indicate that model inference is available.

## Generate locally
From repository root, with Flutter and Rust installed:

```bash
bash scripts/integrate_bridge.sh
```

The same integration and generation commands run in GitHub Actions. Generated glue
must come from `flutter_rust_bridge_codegen`; do not hand-write generated files.

## CI verification
`.github/workflows/ci.yml` runs Rust formatting/tests/Clippy, Flutter formatting,
analysis and tests, generates the bridge, creates the Android platform scaffold,
and builds a debug ARM64 APK artifact.

## Android note
The workflow uses the Android SDK and the Flutter toolchain provided by GitHub Actions.
A debug APK is for installation/testing only, not a signed Play Store release.

## Verification gate
- `cargo fmt --all -- --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `flutter pub get`
- `dart format --output=none --set-exit-if-changed lib test`
- `flutter analyze --no-pub`
- `flutter test --no-pub`
- `flutter build apk --debug --target-platform android-arm64`

Bridge acceptance still requires verifying model loading, streamed generation, and cancellation from Flutter on a physical Android device; successful code generation alone is insufficient.

## llama.cpp native adapter (Alpha 1.4 → Alpha 1.7)

The Rust runtime dynamically loads the Android ARM64 `libnexus_llama_probe.so`
adapter, which statically links the pinned upstream llama.cpp/GGML implementation.
The adapter is packaged by Android CI through `jniLibs`. This is separate from
Flutter Rust Bridge: FRB invokes safe Rust diagnostics and lifecycle functions,
and Rust encapsulates the dynamic C ABI boundary.

Alpha 1.4 initialized the backend only. Alpha 1.6 adds actual GGUF weight loading,
one CPU context, a conservative memory preflight, one-active-session enforcement,
and explicit unload. Alpha 1.7 adds prompt tokenization/evaluation, bounded sampling,
streamed text output, and cancellation. The C ABI frees the context before the
owning model and prevents unload from racing with generation.

## Typed diagnostics and lifecycle API

Runtime diagnostics cross the bridge as `RuntimeDiagnosticsDto`, not a JSON
string. Flutter calls `health_check()` and then maps `runtime_diagnostics()`
into its UI-facing status. The typed `load_gguf_model(path, context_tokens,
threads)` and `unload_gguf_model()` calls expose the native session lifecycle.
`model_loaded` and the actual context size are reported only after native
confirmation. The `generate_text()` API returns a `Stream<InferenceEventDto>`
with a start marker, text deltas, and one terminal event. `cancel_text_generation()`
sets an atomic cancellation request without waiting on the model/session lock.
The bridge callback catches panics, handles split UTF-8 token pieces, and never
allows a Rust panic to cross the C ABI boundary. `inference_available` becomes
true only after a successful non-cancelled response for the active session and
resets when the model is unloaded. Each generation clears KV memory, so history
and multi-turn context are not yet supported.


## Alpha 1.7 generation API

`generate_text(sink, prompt, max_tokens, temperature, top_k, top_p, seed)` is a synchronous Rust operation on an FRB worker while its output is streamed through `StreamSink`. The native entrypoint validates model architecture, prompt bounds, sampling ranges, and context capacity before evaluation. Its first callback is a zero-length start signal; later callbacks contain byte pieces and token counts; its terminal result includes success, cancellation, or an error. Dart's Stop control is enabled only after the start marker.
