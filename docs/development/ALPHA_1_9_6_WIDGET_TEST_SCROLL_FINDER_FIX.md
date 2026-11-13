# Alpha 1.9.6 — Widget test scroll finder correction

## Reported failure

GitHub Actions continued to report `Undefined name 'Scrollable'` in `test/widget_test.dart` even though Alpha 1.9.5 added an explicit import. This left both `flutter analyze` and test compilation blocked.

## Change

- Removed the direct `Scrollable` import and `find.byType(Scrollable)` argument from the dashboard shell widget test.
- Kept `WidgetTester.scrollUntilVisible` and its default scrollable selection. Flutter Test resolves the default scrollable finder internally.
- Preserved all existing assertions and the Alpha 1.9.5 inference-page lint corrections.
- Bumped Flutter package version to `1.9.6+32` and Rust workspace version to `1.9.6`.

## CI policy

`flutter analyze --no-pub` and `flutter test --no-pub` remain required parallel gates. Any failure blocks APK packaging. No check is skipped or weakened.

## Validation boundary

The source-level correction and archive integrity are checked before delivery. Flutter analysis, widget execution, Rust validation, and Android APK compilation must still be confirmed by GitHub Actions.
