# Alpha 2.6.2+46 — Flutter verification fixes

Flutter build metadata: `2.6.2+46`. Rust workspace and bridge ABI remain `2.6.2`.

## Fixes from the GitHub Actions run

- Reworked private IPv4 parsing to accept strict dotted-decimal RFC1918 and IPv4 link-local addresses while rejecting malformed, public, loopback, multicast, out-of-range, and non-canonical leading-zero inputs.
- Normalize decoded QR invitation expirations as UTC `DateTime` values so Unix-millisecond round trips preserve timezone semantics.
- Made the empty inference conversation scrollable and height-aware; short host/widget layouts no longer overflow the available `Expanded` area.
- Migrated resource mode selection from deprecated `RadioListTile.groupValue/onChanged` properties to the `RadioGroup<ResourceMode>` ancestor API.
- Wrapped single-statement flow-control branches in `devices_page.dart` with explicit blocks to clear the three `curly_braces_in_flow_control_structures` analyzer infos.
- Added regression checks for these source contracts and expanded IPv4 validation test cases.

## Verification status

Source-level Python contract checks and archive integrity checks are run before packaging. The latest GitHub log showed 141 Flutter tests passing and three failures; this follow-up addresses the reported protocol, QR time-zone, and inference-layout failures. Flutter analyze/test must be rerun by GitHub Actions to confirm the five analyzer infos and remaining test failures are resolved. APK build remains blocked until both required Flutter gates pass.
