# NEXUS AI — Roadmap after Alpha 2.0.0

This roadmap describes the remaining engineering work from the current local-first Android ARM64 foundation. Each milestone is gated by the previous milestone's CI and device checks; later features must not be marked complete merely because their UI or interface exists.

## Gate 0 — Accept the current Alpha 2.6.2 source baseline

- Run `dart format lib test`, then verify with `dart format --output=none --set-exit-if-changed lib test`.
- Run `flutter analyze --no-pub` and `flutter test --no-pub` concurrently; both remain mandatory.
- Run Rust formatting, workspace tests, and strict Clippy.
- Cross-compile the pinned llama.cpp adapter for Android `arm64-v8a` and build the development Debug APK.
- Install the APK on a physical ARM64 Android device and verify database migration from the previous installed version.
- Verify a real GGUF model load, a complete local response, cancellation, unload, and app restart. Host tests with a fake llama API are not a substitute.

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


## Alpha 2.7 — Adaptive resource management and performance

- Track available RAM, model footprint, CPU load, battery, and thermal state.
- Derive safe context size and CPU thread defaults from device capability, with user-visible overrides and hard safety limits.
- Add bounded caches and predictable cleanup for model, KV, embedding, and retrieval memory.
- Benchmark cold load, warm load, tokens/second, peak memory, cancellation latency, and sustained thermal behavior.
- Evaluate GPU or vendor acceleration only after the CPU path is stable and measured.

## Beta — Reliability, accessibility, and device validation

- Run a physical-device matrix for clean install, upgrade, migration, low storage, low memory, offline use, app backgrounding, process death, and restore.
- Validate Arabic RTL and English LTR, large text, keyboard/screen-reader semantics, contrast, and 48 dp touch targets.
- Add privacy controls for conversation export, deletion, local data reset, model files, and indexed documents.
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
