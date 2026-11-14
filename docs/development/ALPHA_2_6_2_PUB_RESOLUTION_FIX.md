# Alpha 2.6.2 — Pub dependency resolution fix

Build metadata: `2.6.2+44` (Rust workspace remains `2.6.2`; no native ABI change).

## Root cause

The FRB `integrate` command invokes `flutter pub add rust_lib_nexus_app --path=rust_builder`. That command resolves the entire app dependency graph before the workflow reaches its later `flutter pub get` step. The graph could not be solved because `flutter_secure_storage ^11.2.0` requires a Windows secure-storage implementation using `win32 ^6.0.1`, while `file_picker ^10.3.10` constrained its Windows implementation to `win32 ^5.9.0`.

## Fix

- Upgrade `file_picker` to `^12.3.0`, whose federated Windows implementation is on the `win32` 6.x line. The secure-storage version remains unchanged.
- Migrate knowledge and GGUF import to the v12 static `FilePicker.pickFile()` API.
- Migrate knowledge import to `PlatformFile.lengthSync()` / `length()` and `readAsByteStream()`, preserving streamed reads and the existing resource-budget check.
- Keep knowledge picker injection available through a typed function so it remains testable.
- Add a CI source-contract guard for the selected dependency versions and API migration.
- Correct the standalone `scripts/integrate_bridge.sh` continuation slashes.

## Compatibility notes

`file_picker` v12 requires Flutter 3.38 / Dart 3.10 or newer; this project already requires Flutter 3.47 and Dart 3.13. Version 12 is intentionally selected rather than v13 to avoid taking the additional v13 API removals in this patch.

## Verification

The source-level regression guard and existing Python contract/migration tests are run locally. Flutter/Dart package resolution and the real FRB integration command must still be confirmed by GitHub Actions; this environment does not include Flutter or Dart.
