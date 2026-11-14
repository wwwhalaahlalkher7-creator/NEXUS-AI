# Alpha 2.6.4 — Distributed execution protocol foundation

Status: historical foundation milestone; superseded by Alpha 2.6.5 remote execution integration.

## Scope

At the time of Alpha 2.6.4, this milestone prepared the data contract and durable state machine for one-step execution on another paired device. It deliberately did not turn on remote execution. Alpha 2.6.5 subsequently wires authenticated request dispatch, receiver consent, local execution, cancellation, and result return.

## Request contract

`PeerTaskExecutionRequest` contains a unique execution ID, source task/step IDs, overall goal, one step objective, expected output, explicit dependency outputs, creation time, expiry time and SHA-256 digest. The receiver can verify the canonical payload before showing an approval prompt.

- Versioned kind: `task_execution_request`, schema version 1.
- Expiry: no later than 15 minutes after creation; expired requests are rejected during decode.
- Dependency results: unique step IDs, human-readable local agent labels and data-only output.
- Payload: maximum 512 KiB, below the encrypted peer frame ceiling.
- No file attachments, model weights, shell commands, arbitrary code or remote tool definitions.

## Result contract

`PeerTaskExecutionResult` carries the execution ID, outcome (`succeeded`, `failed` or `cancelled`), output/error, completion time and SHA-256 digest. Success requires non-empty output; failure and cancellation require an explanatory reason. The result body uses the same 512 KiB ceiling.

## Durable ledger

SQLite v12 adds `peer_task_executions` with foreign keys to the paired device and optional local agent, direction, state, source task/step references, serialized request/result, digests, timestamps and expiry. The repository provides:

- durable outgoing creation and incoming request storage;
- idempotency for exact incoming retries and rejection of execution-ID reuse with changed content or device;
- compare-and-set state transitions;
- approval-before-running state rules;
- immutable terminal result hashes;
- recovery of `running` entries to `interrupted` after process death.

Terminal states cannot be reopened. A running request cannot be accepted as a result unless the execution ID already exists and is in `running` or `interrupted`.

## Safety boundary

At the 2.6.4 baseline the new code was an execution contract and durable ledger only. The peer handshake was required to advertise `task_execution=false` until all of the following were integrated and tested; Alpha 2.6.5 implements the source integration, with physical-device tests still pending: authenticated request dispatch, receiver-side local ready-agent selection, explicit per-request approval, local `LocalLlamaAgentExecutor` invocation, cooperative cancellation, result return/correlation, reconnect recovery, duplicate/replay handling, and real two-device testing. The local agent's system prompt and model assignment are never imported from the sender.

## Verification added

- Dart tests for request/result round-trip and tampering, expiry, lifetime validation, dependency uniqueness, outcome requirements and state transitions.
- Python SQLite migration test for v12 status/direction checks, foreign-key behavior, indexes and upgrade/create paths.
- Python source-contract test for canonical SHA-256 checks, bounded payloads, idempotency, compare-and-set transitions, recovery and disabled capability.

Flutter/Dart test execution, Android NDK build and physical-device tests must be confirmed by GitHub Actions and device testing; source-level checks are not substitutes.
