# NEXUS AI — Alpha 1.9.3: Clippy host-stub lint fix

NEXUS is a local-first personal AI platform. Alpha 1.9 connects the durable SQLite conversation history to the active GGUF model as role-aware messages. Flutter selects completed turns, Rust validates and marshals the messages, and the native llama.cpp adapter applies the GGUF chat template and counts the resulting tokens. When the formatted prompt plus requested output does not fit, the adapter removes oldest complete turns while preserving system messages and the current user message.


## Alpha 1.9.3 Clippy host-stub lint fix

The non-Android `generate_native_text` stub mirrors the Android adapter's
8-argument callback ABI. It now has a narrowly scoped
`#[allow(clippy::too_many_arguments)]`, matching the Android implementation
and the public runtime wrapper. No ABI shape, callback behavior, or runtime
logic changed.

## Alpha 1.9.2 Rust bridge visibility correction

The stream callback state exposes `finish` to its parent module with
`pub(super)`. This is the narrowest visibility needed by `generate_text`;
the callback state and its implementation remain encapsulated inside the
private `stream_callback` module.

## Alpha 1.9.1 CI formatting correction

The Rust validation stage now runs `cargo fmt --all` after Flutter Rust Bridge
generation has inserted its generated module, then runs
`cargo fmt --all -- --check` as a strict verification step before Rust tests
and Clippy. This handles formatting changes introduced by generated bridge
source without disabling the formatting gate or allowing test failures.

## Alpha 1.7 generation path

- Tokenize a bounded UTF-8 prompt and apply the model's embedded default chat template when available.
- Evaluate the prompt in bounded CPU batches and reject requests that exceed the active context window.
- Generate with a configurable Top-K / Top-P / temperature sampler chain.
- Stream decoded token pieces through the Rust bridge, assembling split UTF-8 sequences safely.
- Signal generation start before prompt evaluation so the Stop action is available during long prompt processing.
- Cancel through an atomic flag and llama.cpp CPU abort callback without acquiring the model/session mutex.
- Clear native KV memory after every request; the current Alpha 1.9 flow reconstructs multi-turn context from completed SQLite messages for each request.
- Report inference as verified only after a complete non-cancelled response; unload resets that verification for the current model.

The current UI exposes a **المحادثة** page with local conversation history, message recovery, an output cap selector, role-aware multi-turn context, tokenizer-accurate context trimming, streamed responses, and a Stop action. The first target remains Android `arm64-v8a` CPU inference.

## Alpha 1.7 boundaries

- Per-request conversation payload: up to 64 completed messages and 48 KiB UTF-8 before native token-aware trimming; formatted prompt: 64 KiB.
- Output limit: 1–1024 tokens in native code; the UI offers 64, 128, 256, and 512.
- Context size: 512–4096 tokens; CPU threads: 1–8.
- Decoder-only text models are supported; encoder/decoder and diffusion models are rejected. Embedded templates must be supported by the pinned llama.cpp helper or an explicit template error is returned.
- Single-file GGUF only. Split GGUF shards, tool execution, vision/audio input, GPU offload, and distributed inference are not part of this milestone. Tool-role messages are transport-capable but no tool execution engine is exposed.
- The host C ABI contract test uses a fake llama API. Only CI's pinned Android NDK build and a physical-device smoke test can verify the actual engine integration.


## Native model-loading foundation (Alpha 1.6)

- Pin and check out the official `ggml-org/llama.cpp` source at commit `cd959bae99ff4bed22bef2604f45241c09bbb8c8` (release v0.9.0).
- Cross-compile the upstream llama.cpp/GGML code as position-independent static libraries for Android `arm64-v8a`, then link them into one NEXUS-owned shared adapter.
- Package `libnexus_llama_probe.so` and `libc++_shared.so` into the APK through `android/app/src/main/jniLibs/arm64-v8a`; the upstream engine code is statically linked inside the adapter.
- Load the isolated C ABI adapter from Rust using a runtime library handle. The handle is retained for the process lifetime.
- Call `llama_backend_init()` once and read `llama_version()` through the adapter.
- Load one GGUF model through `llama_model_load_from_file()` and create one bounded CPU context with `llama_init_from_model()`.
- Release the inference context before freeing its owning model; a second model cannot replace the active session implicitly.
- Check the actual Android `MemAvailable` estimate before model allocation, cap the context to 512–4096 tokens, and limit CPU threads to 1–8.
- Expose typed load/unload operations and actual session diagnostics through Flutter Rust Bridge.
- Show whether a model is actually loaded and its context size in the model library, dashboard session summary, and native runtime diagnostics.
- Keep unsafe Rust denied by default at workspace level; the small Android dynamic-loader module has a local, documented lint allowance.

