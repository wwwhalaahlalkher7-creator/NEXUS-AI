# Alpha 1.4.2 — Rust native module conflict correction

## Goal

Begin actual native integration by compiling a pinned llama.cpp revision for Android ARM64, packaging the NEXUS adapter in the APK, and initializing its backend through a narrow Rust/C ABI adapter.

## Included

- Official source pin: `ggml-org/llama.cpp` commit `cd959bae99ff4bed22bef2604f45241c09bbb8c8` (v0.9.0).
- Android NDK `30.0.16248370` (r30 LTS), ABI `arm64-v8a`, native API target 28; the generated Android app minSdk is explicitly set to 28.
- CMake build with upstream PIC static libraries folded into one NEXUS shared adapter and portable CPU settings (`GGML_NATIVE=OFF`, OpenMP/llamafile/OpenSSL disabled).
- C++ adapter exports only backend initialization and engine version functions.
- Rust dynamically loads the adapter, initializes llama.cpp once per process, and retains the library handle.
- Flutter runtime diagnostics display adapter availability and version.
- Cargokit integration is generated before dependency resolution; generated Rust FFI is isolated behind a module-local `unsafe_code` allowance.
- Tests ensure host builds do not claim that the Android native adapter is available.

## Excluded

- GGUF model loading, inference contexts, tokenization, decoding, sampling, streaming, and cancellation.
- RAM-aware model placement, GPU/Vulkan/OpenCL acceleration, multi-session runtime, and non-ARM64 ABIs.

## Acceptance criteria

1. Rust workspace tests and Clippy pass on the host runner.
2. CMake configures and builds `nexus_llama_probe` for Android ARM64.
3. The APK includes `libnexus_llama_probe.so` and `libc++_shared.so`; dependency inspection confirms all non-platform shared dependencies are resolved.
4. Flutter tests pass after FRB code generation.
5. Debug APK build succeeds and contains all required native shared libraries under `lib/arm64-v8a/`.
6. On an ARM64 Android device, the runtime card reports the real llama.cpp version. A device-level test is still required to prove that Android's dynamic loader initializes the library successfully.

## Known validation boundary

The source archive itself is not locally compiled in this environment. CI output plus a physical Android device smoke test are required before marking the integration validated.


## Alpha 1.4.1 correction

Cargokit generates `rust_builder/pubspec.yaml` with package name
`rust_lib_nexus_app`. The root `pubspec.yaml` now declares the path dependency
using that package name, while retaining `path: rust_builder`. CI and the local
integration script assert the generated package name and dependency mapping.
No llama.cpp runtime behavior changed in this patch.


## Alpha 1.4.2 source-layout correction

The runtime contained both `src/native.rs` and `src/native/mod.rs`, which are
competing Rust module source paths for `mod native;`. The redundant `src/native.rs`
was removed. The directory module and its `engine.rs` implementation are retained.
This is a compile-time source-layout correction; runtime behavior is unchanged.
