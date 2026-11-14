# Alpha 2.6.2+47 — RadioGroup callback typing fix

Flutter package metadata: `2.6.2+47`. Rust workspace and native ABI remain `2.6.2`.

## CI failure

Flutter 3.47 analysis and widget-test compilation rejected a nullable callback passed to `RadioGroup<ResourceMode>.onChanged`. The expression ` _saving ? null : callback ` had type `void Function(ResourceMode?)?`, while `RadioGroup.onChanged` requires the non-null `ValueChanged<ResourceMode?>` callback.

## Fix

The page always supplies a callback. It ignores updates while `_saving` is true and ignores null values; otherwise it calls `_select(value)`. `_select` retains its own saving and same-value guards, so persistence remains serialized and no overlapping saves are started.

## Verification

The source regression contract now asserts the always-present callback and its in-callback saving/null guard. Re-run GitHub Actions for `flutter analyze` and `flutter test`; this host environment does not include Flutter or Dart, so this source package does not claim those gates have passed.
