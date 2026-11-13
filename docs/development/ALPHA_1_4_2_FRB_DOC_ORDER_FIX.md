# NEXUS Alpha 1.4.2 — FRB crate-documentation ordering fix

## Reported failure

The Rust workspace failed during `cargo fmt` with E0753 in
`core/bridge/src/lib.rs`. FRB code generation prepended `mod frb_generated;`
while the `allow_generated_ffi.py` helper added its module-scoped
`#[allow(unsafe_code)]` attribute. The crate-level `//!` documentation could
therefore end up after a Rust item, where inner documentation comments are
invalid.

## Correction

`allow_generated_ffi.py` now relocates crate-level `//!` lines to the beginning
of `lib.rs` before ensuring that `#[allow(unsafe_code)]` is attached directly
to `mod frb_generated;`. This preserves the crate documentation, keeps the
unsafe-code exception narrowly scoped to generated FFI, and remains
idempotent across repeated FRB generation. No lint was disabled and no tests
were removed.

## Validation boundary

The helper was exercised against a fixture representing the generated order
that caused E0753, including a second run to check idempotency. Python syntax,
workflow YAML parsing, shell syntax, and archive integrity were checked. Rust
formatting, tests, Clippy, Flutter tests, and APK compilation must still be
confirmed by GitHub Actions because those toolchains are not installed in the
editing environment.
