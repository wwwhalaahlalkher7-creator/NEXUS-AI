# NEXUS AI — Alpha 1.8.0: Local conversation history

## Objective

Connect the previously scaffolded SQLite conversation records to the local
inference experience without claiming multi-turn model context. This milestone
adds persistence and recovery, not prompt-history composition.

## Delivered

- The first valid prompt creates a conversation whose title is derived from
  the prompt (normalized and length-limited).
- User messages are persisted before native generation begins.
- An assistant draft is inserted with `streaming` status before invoking the
  Rust generation stream.
- Partial assistant output is checkpointed locally at token-count intervals.
- Completion, cancellation, and failure become distinct terminal states.
- The recent conversation is restored when the inference tab is opened.
- A history sheet can reopen conversations and delete one after confirmation.
- Deleting a conversation removes its messages through the existing foreign
  key cascade.
- On the next entry to the inference page, leftover `streaming` messages are
  recovered as `failed`; any checkpointed partial assistant text is retained.

## SQLite schema v4

The `messages.status` CHECK constraint now accepts:

- `streaming`: the assistant draft is still being generated.
- `complete`: generation finished with a non-empty response.
- `cancelled`: the user stopped generation; available partial output is kept.
- `failed`: generation failed or the process ended before completion.

Migration `_upgradeV4MessageStatus` rebuilds only the `messages` table, copies
all existing rows, renames the new table, and recreates the ordered-message
index. The old statuses remain valid and existing conversation/message content
is retained.

## Safety and lifecycle

- History navigation and deletion are disabled while native generation is
  active, preventing the current message from being orphaned mid-stream.
- A process interruption is detected on the next entry to the chat page.
- Message writes are serialized so terminal state cannot overtake a pending
  partial-output checkpoint.
- The platform remains local-first: conversation text is written to the local
  SQLite database and is not sent to a remote service.

## Explicit non-goals at Alpha 1.8

- Prior turns were not passed to `llama.cpp` in this release; Alpha 1.9 adds role-aware messages and tokenizer-accurate context trimming.
- No context summarization, cross-device synchronization, cloud backup, export, or search is included.
- The generation engine in this release remains the Alpha 1.7 single-prompt path.

## Verification

The new host-side `scripts/test_conversation_migration.py` extracts the SQL
statements from the Dart migration source and applies them to SQLite. It checks
preservation of a pre-existing message, acceptance of `cancelled`, rejection of
unknown status values, and cascading deletion. The test is part of the required
native/data contract CI step.

Flutter analysis, widget tests, FRB generation, Rust tests, and the Android
NDK build must still run in GitHub Actions. A host-side SQLite migration test
does not replace those checks or a real Android device smoke test.
