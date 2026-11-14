# NEXUS AI — Roadmap after Alpha 2.0.0

This roadmap describes the remaining engineering work from the current local-first Android ARM64 foundation. Each milestone is gated by the previous milestone's CI and device checks; later features must not be marked complete merely because their UI or interface exists.

## Gate 0 — Accept the current Alpha 2.7.6 source baseline

The estimator and adaptive inference policy must use metadata from the freshly verified GGUF file for each estimate; cached catalog metadata must not override a current file inspection. Selected context and CPU-thread settings are advisory until the user confirms them. Alpha 2.7.4 added scoped KV clearing, process-memory diagnostics, and explicit lifecycle counters; Alpha 2.7.5 adds persisted local benchmark runs, actual loaded-setting provenance, and a safe terminal-drain policy before native unload; Alpha 2.7.6 adds explainable model-specific peer placement. CI and physical-device acceptance remain outstanding.

- Run `dart format lib test`, then verify with `dart format --output=none --set-exit-if-changed lib test`.
- Run `flutter analyze --no-pub` and `flutter test --no-pub` concurrently; both remain mandatory.
- Run Rust formatting, workspace tests, and strict Clippy.
- Generate FRB bindings from the checked-in bridge configuration and verify the generated API.
- Cross-compile the pinned llama.cpp adapter for Android `arm64-v8a` and build the development Debug APK.
- Install the APK on a physical ARM64 Android device and verify database migration from the previous installed version.
- Verify a real GGUF model load, a complete local response, cancellation, unload, and app restart. Host tests with a fake llama API are not a substitute.
- Pair two physical devices and verify capability profile refresh, resource ranking, remote execution consent, result acknowledgement, cancellation, reconnect replay, and process-restart recovery.

## Alpha 2.1 — Agent model routing and session lifecycle (`2.1.1+35`)

Implemented in source as `2.1.1+35`; CI and physical-device acceptance are still pending.

- Verify the target GGUF record before touching the active native session.
- Add an explicit model-switch operation and confirmation UI in the model library and a one-tap confirmed switch from the chat page to a ready agent's assigned installed model.
- Unload the previous session before loading the target; never keep two model sessions active.
- Attempt to restore the previous model if target loading fails.
- Enter `recoveryRequired` and block inference if cleanup or restoration cannot be confirmed; provide an explicit recovery unload action.
- Add a generation lease that prevents prepare, load, switch, and unload while inference is active.
- Verify switching from idle and between models, preflight rejection, rollback, recovery, and generation-lock behavior with deterministic backend tests.
- Still required: device-memory pressure tests, target-file deletion between verification and native open, and physical-device load/switch smoke tests.

## Alpha 2.2 — Local tool registry and controlled execution (`2.2.0+36`)

Implemented in source as explicit user-invoked local tools; CI and physical-device acceptance are still pending.

- Add a versioned allow-listed tool registry with typed argument maps and per-tool timeouts.
- Add strict JSON input budgets, bounded result text, and a maximum number of calls per execution session.
- Register offline calculator, local date/time, and text-statistics tools.
- Support Arabic and English command aliases directly from chat, even when no GGUF model is loaded.
- Normalize Arabic/Persian numerals and common Arabic mathematical symbols; truncate outputs at Unicode code-point boundaries.
- Persist structured tool status/results through the existing `tool` message role without a database migration.
- Gate future mutating/external tools behind explicit user approval; arbitrary shell and unrestricted network/filesystem access remain absent.
- Verify malformed commands, Arabic numeral normalization, arithmetic bounds, unknown tools, approval rejection, timeouts, Unicode-safe output truncation, cancellation/overlap protection, audit serialization, and call budgets.

Not included yet: autonomous LLM-generated tool calls, side-effectful tools, file-system tools, network tools, document retrieval, and agent planning loops. Cooperative cancellation is available in the registry contract; current registered tools remain read-only and deterministic.

## Alpha 2.3 — Autonomous local tool calling (`2.3.0+37`)

Implemented in source; CI and physical-device acceptance are still pending.

