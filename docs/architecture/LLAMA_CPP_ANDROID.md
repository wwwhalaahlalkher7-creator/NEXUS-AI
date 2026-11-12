# llama.cpp Android native boundary

## Version pin

NEXUS builds the official `ggml-org/llama.cpp` source at commit `cd959bae99ff4bed22bef2604f45241c09bbb8c8` (v0.9.0). The pin avoids an unbounded moving branch in reproducible CI builds.

## Build path

1. GitHub Actions checks out the pinned source into `third_party/llama.cpp`.
2. CMake configures the source with Android NDK `30.0.16248370` (r30 LTS), ABI `arm64-v8a`, API 28, position-independent static upstream libraries linked into one NEXUS shared adapter, `GGML_NATIVE=OFF`, OpenMP off, llamafile off, and OpenSSL off. The generated application sets `minSdk = 28` to match the native API target.
3. The NEXUS adapter target links against the upstream `llama` target.
4. The upstream llama.cpp and GGML static libraries are linked into `libnexus_llama_probe.so`; only that adapter and NDK `libc++_shared.so` are copied into `android/app/src/main/jniLibs/arm64-v8a`.
5. The APK verification step confirms that the adapter exports both NEXUS C ABI functions and that every non-platform shared-library dependency is available.

## Runtime boundary

`core/runtime/src/native/engine.rs` loads `libnexus_llama_probe.so` dynamically. The module is the only Rust location with a local `unsafe_code` allowance. It resolves two C ABI functions: `nexus_llama_backend_init` and `nexus_llama_version`. The loaded library is retained in a process-wide `OnceLock` to keep function addresses valid.

The C++ adapter statically includes the upstream llama.cpp and GGML code, runs `llama_backend_init()` once with `std::call_once`, then returns the upstream `llama_version()` string. No model pointer or context is created in Alpha 1.4.

## Safety and limitations

- All public runtime methods are safe Rust methods; raw function pointers do not escape the native module.
- The C++ adapter catches exceptions at the C ABI boundary.
- `libc++_shared.so` is bundled so the Android loader can resolve the shared C++ runtime. Upstream C++/GGML components are statically linked with position-independent code to avoid versioned JNI library-name mismatches.
- The initial target is ARM64 only.
- Loading a model is intentionally deferred. The Flutter status must keep `model_loaded=false` and `inference_available=false`.
