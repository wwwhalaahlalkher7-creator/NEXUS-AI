# Alpha 1.9.3 — Clippy host-stub lint fix

## Failure

The host build selects the non-Android implementation of
`generate_native_text`. Its eight parameters mirror the Android native
adapter boundary, including the callback and opaque user-data pointer. The
host stub lacked the targeted `clippy::too_many_arguments` allowance and
failed the CI command that promotes Clippy warnings to errors.

## Correction

Added `#[allow(clippy::too_many_arguments)]` to the non-Android stub only,
with a comment documenting why its signature intentionally mirrors the
native adapter ABI. The Android implementation already uses the same
narrowly scoped allowance. No global lint relaxation, C ABI change, callback
change, or runtime behavior change was made.

## Verification boundary

The supplied CI log confirms all 14 Rust unit tests passed before Clippy
reported this lint. The corrected source and archive are checked for
consistency, but the Rust compiler, Clippy, Flutter gates, and Android APK
build must run in GitHub Actions to confirm this release. No successful build
is claimed by this package.
