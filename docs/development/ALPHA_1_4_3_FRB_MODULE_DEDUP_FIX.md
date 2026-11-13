# NEXUS Alpha 1.4.3 — FRB module declaration correction

## Root cause

FRB 2.13.0 injects `mod frb_generated;` into `core/bridge/src/lib.rs` and may
append an explanatory block comment to that line. The previous post-generation
helper matched only a bare declaration, failed to recognize the injected line,
and inserted a second declaration. Rust then reported E0428.

## Correction

- Recognize FRB's declaration with or without its trailing comment.
- Keep the first declaration and remove stale duplicates.
- Preserve crate-level `//!` documentation before all items.
- Apply `#[allow(unsafe_code)]` to the one generated module declaration only.
- Keep the transformation idempotent across repeated CI runs.
- Scope `libloading` to Android because the crate is only referenced by the
  `#[cfg(target_os = "android")]` loader module.

## Verification

A fixture containing both the commented FRB declaration and a duplicate bare
declaration was processed twice. Assertions confirmed exactly one declaration,
crate documentation at the top, and the narrow allow attribute immediately
before the declaration. Python compilation, Bash syntax, and CI YAML parsing
passed. Rust fmt, tests, Clippy, Flutter tests, and APK build have not been run
in this editing environment; GitHub Actions must confirm them.
