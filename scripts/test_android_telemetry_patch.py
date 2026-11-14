#!/usr/bin/env python3
"""Verify generated Android host telemetry patch and idempotency."""
from pathlib import Path
import subprocess
import sys
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/patch_android_telemetry.py"
with tempfile.TemporaryDirectory(prefix="nexus-android-telemetry-") as temporary:
    root = Path(temporary)
    scripts = root / "scripts"
    scripts.mkdir(parents=True)
    local_script = scripts / "patch_android_telemetry.py"
    local_script.write_text(SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
    activity = root / "android/app/src/main/kotlin/com/nexusai/nexus_app/MainActivity.kt"
    activity.parent.mkdir(parents=True)
    activity.write_text(
        "package com.nexusai.nexus_app\n\n"
        "import io.flutter.embedding.android.FlutterActivity\n\n"
        "class MainActivity : FlutterActivity()\n",
        encoding="utf-8",
    )
    for _ in range(2):
        subprocess.run([sys.executable, str(local_script)], cwd=root, check=True)
    patched = activity.read_text(encoding="utf-8")
    assert patched.count("class MainActivity") == 1
    assert "readPowerThermal" in patched
    assert "BATTERY_STATUS_CHARGING" in patched
    assert "currentThermalStatus" in patched
    assert "Build.VERSION_CODES.Q" in patched

print("Android telemetry patch PASS: battery/charging/thermal channel and repeatability")
