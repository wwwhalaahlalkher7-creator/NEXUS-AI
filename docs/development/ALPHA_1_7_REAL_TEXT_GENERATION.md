# NEXUS AI — Alpha 1.7.0: Real local text generation

Alpha 1.7 connects the active Android ARM64 GGUF session to a bounded single-turn text-generation path. It is the first NEXUS milestone that submits a prompt to llama.cpp, evaluates it, samples output tokens, and streams decoded text back to Flutter.

## Native generation pipeline

1. Validate the prompt and sampling parameters before taking the native session lock.
2. Confirm that the loaded model is a decoder-only, non-diffusion text model. Encoder/decoder and diffusion architectures are rejected with a clear error because their generation paths are different.
3. Apply the GGUF model's default chat template when one is embedded and supported by the pinned llama.cpp template helper. If no template is available, send the prompt as plain text; if an embedded template is unsupported or invalid, return a visible error instead of silently changing prompt format.
4. Tokenize through `llama_tokenize`, evaluate the prompt in batches of at most 128 tokens, and check that prompt plus requested output fits the active context.
5. Build a sampler chain using Top-K, Top-P, temperature, and a distribution sampler. Seed `0` means `LLAMA_DEFAULT_SEED` (random seed); nonzero values are deterministic seeds.
6. Sample and decode one token at a time. Raw token bytes are sent over the C ABI and are assembled into valid UTF-8 chunks in the Rust bridge before reaching the Dart stream.
7. Clear KV/context memory before and after every request. Alpha 1.7 is intentionally stateless: the next request does not include prior turns.

## Limits and defaults

| Setting | Limit / default |
|---|---|
| Target | Android `arm64-v8a`, CPU only |
| Prompt | 16 KiB UTF-8 maximum |
| Formatted prompt | 64 KiB maximum |
| Generated tokens | 1–1024; UI defaults to 128 |
| Context | 512–4096, as loaded with the model |
| Prompt batch | 128 tokens |
| CPU threads | 1–8, inherited from the active model session |
| Temperature | 0.7 default; accepted range 0.05–2.0 |
| Top-K | 40 default; accepted range 1–100 |
| Top-P | 0.92 default; accepted range 0.1–1.0 |

The UI offers output caps of 64, 128, 256, and 512. The native API permits up to 1024 tokens, but context capacity is always checked before prompt evaluation.

## Cancellation and resource safety

- Generation holds the native session mutex for the duration of the request, so loading/unloading cannot free the model while it is in use.
- Cancellation does not acquire that mutex. It sets an atomic cancellation flag read by the llama.cpp CPU abort callback and by the token loop.
- The Rust dynamic library backend is immutable after initialization and is stored in `OnceLock`; Rust does not hold a global mutex across a long generation call. This allows the cancel API to enter the same adapter concurrently.
- Batch and sampler resources use RAII cleanup. Context memory is cleared on all normal return and error paths.
- The Rust-to-Dart callback catches panics, handles split UTF-8 sequences across token pieces, and reports a terminal event with success, cancellation, or error state.
- `inference_available` remains false until the process completes one non-cancelled generation that yields at least one token.

## User interface

A new **المحادثة** destination provides one prompt editor, a bounded output-token selector, streamed response text, a stop action, and explicit model/session status. The navigation bar is kept to five destinations for mobile usability; device discovery is shown under Settings until it becomes functional. The page clearly states that history and multi-turn context are not available yet.

The dashboard and native status card distinguish model loading from verified inference. A model being loaded is not itself reported as proof that text generation succeeded.

## Verification

- The host-side native adapter contract test compiles the wrapper with a fake llama API and exercises load, successful streaming, cancellation from inside the token callback, invalid settings, context overflow, unload, and exported symbols.
- This fake API test is not a llama.cpp build and cannot prove Android runtime compatibility.
- GitHub Actions remains the authoritative build gate: it checks out the pinned llama.cpp revision, builds the adapter with the pinned Android NDK, verifies all C ABI exports and dependencies, generates FRB bindings, runs Rust formatting/tests/clippy, runs Flutter formatting/analyze/tests in parallel, and builds the development ARM64 APK.
- A real Android device smoke test is still required to verify a compatible GGUF model, model-specific chat template behavior, output quality, memory behavior, and cancellation latency.

The final distribution deliverable remains a signed **Release APK**, not an AAB. The active development CI job continues to build the Debug APK until feature completion and final device validation.
