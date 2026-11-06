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

Bridge acceptance still requires verifying both exported Rust functions from Flutter
on a physical Android device; a successful code-generation step alone is insufficient.