- Advertise only registered read-only local tools in a bounded system instruction.
- Parse only a complete, strict `nexus_tool_call` JSON envelope; prose, Markdown, partial JSON and extra envelope fields remain ordinary assistant text.
- Validate tool names and typed arguments through the same allow-list registry used by explicit slash commands.
- Execute each call with the existing byte, output, timeout, cancellation and three-attempt per-turn budgets.
- Persist the assistant's tool-call envelope and the structured `tool` result as separate role-aware messages.
- Return the tool result to the model as a `tool` role and resume generation to produce the user-facing answer.
- Disable additional tool requests after the per-turn budget is exhausted; reject any further request without running it.
- Expose model tool-call requests as readable UI cards rather than raw protocol JSON, and allow cooperative cancellation while an allowed tool is running.
- Preserve complete interaction groups while trimming context, including assistant tool requests and their tool results.
- Test strict parsing, malformed envelopes, allow-list rejection, read-only advertisement, loop limits, role-aware context continuation and cancellation.

Not included: mutating tools, shell/process execution, unrestricted file or network access, multi-agent delegation, parallel tool execution, or resumable background jobs. LLM compliance with the JSON protocol remains model-dependent and must be smoke-tested using real GGUF models on device. If a GGUF chat template rejects the generic `tool` role, the native adapter retries with the tool result represented as a clearly marked user data block; the durable SQLite record remains a `tool` message.

## Alpha 2.4.0 — Local knowledge library and lexical RAG foundation (`2.4.0+38`)

Implemented in source; CI and physical-device acceptance remain pending.

- Import UTF-8 TXT and Markdown files through the Android file picker with a 4 MiB file limit and a 200,000-character text limit.
- Normalize Arabic diacritics, Alef variants, Arabic/Persian numerals, line endings, and control characters before indexing.
- Split text into 1,200-character chunks with 160-character overlap and store document metadata plus normalized terms in SQLite schema v6.
- Reject duplicate text by a stable non-cryptographic content fingerprint; cascade indexed-chunk deletion when a source is deleted.
- Add a deterministic BM25-style lexical ranker over at most 800 candidate chunks; cap retrieval at five results and a 3,000-character prompt with a context-aware budget.
- Allow retrieval to be disabled per chat composer; retain the selected evidence for the full autonomous tool-call continuation cycle.
- Pass numbered source excerpts as untrusted data, prohibit following embedded instructions, and ask the model to cite source numbers instead of fabricating provenance.
- Add contract and unit tests for normalization, chunk bounds, ranking, source limits, injection framing, deduplication, and SQLite cascading deletion.

Not included in 2.4.0: local embedding models, vector indexes, semantic/hybrid retrieval, PDF/DOCX extraction, OCR, and document export. These remain planned for Alpha 2.4.2 after the lexical path passes CI and Android migration/device checks.

## Alpha 2.4.1 — Adaptive resource policy (`2.4.1+39`)

Implemented in source; Flutter/Rust/Android CI and physical-device acceptance are still pending.

- Add persisted Balanced, Performance, and Unrestricted resource modes in SQLite schema v7.
- Derive Balanced and Performance import/search working budgets from the live Android `MemAvailable` snapshot; Unrestricted opts out of those pre-budgets.
- Remove fixed aggregate document, character, chunk, chunk-count, and search-result ceilings from the knowledge library; Balanced/Performance are memory-budgeted, while Unrestricted continues without an importer or retrieval pre-budget.
- Apply resource mode to knowledge retrieval count, per-document diversity, chat-history transport, model tool-call count, tool envelope/input/output budgets, and prompt payload size; remove the default 8 GiB model-file ceiling.
- Unrestricted mode removes fixed application-level per-turn and corpus quotas while retaining typed allow-list validation, explicit approvals, cancellation, per-tool timeouts, native context-window trimming, and a high FFI transport safety ceiling.
- Raise the role-aware native transport boundary to 4,096 messages and 1 MiB so the model's tokenizer-aware context trim, not a 64-message/64-KiB application cap, determines useful history.
- Verify mode persistence, v6-to-v7 migration, memory-based budget changes, unrestricted behavior, tool cancellation, and model-context trimming.
- Follow-up still required: replace the current 4,096-token native context ceiling and 1,024-token response ceiling with model-metadata-aware, RAM-preflighted configuration, then validate on real Android hardware before claiming an unrestricted context window.

## Alpha 2.4.2 — Semantic and hybrid retrieval (planned)

