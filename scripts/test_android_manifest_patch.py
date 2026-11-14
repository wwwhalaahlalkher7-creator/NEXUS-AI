#!/usr/bin/env python3
"""Exercise the Android manifest patch against a generated-like scaffold."""
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/patch_android_manifest.py"
ANDROID_NS = "http://schemas.android.com/apk/res/android"

with tempfile.TemporaryDirectory(prefix="nexus-android-manifest-") as temporary:
    root = Path(temporary)
    manifest = root / "android/app/src/main/AndroidManifest.xml"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        f'''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="{ANDROID_NS}">
    <application android:label="NEXUS">
    </application>
</manifest>
''',
        encoding="utf-8",
    )

    for _ in range(2):
        subprocess.run([sys.executable, str(SCRIPT)], cwd=root, check=True)

    parsed = ET.parse(manifest).getroot()
    permissions = [node.attrib[f"{{{ANDROID_NS}}}name"] for node in parsed.findall("uses-permission")]
    assert permissions.count("android.permission.INTERNET") == 1
    assert permissions.count("android.permission.ACCESS_NETWORK_STATE") == 1
    assert permissions.count("android.permission.CAMERA") == 1
    camera = parsed.find("uses-feature")
    assert camera is not None
    assert camera.attrib[f"{{{ANDROID_NS}}}name"] == "android.hardware.camera"
    assert camera.attrib[f"{{{ANDROID_NS}}}required"] == "false"
    application = parsed.find("application")
    assert application is not None
    assert application.attrib[f"{{{ANDROID_NS}}}fullBackupContent"] == "@xml/nexus_backup_rules"
    assert application.attrib[f"{{{ANDROID_NS}}}dataExtractionRules"] == "@xml/nexus_data_extraction_rules"

    xml_dir = manifest.parent / "res/xml"
    backup = ET.parse(xml_dir / "nexus_backup_rules.xml").getroot()
    extraction = ET.parse(xml_dir / "nexus_data_extraction_rules.xml").getroot()
    assert backup.tag == "full-backup-content"
    assert extraction.tag == "data-extraction-rules"
    assert backup.find("exclude") is not None
    assert len(extraction.findall("./cloud-backup/exclude")) == 1
    assert len(extraction.findall("./device-transfer/exclude")) == 1

print("Android manifest patch PASS: local-network/camera permissions, optional camera feature, backup rules, XML validity, idempotency")