## Historical Alpha 1.6 limitations (updated by Alpha 1.7 where noted)

- Alpha 1.6 alone loaded GGUF weights and allocated a CPU context without generating text. Alpha 1.7 adds the first bounded single-turn generation path described above.
- A model is not inference-verified merely because it loaded. `inference_available` becomes true only after a complete non-cancelled response for the active model.
- The initial native build targets Android `arm64-v8a` only and sets the minimum Android API to 28 (Android 9). Other ABIs and desktop platforms are not packaged yet.
- The current importer accepts single-file GGUF models only; multi-file GGUF shard sets are rejected until the library can preserve and validate every shard together.
- A successful CI package check proves that the native shared libraries are present in the APK; it does not replace a physical-device smoke test.

## Build and verification

GitHub Actions installs Android NDK `30.0.16248370` (r30 LTS), cross-compiles the pinned llama.cpp source with CMake for Android API 28, statically links upstream llama.cpp/GGML into the NEXUS adapter, copies the adapter and C++ runtime into Android `jniLibs`, generates Flutter Rust Bridge bindings, runs Rust and Flutter checks, builds the ARM64 debug APK, and verifies the adapter exports and native dependency closure.

The CI build is the authoritative compile check. A host-side C ABI contract test compiles the wrapper against a deliberately fake llama API to exercise load/unload, single-session behavior, prompt validation, generation streaming and cancellation callbacks, context overflow, memory rejection, and exported symbols; this is not an upstream llama.cpp compile. The pinned source must still be cross-compiled by GitHub Actions with the Android NDK, and the resulting APK must be smoke-tested on a physical ARM64 device.

Flutter package version: `1.9.3+29`; Rust workspace version: `1.9.3`.

See `docs/development/ALPHA_1_9_MULTI_TURN_CONTEXT.md`,
`docs/development/ALPHA_1_8_LOCAL_CONVERSATION_HISTORY.md`,
`docs/development/ALPHA_1_7_REAL_TEXT_GENERATION.md`,
`docs/development/ALPHA_1_6_GGUF_MODEL_LOADING.md`, and
`docs/architecture/LLAMA_CPP_ANDROID.md`.

## Third-party notices

The Android native adapter includes code from the official `ggml-org/llama.cpp` project at the pinned commit listed above. Its MIT license is bundled in the app at `licenses/llama.cpp-MIT.txt`.


## Flutter/Rust bridge setup

Run `scripts/integrate_bridge.sh` before `flutter pub get`. The integration step
generates the Cargokit `rust_builder/` package used to compile and bundle the
Rust bridge; CI performs this integration automatically.


## Alpha 1.4.1 CI correction (retained)

The Cargokit integration package generated under `rust_builder/` is named
`rust_lib_nexus_app`. The root Flutter manifest must use that exact package key
for its path dependency; the directory name is not the Dart package name. The
CI workflow and `scripts/integrate_bridge.sh` now verify both names before
resolving dependencies. This fixes the FRB integration failure where Pub
reported that `rust_lib_nexus_app` did not match the previously declared
`rust_builder` dependency name.


## Alpha 1.4.2 FRB crate documentation ordering correction

The CI speedup package exposed an ordering interaction between FRB generated
module insertion and the narrowly scoped unsafe-code allow attribute. The
`allow_generated_ffi.py` helper now keeps crate-level `//!` documentation at
the top of `core/bridge/src/lib.rs` before the generated module declaration.
See `docs/development/ALPHA_1_4_2_FRB_DOC_ORDER_FIX.md`.

## Alpha 1.4.2 Rust module correction

Removed the duplicate `core/runtime/src/native.rs` module declaration. The
canonical module remains `core/runtime/src/native/mod.rs`, which exports the
existing `engine` implementation from `core/runtime/src/native/engine.rs`.
Rust rejects having both `native.rs` and `native/mod.rs` for the same module
(`E0761`); this correction resolves that source-layout conflict without
changing the native loader or the llama.cpp adapter behavior.


## CI wait-time optimization

The CI workflow now caches Rust/Cargo dependencies and FRB tools, restores the
llama.cpp Android CMake build tree using a toolchain-aware cache key, uses the
runner CPU allocation for native compilation, and retries APK builds only for
recognized transient network failures. Tests and APK/native-library verification
remain required. See `docs/development/WORKFLOW_SPEEDUP_ALPHA_1_4_2.md`.


## Alpha 1.4.3 FRB module declaration and lint correction

The FRB post-generation helper now recognizes its injected `mod frb_generated;`
declaration even when FRB appends an explanatory block comment. It keeps one
declaration, removes stale duplicates, and applies the narrow
`#[allow(unsafe_code)]` attribute to that declaration. The operation is
idempotent and preserves crate-level documentation. The `libloading` dependency
is now Android-target-only because its only use is inside the Android loader;
host Rust checks no longer report it as unused.

