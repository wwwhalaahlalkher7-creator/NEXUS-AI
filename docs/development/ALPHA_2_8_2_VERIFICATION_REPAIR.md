# Alpha 2.8.2 — Flutter verification repair

## Fixed
- Corrected `_retry()` in `CoreRuntimeCard`: the `setState` callback now uses a block body and returns `void`. The previous expression-bodied callback returned the `Future<CoreRuntimeStatus>` produced by `inspect()`, which Flutter rejects at runtime. The asynchronous inspection remains assigned to `_status` and is handled by the existing `FutureBuilder`.
- Kept the KV-cache confirmation and clear operation asynchronous outside `setState`; only synchronous UI flags are updated inside `setState`.

## Verification status
- Source-level assertion and archive integrity checks are run when this package is assembled.
- Flutter analyze/test, Rust checks, Android NDK build, and device execution must still be confirmed by CI/device; they are not claimed as passed here.
