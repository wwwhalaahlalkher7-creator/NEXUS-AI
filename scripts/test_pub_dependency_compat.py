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
    "Flutter build version has advanced without changing Rust ABI crate version": pubspec["version"] == "2.6.2+44",
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Pub dependency compatibility failures: " + ", ".join(failed))
print(f"Pub dependency compatibility PASS: {len(checks)} checks")
