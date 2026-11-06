# NEXUS AI — Alpha 0.1 foundation

NEXUS AI is a local-first, multi-device AI platform. This repository is the **first source foundation**, not a finished AI runtime.

## Current scope
- Flutter mobile application shell (Arabic RTL by default; English-ready structure).
- Rust workspace with a small, testable core library.
- Agent domain model and in-memory Rust registry foundation.
- SQLite-backed local agent repository in Flutter (create/list/get/update/delete).
- Explicit model-runtime adapter contract; no model is bundled or claimed to run.
- Architecture and development documentation.

## Not included yet
- llama.cpp integration or model downloads.
- Flutter ↔ Rust bridge source and code-generation setup; generated bindings must still be produced and verified on a Flutter/Rust machine.
- Flutter ↔ Rust bridge source and code-generation setup; generated bindings must still be produced and verified on a Flutter/Rust machine.
- Device discovery, pairing, networking, distributed scheduling.
- GitHub Actions or APK artifacts (added after this initial source batch is reviewed).

These are intentionally deferred so the first commit stays small and auditable.

## Requirements
- Flutter stable SDK
- Dart SDK bundled with Flutter
- Rust stable toolchain (`rustup`, `cargo`)
- Android SDK/NDK for Android builds

## Bootstrap
Run from the repository root:

```bash
bash scripts/bootstrap.sh
```

The script creates the missing Android platform folder using Flutter, fetches Dart packages, and checks the Rust workspace. It does not install a model, configure cloud services, or deploy anything.

Then:

```bash
flutter run
```

For Rust checks:

```bash
cargo fmt --all -- --check
cargo test --workspace
```

## Product principles
1. Local-first; network is optional.
2. No fake AI, fake telemetry, or fabricated resource measurements.
3. Every device is an independently useful node.
4. Start by distributing agent tasks; distributed tensor inference is a later research phase.
5. Sensitive actions require explicit user approval.
6. The LLM is never the authority for permissions or security policy.

## UI system
- Primary: `#101828` (navy)
- Accent: `#0D9488` (teal)
- Surface: `#F8FAFC`
- Secondary text: `#64748B`
- Error: `#DC2626`
- Success: `#15803D`
- Typography: Noto Sans Arabic + Inter (font assets are not bundled in this first batch).
- Spacing: 8 dp base grid.
- Minimum touch target: 48 dp.
- Target: WCAG 2.2 AA contrast and accessible semantics.

## Repository status
See `docs/development/ALPHA_0_1_SCOPE.md` and `docs/development/ALPHA_0_2_SCOPE.md` for implemented and deferred work.
