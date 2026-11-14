# Alpha 2.8.1 — Verification Repair

## Scope

This patch repairs issues surfaced by the Flutter CI run without weakening either required verification gate.

## Changes

- Corrected the model-fit estimator's BigInt ceiling division so both operands of integer division are BigInt. This preserves overflow-safe arithmetic for large model and KV-cache estimates.
- Made the native runtime status card vertically scrollable. Devices and test viewports with limited height can reach all memory telemetry and the KV-cache action without a RenderFlex overflow.
- Updated the widget test to scroll the card to the KV-cache action before opening the confirmation dialog. The test verifies the full confirmation message and that only the KV cache clear operation is invoked after explicit confirmation.
- Bumped the Flutter package version to `2.8.1+61` while retaining Rust workspace/native ABI version `2.6.2`.
- Updated peer capability metadata to advertise app version `2.8.1`, and synchronized source-contract assertions with the package and ABI versions.

## Verification status

The source changes were inspected and the archive is checked for integrity. Flutter/Dart analysis, Flutter tests, Rust checks, Android NDK compilation, and APK generation were not run in this environment. CI must pass both `flutter analyze --no-pub` and `flutter test --no-pub`; neither gate is bypassed.


## Follow-up verification repair (`2.8.1+61`)

- Added explicit blocks around every single-statement `if` in `device_network_service.dart` to satisfy the strict Flutter analyzer lint gate after CI formatting.
- Corrected the KV cache confirmation widget test to assert the complete dialog text, including its introductory sentence.
- Incremented only the Flutter build number; the app semantic version remains `2.8.1` and the Rust workspace/native ABI remains unchanged.
- Flutter/Dart, Cargo, NDK and device verification are still required in CI.
