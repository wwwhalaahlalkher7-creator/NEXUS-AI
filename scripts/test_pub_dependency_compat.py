#!/usr/bin/env python3
"""Guards the file_picker / secure-storage dependency compatibility fix."""
from pathlib import Path
import re
import yaml

ROOT = Path(__file__).resolve().parents[1]
pubspec = yaml.safe_load((ROOT / "pubspec.yaml").read_text(encoding="utf-8"))
dependencies = pubspec["dependencies"]
knowledge = (ROOT / "lib/src/features/knowledge/knowledge_import_service.dart").read_text(encoding="utf-8")
models = (ROOT / "lib/src/features/models/model_import_service.dart").read_text(encoding="utf-8")
integrate = (ROOT / "scripts/integrate_bridge.sh").read_text(encoding="utf-8")
rust_manifest = (ROOT / "Cargo.toml").read_text(encoding="utf-8")
peer_network = (ROOT / "lib/src/features/devices/device_network_service.dart").read_text(encoding="utf-8")
app_semantic_version = str(pubspec["version"]).split("+", 1)[0]
rust_version_match = re.search(r'(?m)^version = "([0-9]+\.[0-9]+\.[0-9]+)"$', rust_manifest)
rust_version = rust_version_match.group(1) if rust_version_match else None

integration_lines = integrate.splitlines()
integration_index = integration_lines.index(
    "flutter_rust_bridge_codegen integrate \\" 
)

checks = {
    "file_picker uses the v12 federated API line": dependencies.get("file_picker") == "^12.3.0",
    "secure storage remains on the current encrypted implementation": dependencies.get("flutter_secure_storage") == "^11.2.0",
    "knowledge import uses the static single-file picker": "FilePicker.pickFile(" in knowledge and "FilePicker.platform" not in knowledge,
    "knowledge import uses the streamed file API": "readAsByteStream()" in knowledge and "readStream" not in knowledge,
    "knowledge import obtains size through v12 length APIs": "lengthSync() ?? await file.length()" in knowledge and "file.size" not in knowledge,
    "knowledge import remains injectable for tests": "typedef KnowledgeFilePicker" in knowledge and "KnowledgeFilePicker? filePicker" in knowledge,
    "GGUF import uses the v12 static picker": "FilePicker.pickFile(" in models and "FilePicker.platform" not in models,
    "GGUF import consumes one PlatformFile directly": "selected.path" in models and "selected.files" not in models,
    "FRB integration script uses valid shell continuations": integration_lines[integration_index].endswith("\\") and integration_lines[integration_index + 1].endswith("\\"),
    "SelectableText content expression closes only its value group before named arguments": ": content),\n                textDirection: Directionality.of(context)," in (ROOT / "lib/src/features/inference/inference_page.dart").read_text(encoding="utf-8") and ": content)),\n                textDirection: Directionality.of(context)," not in (ROOT / "lib/src/features/inference/inference_page.dart").read_text(encoding="utf-8"),
    "peer app version matches Flutter package while Rust ABI remains 2.6.2": (
        app_semantic_version == "2.8.2"
        and f"'app_version': '{app_semantic_version}'" in peer_network
        and rust_version == "2.6.2"
    ),
    "peer IPv4 parsing rejects non-canonical and out-of-range octets": "part.length > 1 && part.startsWith('0')" in (ROOT / "lib/src/features/devices/peer_protocol.dart").read_text(encoding="utf-8") and "value > 255" in (ROOT / "lib/src/features/devices/peer_protocol.dart").read_text(encoding="utf-8"),
    "pairing invitation expiry is normalized to UTC": "DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true)" in (ROOT / "lib/src/features/devices/peer_discovery.dart").read_text(encoding="utf-8"),
    "empty conversation remains scrollable in short layouts": "SingleChildScrollView" in (ROOT / "lib/src/features/inference/inference_page.dart").read_text(encoding="utf-8") and "BoxConstraints(minHeight: constraints.maxHeight)" in (ROOT / "lib/src/features/inference/inference_page.dart").read_text(encoding="utf-8"),
    "resource mode radios use RadioGroup with a non-null guarded callback": (
        "RadioGroup<ResourceMode>(" in (ROOT / "lib/src/features/resources/resource_settings_page.dart").read_text(encoding="utf-8")
        and "onChanged: (value) {" in (ROOT / "lib/src/features/resources/resource_settings_page.dart").read_text(encoding="utf-8")
        and "if (!_saving && value != null)" in (ROOT / "lib/src/features/resources/resource_settings_page.dart").read_text(encoding="utf-8")
        and "onChanged: _saving" not in (ROOT / "lib/src/features/resources/resource_settings_page.dart").read_text(encoding="utf-8")
    ),
    "device-page flow control uses explicit blocks": not any("if (mounted) setState(" in line or "if (!mounted) return;" in line for line in (ROOT / "lib/src/features/devices/devices_page.dart").read_text(encoding="utf-8").splitlines()),
}

checks.update({
    "approved peer proposals can be remapped to local agent IDs": "class RemoteTaskPlanRemapper" in (ROOT / "lib/src/features/devices/peer_task_transfer.dart").read_text(encoding="utf-8") and "localAgentByRemoteId" in (ROOT / "lib/src/features/devices/peer_task_transfer.dart").read_text(encoding="utf-8"),
    "peer proposal import commits task and source reference inside one transaction": "importIncomingAsLocalTask" in (ROOT / "lib/src/features/devices/peer_task_transfer.dart").read_text(encoding="utf-8") and "db.transaction((txn) async" in (ROOT / "lib/src/features/devices/peer_task_transfer.dart").read_text(encoding="utf-8") and "imported_task_id" in (ROOT / "lib/src/features/devices/peer_task_transfer.dart").read_text(encoding="utf-8"),
    "device UI requires explicit local agent mapping before import": "_chooseLocalAgentMappings" in (ROOT / "lib/src/features/devices/devices_page.dart").read_text(encoding="utf-8") and "تأكيد التعيين والاستيراد" in (ROOT / "lib/src/features/devices/devices_page.dart").read_text(encoding="utf-8"),
    "peer capability snapshot reports the current Alpha 2.8.2 app version": f"'app_version': '{app_semantic_version}'" in peer_network,
})

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Pub dependency compatibility failures: " + ", ".join(failed))
print(f"Pub dependency compatibility PASS: {len(checks)} checks")
