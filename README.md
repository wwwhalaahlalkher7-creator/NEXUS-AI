# NEXUS AI — Alpha 2.8.1: Flutter verification repair

## Alpha 2.8.1 — Verification repair (`2.8.1+61`)

This maintenance release fixes the BigInt ceiling-division type mismatch in model-fit estimation and makes the native runtime status card scrollable on short screens. The Flutter package metadata advances to `2.8.1+61`; the Rust workspace and native C ABI remain at `2.6.2`. The local privacy center and its SQLite v15 schema are carried forward unchanged. Flutter/Dart CI, Rust checks, Android ARM64 compilation, and physical-device acceptance remain required. The follow-up CI repair adds explicit blocks to single-statement conditionals in the device network service and fixes the KV-cache confirmation widget test to match the complete dialog copy; the Flutter build number is now `+61`.

---

## Alpha 2.8.0 — Local privacy center (`2.8.0+59`)

Implemented in source; Flutter/Dart CI, Android ARM64 compilation, and physical-device acceptance remain required. Add a Privacy & Local Data screen with a user-selected JSON export and individually confirmed deletion of conversation history, indexed knowledge, task/peer-transfer ledgers, and benchmark history. Export includes user-created content and model metadata, but strips local model paths and excludes model binaries, device identity settings, paired-device addresses/fingerprints, peer transfer/execution ledgers, and secure-storage secrets. Only the resource-mode preference is exported from local settings. Export format v1 is a plaintext data snapshot, not a restorable full-app backup; JSON import/restore is not part of this milestone. The current save path materializes the snapshot in app memory and may not suit very large databases on low-RAM phones. Deletion refuses active message streams and active local/peer executions. Clearing these sections preserves GGUF files, model catalog, agents, pairings/secrets and app preferences. SQLite remains v15 and Rust ABI remains 2.6.2; no database migration or external dependency was added.

See `docs/development/ALPHA_2_8_0_LOCAL_PRIVACY_CENTER.md`.

---

## Alpha 2.7.4 — Native memory lifecycle (`2.7.4+56`)

Implemented in source; Flutter/Rust/FRB/Android CI and physical-device acceptance remain required. Generation now uses an explicit scoped KV reset guard on entry and every exit path. Session teardown clears transient KV while the context is alive, then frees the context before the model. A user-confirmed, non-blocking maintenance action can clear only the transient KV state while retaining model weights and the context; it refuses to run while generation owns the native session. Native diagnostics report lifecycle flags/counters and `/proc/self/status` RSS, peak RSS and virtual size. RSS is whole-process memory, not a llama.cpp-only allocation figure, and may remain high after `free()` because the allocator can retain pages. No database migration or third-party dependency was added; two additive native C ABI symbols are included.

See `docs/development/ALPHA_2_7_4_MEMORY_LIFECYCLE.md` and preceding Alpha 2.7 documents.

---

## Previous milestone — Alpha 2.7.3: Adaptive inference policy

## Alpha 2.7.3 — Adaptive inference policy (`2.7.3+55`)

Implemented in source; Flutter/Dart CI, Android ARM64 compilation, and physical-device acceptance remain required. NEXUS now derives a suggested inference context and CPU thread count from a fresh GGUF inspection, the current RAM/CPU/battery/thermal snapshot, and the selected Balanced/Performance/Unrestricted mode. The suggested context is evaluated with the Alpha 2.7.2 model-fit estimator. Balanced mode prefers a fitting context no greater than 2048 tokens; Performance can use the largest fitting context up to the native 4096-token ceiling; Unrestricted may recommend the largest model-supported context while clearly showing fit warnings. CPU thread suggestions respect the current native maximum of eight. Balanced/Performance reduce their suggestions under high CPU load, critical thermal status, or critically low battery while unplugged; Unrestricted never silently derates and instead surfaces warnings.

