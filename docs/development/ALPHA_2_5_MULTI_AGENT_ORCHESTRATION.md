# Alpha 2.5.0 — Multi-agent orchestration and task planning

## Scope

Alpha 2.5 introduces an on-device Plan / Act / Observe workflow over ready local agents. The planner model returns a strict JSON task graph. The app validates schema, agent readiness, unique identifiers, dependency references, and graph acyclicity before showing the plan to the user. A plan is persisted only after review/save, and execution requires a separate explicit confirmation.

## Execution model

- The Android runtime still owns one active llama.cpp model session. Agent steps therefore execute sequentially. When an agent is assigned a different installed GGUF, the existing model manager switches sessions using its verify/unload/load/restore lifecycle. After the task, the executor attempts to restore the model that was active before the run, or returns to idle if there was none.
- A step receives its objective, expected output, and only the outputs of its declared dependencies. Dependency outputs are framed as untrusted data.
- Child agents cannot create nested plans, recursively delegate, or invoke shell/network tools in this milestone.
- Database compare-and-set step acquisition prevents concurrent duplicate starts. An interrupted inference can be repeated only after explicit user resume; inference has no external side effects. There are no automatic retries. Failed dependencies block dependent steps; independent branches may still run.
- The user can cancel the active native generation. Pending work remains persisted and an interrupted/cancelled task can be explicitly resumed. The task detail view shows step outcomes and the append-only event trace; step/event futures are cached and invalidated when execution progresses.

## Persistence

SQLite schema v8 adds:
- `agent_tasks`: goal, planner identity, plan JSON, task status and timestamps.
- `agent_task_steps`: ordered step contracts, dependency keys, agent assignment, status, result and timestamps.
- `agent_task_events`: append-only execution trace.

Foreign keys cascade step/event deletion with their task. Deleting an agent preserves task history and sets the associated agent reference to null.

## Resource and safety policy

- Balanced mode allows up to 8 plan steps; Performance up to 24; Unrestricted has no app-level step-count quota. Planning output remains bounded by the currently supported native generation output ceiling (1,024 tokens).
- Step output is 256 / 512 / 1,024 tokens across Balanced / Performance / Unrestricted, respectively.
- The runner derives its user-message budget from the active model's reported context and reserves room for the system persona, chat template, and completion. If the available context is insufficient, the step fails with a corrective message rather than sending an oversized handoff.
- Only ready registered agents can be assigned. No arbitrary tool execution, network execution, shell access, or parallel model sessions are introduced.

## Verification

Source-level Dart tests cover JSON parsing, DAG ordering/cycle rejection, invalid agents, and mode quotas. Python host contracts cover migration SQL, persistence relations, interrupted state, task cascades, sequential execution, cancellation, model switching, handoff trust framing, and user approval. These are not substitutes for `dart format`, `flutter analyze`, `flutter test`, Rust/NDK compilation, or a physical-device model smoke test; those remain required GitHub Actions/device gates.
