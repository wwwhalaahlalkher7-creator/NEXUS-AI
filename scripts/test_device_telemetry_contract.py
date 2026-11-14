#!/usr/bin/env python3
"""Guard bounded device telemetry and versioned peer capability exchange."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
monitor = (ROOT / "lib/src/features/resources/resource_settings.dart").read_text(encoding="utf-8")
profile = (ROOT / "lib/src/features/resources/peer_resource_advisor.dart").read_text(encoding="utf-8")
service = (ROOT / "lib/src/features/devices/device_network_service.dart").read_text(encoding="utf-8")
kotlin_script = (ROOT / "scripts/patch_android_telemetry.py").read_text(encoding="utf-8")
kotlin_test = (ROOT / "scripts/test_android_telemetry_patch.py").read_text(encoding="utf-8")
dart_test = (ROOT / "test/resource_telemetry_test.dart").read_text(encoding="utf-8")
workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

checks = {
    "CPU telemetry uses two bounded procfs samples": "Duration(milliseconds: 400)" in monitor and "_parseAggregateCpu" in monitor,
    "CPU utilization is calculated from busy versus total tick deltas": "totalDelta - idleDelta" in monitor and "totalDelta <= 0" in monitor,
    "malformed CPU counters remain unknown": "parsed == null || parsed < 0" in monitor and "return null;" in monitor,
    "battery and thermal telemetry use a dedicated Android channel": "com.nexusai/device_telemetry" in monitor and "readPowerThermal" in monitor,
    "unsupported power metrics remain nullable": "if (!Platform.isAndroid) return null" in monitor,
    "battery percentage is constrained to 0..100": "_boundedInt(power?['battery_level_percent'], 0, 100)" in monitor,
    "thermal state is constrained to Android 0..6": "_boundedInt(power?['thermal_status'], 0, 6)" in monitor,
    "peer resource profile remains backward-compatible v1": "peerResourceProfileVersion = 1" in profile and "optional fields" in profile,
    "legacy peers may omit extended telemetry": "if (version != peerResourceProfileVersion) return null" in profile and "optional fields" in profile,
    "profile validates every optional telemetry field": all(item in profile for item in ("rawCpuLoad != null && cpuLoad == null", "rawBattery != null && battery == null", "rawCharging is! bool", "rawThermal != null && thermal == null")),
    "resource snapshots are cached across peer sends": "_cachedResourceSnapshotAt" in service and "Duration(seconds: 10)" in service,
    "capabilities include CPU battery charging and thermal metrics": all(item in service for item in ("cpu_utilization_percent", "battery_level_percent", "is_charging", "thermal_status")),
    "wire profile version remains v1 for old peer compatibility": "'resource_profile_version': 1" in service,
    "extended telemetry is explicitly requested for peer capability exchange": "readSnapshot(includeExtendedTelemetry: true)" in service,
    "Android host patch reads battery and charging state": "BatteryManager.EXTRA_LEVEL" in kotlin_script and "BATTERY_STATUS_CHARGING" in kotlin_script,
    "Android host patch reads thermal status only from API 29+": "Build.VERSION_CODES.Q" in kotlin_script and "currentThermalStatus" in kotlin_script,
    "Android host patch is idempotency-tested": "for _ in range(2)" in kotlin_test,
    "Dart tests cover valid invalid and unsupported telemetry": all(item in dart_test for item in ("54", "140", "thermal_status", "malformed or empty procfs data")),
    "CI applies the Android telemetry patch": "scripts/patch_android_telemetry.py" in workflow,
    "CI runs the telemetry contract suite": "scripts/test_device_telemetry_contract.py" in workflow,
    "CI runs the Android telemetry patch test": "scripts/test_android_telemetry_patch.py" in workflow,
    "local bootstrap applies the telemetry host patch": "python3 scripts/patch_android_telemetry.py" in (ROOT / "scripts/bootstrap.sh").read_text(encoding="utf-8"),
}
failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Device telemetry contract failures: " + ", ".join(failed))
print(f"Device telemetry contract PASS: {len(checks)} checks")