The Models page now offers a review dialog where users can change the recommended context and CPU threads before applying them. The selected values are passed explicitly to `ModelRuntimeManager.prepare` or `switchTo`. A failed switch restores the previous model with its previous thread count. Reconfiguring an already loaded model requires explicit confirmation and performs a controlled unload/reload. Insufficient estimated memory requires a second acknowledgement; the native llama.cpp live preflight remains authoritative. No SQLite migration, Rust ABI change, model metadata change, or third-party dependency was added.

See `docs/development/ALPHA_2_7_3_ADAPTIVE_INFERENCE_POLICY.md` and the preceding Alpha 2.7.2/2.7.1 documents.

## Previous milestone — Alpha 2.7.2: GGUF model-fit estimator

## Alpha 2.7.2 — Model-fit estimation (`2.7.2+54`)

Implemented in source; GitHub Actions, Android ARM64 compilation, and physical-device acceptance remain required. GGUF inspection now extracts architecture-specific attention head counts and per-head K/V dimensions when present. SQLite v14 stores those optional fields while preserving older model records. Before loading an installed model, the Models page can verify the local GGUF file and estimate weight residency, KV-cache memory for a selected context, and runtime reserve against the device's current available RAM.

The estimator uses exact GGUF K/V dimensions when available. If the metadata is incomplete but the architecture is a recognized attention-transformer family, it uses full embedding width for K and V as a conservative multi-head upper-bound fallback. Unsupported/state-space architectures or inconsistent metadata return an unknown result rather than a fabricated fit verdict. The estimate shows a minimum, recommended planning threshold, and upper planning threshold with explicit F16 and memory-margin assumptions. Changing context in the estimator changes the estimate only; it does not silently change runtime settings or an active session.

The estimator is advisory. The native llama.cpp loader still performs its own live `/proc/meminfo` preflight and remains authoritative. This estimate is not a guarantee of successful allocation and does not yet predict quantized KV types, backend-specific allocator fragmentation, mmap residency, or device thermal throttling. No third-party dependency or C ABI change was introduced; the Rust-to-Dart metadata DTO is regenerated by the existing FRB workflow.

See `docs/development/ALPHA_2_7_2_MODEL_FIT_ESTIMATOR.md`, `docs/development/ALPHA_2_7_1_DEVICE_TELEMETRY.md`, and `docs/development/ALPHA_2_7_0_PEER_RESOURCE_AWARENESS.md`.

## Previous milestone — Alpha 2.6.5: Authenticated peer execution, local consent and result return (`2.6.5+51`)

Implemented in source; GitHub Actions, Android ARM64 build, and physical two-device acceptance remain required. The app now negotiates `task_execution` only while the receiving device has its Devices screen open and both local approval and local execution handlers are configured. A sender can dispatch one ready task step through the authenticated AES-256-GCM peer channel. The receiver validates the versioned SHA-256 envelope, stores it idempotently, asks the user to choose a ready local agent and approve this exact request, executes through that device's installed local llama.cpp model, persists a terminal result before attempting delivery, and returns the result to the sender. The sender correlates the result with the paired device and source step, then stores the remote output in its local task ledger and acknowledges the exact result digest. SQLite v13 records that acknowledgement so the receiver only replays terminal results until the sender confirms durable receipt.

Outgoing steps are single-dispatch while active; a local task run is atomically refused while any outbound step for that task is queued, awaiting approval, approved or running. Incoming executions are serialized across peers because each app currently owns one model session. Cancellation is cooperative and results remain in SQLite for reconnect delivery until an authenticated result acknowledgement is committed. Process restart moves an interrupted execution to `interrupted` rather than silently re-running a model generation. Request bodies and result bodies remain within 512 KiB; no model files, agent prompts, shell commands, arbitrary code, tools or remote file access are transferred.

This milestone enables one-step remote execution, **not distributed inference or automatic whole-plan orchestration**. Each remote step requires user approval on the receiving device and a user-selected ready local agent. The receiver must have the Devices screen open when a new request is offered and approved; execution is foreground-only and is not advertised as a background service. Saved terminal results are retried on reconnect until an authenticated acknowledgement confirms the exact result digest. Real two-device testing is still required before treating the feature as production-ready.

