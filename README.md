# NEXUS AI — Alpha 1.4.2: Rust native module conflict fix

NEXUS is a local-first personal AI platform. This milestone begins the real native integration of `llama.cpp` for Android ARM64.

## What is integrated

- Pin and check out the official `ggml-org/llama.cpp` source at commit `cd959bae99ff4bed22bef2604f45241c09bbb8c8` (release v0.9.0).
- Cross-compile the upstream llama.cpp/GGML code as position-independent static libraries for Android `arm64-v8a`, then link them into one NEXUS-owned shared adapter.
- Package `libnexus_llama_probe.so` and `libc++_shared.so` into the APK through `android/app/src/main/jniLibs/arm64-v8a`; the upstream engine code is statically linked inside the adapter.
- Load the isolated C ABI adapter from Rust using a runtime library handle. The handle is retained for the process lifetime.
- Call `llama_backend_init()` once and read `llama_version()` through the adapter.
- Show native adapter availability and the engine version in the runtime diagnostics card.
- Keep unsafe Rust denied by default at workspace level; the small Android dynamic-loader module has a local, documented lint allowance.

## Explicit limitations

- This milestone initializes the llama.cpp backend only. It does **not** load any GGUF model, create an inference context, tokenize prompts, generate text, or stream tokens.
- `inference_available` and `model_loaded` remain `false` by design.
- The initial native build targets Android `arm64-v8a` only and sets the minimum Android API to 28 (Android 9). Other ABIs and desktop platforms are not packaged yet.
- A successful CI package check proves that the native shared libraries are present in the APK; it does not replace a physical-device smoke test.

## Build and verification

GitHub Actions installs Android NDK `30.0.16248370` (r30 LTS), cross-compiles the pinned llama.cpp source with CMake for Android API 28, statically links upstream llama.cpp/GGML into the NEXUS adapter, copies the adapter and C++ runtime into Android `jniLibs`, generates Flutter Rust Bridge bindings, runs Rust and Flutter checks, builds the ARM64 debug APK, and verifies the adapter exports and native dependency closure.

The CI build is the authoritative compile check. The CMake adapter wrapper was sanity-built locally against a minimal fake llama API, but the pinned upstream source has not been cross-compiled here because the Android NDK, Flutter, Dart, and Rust/Cargo toolchains are not available. GitHub Actions remains the authoritative Android build check.

See `docs/development/ALPHA_1_4_SCOPE.md` and `docs/architecture/LLAMA_CPP_ANDROID.md`.

## Third-party notices

The Android native adapter includes code from the official `ggml-org/llama.cpp` project at the pinned commit listed above. Its MIT license is bundled in the app at `licenses/llama.cpp-MIT.txt`.


## Flutter/Rust bridge setup

Run `scripts/integrate_bridge.sh` before `flutter pub get`. The integration step
generates the Cargokit `rust_builder/` package used to compile and bundle the
Rust bridge; CI performs this integration automatically.


## Alpha 1.4.1 CI correction (retained)

The Cargokit integration package generated under `rust_builder/` is named
`rust_lib_nexus_app`. The root Flutter manifest must use that exact package key
for its path dependency; the directory name is not the Dart package name. The
CI workflow and `scripts/integrate_bridge.sh` now verify both names before
resolving dependencies. This fixes the FRB integration failure where Pub
reported that `rust_lib_nexus_app` did not match the previously declared
`rust_builder` dependency name.


## Alpha 1.4.2 Rust module correction

Removed the duplicate `core/runtime/src/native.rs` module declaration. The
canonical module remains `core/runtime/src/native/mod.rs`, which exports the
existing `engine` implementation from `core/runtime/src/native/engine.rs`.
Rust rejects having both `native.rs` and `native/mod.rs` for the same module
(`E0761`); this correction resolves that source-layout conflict without
changing the native loader or the llama.cpp adapter behavior.


## CI wait-time optimization

The CI workflow now caches Rust/Cargo dependencies and FRB tools, restores the
llama.cpp Android CMake build tree using a toolchain-aware cache key, uses the
runner CPU allocation for native compilation, and retries APK builds only for
recognized transient network failures. Tests and APK/native-library verification
remain required. See `docs/development/WORKFLOW_SPEEDUP_ALPHA_1_4_2.md`.
