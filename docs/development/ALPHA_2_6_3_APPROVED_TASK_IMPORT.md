# Alpha 2.6.3 — Approved peer task import

Flutter package version: `2.6.3+48`. Rust workspace and native ABI remain `2.6.2`. SQLite schema: v11.

## Behavior

An incoming proposal must first be received and approved in the encrypted peer-transfer flow. The user can then choose **Import as local task**. NEXUS extracts distinct remote agent IDs and requires an explicit mapping from each one to a locally configured `ready` agent. The mapping dialog never imports a remote agent name, persona, system prompt, or model ID.

After mapping, `AgentTaskPlanParser` validates the complete plan against the receiving device's local ready agents and the original goal. The repository then re-checks agent readiness in the SQLite transaction and atomically inserts a local planned task, pending task steps, a provenance event and an `imported_task_id` reference on the incoming transfer. Repeated requests return the existing task ID rather than duplicating the local task. If the local task is later deleted, the FK clears the import reference and the user can re-import deliberately.

## Execution boundary

Importing is not execution. Imported tasks remain `planned`. The user must open Agents → Tasks, review the locally remapped plan, then explicitly press the existing execution action. The receiving device uses its own agents, model files and local runtime. The source device's agent identifiers and model assignments are never trusted or transferred as executable configuration.

Peer capability remains `task_execution=false`. There is no remote invocation, worker lease, cancellation RPC, result return path, file transfer or distributed inference in this milestone.

## Database

SQLite v11 adds nullable `remote_task_transfers.imported_task_id` referencing `agent_tasks(id) ON DELETE SET NULL`, plus an index. Both fresh creation and upgrades from v10 create the column. Import writes the task and reference in one transaction.

## Verification

New host contract checks cover v11 migration, FK behavior, local mapping, ready-agent revalidation, idempotency and the no-auto-execution boundary. Dart unit tests cover complete mapping and rejection of missing/malformed mappings. Flutter analyze/test, FRB integration, Android ARM64 build and physical device acceptance still require GitHub Actions and real-device verification.