See `docs/development/ALPHA_2_6_5_REMOTE_EXECUTION_INTEGRATION.md`.

## Previous milestone — Alpha 2.6.4: Distributed execution protocol foundation (`2.6.4+49`)

Alpha 2.6.4 established the versioned request/result envelopes, SHA-256 integrity, 15-minute expiry, bounded dependency outputs and durable SQLite v12 execution ledger. It defined the compare-and-set state machine and process-restart recovery. It did not yet dispatch requests through the network or call the local model executor; those integrations are the Alpha 2.6.5 additions.

See `docs/development/ALPHA_2_6_4_EXECUTION_PROTOCOL_FOUNDATION.md`.

## Previous milestone — Alpha 2.6.3: Approved peer task import

Source milestone prepared; GitHub Actions, Android ARM64 build, and physical-device acceptance are still required.

An incoming proposal that was already approved for storage can now be imported as a local planned task. The user must explicitly map every remote agent identifier to a ready local agent; remote names, personas, prompts, model assignments, and other device metadata are never imported as executable identities. The app re-validates the mapped plan and dependency graph locally, then commits the new `agent_tasks`, pending `agent_task_steps`, provenance event, and source-transfer reference in one SQLite transaction. SQLite schema v11 adds a nullable `imported_task_id` foreign key so repeated import attempts return the same task ID instead of creating duplicates. Deleting the local task clears that reference, allowing a deliberate re-import later. Import does not start generation. The task remains `planned` until the user opens Agents → Tasks and explicitly reviews and runs it on this device. The peer capability continues to advertise `task_execution=false`; remote execution, remote cancellation, result routing and distributed inference are not enabled in this release.

See `docs/development/ALPHA_2_6_3_APPROVED_TASK_IMPORT.md`.

## Previous milestone — Alpha 2.6.2: Encrypted task proposal transport

Explicitly paired devices can now exchange durable task proposals through their existing AES-256-GCM sequenced peer channel. Outgoing proposals are written to a local SQLite outbox before network send, correlate acknowledgements by transfer ID, and remain queued for a later reconnect if delivery is interrupted. The receiver validates the envelope and SHA-256 payload digest, checks the plan structure and dependency DAG, then asks the user to approve or reject that specific proposal before storage. The approval dialog expires after 60 seconds; no decision leaves the sender's outbox queued for retry. An approved proposal is committed locally as `kept` before the positive acknowledgement is sent; an explicit rejection is also persisted as `declined`, so duplicate deliveries replay the same decision without reopening the prompt. Exact duplicate delivery is idempotent; reuse of an ID with different data is rejected. A rejected or permanently invalid proposal is not retried automatically. Keeping a proposal does not import remote agents, execute steps, transfer model files or enable distributed inference. The current proposal frame payload ceiling is 512 KiB to stay below the encrypted 1 MiB frame envelope; file attachments and chunked transfer are future work. SQLite schema v10 adds the durable inbox/outbox.

## Previous milestone — Alpha 2.6.1: Local discovery and QR pairing

NEXUS retains the authenticated encrypted TCP pairing protocol from Alpha 2.6.0 and adds opt-in IPv4 UDP broadcast discovery on a separate port, time-limited QR invitations, an in-app camera scanner with clipboard fallback, and interface-change detection. Discovery advertisements contain only a nonce, device identity label, platform and TCP port; they never contain the pairing secret. Each result is treated as untrusted until a known secure pairing key validates the remote identity, or an invitation QR is scanned and the existing challenge/HMAC/X25519 handshake succeeds. A scanned invitation is shown for explicit user confirmation; the host still approves first-time pairing. The local-device discovery socket is closed when neither an invitation nor a scan is active. UDP discovery is best-effort: a blocked broadcast socket does not disable QR or manual pairing. Probe replies are rate-limited per source and the source cache is bounded. Interface changes refresh invite addresses and clear stale discovery results. Manual IPv4 entry remains available. This phase does not add remote task execution, file/model transfer or distributed inference. Android target SDK remains 36 until the Android 17 / SDK 37 `ACCESS_LOCAL_NETWORK` runtime permission flow is implemented. QR scanning uses bundled ML Kit on Android and adds approximately 3–10 MB to the app package. See `docs/development/ALPHA_2_6_1_NETWORK_DISCOVERY_QR.md`.

