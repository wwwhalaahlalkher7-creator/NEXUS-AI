# NEXUS AI — Alpha 1.9.0: Multi-turn conversation context

## Objective

Use the locally persisted conversation as actual model context. Every request includes completed messages with explicit roles; the current assistant draft is excluded. The GGUF's embedded chat template is applied by the same pinned llama.cpp version that tokenizes and evaluates the prompt.

## Delivered

- `ChatMessageInputDto` exposes role-aware messages through Flutter Rust Bridge.
- Flutter selects completed conversation messages and excludes streaming/failed/cancelled drafts from inference context.
- `ConversationContextBuilder` enforces a 64-message and 48 KiB transport budget while retaining system messages and the current user turn.
- Rust validates supported roles (`system`, `user`, `assistant`, `tool`), non-empty content, the trailing current user turn, message count, payload bytes, and NUL safety.
- Rust marshals message views through a stable `repr(C)` ABI while retaining every owned C string for the synchronous native call.
- The native adapter builds the `llama_chat_message` array and calls `llama_chat_apply_template` with all retained turns and `add_ass=true`.
- The formatted prompt is tokenized with the active GGUF vocabulary, including model-configured BOS handling.
- If the prompt plus requested completion exceeds `llama_n_ctx`, the adapter drops oldest complete user/assistant exchanges, then re-applies the template and re-tokenizes. System messages and the newest user message are preserved.
- If the current user message and system messages cannot fit, the request fails instead of silently truncating the current turn.
- The native return value reports the exact count of messages trimmed by the token-aware context manager. The terminal stream event carries that count and the UI shows an informational notice.
- The KV cache is cleared between requests; the model receives conversational continuity by reconstructing prompt context from SQLite history on each turn.

## Boundaries

- First target remains Android `arm64-v8a` CPU inference.
- Only decoder-only text GGUF models with a supported embedded llama.cpp template are accepted by the template path. The fallback formatter for a model without an embedded template uses explicit role labels and may vary in quality by model.
- Tool-role messages can be represented, but no tool execution, function calling, or agent tool loop is implemented.
- Context summarization is not implemented. Old turns are removed, not summarized.
- Vision, audio, GPU offload, split GGUF shards, remote inference, and distributed execution remain out of scope.

## Verification

- `scripts/test_llama_adapter_contract.py` compiles the NEXUS C++ adapter against a fake llama API and tests multi-role template application, preservation of recent messages, old-turn trimming, exact trim count, invalid current-turn role, generation, cancellation, and session lifecycle. This is a host contract test, not a real llama.cpp integration build.
- `test/conversation_context_builder_test.dart` checks selection of completed roles, chronological ordering, dropping old complete turns, preserving system/latest messages, and rejecting an oversized current message.
- `scripts/test_conversation_migration.py` continues to validate SQLite v4 migration preservation.
- GitHub Actions must run FRB generation, `cargo fmt --check`, `cargo test`, `cargo clippy`, Dart formatting, `flutter analyze`, `flutter test`, and the Android NDK build against the pinned llama.cpp source.
- A physical Android ARM64 smoke test with more than one turn is required to validate the actual GGUF chat template and memory behaviour.
