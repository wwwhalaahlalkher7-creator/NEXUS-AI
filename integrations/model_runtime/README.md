# Model runtime adapter

## Alpha 1.4 — native backend initialization

The Android ARM64 build now checks out a pinned official llama.cpp source revision, compiles its shared libraries with CMake/NDK, packages them into the APK, and includes a small C ABI adapter. Rust dynamically loads that adapter, calls `llama_backend_init()` once, and reads `llama_version()`. The shared-library handle remains alive for the application process.

The Flutter runtime diagnostics report native adapter availability and version. Host tests intentionally report that the Android native adapter is unavailable.

## Not implemented yet

- GGUF model loading and freeing
- `llama_context` creation and memory planning
- Tokenization, prompt evaluation, sampling, and decoding
- Streaming tokens and cancellation
- Multiple model sessions or GPU acceleration

A successful adapter initialization is not a loaded model and does not make inference available.
