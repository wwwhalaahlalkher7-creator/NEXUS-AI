# NEXUS AI — Alpha 0.7: GGUF import and header validation

## Delivered in this milestone
- Native Android file selection filtered to `.gguf` files.
- Rust validates the file extension, file accessibility, minimum header length, `GGUF` magic bytes, supported header version (2 or 3), and bounded non-zero tensor/metadata counts.
- Header inspection reads only 24 bytes; it does not load tensor weights into memory.
- Valid files are copied into the app's private application-support `models/` directory and recorded in SQLite with their path and byte size.
- The model library distinguishes metadata-only records from imported local files.
- Replacing a model file is supported; deleting the catalog record does not claim to securely erase the model file.

## Important limitations
- A valid header is not a full integrity check. Tensor offsets, tensor payloads, quantization compatibility, and the entire file are not verified.
- The model is imported but not loaded into RAM or VRAM.
- No llama.cpp backend, token generation, streaming, cancellation, or inference API is included yet.
- The import operation needs free storage roughly equal to the model file size; cloud-provider selections may also be staged by Android's file picker before the private copy.
- Model files remain in the app-private models directory when the catalog entry is deleted; cleanup policy is intentionally deferred to avoid accidental data loss.

## Verification
CI is expected to run Rust formatting, Rust tests and Clippy, Dart formatting, Flutter tests, bridge generation, and Android debug APK build. The local authoring environment does not include Flutter/Android toolchains, so no local APK build is claimed.