- Integrate a small on-device embedding model with an explicit memory and CPU budget.
- Generate and persist normalized vectors; use a bounded nearest-neighbour index with model/version metadata.
- Combine semantic scores with lexical BM25 scores and deduplicate adjacent overlapping chunks.
- Add PDF text extraction and DOCX support only after safe format validation and size limits.
- Show source previews and citation navigation; verify the referenced source still exists before opening it.
- Measure retrieval precision, recall, latency, and memory on representative Arabic and English documents.

## Alpha 2.5.0 — Multi-agent orchestration and task planning (`2.5.0+40`)

Implemented in source; Flutter/Rust/Android CI and physical-device acceptance are still pending.

- Generate strict JSON plans from ready local agents and validate them as acyclic dependency graphs.
- Show the proposed plan for review; saving and execution are separate explicit actions.
- Persist task plans, step transitions, outputs, interruption state, and append-only execution events in SQLite schema v8.
- Execute steps sequentially against the single native llama.cpp session; safely switch/restore GGUF sessions when agents have distinct installed model assignments.
- Pass only declared dependency outputs through typed hand-off contracts and label them as untrusted data.
- Prevent duplicate step acquisition, recursive delegation, nested plans, unregistered agents, and shell/network execution.
- Block dependent steps after failed prerequisites while allowing independent branches to continue.
- Support native generation cancellation and explicit resume of interrupted/cancelled tasks.
- Use resource-mode step budgets and active-model context-aware hand-off sizing.

Not included: parallel model sessions, parallel agent execution, automatic retries, tool execution inside delegated agents, or distributed agents. These require separate scheduling, permission, and cancellation work.

## Alpha 2.6.0 — Secure local device connectivity (`2.6.0+41`)

Implemented in source; GitHub Actions and physical-device acceptance remain pending.

- Add explicit opt-in TCP listening on private IPv4 and time-limited pairing invitations; manually enter peer IPv4 and port.
- Authenticate pairing with a fresh server challenge and HMAC proof of a 256-bit secret; derive session keys with ephemeral X25519 and HKDF-SHA-256.
- Encrypt frames using AES-256-GCM with peer-bound associated data and strict sequence validation against replay/reordering.
- Require host approval when no secure key exists and use a two-phase commit before both devices save the pairing.
- Keep pairing secrets in platform secure storage; store device metadata and an event trail in SQLite schema v9.
- Stop and invalidate pending handshakes when the listener is stopped; restrict unauthenticated handshakes to four concurrent sockets without limiting paired devices.
- Exchange read-only device capability snapshots and ping/pong health checks.
- Pin Android `targetSdk` to 36 until the Android 17/API 37 `ACCESS_LOCAL_NETWORK` runtime permission flow or a system-mediated picker is implemented.

Not included: automatic mDNS discovery, public Internet relay, file/model transfer, task replication, distributed execution, or remote command execution. These require separate transport, scheduling, privacy, and security work.

## Alpha 2.6.1 — Local UDP discovery and QR pairing (`2.6.1+42`)

Implemented in source; GitHub Actions, Android build, and physical two-device acceptance remain pending.

- Add explicit 30-second IPv4 UDP broadcast discovery on port `47832`, separate from the TCP peer protocol on `47831`.
- Use fresh short-lived probe nonces, strict packet-size bounds, sender-address validation, device-ID validation, and stale-result expiry. Advertisements never carry pairing secrets or trigger pairing.
- Advertise only while a valid, unclaimed invitation is active. Close the discovery socket when neither scanning nor hosting an invite.
- Encode the same short-lived 256-bit invite secret, peer ID, display name, private IPv4 addresses, TCP port and expiration into a versioned QR payload. Reject malformed, public-address, expired, and incorrectly sized secrets.
- Add an in-app camera scanner and a confirmation screen before connecting. The host must still approve a new peer; remote ID must match the scanned invitation before the authenticated handshake is committed.
- Reconnect a previously trusted device through a newly discovered address only when the existing platform-secure pairing key verifies the expected peer identity.
- Watch IPv4 interface fingerprints, clear stale discovery results on change, recreate the UDP socket when needed, and refresh invite addresses without changing its secret or expiration.
- Add Android camera permission while keeping camera hardware optional. Keep `targetSdk=36`; Android 17/API 37 local-network runtime permission work is still required before raising it.
- Add Dart protocol tests plus Python contract and manifest idempotency checks. Real Wi-Fi/hotspot broadcast behavior, camera permission behavior, QR scan, and two-device migration/reconnect remain physical-device gates.