A fixture reproducing the injected-comment plus duplicate-declaration case was
run through the helper twice and passed structural assertions. Full Rust and
Android builds remain to be confirmed by GitHub Actions.


## Alpha 1.4.4 Flutter Material package and runtime status correction

The app now uses the standalone official `material_ui` package consistently
instead of mixing it with the deprecated `package:flutter/material.dart`
entrypoint. The dependency is declared explicitly, and app localization delegates
come from `material_ui`. This aligns with the Flutter 3.50+ migration.

The unavailable GGUF runtime status now explicitly reports that the engine is
not available until native model loading is connected. It keeps the session in
`readyToLoad`; it never marks a model as loaded without a functioning backend.
The FRB cleanup also removes stale attributes attached to deleted duplicate
module declarations.

See `docs/development/ALPHA_1_4_4_MATERIAL_UI_RUNTIME_TEST_FIX.md`.


## Alpha 1.4.5 agent dialog and radio API correction

The agent-creation dialog now owns its text controllers in a dedicated stateful
route widget and disposes them only when that route is actually removed. This
avoids disposing a controller while the dialog reverse transition still has a
mounted text field. The form uses a scrollable alert dialog to remain usable on
short displays and with the software keyboard open.

The local-model selector now uses the `RadioGroup` ancestor API instead of the
deprecated `RadioListTile.groupValue` and `onChanged` properties. Failed local
model-file checks use the same clear verification wording asserted by the
widget tests. Flutter static analysis is now a required CI step rather than an
advisory step.

Flutter package version: `1.8.0+25`; Rust workspace version: `1.8.0`.


## Alpha 1.4.6 parallel Flutter verification

The CI workflow runs `flutter analyze --no-pub` and `flutter test --no-pub` concurrently in the same required verification step. Each command writes to its own log and its exit status is captured independently. The step waits for both commands, prints both logs, and fails if either command exits non-zero. The Android APK build is downstream and therefore cannot start unless both checks pass. Neither check uses `continue-on-error`, `|| true`, or a warning-only mode.

This reduces sequential wait time while preserving both checks as hard CI gates. Both processes are allowed to finish so their complete diagnostics are available; any failure blocks all subsequent steps.


## Alpha 1.4.7 CI maintenance and Release milestone

The CI runner is pinned to `ubuntu-24.04` to prevent an untested automatic
Ubuntu image migration during active development. GitHub Actions dependencies
were updated to maintained releases using the Node.js 24 runtime where
applicable. The Java distribution remains Temurin 17, and the Android NDK,
ABI, API level, Rust toolchain channel, and Flutter stable channel were not
changed by this maintenance update.

Formatting checks are now non-mutating: Rust uses
`cargo fmt --all -- --check`, and Dart uses
`dart format --output=none --set-exit-if-changed lib test`. The workflow fails
when checked-in or generated source files need formatting instead of silently
rewriting files inside the runner.

### Build mode policy

During active development, CI continues to create and upload an ARM64 **Debug**
APK for quick installation and smoke testing. This is intentional and is not
the final distribution build. Once feature development is complete and the
release candidate passes the final device tests, the release milestone must:

1. Configure Android release signing with a dedicated upload keystore stored
   only as protected GitHub Secrets (never commit the keystore or passwords).
2. Build with `flutter build apk --release --no-pub --target-platform android-arm64`.
3. Verify the Release APK contains the NEXUS llama.cpp adapter and C++ runtime.
4. Verify APK signature and package metadata, then upload a clearly named
   `nexus-android-arm64-release.apk` artifact.
5. Keep Debug builds for development diagnostics; use the signed Release APK
   as the final installable distribution artifact. The project target remains
   APK, not AAB.

Do not switch the current CI job to Release before development and final
verification are complete. The signing/release workflow is a deliberate final
stage, not part of this alpha CI-maintenance change.


## Alpha 1.5.0 — Typed Flutter ↔ Rust runtime bridge

The Flutter runtime service now calls the Rust bridge health endpoint and then
receives a strongly typed `RuntimeDiagnosticsDto` through
`flutter_rust_bridge`. Runtime state is no longer serialized as a manually
assembled JSON string and parsed back into Dart. The DTO carries the core
identity, bridge reachability, native adapter availability/version/message,
registry identifiers, and explicit `inference_available` / `model_loaded`
flags.

The UI maps the typed response into `CoreRuntimeStatus`. A failed bridge health
check or initialization still produces an unavailable state; the service never
turns a bridge connection into a claim that inference or a model is active.
The existing GGUF header inspection remains a separate typed Rust bridge call.

