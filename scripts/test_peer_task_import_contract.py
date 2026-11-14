#!/usr/bin/env python3
"""Guard explicit, idempotent import of accepted peer proposals."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
transfer = (ROOT / "lib/src/features/devices/peer_task_transfer.dart").read_text(encoding="utf-8")
service = (ROOT / "lib/src/features/devices/device_network_service.dart").read_text(encoding="utf-8")
page = (ROOT / "lib/src/features/devices/devices_page.dart").read_text(encoding="utf-8")
checks = {
    "only incoming kept proposals can be imported": "transfer['direction'] != 'incoming' || transfer['status'] != 'kept'" in transfer,
    "goal must match before import": "transfer['goal'] != plan.goal.trim()" in transfer,
    "agent assignment is revalidated as ready inside SQLite transaction": "status = ?" in transfer and "mappedAgentIds.any((id) => !readyAgentIds.contains(id))" in transfer,
    "import creates a local planned task and pending steps": "AgentTaskStatus.planned.name" in transfer and "AgentTaskStepStatus.pending.name" in transfer,
    "import records source provenance in task event": "peer_proposal_imported" in transfer and "source_device_id" in transfer,
    "repeated import returns original local task ID": "if (existingTask.isNotEmpty) return importedTaskId" in transfer,
    "local task creation and transfer reference share one transaction": "importIncomingAsLocalTask" in transfer and "db.transaction((txn) async" in transfer and "imported_task_id" in transfer,
    "network service exposes import operation": "importTaskProposal" in service,
    "UI only imports after manual local agent mapping": "_chooseLocalAgentMappings" in page and "RemoteTaskPlanRemapper.remap" in page,
    "import never auto-executes the task": "لم يبدأ التنفيذ" in transfer and "لا يبدأ التنفيذ تلقائياً" not in page,
}
for name, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'} {name}")
failed = [name for name, ok in checks.items() if not ok]
if failed:
    raise SystemExit("Peer task import contract failures: " + ", ".join(failed))
print(f"Peer task import contract PASS: {len(checks)} checks")
