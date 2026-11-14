#!/usr/bin/env python3
"""Install the NEXUS Android battery/thermal telemetry method channel."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android"
MAIN_ACTIVITIES = list(ANDROID.glob("app/src/main/kotlin/**/MainActivity.kt"))
if len(MAIN_ACTIVITIES) != 1:
    raise SystemExit(
        f"Expected exactly one generated MainActivity.kt, found {len(MAIN_ACTIVITIES)}"
    )
activity = MAIN_ACTIVITIES[0]
existing = activity.read_text(encoding="utf-8")
match = re.search(r"(?m)^package\s+([A-Za-z_][A-Za-z0-9_.]*)\s*$", existing)
if match is None:
    raise SystemExit("Could not determine generated Android MainActivity package")
package = match.group(1)

source = f'''package {package}

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {{
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.nexusai/device_telemetry"
        ).setMethodCallHandler {{ call, result ->
            when (call.method) {{
                "readPowerThermal" -> result.success(readPowerThermalSnapshot())
                else -> result.notImplemented()
            }}
        }}
    }}

    private fun readPowerThermalSnapshot(): Map<String, Any?> {{
        val batteryIntent = registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )
        val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val batteryPercent = if (level >= 0 && scale > 0) {{
            (level * 100f / scale).roundToInt().coerceIn(0, 100)
        }} else {{
            null
        }}
        val status = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = when (status) {{
            BatteryManager.BATTERY_STATUS_CHARGING,
            BatteryManager.BATTERY_STATUS_FULL -> true
            BatteryManager.BATTERY_STATUS_DISCHARGING,
            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> false
            else -> null
        }}
        val thermalStatus: Int? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {{
            try {{
                getSystemService(PowerManager::class.java).currentThermalStatus
            }} catch (_: Throwable) {{
                null
            }}
        }} else {{
            null
        }}
        return mapOf(
            "battery_level_percent" to batteryPercent,
            "is_charging" to charging,
            "thermal_status" to thermalStatus
        )
    }}
}}
'''
activity.write_text(source, encoding="utf-8")

written = activity.read_text(encoding="utf-8")
required = (
    'MethodChannel(',
    'com.nexusai/device_telemetry',
    'Intent.ACTION_BATTERY_CHANGED',
    'BatteryManager.EXTRA_LEVEL',
    'PowerManager::class.java',
    'Build.VERSION_CODES.Q',
    '"thermal_status"',
)
missing = [item for item in required if item not in written]
if missing:
    raise SystemExit("Android telemetry host patch is incomplete: " + ", ".join(missing))
print(f"Android battery/thermal telemetry channel patched: {activity.relative_to(ROOT)}")