Alpha 1.5 strengthened the Flutter/Rust boundary only. At that milestone it
did not load a GGUF model, create an inference context, or generate text.
Alpha 1.6 extends the typed bridge with the native loading lifecycle described
below, subject to CI and physical-device validation.


## Alpha 1.6.0 — Real GGUF model loading and CPU session lifecycle

The native adapter now loads real GGUF weights with the pinned llama.cpp C API,
creates one CPU context, reports the actual context size, and frees the context
before freeing the model. The process owns only one active session; loading a
different model requires an explicit unload first. The adapter rejects invalid
paths, empty files, unsupported context/thread values, and a conservative
preflight memory estimate that cannot be established or satisfied.

Flutter calls the typed `load_gguf_model` and `unload_gguf_model` bridge APIs.
The model library and dashboard share one app-scoped session manager, report
loading/unloading states, and prevent deleting or replacing the active model
file. Runtime diagnostics show the loaded context. The importer rejects split
GGUF shards until it can preserve the complete shard set atomically.
At the Alpha 1.6 milestone, a successful load was not represented as
text-generation availability. Alpha 1.7 adds the first generation path, while
runtime verification still remains false until a complete non-cancelled response
has actually been produced.

The CI workflow verifies the NEXUS native C ABI exports and generated FRB
load/unload/generate/cancel APIs. A host-side adapter contract test uses a fake
llama API for deterministic lifecycle tests; only the NDK build against the
pinned upstream source can establish ABI compatibility with that exact engine.
The Alpha 1.8 SQLite migration and Alpha 1.9 multi-turn context contracts are also executed on the host.

See `docs/development/ALPHA_1_6_GGUF_MODEL_LOADING.md`.


## Alpha 1.7.0 — Real local text generation

Alpha 1.7 adds the first actual inference path on top of the Alpha 1.6 model lifecycle. It uses the pinned llama.cpp C API for prompt tokenization, optional embedded chat-template formatting, bounded prompt evaluation, Top-K / Top-P / temperature sampling, token-to-piece decoding, and incremental output over Flutter Rust Bridge. The native C ABI start event unlocks cancellation before the first generated token, and cancellation does not wait for the model mutex.

Inference verification is scoped to the active model session and is reset when that session is unloaded. A loaded model is not considered inference-verified until one complete non-cancelled response produces at least one token. Alpha 1.7 initially sent one prompt per request; Alpha 1.9 now reconstructs multi-turn prompt context from the SQLite conversation history while still clearing native KV memory between calls. This is conversational context, not yet a full agent/tool runtime.

See `docs/development/ALPHA_1_7_REAL_TEXT_GENERATION.md`.


## Alpha 1.8.0 — Local conversation history

Alpha 1.8 connects the existing SQLite conversation tables to the inference screen. The first user message creates a titled conversation; user messages and assistant drafts are persisted, streaming output is checkpointed, and terminal messages are marked complete, cancelled, or failed. The history sheet restores recent conversations and supports confirmed deletion, while interrupted streaming rows are recovered as failed messages the next time the chat page is opened. SQLite schema version 4 preserves existing rows while adding the explicit `cancelled` status.

At Alpha 1.8 this was persistence and UI continuity only: that release sent each prompt to the model independently. Alpha 1.9 supersedes this limitation by assembling role-aware history and budgeting the formatted prompt against the loaded model context.

The host-side `scripts/test_conversation_migration.py` executes the migration SQL against SQLite and checks data preservation, status validation, and cascading deletion. See `docs/development/ALPHA_1_8_LOCAL_CONVERSATION_HISTORY.md`.


## Alpha 1.9.0 — Multi-turn conversation context

Alpha 1.9 passes completed `system`, `user`, `assistant`, and `tool` messages from the SQLite-backed inference page through the typed Flutter Rust Bridge API. Rust validates role count, message content, the current-turn boundary, payload size, and NUL safety before creating stable C strings for the native C ABI. The adapter applies the active GGUF chat template to the full role-aware message sequence rather than wrapping only the latest user text.

The formatted prompt is tokenized with the loaded model vocabulary. If prompt tokens plus the requested completion exceed the actual loaded context, the adapter removes the oldest complete user/assistant turn and re-applies the model template until the request fits. System messages and the newest user message are retained. The terminal stream event reports how many messages were removed so the UI can show a non-error context notice. Context KV memory is still cleared after each call; multi-turn state is reconstructed from local history on each request, not retained in native memory.

The host C ABI contract test uses a fake llama API and verifies multi-role template input, current-user turn validation, context overflow, old-turn trimming, cancellation, and the trim count. This is a deterministic contract test only; GitHub Actions must still generate FRB bindings, run Rust and Flutter gates, and compile the pinned upstream llama.cpp adapter for Android ARM64. A physical-device test is still required to validate model-specific template behaviour and memory use.