## Previous milestone — Alpha 2.6.0: Secure local device connectivity

Alpha 2.6.0 introduced explicit local TCP listening, one-time 256-bit pairing secrets, host approval, X25519/HMAC/HKDF key agreement, AES-256-GCM sequenced frames, secure-storage key persistence, SQLite v9 peer metadata and read-only capability/ping exchanges. See `docs/development/ALPHA_2_6_LOCAL_DEVICE_NETWORKING.md`.

## Previous milestone — Alpha 2.5.0: Multi-agent orchestration

### Alpha 2.5.0 scope

NEXUS can now build a strict JSON plan with a selected local planner agent, validate ready-agent assignments and dependency cycles, and show the proposed plan before saving or execution. Plans, task steps, outputs, interruption states and an append-only event trace persist locally in SQLite schema v8 and are visible in task history. Planner output cannot silently replace the original user goal. See `docs/development/ALPHA_2_5_MULTI_AGENT_ORCHESTRATION.md` for details. Execution is sequential because the current runtime intentionally owns one llama.cpp model session; the model manager safely switches between agents' installed model assignments. Agents receive typed handoffs containing only declared dependency outputs, explicitly framed as untrusted data. Child agents cannot recursively delegate or request shell/network execution. Failed prerequisites block dependent steps while independent steps may continue. Native generation can be cancelled, and interrupted/cancelled tasks can be explicitly resumed.

Balanced, Performance and Unrestricted resource modes control plan-size and output budgets; the actual model context window still governs handoff size. Parallel model execution, nested delegation, delegated tool calls and distributed agents are not included.

## Alpha 2.4.1 — Adaptive resource policy and unrestricted mode

NEXUS now offers three local resource modes: Balanced, Performance, and Unrestricted. The selected mode is stored locally in SQLite schema v7 and applied to imports, knowledge retrieval, conversation transport, and local tool execution. Balanced and Performance import/search budgets are calculated from the current Android `MemAvailable` value rather than fixed per-file or per-library quotas. Unrestricted mode opts out of those pre-budgets entirely. The knowledge library no longer caps the number of documents, total indexed characters, or chunk count; Balanced and Performance chunking follows its dynamic import budget, while Unrestricted continues without an application pre-budget until processing completes or the operating system intervenes. Unrestricted mode removes fixed result, per-document, conversation-count, conversation-byte, tool-input/output, and per-turn tool-call budgets. The local allow-list, typed tool validation, explicit approval checks for modifying/external tools, per-tool execution timeout, cancellation, model context window, Android memory, and storage capacity remain real constraints.

The native transport boundary now allows up to 4,096 role-aware messages and 1 MiB of combined message content before llama.cpp performs tokenizer-accurate trimming against the active model context. This is a bridge safety ceiling, not an application quota. It prevents unbounded allocation at the Dart/Rust/C++ boundary while no longer forcing conversations to stop at 64 messages or 64 KiB. Search query terms are limited to 128 per SQL request because each term is bound twice and SQLite must remain below its portable bind-variable ceiling.

## Alpha 2.4.0 — Local knowledge library and lexical retrieval

The previous milestone added an on-device TXT/Markdown library, Arabic text normalization, overlapping chunks, deterministic BM25-style lexical retrieval, source numbering, and untrusted-source framing. Alpha 2.4.1 removes fixed file/document/library/chunk/candidate/result/prompt quotas. Balanced and Performance budgets are sized from the live memory snapshot or active model context. Unrestricted mode removes the importer and retrieval pre-budgets entirely; the user accepts the risk of Android terminating the process under memory pressure. Model files no longer have a default 8 GiB Flutter-side ceiling; native memory preflight remains authoritative. The current native runtime still has an explicit context ceiling of 4,096 tokens, an output ceiling of 1,024 tokens, and a transport envelope of 1 MiB / 4,096 messages; these are existing engine limits, not cloud quotas, and require a separate native-context expansion milestone.

