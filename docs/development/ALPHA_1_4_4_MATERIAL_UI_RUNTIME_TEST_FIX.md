# NEXUS Alpha 1.4.4 — Material UI dependency and runtime test correction

## 1. Material UI resolution failure

The CI log showed that app and test sources referenced
`package:material_ui/material_ui.dart`, but the root `pubspec.yaml` did not list
`material_ui`. The compiler consequently could not resolve Material symbols,
which cascaded into false-looking errors for `Widget`, `State`, `MaterialApp`,
`Scaffold`, and related APIs.

Correction:

- Declare `material_ui: ^1.11.0` as a direct dependency.
- Migrate every app and widget-test Material import to
  `package:material_ui/material_ui.dart` so legacy and standalone Material
  types are not mixed.
- Read `GlobalMaterialLocalizations.delegates` from `material_ui`; remove the
  now-unneeded direct `flutter_localizations` import and dependency.
- Raise the declared Dart lower bound to 3.13, matching the Material UI package
  toolchain requirement. The manifest declares Flutter 3.47 or newer, and CI uses
  the stable Flutter channel.

## 2. Unavailable runtime test

The test `production unavailable backend never reports a model as loaded`
expects the failure/status message to contain `غير متاح`. The unavailable
backend path correctly kept the state at `readyToLoad` and `isLoaded == false`,
but its message said only that the native load path had not yet been wired.
The implementation now explicitly says the GGUF engine is unavailable until
native loading is connected. The state behavior is unchanged and no model is
falsely reported as loaded. The dashboard also displays its current no-active-model
state explicitly, matching the widget test and avoiding an implied inference claim.

## 3. Release identifiers

- Flutter package: `1.4.4+18`
- Rust workspace: `1.4.4`

## 4. Verification status

Static source checks, manifest checks, workflow YAML parsing, and ZIP integrity
are performed for this package. Flutter, Dart, Cargo, Rust, the Android NDK,
Flutter tests, Rust tests, and APK compilation are not available in this editing
environment. GitHub Actions must confirm dependency resolution, all tests,
analysis, and APK build on the stable Flutter toolchain.


## 5. Retained FRB cleanup hardening

The bridge post-generation helper also removes an orphaned scoped allowance
when deleting a duplicate generated module declaration. This prevents the
attribute from accidentally attaching to the next Rust item.
