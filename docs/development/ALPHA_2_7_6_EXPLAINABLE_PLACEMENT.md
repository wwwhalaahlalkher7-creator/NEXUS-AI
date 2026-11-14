# Alpha 2.7.6 — Explainable peer placement (`2.7.6+58`)

Implemented in source. Flutter/Rust CI, Android ARM64 compilation, and physical two-device acceptance remain outstanding.

## Scope

The placement advisor ranks paired peers for one installed local GGUF model and one requested context size. It combines fresh resource telemetry with the existing `ModelFitEstimator` and requires the candidate to advertise at least one ready local agent assigned to a model with a matching GGUF metadata profile.

## Capability inventory

Each peer sends:

- `ready_model_profiles_version: 1`
- `ready_model_profile_signatures: string[]`

The list is built only from installed `llamaCpp` models assigned to agents whose status is `ready`. Before advertising a signature, the sender checks that the model path exists and its current file size matches the stored model size. No local model ID, model display name, path, or tensor payload is disclosed. Duplicate signatures are deduplicated.

The signature covers architecture, file size, context length, layer count, embedding length, attention head/KV dimensions, GGUF file type, and parameter count. It is a stable compatibility key for metadata only, not a cryptographic hash of the model weights. Two different weight files can share the same metadata profile.

The inventory is additive to the existing resource capability snapshot. Older peers that do not send it remain connectable but are classified as `modelInventoryUnknown` for model-specific placement. No SQLite migration or native ABI change is required.

## Ranking

`PeerExecutionPlacementAdvisor.rankForModel` performs these checks in order:

1. Device trust, connectivity, distributed execution protocol, valid resource profile, freshness, and single-session occupancy.
2. Presence of a valid, versioned ready-agent profile inventory.
3. Matching GGUF metadata signature for the selected local model.
4. The existing model-fit estimator using the peer's reported available RAM and the selected context.

The result distinguishes likely fit, tight fit, insufficient memory, unknown estimate, missing matching profile, missing inventory, stale resources, busy peers, unsupported protocol, offline peers, and blocked peers.

Eligible devices are ordered by memory headroom after the recommended requirement, then measured CPU utilization, thermal status, battery level, and logical CPU cores. Each assessment exposes human-readable reasons and memory figures.

A tight-fit device remains manually selectable with a visible warning. An insufficient-memory candidate is not considered eligible. Stale, malformed, missing, or unknown inputs never become a zero-value or assumed-fit recommendation.

## UI and safety

The Devices page adds a flow to select an installed GGUF model, choose one of the supported context sizes, verify the local file, and view the peer ranking. The dialog is advisory only and does not dispatch a task. Existing peer execution still requires manual device selection, local agent selection at the receiver, and explicit receiver approval. The receiver's native memory preflight remains authoritative.

The profile match does not prove identical tensor contents and does not guarantee model correctness or successful loading. The remote ready agent could be reassigned after the last capability snapshot; therefore a fresh ping before a real execution and receiver-side review remain necessary.

## Verification added

- Dart tests for matching profiles, missing/legacy inventory, unavailable model profiles, fit/tight/insufficient memory states, and explainability.
- Host-side source contract for inventory privacy, file existence/size verification, estimator integration, explicit manual selection, and no dispatch from the advisor.
- SQLite schema remains v15; Rust workspace/ABI remains v2.6.2.

## Remaining acceptance work

- Pass `dart format`, `flutter analyze`, and `flutter test` in GitHub Actions.
- Pass Rust formatting/tests/clippy, FRB generation, and real llama.cpp Android NDK compilation.
- Test inventory refresh after agent/model assignment changes and file removal.
- Test placement on at least two physical Android devices, including stale telemetry, missing profiles, tight/insufficient memory, thermal/battery derating visibility, and actual receiver agent approval.
