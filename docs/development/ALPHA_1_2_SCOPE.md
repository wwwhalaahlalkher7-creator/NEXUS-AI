# NEXUS AI Alpha 1.2 — Verified Agent Model Assignment

## Scope

Alpha 1.2 hardens the local agent-to-model association introduced in Alpha 1.1.

- An agent may only be assigned a model that is registered as an installed local
  `llama.cpp` model with a non-empty local path.
- Before saving an assignment, the app runs the existing bounded GGUF file audit.
  A missing file, size mismatch, or invalid GGUF header prevents the assignment.
- Removing a model catalog record clears any agent `model_id` references in the
  same SQLite transaction, preventing dangling local assignments.
- Widget coverage includes successful audited assignment and rejection when the
  file audit fails.

## Explicit limitations

- The audit checks file existence, recorded size, GGUF header, and metadata. It
  does not hash tensor payloads, validate all tensor offsets, or prove that the
  model can be loaded or executed.
- No inference backend is integrated in this milestone. An assigned model is a
  verified local file association, not a running model or executable agent.
- Runtime loading, memory budgeting, cancellation, streaming generation, and
  tool execution remain future milestones.

## Validation

The repository CI remains authoritative for `flutter test`, Rust tests/Clippy,
FRB generation, and Android debug APK build. This development environment does
not include Flutter, Dart, or Cargo, so no local compile or test result is claimed.
