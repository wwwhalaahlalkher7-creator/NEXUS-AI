#!/usr/bin/env python3
"""Add required local-network permissions and secure-storage backup rules."""
from pathlib import Path
import re

manifest = Path("android/app/src/main/AndroidManifest.xml")
if not manifest.is_file():
    raise SystemExit("Generated AndroidManifest.xml is missing")
text = manifest.read_text(encoding="utf-8")
required_permissions = (
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.CAMERA",
)
for permission in required_permissions:
    if permission in text:
        continue
    line = f'    <uses-permission android:name="{permission}" />\n'
    match = re.search(r"(?m)^\s*<application\b", text)
    if match is None:
        raise SystemExit("Could not locate application element in Android manifest")
    text = text[:match.start()] + line + text[match.start():]

camera_feature = '<uses-feature android:name="android.hardware.camera" android:required="false" />'
if camera_feature not in text:
    match = re.search(r"(?m)^\s*<application\b", text)
    if match is None:
        raise SystemExit("Could not locate application element for camera feature")
    text = text[:match.start()] + f"    {camera_feature}\n" + text[match.start():]

application = re.search(r"<application\b([^>]*)>", text, re.DOTALL)
if application is None:
    raise SystemExit("Could not parse application element")
attributes = application.group(1)
for name, value in (
    ("android:fullBackupContent", "@xml/nexus_backup_rules"),
    ("android:dataExtractionRules", "@xml/nexus_data_extraction_rules"),
):
    if name in attributes:
        text = re.sub(
            rf'({re.escape(name)}\s*=\s*)"[^"]*"',
            rf'\1"{value}"',
            text,
            count=1,
        )
    else:
        insertion = application.end() - 1
        text = text[:insertion] + f'\n        {name}="{value}"' + text[insertion:]

manifest.write_text(text, encoding="utf-8")
xml_dir = Path("android/app/src/main/res/xml")
xml_dir.mkdir(parents=True, exist_ok=True)
(xml_dir / "nexus_backup_rules.xml").write_text(
    '''<?xml version="1.0" encoding="utf-8"?>
<full-backup-content>
    <!-- Secure-storage keys are device-bound; never restore shared preferences. -->
    <exclude domain="sharedpref" path="." />
</full-backup-content>
''',
    encoding="utf-8",
)
(xml_dir / "nexus_data_extraction_rules.xml").write_text(
    '''<?xml version="1.0" encoding="utf-8"?>
<data-extraction-rules>
    <cloud-backup>
        <exclude domain="sharedpref" path="." />
    </cloud-backup>
    <device-transfer>
        <exclude domain="sharedpref" path="." />
    </device-transfer>
</data-extraction-rules>
''',
    encoding="utf-8",
)
for permission in required_permissions:
    if permission not in text:
        raise SystemExit(f"Failed to add Android permission: {permission}")
if "@xml/nexus_backup_rules" not in text or "@xml/nexus_data_extraction_rules" not in text:
    raise SystemExit("Secure-storage backup rules are not referenced")
print("Android local-network permissions and secure-storage backup exclusions verified")