## Alpha 2.3.0 — Autonomous local tool calling (previous milestone)


NEXUS AI now includes a versioned allow-list of offline tools exposed through explicit chat commands. Alpha 2.2.0 adds a safe arithmetic parser, local date/time and text statistics, per-turn call budgets, bounded JSON inputs and outputs, timeouts, explicit approval gates for future modifying tools, and durable tool-role audit messages. Arabic command aliases and Arabic/Persian numeral normalization are supported. Output truncation counts Unicode code points and records cooperative cancellation distinctly from rejection. These commands work without loading a GGUF model. Alpha 2.3 adds a strict JSON envelope for model-requested calls to the allow-listed read-only tools. The app validates the complete response, checks the tool schema and per-turn budget, executes locally, persists the assistant request and tool result as separate role-aware messages, then returns the result to the model for a follow-up response. Tool calls are sequential, capped at three per user turn, cancellable, and never execute prose, Markdown fences, shell commands, arbitrary code, network requests or unregistered tools.


NEXUS carries each ready agent's system persona into native model inference and persists the selected agent with the conversation. Alpha 2.1.1 adds explicit model routing from the model library: the target GGUF is verified before the current session is unloaded, the new model is loaded under one-session limits, and a failed target load triggers an attempt to restore the previous model. If restoration cannot be confirmed, the runtime enters a recovery-required state and blocks inference until an explicit unload succeeds.

A generation lease protects the active native session while inference runs. Model prepare, load, switch and unload operations are rejected during generation; the lease is released only after the native stream reports a terminal event or error. The model library exposes a confirmed model-switch action and a recovery unload action. The chat page can also switch to a ready agent's assigned, installed local model after explicit confirmation. The Android target remains ARM64 CPU inference with one active model session.

Semantic/vector retrieval, PDF and DOCX extraction, distributed task execution and inference, GPU offload, and vision/audio remain future milestones.

## Alpha 2.0.0 — Agent personas and conversation binding (base milestone)

See `docs/development/ALPHA_2_0_AGENT_PERSONAS.md` for the original persona and conversation-binding scope.

## Alpha 1.9.6 — Widget test scroll finder correction

The dashboard shell widget test calls `scrollUntilVisible` without directly referencing the `Scrollable` type. Flutter Test resolves the default scrollable internally, removing the direct symbol dependency that caused the repeated undefined-identifier failure. Flutter analysis and tests remain mandatory parallel gates; no gate is weakened or skipped.

NEXUS is a local-first personal AI platform. Alpha 1.9 connects durable SQLite conversation history to the active GGUF model as role-aware messages. Flutter selects completed turns, Rust validates and marshals messages, and the native llama.cpp adapter applies the GGUF chat template and counts the resulting tokens. Alpha 2.0 adds durable agent personas and conversation-to-agent binding on top of that inference path.

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
- The host C ABI contract test uses a fake llama API. Alpha 2.3 resumes generation after a tool result; if a GGUF chat template rejects the generic `tool` role, the adapter retries with a clearly marked, data-only user message while SQLite retains the original `tool` role. Only CI's pinned Android NDK build and a physical-device smoke test can verify the actual engine integration.


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

Flutter package version: `2.7.6+58`; Rust workspace version: `2.6.2` (no breaking native ABI change; two additive symbols were added for memory diagnostics and KV maintenance). SQLite database version: `15` (includes local resource settings, knowledge library, orchestration tables, paired devices, durable peer task inbox/outbox, idempotent local task-import references, the durable distributed-execution ledger, and optional GGUF attention dimensions for model-fit estimation). The inference message bubble syntax was corrected so `SelectableText` keeps its `textDirection` and `style` named arguments inside the constructor call. Flutter verification fixes also normalize invitation expiry to UTC, make empty inference state scrollable in short layouts, migrate resources to `RadioGroup`, and explicitly block device-page flow control, and provide a non-null RadioGroup callback that ignores changes while a resource-mode save is in progress. The `file_picker` dependency is pinned to the compatible v12 API line (`^12.3.0`) so its Windows implementation can resolve `win32` 6 alongside `flutter_secure_storage ^11.2.0`.

