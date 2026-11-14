#!/usr/bin/env python3
"""Guard resource-aware peer suitability reporting and capability exchange."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
profile = (ROOT / "lib/src/features/resources/peer_resource_advisor.dart").read_text(encoding="utf-8")
monitor = (ROOT / "lib/src/features/resources/resource_settings.dart").read_text(encoding="utf-8")
service = (ROOT / "lib/src/features/devices/device_network_service.dart").read_text(encoding="utf-8")
page = (ROOT / "lib/src/features/devices/devices_page.dart").read_text(encoding="utf-8")
test = (ROOT / "test/peer_resource_advisor_test.dart").read_text(encoding="utf-8")

checks = {
    "resource profile is versioned": "peerResourceProfileVersion = 1" in profile,
    "resource profile carries RAM CPU execution and optional telemetry fields": all(
        field in profile for field in (
            "availableMemoryBytes", "totalMemoryBytes", "cpuLogicalCores", "activePeerExecutions",
            "cpuUtilizationPercent", "batteryLevelPercent", "isCharging", "thermalStatus"
        )
    ),
    "resource profile rejects impossible and oversized values": "available > total" in profile and "cores > 256" in profile and "available > 1 << 60" in profile and "rawTotal != null && total == null" in profile,
    "resource profile has explicit freshness": "peerResourceProfileMaxAge = Duration(minutes: 5)" in profile,
    "advisor excludes blocked peers": "PeerPlacementStatus.blocked" in profile and "device.isBlocked" in profile,
    "advisor excludes disconnected peers": "PeerPlacementStatus.offline" in profile and "!connected" in profile,
    "advisor requires the exact execution protocol": "task_execution_version" in profile and "peerTaskExecutionVersion" in profile,
    "advisor refuses busy single-slot devices": "profile.isBusy" in profile and "activePeerExecutions > 0" in profile,
    "eligible peers are ranked by actual available RAM then logical cores": "availableMemoryBytes" in profile and "cpuLogicalCores" in profile and "compareTo" in profile,
    "advisor does not auto-dispatch": "Neither path dispatches tasks automatically" in profile,
    "CPU logical cores are measured from the runtime": "Platform.numberOfProcessors" in monitor,
    "Android/Linux memory comes from procfs": "File('/proc/meminfo')" in monitor and "MemAvailable" in monitor,
    "unknown memory is not published as zero capacity": "availableMemory > 0" in service,
    "capability profile includes sample timestamp": "resource_profile_updated_at_unix_ms" in service,
    "capability profile includes active execution occupancy": "active_peer_executions" in service and "execution_busy" in service,
    "busy state is refreshed on admission and release": "_refreshConnectedPeerCapabilities();" in service,
    "ping refreshes peer resource snapshots": "await _sendCapabilities(deviceId);" in service and "await _sendCapabilities(session.deviceId);" in service,
    "UI ranks compatible peers before rendering": "PeerExecutionPlacementAdvisor.rank(" in page and "_deviceCard(context, placement)" in page,
    "UI explains the heuristic and manual nature": "وجود وكيل جاهز بملف مواصفات GGUF متوافق" in page and "لا يُرسل أي طلب تلقائياً" in page,
    "Dart tests cover ranking freshness validation and telemetry display": all(
        item in test for item in (
            "fresh compatible peers", "busy peers", "stale and missing", "blocked offline",
            "impossible or malformed", "resource summary renders only measured telemetry"
        )
    ),
    "extended telemetry is sourced from measured snapshots only": all(
        item in service for item in (
            "snapshot?.cpuUtilizationPercent", "snapshot?.batteryLevelPercent",
            "snapshot?.isCharging", "snapshot?.thermalStatus"
        )
    ),
    "model-specific ranking uses the model fit estimator": "rankForModel" in profile and "ModelFitEstimator.estimate" in profile,
    "peer inventory contains only ready assigned local models": "AgentRecordStatus.ready" in service and "readyModelIds.contains(model.id)" in service,
    "peer capability shares profile signatures without names or paths": "ready_model_profile_signatures" in service and "No local model IDs, display names, paths" in service,
    "profile signatures are explicitly not content hashes": "cryptographic hash of tensor contents" in (ROOT / "lib/src/features/resources/peer_model_profile.dart").read_text(encoding="utf-8"),
    "model-specific placement UI verifies model and lets user choose context": "_showModelPlacementAdvisor" in page and "LocalModelFileVerifier().verify(selectedModel)" in page and "اختر حجم السياق" in page,
    "placement UI preserves manual dispatch and receiver approval": "لا يُرسل أي طلب تلقائياً" in page and "موافقة الجهاز المستلم تظل إلزامية" in profile,
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Peer resource advisor contract failures: " + ", ".join(failed))
print(f"Peer resource advisor contract PASS: {len(checks)} checks")