Not included: mDNS, Internet relay, API 37 local-network permission flow, task distribution, file/model transfer, or distributed inference.

## Alpha 2.6.2 — Encrypted peer task proposal transport (`2.6.2+43`)

Implemented in source; GitHub Actions and physical two-device acceptance remain pending.

- Add a durable per-device SQLite v10 outbox and consent-approved inbox.
- Send only explicitly selected `planned` tasks over the authenticated AES-GCM peer channel.
- Validate envelope version, transfer/source IDs, plan JSON, step fields, dependency references and cycles.
- Verify a SHA-256 payload digest and bind acknowledgements to the intended authenticated peer.
- Require explicit per-proposal approval before writing the incoming record; expire unanswered requests after 60 seconds.
- Commit approved inbound proposals before sending a positive acknowledgement; deduplicate exact transfer IDs and reject conflicting reuse.
- Keep retryable failures queued across disconnection; persist an incoming user decline as `declined` and a sender-side permanent rejection as `rejected`, without retrying either decision.
- The capability handshake advertises `task_transfer=true` but keeps `task_execution=false`. No remote task is imported or executed.
- Single-frame proposal body is limited to 512 KiB; attachments, chunked transfer, remote execution and distributed inference remain future milestones.

Still required: Flutter/Dart/Rust CI, Android ARM64 build, physical two-device transfer, reconnect/retry, duplicate delivery, reject/keep, and app process restart verification.


## Alpha 2.6.5 — Remote execution integration (`2.6.5+51`)

Implemented in source; Flutter/Rust CI, Android ARM64 build, and physical two-device acceptance remain required.

- Negotiate `task_execution=true` only when local receiver approval and execution handlers are configured; the capability is withdrawn when the Devices screen closes.
- Dispatch one task step through the existing authenticated AES-256-GCM peer session using the versioned SHA-256 request envelope.
- Persist incoming requests before prompting; require the receiver to select a ready local agent and explicitly approve each request.
- Invoke only the receiver's local `LocalLlamaAgentExecutor` and installed model; never import remote agent prompts, model IDs, model files, shell, arbitrary code or tools.
- Persist terminal results before network delivery, correlate them to the original paired device and source step, and replay them after reconnection only until an authenticated acknowledgement matches the result digest (SQLite v13).
- Propagate cancellation to the active local generation; serialize inbound executions globally because the current app owns one model session.
- Atomically reject a local whole-task run while outbound peer steps are active, and reject dispatching the same task step to multiple peers while a prior dispatch is active.
- Recover in-flight work as `interrupted` after process death rather than repeating generation; users must explicitly create a new attempt.
- Keep request/result payloads within 512 KiB and execution to one explicitly approved step at a time.

Not included: automatic whole-plan distribution, multi-model concurrency, model/file transfer, remote shell or arbitrary remote tools, or distributed tensor inference. Both devices must keep the Devices screen open for capability advertisement and explicit local approval; physical two-device, reconnect, cancellation and process-restart tests remain release gates.

## Previous milestone — Alpha 2.6.4: Distributed execution protocol foundation (`2.6.4+49`)

Alpha 2.6.4 defined versioned request/result envelopes, SHA-256 integrity, a 15-minute expiry, bounded dependency outputs, and the SQLite v12 durable ledger with compare-and-set transitions and process-restart recovery. It did not dispatch execution over the network; the active integration is added in Alpha 2.6.5.


## Alpha 2.7 — Adaptive resource management and performance

- Track available RAM, model footprint, CPU load, battery, and thermal state.
- Derive safe context size and CPU thread defaults from device capability, with user-visible overrides and hard safety limits.
- Add bounded caches and predictable cleanup for model, KV, embedding, and retrieval memory.
- Benchmark cold load, warm load, tokens/second, peak memory, cancellation latency, and sustained thermal behavior.
- Evaluate GPU or vendor acceleration only after the CPU path is stable and measured.

