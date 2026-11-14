# Alpha 2.6.5 — Remote execution integration (`2.6.5+51`)

SQLite schema v13 adds `result_acknowledged_at_unix_ms`; the receiver stops replaying a terminal result only after an authenticated acknowledgement matches the same execution ID, paired device, and SHA-256 result digest.

Status: implemented in source; Flutter/Dart/Rust CI, Android ARM64 APK build, and two-device acceptance are still required.

## Runtime capability negotiation

`task_execution` is advertised as true only while the receiving `DevicesPage` has installed both an explicit approval callback and a local executor callback. The callbacks are cleared when the page is disposed, which sends a capability update disabling new inbound work. This is an interactive foreground workflow; the receiver needs the Devices screen open for a new approval prompt, and the app does not claim background task execution.

## Sender workflow

1. The user chooses a connected, paired peer that advertises the matching execution protocol version.
2. The sender chooses one planned or interrupted task and one pending/interrupted step whose dependencies are already successful.
3. The request contains the overall goal, selected step, expected output and only the declared dependency outputs. It does not contain model files, local agent prompts, or executable code.
4. The sender creates the durable outgoing ledger entry before network dispatch. SQLite transaction checks that the task and step are still eligible and that the same step has no other active remote dispatch.
5. `AgentTaskOrchestrator` uses the same SQLite transaction boundary to refuse a whole local task run while any outgoing step is queued, awaiting approval, approved or running. This avoids running the same source step locally while a peer is executing it.

## Receiver workflow

1. The secure session authenticates the paired device; the request envelope verifies protocol version, expiry, field shapes, payload size and SHA-256 digest.
2. The incoming record is committed idempotently before user interaction.
3. The user sees the sending peer, goal, step, expected output and dependency results. Dependency results are explicitly identified as untrusted data.
4. The user selects a local `ready` agent and approves this specific execution. Remote identities, personas, prompts and model assignments are not imported.
5. `LocalLlamaAgentExecutor` selects/loads only the receiver's local installed model, runs one step under the model manager's generation lease, and attempts to restore the model that was active before the request.
6. The receiver commits a terminal result to SQLite before attempting network delivery. A send failure does not rewrite the execution outcome; the stored result is retried after reconnect until the sender acknowledges the exact digest.

Inbound execution is serialized across all peers because the app currently supports one active llama.cpp model session. Requests arriving while that slot is occupied receive a retryable response. This is a deliberate concurrency limitation, not an artificial account or service quota.

## Cancellation and recovery

- The sender can request cancellation while awaiting approval or while running.
- The receiver cancels the active `AgentTaskCancellationToken`, which reaches the native generation cancellation callback.
- If cancellation arrives before native generation starts, the receiver records and returns a cancelled terminal result without starting the model.
- The sender only updates the original source step when the execution ID and paired device match its outgoing ledger record. Success saves the returned output; cancellation marks the step interrupted; failure records an error.
- Terminal results are durable and resent on reconnect only while the sender has not acknowledged the exact result digest. Duplicate exact results are accepted by digest; changed results for the same execution ID are rejected.
- On process restart, interrupted executions are not automatically replayed. The user must explicitly start a new attempt to avoid accidentally repeating costly or non-idempotent model work.

## Security boundaries

No shell, process, arbitrary code, filesystem browsing, model transfer, network tool, remote tool registry, or cloud endpoint is included. The local agent is selected by the receiving user. Results and dependency outputs from a peer are data, not authority; downstream agents are instructed to treat them as untrusted input.

## Verification added

- Source-contract tests for dynamic capability gating, encrypted request dispatch, local approval, one-model admission, cancellation, result persistence/delivery ordering, result acknowledgement and bounded replay, source-step result application, and no shell/process dispatch.
- SQLite transaction contracts for one active remote dispatch per source step and task-run exclusion while outbound peer execution is active.
- Dart state-machine tests for approval, running, cancellation and terminal transitions.
- Existing discovery, pairing, transfer, task import, orchestration, RAG, tools and SQLite migration contracts remain enabled in CI.

Not yet verified in this environment: `flutter analyze`, `flutter test`, `cargo test`, FRB integration, Android NDK build, and real two-device execution/cancellation/reconnect. GitHub Actions and physical-device acceptance remain mandatory before calling the feature release-ready.
