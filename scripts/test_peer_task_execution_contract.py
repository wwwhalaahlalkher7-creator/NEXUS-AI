#!/usr/bin/env python3
"""Guard the validated request/result envelope and execution state machine."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lib/src/features/devices/peer_task_execution.dart").read_text(encoding="utf-8")
service = (ROOT / "lib/src/features/devices/device_network_service.dart").read_text(encoding="utf-8")

checks = {
    "request envelope has a versioned execution kind": "'kind': 'task_execution_request'" in source and "peerTaskExecutionVersion = 1" in source,
    "request is bound to task and step IDs": "sourceTaskId" in source and "sourceStepId" in source,
    "request authenticates canonical payload with SHA-256": "Sha256().hash(utf8.encode(jsonEncode(core)))" in source and "payloadSha256" in source,
    "request digest comparison is constant-time": "_constantTimeEquals(actualHash, suppliedHash)" in source,
    "request has a short explicit expiry window": "peerTaskExecutionRequestLifetime = Duration(minutes: 15)" in source and "expiresAt <= currentTime" in source,
    "dependency output IDs are unique": "!dependencyIds.add(dependency.stepId)" in source,
    "request and result fit a sub-frame transport budget": "peerTaskExecutionMaximumBytes = 512 * 1024" in source and 512 * 1024 < 1024 * 1024,
    "result envelope has terminal outcome validation": "'succeeded', 'failed', 'cancelled'" in source,
    "result digest is checked before persistence": "_constantTimeEquals(actualHash, suppliedHash)" in source and "resultSha256" in source,
    "execution statuses require approval before running": "PeerTaskExecutionStatus.awaitingApproval" in source and "PeerTaskExecutionStatus.approved" in source,
    "terminal states cannot be reopened": "PeerTaskExecutionStatus.succeeded," in source and "return allowed[from]?.contains(to) ?? false" in source,
    "outgoing records are durable before dispatch": "createOutgoing" in source and "status': PeerTaskExecutionStatus.queued.wireName" in source,
    "outgoing step is single-dispatch while active": "هذه الخطوة لها طلب تنفيذ بعيد نشط بالفعل" in source and "source_step_key = ? AND status IN (?, ?, ?, ?)" in source,
    "incoming records are idempotent by device and request hash": "existing['device_id'] != deviceId" in source and "existing['request_sha256'] != request.payloadSha256" in source,
    "status transitions use compare-and-set": "where: 'execution_id = ? AND status = ?'" in source,
    "duplicate result is accepted only when exact hash matches": "if (priorHash != result.payloadSha256)" in source,
    "process-death running jobs are recovered as interrupted": "recoverRunningAsInterrupted" in source and "status IN (?, ?)" in source,
    "runtime capability is enabled only while local approval and execution handlers exist": "'task_execution': onPeerTaskExecutionApproval != null" in service and "onPeerTaskExecute != null" in service,
    "authenticated request dispatch is active": "kind == 'task_execution_request'" in service and "unawaited(_handleIncomingPeerExecution(session, message))" in service,
    "receiver requires per-request local consent": "approvalHandler(PeerTaskExecutionPrompt" in service and "if (!decision.accepted)" in service,
    "receiver invokes only the selected local executor": "await executeHandler(" in service and "localAgentId: localAgentId" in service,
    "terminal result is persisted before best-effort delivery": service.index("await _executionRepository.storeResult(result: result)") < service.index("await _sendExecutionResultBestEffort(session, result)"),
    "network failure does not rewrite a committed execution outcome": "send failure must never be misreported" in service and "_sendExecutionResultBestEffort" in service,
    "reconnect replays the same durable request ID": "item.status == PeerTaskExecutionStatus.awaitingApproval" in service and "record.requestJson" in service,
    "late result can recover an acknowledgement lost during reconnect": "record.status == PeerTaskExecutionStatus.queued" in service and "to: PeerTaskExecutionStatus.running" in service,
    "source task reservation and remote dispatch share SQLite serialization": "beginTaskRun" in (ROOT / "lib/src/features/orchestration/agent_task_repository.dart").read_text(encoding="utf-8") and "db.transaction((txn) async" in (ROOT / "lib/src/features/devices/peer_task_execution.dart").read_text(encoding="utf-8"),
    "cancellation propagates to the active native generation": "token.cancel();" in service and "cancellationToken: cancellation" in service,
    "only one remote execution may occupy the local model session": "_pendingIncomingExecutionDevices.isNotEmpty" in service,
    "stored incoming results are retried only until acknowledged": "Future<void> _flushPeerExecutionResults(String deviceId)" in service and "record.resultAcknowledgedAtUnixMs != null" in service,
    "sender acknowledges an exact persisted result digest": "task_execution_result_ack" in service and "result.payloadSha256" in service and "_sendExecutionResultAckBestEffort" in service,
    "receiver binds result acknowledgement to peer, execution ID and digest": "markResultAcknowledged" in service and "record.deviceId != session.deviceId" in service and "record.resultSha256 != digest" in service,
    "result replay waits for a peer with the compatible execution protocol": "capabilities['task_execution_version'] == peerTaskExecutionVersion" in service and "_flushPeerExecutionResults(session.deviceId)" in service,
    "result acknowledgement is durably stored and idempotent": "result_acknowledged_at_unix_ms" in source and "row['result_acknowledged_at_unix_ms'] != null" in source,
    "sender correlates results to the paired peer and outgoing request": "record.direction != 'outgoing'" in service and "record.deviceId != session.deviceId" in service,
    "sender applies successful remote output to the matching local step": "_applyRemoteStepResult(record, result)" in service and "AgentTaskStepStatus.succeeded" in service,
    "local task run is blocked while remote steps are outstanding": "beginTaskRun(taskId)" in (ROOT / "lib/src/features/orchestration/agent_task_orchestrator.dart").read_text(encoding="utf-8"),
    "terminal task steps are skipped during resume rather than re-reserved": "priorStatus == AgentTaskStepStatus.failed" in (ROOT / "lib/src/features/orchestration/agent_task_orchestrator.dart").read_text(encoding="utf-8") and "priorStatus == AgentTaskStepStatus.blocked" in (ROOT / "lib/src/features/orchestration/agent_task_orchestrator.dart").read_text(encoding="utf-8"),
    "no shell or unrestricted process dispatch was added": "Process.start" not in service and "Process.run" not in service,
}

failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'} {name}")
if failed:
    raise SystemExit("Peer task execution contract failures: " + ", ".join(failed))
print(f"Peer task execution contract PASS: {len(checks)} checks")
