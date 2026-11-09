# Alpha 0.6 — Rust runtime bridge integration

## Implemented in this milestone
- Added a machine-readable runtime diagnostics API in the Rust bridge.
- Updated the Rust core stage identifier to `alpha-0.6-rust-runtime-bridge`.
- Flutter initializes the generated FRB binding on Android/iOS and requests diagnostics from Rust.
- Dashboard shows bridge connectivity, core version/stage, registry ownership, and inference availability.
- Added a retry action and explicit unavailable/error states.
- Added Dart parsing tests and Rust bridge diagnostics tests.

## Explicit limitations
- `llama.cpp` is not linked.
- No model is downloaded, loaded, or executed.
- Model metadata remains in Flutter SQLite.
- The Rust agent registry remains process-local/in-memory.
- Runtime diagnostics are not hardware telemetry and do not report fabricated CPU/RAM values.

## CI contract
Rust formatting, Rust tests, Clippy, Flutter tests, and the Android ARM64 debug APK build remain blocking. Flutter analysis remains advisory/non-blocking. FRB bindings are generated in CI before Dart tests and APK compilation.

## Next milestone
Introduce a real inference backend adapter (llama.cpp) with explicit model file validation, load/unload lifecycle, memory limits, cancellation, and streaming output. Do not mark a model as loaded until the native backend confirms success.
