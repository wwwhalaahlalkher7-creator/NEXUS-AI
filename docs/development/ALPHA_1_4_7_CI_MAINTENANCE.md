# Alpha 1.4.7 — CI maintenance and non-mutating verification

## Changes

- Pin the hosted runner to `ubuntu-24.04` during active development.
- Update GitHub Actions dependencies to maintained releases: checkout v7,
  cache restore/save v5, setup-java v6, setup-android v4, Gradle setup v6.4.1,
  upload-artifact v7, Flutter action v2.23.0, and rust-cache v2.9.3.
- Keep Temurin Java 17 and the current Flutter/Rust/Android native toolchain
  configuration unchanged.
- Replace mutating Rust formatting with `cargo fmt --all -- --check`.
- Replace mutating Dart formatting with
  `dart format --output=none --set-exit-if-changed lib test`.
- Keep Flutter analysis and Flutter tests as parallel, independently required
  gates. Either failure blocks the APK build.
- Continue building the ARM64 Debug APK during active development.

## Why Debug remains for now

Debug builds are the development/test artifact. The final app must be built as a
signed Release APK after feature development is complete and the final device
smoke tests pass. This change intentionally does not create or rotate signing
keys and does not enable distribution signing prematurely.

## Final Release checklist

1. Create a dedicated Android upload keystore and keep it outside the repo.
2. Store keystore bytes/base64 and passwords as protected GitHub Secrets.
3. Add/enable the release signing configuration without exposing secrets in
   workflow logs or generated files.
4. Build using:
   `flutter build apk --release --no-pub --target-platform android-arm64`.
5. Verify `build/app/outputs/flutter-apk/app-release.apk` exists and is non-empty.
6. Verify the APK includes `lib/arm64-v8a/libnexus_llama_probe.so` and
   `lib/arm64-v8a/libc++_shared.so`.
7. Verify the APK signature with Android build-tools (`apksigner verify`).
8. Upload the final artifact as `nexus-android-arm64-release.apk`.
9. Install the signed Release APK on the target Android device and smoke-test
   launch, navigation, local database initialization, native bridge loading,
   and model-runtime diagnostics.

The intended distribution format is APK. Do not change the final deliverable to
AAB unless the product distribution requirement changes.
