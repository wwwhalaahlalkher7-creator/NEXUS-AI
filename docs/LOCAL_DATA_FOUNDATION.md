# NEXUS local data foundation (Alpha 0.4 work)

This document records the SQLite persistence foundation introduced in Alpha
0.4 and extended through Alpha 1.8. The current conversation screen uses this
local store, while multi-turn model-context assembly remains a separate stage.

## SQLite schema version 4

- `agents`: existing local agent records.
- `models`: model catalog metadata and installation state.
- `conversations`: local conversation metadata and last-message preview.
- `messages`: ordered conversation messages with role and delivery state. Version 4 adds the explicit `cancelled` terminal state while preserving prior rows.

Foreign keys are enabled on every database connection. Deleting a conversation
cascades to its messages. Indexes support recent conversations, recent model
updates, and ordered message retrieval.

## Repositories

- `ConversationRepository`: create/get/list conversations, append messages
  transactionally, create assistant streaming drafts, persist streaming
  checkpoints and terminal states, recover interrupted messages, read messages
  in order, and delete conversations with cascading message removal.
- `ModelRepository`: register/list/get model metadata, update installation
  state, and delete catalog entries.

`registered` is metadata only. It does not mean a model file exists or that
llama.cpp is integrated. `installed` should only be set after verifying the
local model file in a later model-management implementation.

## Migration

Existing version-1 through version-3 databases retain their existing agent,
model, conversation, and message data. Version 4 rebuilds only the messages
table to extend its status constraint; fresh installations run the same schema
creation and migration sequence.

## Alpha 1.8 conversation persistence

The inference screen now creates a conversation from the first prompt, stores
user messages and assistant drafts, checkpoints partial streamed output, and
writes a terminal state on completion, cancellation, or failure. Recent
conversations can be reopened or deleted from the history sheet. On startup,
any message left in `streaming` by process termination is marked `failed`; its
partial text is retained when available. This persistence layer does not yet
compose historical messages into the native model prompt.