See `docs/development/ALPHA_2_6_4_EXECUTION_PROTOCOL_FOUNDATION.md`,
`docs/development/ALPHA_2_6_2_PEER_TASK_TRANSFER.md`,
`docs/development/ALPHA_2_6_1_NETWORK_DISCOVERY_QR.md`,
`docs/development/ALPHA_2_6_LOCAL_DEVICE_NETWORKING.md`,
`docs/development/ALPHA_2_5_MULTI_AGENT_ORCHESTRATION.md`,
`docs/development/ALPHA_2_3_AUTONOMOUS_TOOL_CALLING.md`,
`docs/development/ALPHA_2_2_LOCAL_TOOLS.md`,
`docs/development/ALPHA_2_1_AGENT_MODEL_ROUTING.md`,
`docs/development/ALPHA_2_0_AGENT_PERSONAS.md`,
`docs/development/ROADMAP_POST_ALPHA_2_0.md` for the remaining milestones,
`docs/development/ALPHA_1_9_MULTI_TURN_CONTEXT.md`,
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

## Alpha 2.4.0 historical scope (superseded by Alpha 2.4.1 resource policy)

- Indexed formats: UTF-8 TXT, Markdown (`.md` and `.markdown`). PDF, DOCX, images, OCR, embeddings, and vector search are not implemented in this milestone.
- Alpha 2.4.0 initially shipped conservative per-file, library, candidate, result, and prompt quotas. Alpha 2.4.1 supersedes those fixed application quotas with the selected resource profile: Balanced and Performance use memory-aware budgets, while Unrestricted removes the artificial importer and retrieval pre-budgets.
- Documents are split into overlapping 1,200-character chunks with a 160-character overlap. Original source files are not copied into the app database; text chunks and normalized search forms are stored locally.
- Local text excerpts are untrusted data. Tool instructions found inside a source are never executed.


## Alpha 2.7.5 — Local benchmark harness (`2.7.5+57`)

Implemented in source; Dart/Flutter CI, Rust/FRB integration, Android ARM64 build, and physical-device performance acceptance remain required.

- Add a local benchmark page reachable from the model library. It requires an installed GGUF model, an idle runtime session, and explicit user confirmation before loading or generating.
- Measure the first app-managed load and a repeat load separately. The repeat load may benefit from the operating-system page cache; Android cannot reliably flush that cache without elevated privileges, so the UI does not call it a guaranteed cold-cache measurement. The effective loaded context and thread count returned by the runtime are persisted rather than merely echoing requested values.
- Run a short warm-up excluded from throughput, then two measured generation passes. Compute tokens/second from the actual stream token counts and elapsed wall time, not requested output length.
- Run a separate cancellation probe. Record cancellation latency only when the native cancellation request is accepted and the stream reaches its terminal cancelled event; otherwise leave the metric unavailable.
- Sample process-wide RSS high-water mark, thermal status, battery level, and runtime version around load/generation phases. RSS is labelled the process lifetime VmHWM since app start, not a per-benchmark or model-only peak; thermal/battery values stay unknown when the OS does not expose them.
- Persist provenance and results locally in SQLite schema v15: model identity/name/architecture/file size, context, CPU threads, first/repeat load times, generation elapsed time/token count/throughput, process VmHWM lifetime watermark, cancellation observation/latency, thermal/battery endpoints, runtime version, status, and failure detail.
- Release the generation lease and attempt to unload the benchmark model after terminal stream completion. On a generation timeout, request native cancellation and wait up to 30 seconds for a terminal event. If no terminal event arrives, retain the generation lease and skip unload to avoid freeing a context that native code may still use; the UI instructs the user to restart the app.
- Keep benchmark history after deleting a model catalog entry by using a soft model identifier rather than a foreign key.
- Add Dart metric/record round-trip tests and host Python migration/source-contract checks to CI.

