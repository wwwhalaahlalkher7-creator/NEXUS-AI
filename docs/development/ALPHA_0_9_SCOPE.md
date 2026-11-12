# NEXUS AI — Alpha 0.9: Local model file audit

## Delivered in this milestone
- The model library can re-audit a previously imported local GGUF file.
- The audit checks that the recorded private path exists, the current byte length matches the stored length, and the Rust GGUF header/metadata inspection still succeeds.
- The UI reports the outcome and clearly states the audit boundary.
- Verification is read-only: it does not rewrite model metadata, delete files, or mark a model runnable.

## Explicit limitations
- This is not a cryptographic checksum or full file-integrity proof.
- Tensor descriptors, offsets, alignment, tensor payloads, quantization consistency, and architecture compatibility are not verified.
- Passing this audit does not mean that llama.cpp is integrated or that inference is available.

## Verification expected in CI
- Rust formatting, tests, and Clippy.
- Dart formatting, analysis, and Flutter widget/unit tests.
- Flutter Rust Bridge generation and Android debug ARM64 APK build.
