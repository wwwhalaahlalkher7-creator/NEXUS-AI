# NEXUS Alpha 0.5 — Model library

## Delivered in this increment

- A model-library screen replaces the former navigation placeholder.
- Users can register a model name and runtime category (`llamaCpp` or `external`).
- Model metadata is persisted through `ModelRepository` in SQLite.
- Users can remove a catalog entry after confirmation.
- Empty, loading, failure, refresh, and populated states are implemented.
- Widget tests cover registration and deletion through an injected `ModelStore`.

## Deliberate scope boundary

A catalog entry has `registered` status. It is not proof that model weights
exist on disk, are valid, are downloaded, or are loaded into a runtime.
This increment does not add a download manager, filesystem permission flow,
llama.cpp bindings, inference, or an active-model indicator.

## Next engineering increment

Build the native runtime boundary and device capability inspection, then
connect verified model-file metadata to a runtime adapter. Only after that
should model installation and inference states become actionable in the UI.
