# Alpha 2.4.1 — Adaptive resource policy

## Scope

NEXUS exposes three user-selected local resource profiles:

- **Balanced:** conservative temporary-memory allocation and bounded retrieval/tool payloads.
- **Performance:** larger working-memory allocations, more retrieved context, and larger tool/conversation budgets.
- **Unrestricted:** no fixed application-level corpus/result/per-turn ceilings; it uses current device memory and the model's native context where those can be measured.

The selected mode is persisted in SQLite `app_settings` (schema v7). Upgrade from v6 creates the preference table without rebuilding existing knowledge documents, chunks, conversations, or tool audit messages.

## Removed fixed quotas

The knowledge library no longer imposes the previous 4 MiB file, 200,000-character document, 80-document, 4,000-chunk, 3,000,000-character aggregate, 800-candidate, five-result, or 3,000-character retrieval-prompt ceilings. Chunk count scales with the source document. Balanced and Performance search candidate budgets derive from the current `MemAvailable` snapshot. Unrestricted mode applies no import-size, SQL candidate, result-count, or per-document retrieval cap; the user accepts the corresponding risk of process-level memory pressure.

## Resource-aware behavior

- Balanced and Performance compute temporary import budgets from `MemAvailable` using 2% and 4% of the available snapshot. If the memory probe fails, they use conservative fallback budgets. Unrestricted has no importer budget at all, even when a memory snapshot is available; this is an explicit opt-in to possible process-level memory pressure.
- Conversation history transport is 64 messages / 48 KiB in Balanced and 256 / 256 KiB in Performance. Unrestricted lets native tokenizer-aware context trimming select the history.
- Model tool-call counts, envelope sizes, argument bytes, result characters, retrieval result count, and per-source diversity follow the selected resource mode.
- The model's active context length remains authoritative. A larger history is accepted at the app layer but the native tokenizer removes oldest complete turns as required to fit the model.

## Safety boundaries that remain

Unrestricted means no artificial application quotas, not infinite hardware. Android RAM, local storage, CPU speed, battery/thermal behavior, SQLite/OS limits, and model context remain real limits. The native Dart/Rust/C++ boundary accepts up to 4,096 messages and 1 MiB of combined message text as a high transport safety ceiling. Tool calls remain restricted to the registered allow-list. Typed schemas remain validated; modifying or external-access tools still require explicit user approval; tools retain per-operation timeouts and cooperative cancellation. No shell, arbitrary-code, or unrestricted network executor is introduced by changing the resource mode.

## Verification required

The source contains host-side tests for mode budgets, unlimited ranking, unrestricted conversation history, tool-session budget behavior, and the v6-to-v7 settings migration. CI must still run Dart formatting, Flutter analyze/tests, Rust formatting/tests/Clippy, Android NDK compilation, and the ARM64 Debug APK build. A device test must validate the real memory probe, app behavior under low memory/storage, and model context trimming with real GGUF models.

Model imports no longer carry a default 8 GiB Flutter-side file ceiling. The native loader's memory preflight remains authoritative; an integrator may still set an explicit `maxModelFileBytes` policy ceiling.

**Known remaining native ceilings:** the current llama adapter still accepts up to 4,096 context tokens, up to 1,024 generated tokens per response, and a chat transport envelope of 1 MiB / 4,096 messages. Alpha 2.4.1 does not claim to remove these engine-level limits. The context ceiling requires a model-metadata-aware native change plus a device memory test, and is tracked separately.
