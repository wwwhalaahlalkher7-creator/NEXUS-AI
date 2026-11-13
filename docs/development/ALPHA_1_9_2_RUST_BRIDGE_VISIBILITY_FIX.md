# Alpha 1.9.2 — Rust bridge visibility fix

## Failure

`generate_text` in the parent `api` module calls `StreamCallbackState::finish`,
but `finish` was private to the nested `stream_callback` module. Rust correctly
reported E0624 (private method).

## Correction

Changed the method declaration to `pub(super) fn finish(...)`. This grants
visibility only to the immediate parent module, which contains the call site.
The nested module itself and the callback state remain encapsulated.

## Verification boundary

Source-level assertions and archive integrity are checked when packaging.
The Rust compiler, workspace tests, Clippy, Flutter checks, and Android APK
build must still run in GitHub Actions; this package does not claim those
checks have passed.
