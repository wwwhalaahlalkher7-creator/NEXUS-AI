# Alpha 2.8.0 — Local privacy center (`2.8.0+59`)

Implemented in source; Flutter/Dart CI, Android compilation, and physical-device acceptance remain pending.

## User-facing capabilities

- Add a Privacy & Local Data screen reachable from the app shell.
- Export a readable JSON snapshot through the platform save dialog.
- Include agent definitions/instructions, model metadata, conversations/messages, knowledge documents/chunks, agent tasks/steps/events, benchmark runs, and the selected resource mode.
- Exclude local model filesystem paths, model weight files, device identity settings, paired-device addresses/fingerprints, peer transfer/execution ledgers, and secure-storage secrets.
- Export is a one-way data snapshot in format version 1. Import/restore is not implemented in this milestone.
- Offer individually confirmed deletion for conversation history, knowledge index, task/peer transfer ledgers, and benchmark history.
- Refuse conversation deletion while a streaming message exists. Refuse task-history deletion while a local task is running or a peer execution is queued, awaiting approval, approved, or running.
- Keep GGUF files, model catalog, agent configuration, peer pairings/secure secrets, and app settings intact when clearing the selected history sections.
- Keep SQLite v15 and Rust ABI 2.6.2; no schema migration or external dependency was added.

## Privacy and recovery boundaries

The JSON export contains user-authored content and can be sensitive; the file is plaintext (not encrypted) and the UI warns the user to save it in a trusted location. Export currently materializes the JSON snapshot in app memory before passing bytes to the native save dialog, so very large local databases may exceed available memory on low-RAM phones; the export does not silently truncate content. It intentionally omits device network identities and pairing material. Model file paths are removed at both query and serialization layers. Source TXT/Markdown files are not copied into the app's knowledge index and are not deleted when clearing indexed knowledge chunks.

The export is not an application backup and cannot restore model binaries, pairing secrets, or full peer state. The current milestone does not provide JSON import, automatic cloud backup, or whole-app reset. Users remove/revoke individual peer trust from the Devices screen.

## Validation

- Add Dart unit coverage for export format, path redaction, settings allow-list, and privacy manifest.
- Add a CI source-contract test for included/excluded tables, deletion confirmation, in-flight guards, and no schema migration.
- CI must still run Dart format/analyze/tests, Rust fmt/test/clippy, FRB generation, native Android ARM64 build, and APK packaging. Physical-device acceptance remains pending.
