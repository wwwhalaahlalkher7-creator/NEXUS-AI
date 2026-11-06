# Alpha 0.1 — scope and acceptance

## Implemented in this source batch
- Flutter Material 3 application shell.
- Arabic-first navigation and dashboard.
- System light/dark theme behavior.
- Rust Cargo workspace.
- Agent domain model with basic validation.
- In-process agent registry with duplicate-ID protection.
- Rust unit tests for registry behavior.
- Model runtime boundary documentation.

## Not implemented (must not be represented as complete)
- Flutter ↔ Rust bridge.
- SQLite persistence.
- Actual agent execution/planning.
- llama.cpp or any loaded model.
- Resource telemetry.
- Device identity, pairing, discovery or P2P.
- Background services.
- APK build and CI.

## Acceptance before adding CI
1. `flutter pub get` completes.
2. `flutter analyze` has no errors.
3. `flutter test` passes.
4. `cargo fmt --all -- --check` passes.
5. `cargo test --workspace` passes.
6. App launches on the target Android phone after Android platform generation.
7. No model-running or device-monitoring claims appear in the UI.

## Next implementation batch
1. Decide and pin a compatible Flutter-Rust bridge version.
2. Generate and verify bridge bindings on Android.
3. Add SQLite persistence with migrations.
4. Add repository tests and failure handling.
5. Only then add GitHub Actions for analysis, tests and APK artifact builds.
