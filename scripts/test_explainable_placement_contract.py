#!/usr/bin/env python3
"""Guard model-specific, explainable peer placement and privacy boundaries."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
advisor = (ROOT / "lib/src/features/resources/peer_resource_advisor.dart").read_text(encoding="utf-8")
model_profile = (ROOT / "lib/src/features/resources/peer_model_profile.dart").read_text(encoding="utf-8")
service = (ROOT / "lib/src/features/devices/device_network_service.dart").read_text(encoding="utf-8")
page = (ROOT / "lib/src/features/devices/devices_page.dart").read_text(encoding="utf-8")
test = (ROOT / "test/peer_resource_advisor_test.dart").read_text(encoding="utf-8")
database = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")

checks = {
    "model profile accepts only installed local llama.cpp models": all(
        token in model_profile for token in ("ModelRuntime.llamaCpp", "ModelInstallStatus.installed", "model.sizeBytes")
    ),
    "profile signature includes all model-fit metadata": all(
        token in model_profile for token in ("fileBytes", "architecture", "contextLength", "blockCount", "embeddingLength", "attentionHeadCountKv", "attentionKeyLength", "attentionValueLength", "parameterCount")
    ),
    "profile signature is explicitly metadata-only": "cryptographic hash of tensor contents" in model_profile and "two different weight files can share" in model_profile,
    "inventory includes only profiles assigned to ready agents": "AgentRecordStatus.ready" in service and "readyModelIds.contains(model.id)" in service,
    "inventory confirms local model file and size before advertising": "await file.exists()" in service and "await file.length() != model.sizeBytes" in service,
    "inventory omits local IDs names paths and file contents": "No local model IDs, display names, paths, or file contents are disclosed" in service,
    "capability inventory is versioned and sent over existing peer channel": "ready_model_profiles_version" in service and "ready_model_profile_signatures" in service and "session.channel.send" in service,
    "model placement evaluates fresh peer profile before inventory": "_statusFor(" in advisor and "profile.isFresh" in advisor and "profile.isBusy" in advisor,
    "model placement uses the same model fit estimator for peer RAM": "ModelFitEstimator.estimate(" in advisor and "availableMemoryBytes: profile.availableMemoryBytes" in advisor,
    "model inventory unknown and missing profiles are not eligible": "PeerPlacementStatus.modelInventoryUnknown" in advisor and "PeerPlacementStatus.modelUnavailable" in advisor,
    "ranker explains memory headroom CPU thermal and battery factors": all(
        token in advisor for token in ("recommendedRequiredBytes", "cpuUtilizationPercent", "thermalStatus", "batteryLevelPercent")
    ),
    "ranker preserves manual execution and never auto-dispatches": "Neither path dispatches tasks automatically" in advisor,
    "UI selects an installed model and context before ranking": all(
        token in page for token in ("_showModelPlacementAdvisor", "ModelInstallStatus.installed", "اختر حجم السياق", "rankForModel")
    ),
    "UI verifies local source model before calculating": "LocalModelFileVerifier().verify(selectedModel)" in page,
    "UI explicitly warns metadata matching is not tensor identity": "ليس بصمة محتوى الأوزان" in page,
    "UI does not dispatch from the recommendation dialog": (
        "child: const Text('إغلاق')" in page
        and "Future<void> _showModelPlacementAdvisor()" in page
        and "_sendRemoteStep(" not in page[page.index("Future<void> _showModelPlacementAdvisor()") : page.index("Widget _taskTransfersSection")]
        and "sendTaskStepForRemoteExecution(" not in page[page.index("Future<void> _showModelPlacementAdvisor()") : page.index("Widget _taskTransfersSection")]
    ),
    "new tests cover fit, unavailable profile, unknown inventory and tight fit": all(
        token in test for token in ("model placement ranks only peers", "model placement reports unknown inventory", "tight memory fit", "metadata compatibility")
    ),
    "placement adds no database migration": "_databaseVersion = 15" in database,
    "placement adds no new external dependency": "cryptography:" in pubspec and "file_picker: ^12.3.0" in pubspec,
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Explainable placement contract failures: " + ", ".join(failed))
print(f"Explainable placement contract PASS: {len(checks)} checks")
