#!/usr/bin/env python3
"""Guards the file_picker / secure-storage dependency compatibility fix."""
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
pubspec = yaml.safe_load((ROOT / "pubspec.yaml").read_text(encoding="utf-8"))
dependencies = pubspec["dependencies"]
knowledge = (ROOT / "lib/src/features/knowledge/knowledge_import_service.dart").read_text(encoding="utf-8")
models = (ROOT / "lib/src/features/models/model_import_service.dart").read_text(encoding="utf-8")
integrate = (ROOT / "scripts/integrate_bridge.sh").read_text(encoding="utf-8")

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
    "Flutter build version has advanced without changing Rust ABI crate version": pubspec["version"] == "2.6.2+47",
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

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Pub dependency compatibility failures: " + ", ".join(failed))
print(f"Pub dependency compatibility PASS: {len(checks)} checks")
