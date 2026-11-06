# Alpha 0.3 — native bridge foundation

## Added in this source batch
- Dedicated `nexus-bridge` Rust crate in the workspace.
- `flutter_rust_bridge` dependencies pinned to 2.13.0.
- API exposing core metadata and a deterministic health check.
- Code-generation configuration and setup scripts.
- Bridge architecture and verification documentation.

## Important limitation
Generated bindings and Android Gradle integration are not fabricated. They must be
produced by the official generator on a machine with Flutter and Rust installed.
The supplied script performs integration and generation.

## Acceptance gate
1. Generator succeeds without manual edits to generated code.
2. Rust workspace tests and formatting pass.
3. Flutter analysis and tests pass.
4. Android native library builds for the phone's ARM64 ABI.
5. Flutter calls `health_check()` and receives the exact Rust response.
6. Flutter reads core metadata from Rust at runtime.

## Deferred
- Moving SQLite repository operations into Rust.
- Model loading and inference.
- Resource telemetry and device networking.
- CI/APK workflows, added after local bridge validation.
