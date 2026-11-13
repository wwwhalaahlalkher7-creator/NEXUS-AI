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

## llama.cpp native adapter (Alpha 1.4 → Alpha 1.9)

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
resets when the model is unloaded. Native KV memory is cleared after each request;
Alpha 1.9 reconstructs multi-turn context by sending completed role-aware messages
from local SQLite history through the model chat template on every request.


## Historical Alpha 1.7 single-prompt API

Alpha 1.7 originally exposed `generate_text(sink, prompt, max_tokens, temperature, top_k, top_p, seed)`. Alpha 1.9 replaces the single-prompt argument with a bounded role-aware message list; the native streaming lifecycle remains the same. Its first callback is a zero-length start signal; later callbacks contain byte pieces and token counts; its terminal result includes success, cancellation, an error, and the number of trimmed history messages.


## Alpha 1.9 role-aware generation API

`generate_text(sink, messages, max_tokens, temperature, top_k, top_p, seed)` accepts a bounded vector of `ChatMessageInputDto` values. Rust validates the roles and message bounds, keeps owned `CString` buffers alive for the synchronous native call, and passes an array of `repr(C)` message views to the NEXUS adapter. The adapter applies the model's embedded llama.cpp chat template to the full sequence and returns `trimmed_messages` with the terminal generation event.

The context limit is measured with the loaded model vocabulary after formatting. Oldest complete user/assistant turns are removed until the formatted prompt plus the requested completion fits; system messages and the newest user turn are never removed. Flutter reports any trimming to the user.
