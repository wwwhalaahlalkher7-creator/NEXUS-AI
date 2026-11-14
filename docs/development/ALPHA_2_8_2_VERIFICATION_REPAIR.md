# Alpha 2.8.2 — Flutter verification repair

## Fixed
- Corrected `_retry()` in `CoreRuntimeCard`: the `setState` callback now uses a block body and returns `void`. The previous expression-bodied callback returned the `Future<CoreRuntimeStatus>` produced by `inspect()`, which Flutter rejects at runtime. The asynchronous inspection remains assigned to `_status` and is handled by the existing `FutureBuilder`.
- Kept the KV-cache confirmation and clear operation asynchronous outside `setState`; only synchronous UI flags are updated inside `setState`.

## Verification status
- Source-level assertion and archive integrity checks are run when this package is assembled.
- Flutter analyze/test, Rust checks, Android NDK build, and device execution must still be confirmed by CI/device; they are not claimed as passed here.


## Follow-up CI contract repair (`2.8.2+63`)

- Updated the Flutter package build metadata from `2.8.2+62` to `2.8.2+63`.
- Updated peer capability metadata to advertise app semantic version `2.8.2`.
- Replaced stale `2.8.1+61` source-contract expectations with checks that align the app semantic version with `pubspec.yaml` while preserving Rust workspace/native ABI version `2.6.2`.
- No Rust source, native C ABI symbol, or SQLite schema change was made for this fix.
- The CI failure reported for the previous build was a stale version assertion; host C ABI contract tests had already passed. Full Flutter/Rust/Android verification remains pending CI.