## Alpha 2.7.1 — Bounded device telemetry (`2.7.1+53`)

Implemented in source; Flutter/Dart CI, generated Android host compilation, Android ARM64 build, and physical-device acceptance remain required.

- Sample aggregate `/proc/stat` counters twice over 400 ms and calculate CPU utilization from total and idle tick deltas. Invalid and non-monotonic counters return unknown.
- Read battery level and charging state from Android `ACTION_BATTERY_CHANGED` through the generated Kotlin host. No runtime permission is added for these readings.
- Read thermal status through `PowerManager.currentThermalStatus` on API 29+; API 28 and platforms without the API report unknown.
- Add an idempotent patch for the generated `MainActivity.kt` and expose telemetry using `com.nexusai/device_telemetry`.
- Extend the existing peer capability v1 profile with optional CPU, battery, charging, and thermal fields for backward compatibility; older peers that omit the new fields remain valid.
- Cache the extended snapshot for ten seconds across capability sends; the UI displays only validated received values and never auto-dispatches.
- Add deterministic Dart tests for valid, invalid, and unavailable readings plus Python contract and Android host patch idempotency tests.

Not included: model-specific RAM fit, GPU capacity, automatic placement, or periodic background sampling. API-specific behaviour and thermal readings require a real Android device.

See `docs/development/ALPHA_2_7_1_DEVICE_TELEMETRY.md`.

## Alpha 2.7.2 — GGUF model-fit estimator (`2.7.2+54`)

Implemented in source; Flutter/Rust/FRB/Android CI and physical-device acceptance remain required.

- Extend bounded GGUF metadata inspection with `attention.head_count`, `attention.head_count_kv`, `attention.key_length`, and `attention.value_length`, retaining only architecture-prefixed values.
- Persist the optional attention dimensions in SQLite v14 without rebuilding or discarding v13 model rows.
- Estimate the F16 KV cache from context × layers × KV heads × (key length + value length) × bytes per element when the required GGUF fields exist.
- For recognized attention-transformer architectures with incomplete head dimensions, use the aggregate embedding width for K and V as an explicitly labeled conservative multi-head upper-bound fallback.
- Return an unknown estimate for unsupported/state-space architectures, inconsistent dimensions, missing model metadata, invalid contexts, or unverified files rather than guessing.
- Display model file size, KV cache, runtime reserve, current available RAM, minimum/recommended/upper planning thresholds, and the assumptions that produce them.
- Allow the user to compare supported context sizes inside the estimator. This changes only the estimate and does not silently mutate runtime settings or an active model session.
- Keep the estimate advisory; the native llama.cpp loader retains its own live memory preflight and remains authoritative.
- Test exact GQA dimensions, full-width fallback, missing telemetry, insufficient/tight memory, unsupported architectures, malformed metadata, context limits, SQLite v13→v14 preservation, and the FRB DTO regeneration path.

Known uncertainty: resident mmap pages, quantized KV cache overrides, allocator fragmentation, prompt/batch workspaces, and model-specific runtime overhead are not yet measured. The estimator must not claim guaranteed load success.

See `docs/development/ALPHA_2_7_2_MODEL_FIT_ESTIMATOR.md`.

## Alpha 2.7.4 — Native memory lifecycle (`2.7.4+56`)

Implemented in source; Flutter/Rust/FRB/Android CI and physical-device memory-pressure acceptance remain required.

- Keep generation KV memory scoped with an RAII reset guard that clears at request entry and on every terminal path, including cancellation and decode/callback failures.
- Clear transient KV/sequence state before freeing its owning context; free the context before its model weights.
- Add an explicit, non-blocking KV maintenance operation. It uses a try-lock and refuses while a generation owns the session; it clears KV only and never unloads weights or the context.
- Add an additive C ABI snapshot for model/context/generation state, successful model load/unload counts, KV clear count, and Linux `/proc/self/status` RSS, peak RSS, and virtual memory.
- Keep process RSS explicitly labelled as whole-process telemetry, not llama.cpp-only memory. Allocator retention can keep RSS high after native objects are freed; RSS reduction is not a cleanup success criterion.
- Expose diagnostics through Rust and FRB and show them in the runtime card. The UI requires confirmation before clearing KV and disables the action while generation is reported active.
- Verify reset-on-success/cancel paths, clear refusal during generation, idempotent unload counters, context-before-model destruction, FFI layout, and UI confirmation.
- No SQLite migration, third-party dependency, runtime model setting change, or breaking Rust/native function signature change is added. Two additive C ABI symbols are required and are resolved from the rebuilt adapter.

