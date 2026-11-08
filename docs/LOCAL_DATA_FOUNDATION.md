# NEXUS local data foundation (Alpha 0.4 work)

This increment adds the local persistence contracts for the next application
capabilities. It does not claim that model inference or AI chat is active.

## SQLite schema version 2

- `agents`: existing local agent records.
- `models`: model catalog metadata and installation state.
- `conversations`: local conversation metadata and last-message preview.
- `messages`: ordered conversation messages with role and delivery state.

Foreign keys are enabled on every database connection. Deleting a conversation
cascades to its messages. Indexes support recent conversations, recent model
updates, and ordered message retrieval.

## Repositories

- `ConversationRepository`: create/list conversations, append messages
  transactionally, read messages in order, and delete conversations.
- `ModelRepository`: register/list/get model metadata, update installation
  state, and delete catalog entries.

`registered` is metadata only. It does not mean a model file exists or that
llama.cpp is integrated. `installed` should only be set after verifying the
local model file in a later model-management implementation.

## Migration

Existing version-1 databases keep their agent data. The version-2 tables are
created through `onUpgrade`; fresh installations create all tables.