Not included: root-only cold page-cache control, background thermal polling, GPU benchmarks, multi-device comparative benchmark orchestration, or automatic model/peer placement. Physical-device runs are still required to characterize sustained thermal behaviour and measurement repeatability.

See `docs/development/ALPHA_2_7_5_BENCHMARK_HARNESS.md`.

## Alpha 2.7.6 — Explainable peer placement (`2.7.6+58`)

Implemented in source; Flutter/Rust CI, Android ARM64 build, and physical two-device acceptance remain pending.

- Advertise a privacy-minimized inventory of GGUF metadata signatures assigned to ready local agents. The capability snapshot contains no local model IDs, names, paths, or tensor contents; peers can compare metadata profiles without receiving the catalog itself.
- Verify that each advertised model record is still installed and its local path exists with the recorded file size before publishing its profile. Inventory versioning is additive and does not require a SQLite migration or a breaking peer-protocol version bump.
- Build a stable compatibility signature from architecture, file size, context length, layer count, embedding length, attention dimensions, file type, and parameter count. This is a metadata compatibility key, not a cryptographic hash of model weights or proof that tensor contents are identical.
- Add `PeerExecutionPlacementAdvisor.rankForModel` to assess a selected installed GGUF model and context against each peer's fresh RAM, CPU occupancy, thermal state, battery, single-session occupancy, and ready-agent model-profile inventory.
- Run the existing model-fit estimator against each peer's reported available RAM. Separate likely-fit, tight-fit, insufficient-memory, model-unavailable, unknown-inventory, stale, busy, unsupported, offline, and blocked states.
- Rank first by model fit and memory headroom, then by measured CPU load, thermal status, battery, and logical cores. Attach human-readable reasons and memory figures to each recommendation.
- Add a device-page flow to select a local verified GGUF model and context, then view an explainable ranked list. The recommendation dialog does not dispatch a task; device selection remains manual and the receiver must still choose a local ready agent and explicitly approve execution.
- Add Dart unit tests for matching profiles, missing/legacy inventories, tight fit warnings, insufficient memory, and ranking. Add a host-side source contract to CI. Preserve SQLite schema v15 and Rust ABI 2.6.2.

Important limitation: profile matching compares GGUF metadata only, not tensor contents. A candidate's estimate is conditional on its advertised ready agent still using a model with that profile; actual native memory preflight and receiver approval remain authoritative. Physical two-device acceptance is required before treating placement recommendations as operationally reliable.

See `docs/development/ALPHA_2_7_6_EXPLAINABLE_PLACEMENT.md`.

## Exact remaining work after Alpha 2.8.0

1. **Beta acceptance:** run clean-install/upgrade/migration, low-storage/low-memory, offline, background/process-death, restore, RTL/LTR, accessibility, long-session, repeated load/unload, cancellation, thermal-soak, and benchmark-repeatability tests. Review JSON export contents/redaction and document a restore/import strategy. Validate model-specific peer placement with at least two physical Android devices, including stale telemetry, model inventory mismatch, low-memory rejection, receiver approval, result acknowledgement, reconnect, and process-restart recovery.
2. **Release CI and native build:** from a clean GitHub Actions run, pass Dart format/analyze/test, Rust fmt/test/clippy, FRB generation, pinned llama.cpp Android NDK compilation for `arm64-v8a`, and Debug APK packaging. Fix every failure before scope freeze.
3. **Release APK:** build and sign the `arm64-v8a` Release APK (not AAB), verify signing certificate/package/version/native libraries and upgrade path, then publish APK, SHA-256, release notes, and installation/recovery guidance.

Historical scope note for Alpha 2.7.0: resource telemetry, model fit, adaptive inference, memory lifecycle, benchmarks, and explainable placement were split into follow-on milestones. Alpha 2.7.1–2.7.6 are implemented in source; CI and physical-device acceptance remain pending.