Still required: generated FRB binding check, Dart format/analyze/tests, Rust fmt/test/clippy, real Android ARM64 adapter build, and physical-device repeated load/generate/cancel/clear/unload memory-pressure tests.

See `docs/development/ALPHA_2_7_4_MEMORY_LIFECYCLE.md`.

## Alpha 2.7.3 — Adaptive inference policy (`2.7.3+55`)

Implemented in source; Flutter/Dart CI, Android ARM64 compilation, and physical-device acceptance remain required.

- Recommend a model-supported context from fresh GGUF inspection and the model-fit estimate. Balanced considers up to 2048 tokens; Performance considers up to the native 4096-token ceiling; Unrestricted may select the largest model-supported context while exposing fit warnings.
- Recommend CPU threads from logical cores up to the native eight-thread ceiling. Balanced starts conservatively; Performance/Unrestricted can use the available engine threads.
- Reduce Balanced/Performance thread suggestions under high CPU load, severe/critical thermal state, or low battery while unplugged. Unrestricted reports these conditions without silently throttling.
- Let the user review and override context and threads in the Models page before applying. Insufficient-memory estimates require explicit acknowledgement and never bypass the native loader preflight.
- Pass explicit values through `ModelRuntimeManager.prepare` and `switchTo`; preserve prior thread settings when rolling back a failed model switch. Reconfiguring the active model requires explicit confirmation and unload/reload.
- No schema migration, Rust ABI change, dynamic active-session resize, GPU selection, or background auto-adjustment is included.

Still required: Flutter/Dart/Rust CI, Android ARM64 build, and physical-device measurements for thermal stability and practical thread/context choices.

See `docs/development/ALPHA_2_7_3_ADAPTIVE_INFERENCE_POLICY.md`.

## Alpha 2.7.0 — Peer resource awareness (`2.7.0+52`)

Implemented in source; Dart/Flutter CI, Rust CI, Android ARM64 build, and physical-device acceptance are pending.

- Advertise a versioned snapshot containing available/total RAM when readable, logical CPU count, active inbound peer-execution occupancy, and sample timestamp.
- Treat missing memory as unknown, and treat profiles older than five minutes or implausibly future-dated as stale.
- Refresh peer capabilities on ping and whenever the local single execution slot becomes occupied or free.
- Exclude blocked, offline, protocol-incompatible, busy, stale, and unknown-resource peers from execution recommendations.
- Rank eligible peers by available RAM, then logical CPU count, with a deterministic name tie-break.
- Show the recommendation and resource facts in the device UI. The user still selects the peer; receiver approval remains mandatory and no automatic dispatch is performed.
- Keep SQLite at v13; the resource profile is stored in the existing capability JSON and requires no migration.

Historical scope note for Alpha 2.7.0: that milestone did not include device telemetry, model-specific peak-memory estimation, adaptive context/thread selection, memory lifecycle management, benchmarks, or explainable placement. These capabilities were split into follow-on milestones. Current Beta and Release acceptance work is listed after Alpha 2.8.0; source milestones 2.7.1–2.7.6 are implemented, while CI and physical-device acceptance remain pending.

## Alpha 2.8.0 — Local privacy center (`2.8.0+59`)

Implemented in source; Flutter/Dart CI and physical-device acceptance remain pending.

- Export user-authored content and local configuration as a versioned JSON snapshot through the native save dialog.
- Include agents/instructions, model metadata, conversations/messages, knowledge documents/chunks, tasks/steps/events, benchmark history, and the resource-mode preference.
- Exclude local model paths and weight files, device identity, paired-device addresses/fingerprints, peer transport/execution ledgers, and secure-storage secrets.
- Add individually confirmed deletion for conversation history, knowledge index, task/peer ledgers, and benchmark history.
- Refuse destructive cleanup while a conversation stream or local/peer execution is active.
- Preserve model binaries, model catalog, agents, paired-device trust/keys, and preferences when deleting selected histories.
- Keep SQLite v15 and Rust ABI 2.6.2; no migration or dependency was added.

