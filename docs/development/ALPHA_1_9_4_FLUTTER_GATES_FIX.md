# Alpha 1.9.4 — Flutter verification fixes

## CI failures addressed

- Added explicit blocks to the two `if` statements reported by `flutter analyze` in the inference page.
- Made the generation-limit dropdown expand within its allocated width and increased its compact field width to avoid a `RenderFlex` overflow in widget tests.
- Updated dashboard tests to assert the current model-session wording rather than removed legacy copy.
- Made dashboard tests scroll the `ListView` until the session summary is visible before asserting load/unload state.
- Updated the app-shell widget test to verify the current `لا يوجد نموذج محمّل` state.
- Updated dashboard milestone copy from the historical Alpha 1.7 description to the implemented Alpha 1.9 multi-turn context capability.

## Verification policy

The CI workflow still runs `flutter analyze --no-pub` and `flutter test --no-pub` concurrently and blocks the APK build if either command fails. No verification gate was disabled or softened.

The local source package is statically inspected only; the GitHub Actions run is required to confirm Dart analysis, Flutter widget tests, and the Android build.
