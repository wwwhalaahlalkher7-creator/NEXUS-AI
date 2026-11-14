# Alpha 2.6.2 — Encrypted peer task proposal transport

## Scope

This milestone introduces a durable transport for task proposals between devices already paired by the NEXUS local-device protocol. It does not run a remote agent and does not move model weights.

## Outgoing flow

1. The user selects a task whose local status is `planned` and a paired, non-blocked destination device.
2. NEXUS validates the plan, builds a versioned proposal envelope and computes SHA-256 over its canonical core fields.
3. The transfer is committed to `remote_task_transfers` as `outgoing / queued` before attempting network I/O.
4. When the peer session is connected, the envelope is sent through the existing AES-256-GCM sequenced channel.
5. The sender waits for a correlated acknowledgement carrying the same transfer ID.
6. A positive acknowledgement changes the outbox status to `sent`; a timeout or disconnection leaves it `queued` for reconnect retry.

## Incoming flow

1. Only a fully paired secure session can deliver the envelope.
2. The receiver validates the protocol version, IDs, goal, plan JSON, size ceiling, step structure, dependency references and DAG acyclicity.
3. SHA-256 is recalculated and compared in constant time with the supplied payload digest.
4. The receiver opens a per-transfer consent dialog that shows the source device, goal and validated plan; the dialog defaults to no decision and expires after 60 seconds.
5. An explicit approval inserts the incoming record into SQLite as `incoming / kept`; an explicit rejection is stored as `incoming / declined`. Both decisions are committed transactionally. A rejection is permanent for that transfer; timeout or an unavailable UI is retryable and leaves the sender's outbox queued.
6. Only after the accepted record or rejection decision is durable does the receiver acknowledge. Repeated deliveries replay the stored decision without creating another row or reopening the prompt. Reusing a transfer ID with a different source device, direction or payload hash is rejected.
7. Accepted and declined outcomes are visible in the local transfer history. The accepted item can be inspected in the proposal inbox. `kept` means the user consented to retain untrusted plan data; it does not mean the plan was imported or executed.

## Trust and execution boundaries

- The transfer channel inherits peer identity proof, AES-256-GCM encryption, associated-data binding and monotonic frame sequencing from Alpha 2.6.0.
- An encrypted paired peer is authenticated as a device, not as a trusted author of plans. All remote plan text remains untrusted data.
- No incoming proposal is inserted into `agent_tasks` and no remote `agent_id` is treated as a local agent assignment.
- No task step runs automatically, including after acknowledgement, reconnect or user selection of “keep”.
- The `task_execution` capability remains `false`; `task_transfer` indicates proposal transport only.
- Local database cascade removes device transfer records if the peer is unpaired.
- Proposal content is currently a single secure frame with a 512 KiB combined goal/plan budget; attachments and chunked resumable file transfer are not implemented.

## Persistence

SQLite v10 adds `remote_task_transfers` with per-device foreign-key ownership, direction/status constraints, payload digest, timestamps, and last error. The table is a local outbox/inbox and does not store pairing secrets.

## Verification

Host-side Python contracts validate schema creation, upgrade path, constraints (including permanent rejection and declined inbox state), indexes, foreign-key cascade, secure-channel transport integration, explicit consent-before-storage, persistence-before-positive-ack, deduplication, retry path and consent UI. Dart unit tests are included for the envelope hash, malformed payload rejection, dependency cycles and frame-size budget; they have not yet run in this environment. GitHub Actions must still run `dart format`, Flutter analyze/test, Rust checks, Android NDK compile and APK packaging. Physical two-device tests are required before treating this as validated end-to-end networking.

## Known limitations

- Delivery retry occurs when the same paired device reconnects while the app/service is active; there is no background Android service guaranteeing delivery after process termination.
- A successful transfer acknowledgement confirms that the receiver explicitly approved and durably stored the proposal; it does not confirm import or execution.
- Plans refer to agent IDs from the sending device and require an explicit future import/mapping flow before local execution can be considered.
- Transfer is single-frame; large artifacts, model files and chunked resumable streams are future work.
