# NEXUS AI — Alpha 0.8: GGUF metadata inspection

## Delivered in this milestone
- Rust inspects the GGUF fixed header and metadata directory without loading tensor weights.
- Extracts selected metadata when present: architecture, model name, tokenizer model, context length, block count, embedding length, file type, and parameter count.
- Supports the GGUF metadata scalar types used for selected values and safely skips supported primitive and string arrays for unrelated metadata.
- Enforces bounds on metadata entry count, tensor count, key/string lengths, and array item counts; checks file boundaries before reads and seeks.
- The Flutter model library persists the extracted metadata in SQLite schema version 3 and displays the architecture, context length, layer count, embedding length, and model name.
- Database migration from schema version 2 adds nullable metadata columns without deleting existing model records.

## Important limitations
- This is a bounded metadata-directory inspection, not a full GGUF integrity check.
- Tensor descriptors, offsets, alignment, tensor payloads, quantization block consistency, and model compatibility are not validated.
- The metadata fields are optional; a model may omit fields or use architecture-specific metadata that is not displayed.
- Parameter count and file type are reported as stored metadata values, not independently verified facts.
- No llama.cpp backend, model loading, memory allocation, token generation, streaming, cancellation, or inference API is included.
- A successful metadata inspection does not mean that the model can be loaded on the current device.

## Verification expected in CI
- Rust formatting, Rust unit tests, and Clippy.
- Dart formatting and Flutter widget/unit tests.
- Flutter Rust Bridge generation and Android debug ARM64 APK build.
- The local authoring environment does not include Flutter/Android toolchains; no local APK build is claimed.
