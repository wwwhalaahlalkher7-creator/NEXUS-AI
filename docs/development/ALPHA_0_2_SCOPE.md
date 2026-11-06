# Alpha 0.2 — local persistence

## Delivered in this batch
- SQLite schema for local agent records.
- Versioned database initialization.
- Parameterized repository operations: create, list, get, update status, delete.
- Serialization test for the Dart record model.

## Still not complete
- Rust is not yet called from Flutter.
- The SQLite repository currently belongs to the Dart application layer.
- Agent execution, planner, tools, model inference and network remain deferred.

## Why persistence is in Dart for now
This keeps Android SQLite access on a mature Flutter plugin while the Rust bridge is introduced independently and tested. It avoids prematurely coupling the database driver to Android NDK cross-compilation. The domain and execution logic remain intended for Rust.

## Verification
Run:
```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
cargo fmt --all -- --check
cargo test --workspace
```
