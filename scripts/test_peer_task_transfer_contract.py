#!/usr/bin/env python3
"""Static contracts for authenticated, durable, review-only peer task transfer."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
service = (ROOT / "lib/src/features/devices/device_network_service.dart").read_text(encoding="utf-8")
protocol = (ROOT / "lib/src/features/devices/peer_task_transfer.dart").read_text(encoding="utf-8")
page = (ROOT / "lib/src/features/devices/devices_page.dart").read_text(encoding="utf-8")
manifest = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
readme = (ROOT / "README.md").read_text(encoding="utf-8")

checks = {
    "only explicitly paired non-blocked peers can receive proposals": "device == null || device.isBlocked" in service and "repository.get(deviceId)" in service,
    "peer must advertise the exact task-transfer protocol version": "device.capabilities['task_transfer'] != true" in service and "device.capabilities['task_transfer_version'] != peerTaskTransferVersion" in service,
    "only planned tasks are eligible for outgoing proposals": "task.status.name != 'planned'" in service,
    "task payload hash uses SHA-256 and constant-time comparison": "Sha256().hash" in protocol and "_constantTimeStringEquals(actualHash, suppliedHash)" in protocol,
    "proposal validates JSON structure, step IDs and dependencies": all(value in protocol for value in ("schema_version", "dependencies[id]", "مخطط المهمة يحتوي دورة اعتماد", "اعتماد غير موجود")),
    "proposal data is frame-bounded": "peerTaskProposalMaximumBytes = 512 * 1024" in protocol and "peerMaximumFrameBytes" in (ROOT / "lib/src/features/devices/peer_protocol.dart").read_text(encoding="utf-8"),
    "outgoing messages use existing encrypted sequenced peer channel": "session.channel.send(envelope.toMessage())" in service and "AesGcm.with256bits()" in (ROOT / "lib/src/features/devices/peer_protocol.dart").read_text(encoding="utf-8"),
    "receiver requires a per-transfer user decision before persistence": "onTaskProposalRequest" in service and "if (approved == null)" in service and service.index("if (approved == null)") < service.index("storeIncoming(", service.index("Future<void> _handleIncomingTaskProposal")),
    "new incoming record is committed before positive acknowledgement": service.index("storeIncoming(", service.index("Future<void> _handleIncomingTaskProposal")) < service.index("'accepted': true", service.index("storeIncoming(", service.index("Future<void> _handleIncomingTaskProposal"))),
    "duplicate transfer IDs are deduplicated and payload conflicts rejected": "existing['payload_sha256'] != envelope.payloadSha256" in protocol and "return false" in protocol,
    "sender waits for a peer-bound correlated acknowledgement": "_pendingTaskAcks[transferId]" in service and "completer.future.timeout" in service and "expectedDeviceId == session.deviceId" in service,
    "outbox survives disconnection and retries after peer capability negotiation": "status: 'queued'" in service and "_flushQueuedTaskTransfers(deviceId)" in service and "retryQueuedTaskTransfers" in service and "capabilities['task_transfer_version'] == peerTaskTransferVersion" in service,
    "incoming proposals are consent-only and never auto-executed": "لم يتم تشغيله" in service and "لا يتم استيراد الوكلاء أو تشغيل الخطوات" in page and "onTaskProposalRequest = _confirmIncomingTaskProposal" in page,
    "consent dialog has explicit accept, reject and expiry outcomes": "Navigator.of(dialogContext).pop(false)" in page and "Navigator.of(dialogContext).pop(true)" in page and "Duration(seconds: 60)" in page,
    "recipient stores accepted proposals in kept state": "decision = 'kept'" in protocol and "transfer.status == 'kept'" in page,
    "explicit rejection is persisted and duplicate requests are not re-prompted": "decision: approved ? 'kept' : 'declined'" in service and "existing.status == 'declined'" in service and "سبق أن رفض المستخدم هذا المقترح" in service,
    "only one consent dialog per paired peer can be pending": "_pendingIncomingTaskPrompts.add(session.deviceId)" in service and "_pendingIncomingTaskPrompts.remove(session.deviceId)" in service,
    "paired and non-blocked state is rechecked before storing": service.count("repository.get(session.deviceId)") >= 2 and "أُزيل الاقتران أو حُظر الجهاز أثناء المراجعة" in service,
    "permanent rejection is not accidentally re-queued": "permanentlyRejected" in service and "status: permanentFailure ? 'rejected' : 'queued'" in service and "if (!permanentlyRejected)" in service,
    "capabilities retain proposal transport while execution is dynamically gated": "'task_transfer': true" in service and "'task_execution': onPeerTaskExecutionApproval != null &&" in service and "onPeerTaskExecute != null" in service,
    "transport records are tied to paired-device lifecycle": "REFERENCES paired_devices(id) ON DELETE CASCADE" in manifest,
    "SQLite v11 import migration is included on create and upgrade": "static const _databaseVersion = 15" in manifest and "await _upgradeV11RemoteTaskImport(db);" in manifest and "if (oldVersion < 10)" in manifest and "if (oldVersion < 11)" in manifest and "'declined', 'rejected'" in manifest and "imported_task_id" in manifest,
    "UI refreshes on accepted, declined and rejected transfer outcomes": all(value in page for value in ("DeviceNetworkEventType.taskProposalReceived", "DeviceNetworkEventType.taskProposalSent", "DeviceNetworkEventType.taskProposalDeclined", "DeviceNetworkEventType.taskProposalRejected")),
}
failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Peer task transfer contract failures: " + ", ".join(failed))
print(f"Peer task transfer contract PASS: {len(checks)} checks")
