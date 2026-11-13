# NEXUS Alpha 1.4.5 — Agent dialog lifecycle and RadioGroup correction

## Reported failures

- Flutter analysis reported deprecated `RadioListTile.groupValue` and
  `RadioListTile.onChanged` usage.
- Agent creation disposed `TextEditingController` instances immediately after
  `showDialog` completed. A route can still be mounted during its reverse
  transition, so the text field could attach to an already disposed controller.
- The creation form could overflow vertically in a constrained dialog.
- A failed local model file audit displayed wording that did not match the
  widget test's verification message.
- Subsequent focus/overlay/build-scope exceptions were observed while tests
  were cleaning up after the failing dialog and menu interactions. These must
  be rechecked in CI after the lifecycle correction.

## Changes

1. Moved creation form controllers and validation into `_CreateAgentDialog`, a
   dedicated `StatefulWidget`. Its `dispose` method owns controller cleanup,
   ensuring cleanup follows widget-route lifetime rather than the `showDialog`
   result future. Added a widget regression test for cancelling the dialog.
2. Enabled scrollable alert-dialog content and removed autofocus to avoid
   forcing a focused editable field through the dialog's teardown transition.
3. Replaced deprecated radio properties with a `RadioGroup<String>` ancestor;
   each `RadioListTile` now supplies only its value and presentation.
4. Aligned the failed file-audit message with the widget test wording.
5. Promoted `flutter analyze --no-pub` to a required CI gate.

## Version

- Flutter package: `1.4.5+19`
- Rust workspace: `1.4.5`

## Verification status

Static source and archive checks can be run locally. Flutter analyzer, widget
tests, Rust tests, and Android APK build must be confirmed by GitHub Actions;
this environment does not contain Flutter or Dart.
