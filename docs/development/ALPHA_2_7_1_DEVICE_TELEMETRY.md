# Alpha 2.7.1 — Bounded device telemetry (`2.7.1+53`)

## Scope

This milestone extends the resource snapshot already exchanged by paired peers. It adds measured CPU utilization, Android battery/charging state, and Android thermal status while preserving the previous resource-profile wire contract.

## Measurements

- **CPU:** read the aggregate `cpu` line from `/proc/stat`, wait 400 ms, read it again, and compute `(totalDelta - idleDelta) / totalDelta`. Invalid counters, counter resets, and unavailable procfs data yield `null`.
- **Battery:** Android's sticky `ACTION_BATTERY_CHANGED` intent provides level/scale and status. The level is normalized to 0–100. Charging is true for CHARGING/FULL, false for DISCHARGING/NOT_CHARGING, and null otherwise.
- **Thermal:** `PowerManager.currentThermalStatus` is queried only on Android API 29+. API 28 and unavailable services produce null. The integer status follows Android's 0–6 status enumeration.
- **Memory and cores:** existing `/proc/meminfo` and Dart runtime measurements remain unchanged.

## Transport and compatibility

The capability profile remains wire version 1. Added fields are optional: `cpu_utilization_percent`, `battery_level_percent`, `is_charging`, and `thermal_status`. Older peers continue to parse the original fields; the new peer parser validates each optional value and rejects out-of-range or malformed values. A ten-second local snapshot cache avoids repeating the 400 ms sampling interval for every connected peer.

## Android host integration

The Android project is generated in CI/bootstrap. `scripts/patch_android_telemetry.py` patches the generated `MainActivity.kt` with a read-only method channel named `com.nexusai/device_telemetry`. The patch is idempotent and tested against a generated-like scaffold. No battery permission or external package dependency is required.

## Verification

Source tests cover normal CPU deltas, invalid/reset counters, valid power values, out-of-range power values, and nullable unsupported metrics. Python contract tests check the sampling formula, field bounds, backward-compatible profile version, capability publication, and CI integration. The Android patch test runs twice to verify idempotence.

Still required: Flutter format/analyze/widget tests, Rust gates, FRB generation, Android ARM64 APK build, and on-device verification of battery and thermal values. Thermal status availability and actual thermal behaviour must be checked on physical API 29+ devices; no host-side contract test substitutes for that acceptance.
