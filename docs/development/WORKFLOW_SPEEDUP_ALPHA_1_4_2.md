# NEXUS CI wait-time optimization — Alpha 1.4.2

This change optimizes the existing single-job CI workflow without removing or
weakening Rust/Flutter tests, native-library checks, or the ARM64 debug APK build.
It does not deploy or modify the website/backend.

## Implemented changes

1. **Rust/Cargo cache** — `Swatinem/rust-cache@v2` runs after Rust toolchain setup
   and reuses Cargo registry/dependency artifacts and compiled dependency outputs.
   `cache-on-failure: true` allows valid dependency caches to be retained even
   when a later test/build stage fails. `cache-bin: false` keeps binary ownership
   separate. A dedicated versioned
   `actions/cache` stores only `flutter_rust_bridge_codegen` and `cargo-expand`,
   keyed to the Rust compiler version and exact tool versions. FRB codegen remains
   pinned to `2.13.0`; `cargo-expand` is pinned to `1.0.127`, matching the version
   shown in the supplied CI log. First-run install cost remains; later compatible
   runs can restore both tools.

2. **llama.cpp source and CMake caches** — the pinned upstream checkout is
   cached separately, so later runs can skip cloning it. The Android ARM64 Ninja
   build directory is restored before CMake configuration/build and saved after
   the native build step. The build cache also saves `native/llama` alongside the
   generated build tree: this preserves source mtimes across fresh runners, so
   Ninja can genuinely skip unchanged object files rather than rebuilding all
   upstream sources after every checkout. The key includes OS/architecture, a
   fingerprint of Clang/CMake/Ninja plus NDK/ABI/API/upstream revision, and a
   hash of every file under `native/llama`. There is deliberately no broad
   `restore-keys` fallback, avoiding reuse of an unrelated native build tree.
   The cached upstream Git checkout is checked against the expected commit before
   the build, so stale or mismatched source cannot silently enter the build.

   The literal `cmake-v1` is a cache schema. Increment it (for example to
   `cmake-v2`) whenever any CMake command-line `-D` flag or other native build
   setting in the workflow changes. The upstream source pin and installed
   toolchain versions are independently represented in the key.

3. **Parallel native compilation** — CMake now uses `--parallel "$(nproc)"`
   instead of a fixed value of 2. This respects the CPU count allocated to the
   GitHub-hosted runner and does not request a larger or paid runner.

4. **Selective APK retries** — APK build attempts are retried up to two more
   times only when logs contain known temporary network/repository failures
   (HTTP 408/429/5xx, DNS/socket/connection/TLS timeout). Build/compiler/configuration
   failures stop immediately. Retry delays increase from 15 to 30 seconds.

## Existing caches deliberately retained

- `subosito/flutter-action` already has `cache: true`; its documented
  backward-compatible behavior also enables the Pub cache when `pub-cache` is
  omitted. No duplicate Flutter/Pub cache was added.
- `gradle/actions/setup-gradle@v4` already caches Gradle dependencies. It remains
  in place.

## Cache limits and expected behavior

- The first run after this change may be similar to the current runtime because
  it must populate the new caches.
- Benefits appear on later runs with the same Rust toolchain/dependencies,
  Android native toolchain, source pin and CMake configuration.
- GitHub caches are subject to repository storage/retention limits. This patch
  stores the pinned upstream llama.cpp checkout, the CMake build tree and the
  small NEXUS native adapter source directory; it avoids broad fallback restore.
- `rust-cache` is more effective when `Cargo.lock` is checked in. This source
  snapshot currently has no `Cargo.lock`; creating one is a separate dependency
  reproducibility decision and was not improvised in this workflow-only patch.

## Verification boundary

Static checks can validate YAML structure, shell syntax, cache-key consistency,
retry classification examples and ZIP integrity. They cannot prove that GitHub
will get a cache hit or measure end-to-end savings. Compare at least two Actions
runs: the first populates caches; the next comparable run reveals the actual
restore/build durations. Flutter, Dart, Android NDK and Cargo are not installed
in the editing environment, so Rust tests, Flutter tests and APK compilation
were not executed here.
