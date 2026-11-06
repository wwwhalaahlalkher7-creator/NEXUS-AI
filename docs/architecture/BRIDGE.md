# Flutter ↔ Rust bridge

## Selected bridge
`flutter_rust_bridge` pinned to 2.13.0 in Dart and Rust. The dedicated `core/bridge`
crate depends on `core/runtime`, so Flutter will call the same Rust workspace core.

## Initial exported API
- `get_core_info_for_app()` returns the compiled Rust core identity and stage.
- `health_check()` returns a deterministic bridge reachability response.

These calls establish a native boundary before moving agent orchestration or model
execution across it.

## Generate on a machine with Flutter and Rust installed
From repository root run:

```bash
bash scripts/integrate_bridge.sh
```

Inspect and commit generated changes, especially `apps/nexus_app/lib/src/rust/`,
`core/bridge/src/frb_generated.rs`, and Android Gradle integration. Never hand-write
generated glue code.

## Android note
The default integration depends on the Flutter/Rust toolchain and Android NDK
configuration. We do not pin an NDK version until generated Gradle integration and
the actual build environment are inspected. First phone target is Android ARM64.

## Verification gate
- `cargo test --workspace`
- `cargo fmt --all -- --check`
- `flutter pub get`
- `dart format --output=none --set-exit-if-changed lib test`
- `flutter analyze`
- `flutter test`
- `flutter run` on a physical Android device

Bridge is accepted only after Flutter calls both exported Rust functions on-device.
