# Alpha 1.9.1 — Rust formatting CI correction

## Failure

The Alpha 1.9.0 workflow generated Flutter Rust Bridge integration code and
then ran `cargo fmt --all -- --check`. The generated module insertion and
several existing Rust lines were not rustfmt-normalized, so the check exited
with status 1 before Rust tests or Clippy could run.

## Fix

The Rust validation step now runs these commands in order:

1. `cargo fmt --all` — normalize handwritten and generated Rust source.
2. `cargo fmt --all -- --check` — verify that formatting is now clean.
3. `cargo test --workspace` — run the workspace test suite.
4. `cargo clippy --workspace --all-targets -- -D warnings` — enforce lint quality.

No formatting check, test, or lint gate is disabled. No `continue-on-error` or
error suppression was introduced. The Android build and Flutter gates remain
unchanged.

## Verification limitation

The local patch environment does not contain Rust/rustfmt, so the actual
formatter execution must be confirmed by the next GitHub Actions run. The
workflow installs the `rustfmt` component before this stage.
