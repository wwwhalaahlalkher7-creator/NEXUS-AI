# llama.cpp Android native boundary

## Version pin

NEXUS builds the official `ggml-org/llama.cpp` source at commit `cd959bae99ff4bed22bef2604f45241c09bbb8c8` (v0.9.0). The pin avoids an unbounded moving branch in reproducible CI builds.

## Build path

1. GitHub Actions checks out the pinned source into `third_party/llama.cpp`.
2. CMake configures the source with Android NDK `30.0.16248370` (r30 LTS), ABI `arm64-v8a`, API 28, position-independent static upstream libraries linked into one NEXUS shared adapter, `GGML_NATIVE=OFF`, OpenMP off, llamafile off, and OpenSSL off. The generated application sets `minSdk = 28` to match the native API target.
3. The NEXUS adapter target links against the upstream `llama` target.
4. The upstream llama.cpp and GGML static libraries are linked into `libnexus_llama_probe.so`; only that adapter and NDK `libc++_shared.so` are copied into `android/app/src/main/jniLibs/arm64-v8a`.
5. The APK verification step confirms that the adapter exports all required NEXUS C ABI symbols and that every non-platform shared-library dependency is available.

## Runtime boundary

`core/runtime/src/native/engine.rs` loads `libnexus_llama_probe.so` dynamically. The module is the only Rust location with a local `unsafe_code` allowance. It resolves the backend initialization, version, model lifecycle, status, generation, cancellation, and error functions. The loaded library is retained in a process-wide `OnceLock` to keep function addresses valid.

The C++ adapter statically includes the upstream llama.cpp and GGML code, runs `llama_backend_init()` once with `std::call_once`, and exposes a narrow NEXUS-owned C ABI. The Android Rust loader resolves the model load/unload, status, generation, cancellation, and error-query exports once, retaining the library handle for the process lifetime.

## Safety and limitations

- All public runtime methods are safe Rust methods; raw function pointers do not escape the native module.
- The C++ adapter catches exceptions at the C ABI boundary.
- `libc++_shared.so` is bundled so the Android loader can resolve the shared C++ runtime. Upstream C++/GGML components are statically linked with position-independent code to avoid versioned JNI library-name mismatches.
- The initial target is ARM64 only.
- The first inference path supports decoder-only text models and a single prompt per request. Encoder/decoder and diffusion architectures are rejected.
- Prompt and output sizes are bounded against the active context. CPU threads are inherited from the loaded session; GPU offload remains disabled.
- Generation holds the native session mutex so unload cannot release model memory during compute. Cancellation is independent: it sets an atomic flag read by both the token loop and llama.cpp abort callback.
- The adapter clears KV memory before and after each request. Alpha 1.7 does not retain multi-turn chat context.
- `inference_available` is a per-loaded-model verification flag. It becomes true only after a completed non-cancelled response with at least one output token, and resets when the model is unloaded.


## Current model import boundary

NEXUS Alpha 1.6 currently imports a single GGUF file per model record. Split GGUF shard sets (for example `model-00001-of-00003.gguf`) are rejected before copying because the current library store and importer do not yet preserve the full shard set. Multi-file shard support must be implemented as one atomic model package before it is enabled.


## Alpha 1.7 generation flow

The generation entrypoint follows the pinned v0.9.0 API in `llama.h`: optional `llama_chat_apply_template` (which supports a predefined set of templates, not arbitrary Jinja), `llama_tokenize`, prompt evaluation with `llama_batch_init` / `llama_decode`, a sampler chain (`top_k`, `top_p`, `temp`, `dist`), `llama_sampler_sample`, and `llama_token_to_piece`. Unsupported embedded templates fail explicitly instead of being silently bypassed. The C ABI calls a zero-byte start event as soon as generation becomes active, then emits byte pieces as tokens are sampled. Rust reassembles split UTF-8 sequences before publishing `InferenceEventDto` events to Dart. The Dart page exposes Stop only after this native start event.

The pinned header documents the tokenization and token-to-piece contract, the chat-template output-size retry behavior, the sampler chain usage, and the CPU abort callback. See the official pinned source at [llama.h](https://github.com/ggml-org/llama.cpp/blob/cd959bae99ff4bed22bef2604f45241c09bbb8c8/include/llama.h).