Limitations: JSON export is plaintext and materializes the snapshot in app memory; it is a data snapshot, not a full-app backup. Import/restore, whole-app reset, model-binary backup, pairing-secret backup, and cloud synchronization are not included.

See `ALPHA_2_8_0_LOCAL_PRIVACY_CENTER.md`.

## Beta — Reliability, accessibility, and device validation

- Run a physical-device matrix for clean install, upgrade, migration, low storage, low memory, offline use, app backgrounding, process death, and restore.
- Validate Arabic RTL and English LTR, large text, keyboard/screen-reader semantics, contrast, and 48 dp touch targets.
- Complete privacy acceptance for JSON export/redaction and selected-history deletion. JSON restore, whole-app reset, and backup/restore coverage for model files and paired-device secrets remain separate work.
- Run long-session, repeated load/unload, multi-agent, and thermal soak tests.
- Document supported Android versions, device requirements, model compatibility, and known limitations.

## Release — Signed Android APK

- Freeze feature scope and require every CI gate to pass from a clean workflow run.
- Build a signed `arm64-v8a` Release APK; do not switch to AAB for this delivery target.
- Verify signing certificate, package/version metadata, native library packaging, and clean installation/upgrade.
- Generate SHA-256 checksum and release notes; archive the exact source revision and build artifacts.
- Publish the APK with installation, update, backup, and troubleshooting guidance.

## Optional later work

Vision, speech input/output, additional Android ABIs, desktop platforms, GPU acceleration, and cloud synchronization remain separate later milestones. They must not delay the reliable offline CPU-first path.


### Alpha 2.6.2+45 — Inference widget syntax correction

Follow-up CI repair for the `SelectableText` constructor in `inference_page.dart`: remove the extra closing parenthesis before `textDirection`, and guard the exact malformed pattern with `scripts/test_pub_dependency_compat.py`. The Flutter package build metadata is `2.6.2+45`; Rust remains `2.6.2`. Dart formatting, analysis, tests, FRB integration, and APK build still require a clean GitHub Actions run.


### Alpha 2.6.2+46 — Flutter verification follow-up

Fix the latest GitHub test failures: deterministic strict private IPv4 parsing, UTC normalization for QR expiry timestamps, and a scrollable short-height inference empty state. Remove Flutter analyzer infos by using `RadioGroup<ResourceMode>` and explicit blocks in device page flow-control statements. Flutter analyze/test and APK build remain pending a new CI run.


### Alpha 2.6.2+47 — RadioGroup callback typing fix

The first host Flutter verification run after `2.6.2+46` found one compile error: the nullable `_saving ? null : callback` expression was passed to `RadioGroup.onChanged`, whose current API requires a non-null `ValueChanged<ResourceMode?>`. The callback is now always provided and returns without changing state while `_saving` is true or the selected value is null. The source-contract test verifies the non-null callback shape. Flutter package metadata is `2.6.2+47`; Rust workspace and native ABI remain `2.6.2`. Re-run GitHub Actions to confirm Dart analysis and all widget tests.


## Alpha 2.6.3 — Approved peer proposal import (`2.6.3+48`)

Implemented in source; Flutter CI and physical two-device acceptance are pending.

- Add explicit mapping from each remote agent ID in an approved proposal to a locally configured `ready` agent. Remote personas, prompts, model assignments and untrusted labels are not imported.
- Re-parse and validate the remapped dependency graph against the receiving device's current ready-agent catalog.
- Add SQLite v11 `imported_task_id` reference with `ON DELETE SET NULL`.
- Atomically create a local `planned` task, pending local steps, source-provenance event and imported-task reference in a single SQLite transaction.
- Make repeat imports idempotent: a transfer with a valid imported-task reference returns the existing local task ID.
- Keep imported tasks local and inert until a user opens Agents → Tasks and explicitly starts the task.
- Keep the peer handshake `task_execution=false`.

Not included: remote agent execution, remote cancellation, result transport, task leases, file/model transfer or distributed inference. These remain the next protocol milestone after Flutter CI and two-device import/upgrade tests pass.

## Alpha 2.7.5 — Local benchmark harness (`2.7.5+57`)

Implemented in source; Dart/Flutter CI, FRB generation, Android ARM64 compilation, and physical-device benchmark acceptance remain pending.

- Add an explicit benchmark page for installed local GGUF models. The runner refuses to start during active generation, while another operation is in progress, while a model is loaded, or when recovery is required.
- Measure first load and repeat load independently. Repeat load is not called a guaranteed cold-cache test because the app cannot flush the Android/Linux page cache without privileged access.
- Exclude one warm-up generation from throughput; calculate aggregate tokens/second from actual generated token counts and elapsed wall time over measured passes.
- Measure cancellation latency separately and record it only when native cancellation was accepted and a terminal cancelled stream event was received.
- Sample process RSS high-water mark, thermal status, battery level, and runtime version around load and generation phases. Missing measurements remain null; process RSS remains labelled process-wide.
- Persist local benchmark provenance and outcomes in SQLite schema v15, including model, file size, context, CPU threads, load times, generation token/time/throughput values, peak RSS, cancellation result, thermal/battery readings, runtime version, completion status and errors.
- Release generation leases in `finally` and attempt to unload the benchmark session even when a stage fails. Preserve benchmark history after model catalog deletion through soft model references.
- Add unit tests for metrics/record serialization and host migration/source contract tests to CI.

Not included: privileged cold-cache flushing, continuous background thermal sampling, GPU measurement, or automatic placement based on benchmark history. Sustained thermal soak and repeatability need physical Android measurements.

See `docs/development/ALPHA_2_7_5_BENCHMARK_HARNESS.md`.

## Alpha 2.7.6 — Explainable peer placement (`2.7.6+58`)

Implemented in source; Flutter/Rust CI, Android ARM64 build, and physical two-device acceptance remain pending.

- Advertise only GGUF metadata compatibility signatures that are assigned to ready local agents. Do not reveal model IDs, names, paths, or tensor contents.
- Confirm local file existence and exact recorded size before advertising a signature. Keep the inventory additive and backward-compatible at the peer-capability layer.
- Use architecture, file size, context length, layer count, embedding length, attention dimensions, file type, and parameter count as a metadata compatibility key. This is not a cryptographic weight-file hash.
- Evaluate each fresh, connected, unblocked and idle peer for a selected installed GGUF model/context using the existing model-fit estimator against that peer's available RAM.
- Explain the fit outcome and ranking using memory headroom, CPU utilization, thermal status, battery, and logical cores; classify missing inventory, missing matching profile, unknown fit, insufficient memory, tight fit, stale telemetry, busy, unsupported, offline and blocked states separately.
- Add a UI flow for selecting a verified local GGUF model and context and viewing the ranked candidate list. No task is sent by the advisor; peer selection remains manual, and receiver agent selection plus explicit approval remain mandatory.
- Add Dart tests and a CI source-contract test. Preserve SQLite v15 and Rust ABI 2.6.2.

Limitation: the peer compatibility signature compares model metadata, not tensor contents. Estimates are conditional on a ready agent remaining assigned to a model with that profile; the receiver's native memory preflight remains authoritative.

See `ALPHA_2_7_6_EXPLAINABLE_PLACEMENT.md`.

## Exact remaining work after Alpha 2.8.0

1. **Beta acceptance:** clean install/upgrade/migration; low storage and memory; offline use; background/process-death recovery; RTL/LTR and accessibility; long sessions; repeated load/unload/cancel; thermal soak; benchmark repeatability; and two-device acceptance of model-specific placement, execution approval, result acknowledgement, reconnect, and restart recovery.
2. **Clean CI and native Android build:** Dart format/analyze/test, Rust fmt/test/clippy, FRB generation, pinned llama.cpp NDK compilation for ARM64, and Debug APK packaging must all pass on a clean GitHub Actions run.
3. **Release APK:** freeze scope, build and sign an `arm64-v8a` Release APK (not AAB), verify certificate/package/version/native libraries and upgrade path, and deliver APK, SHA-256, release notes, and recovery/install instructions.

Historical scope note for Alpha 2.7.0: resource telemetry, model fit, adaptive inference, memory lifecycle, benchmarks, and placement were split into follow-on milestones. Alpha 2.7.1–2.7.6 are implemented in source; CI and physical-device acceptance remain pending.
