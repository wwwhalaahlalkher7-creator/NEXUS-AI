#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

command -v cargo >/dev/null 2>&1 || {
  echo "ERROR: Rust/Cargo is required." >&2
  exit 1
}
command -v flutter >/dev/null 2>&1 || {
  echo "ERROR: Flutter SDK is required." >&2
  exit 1
}

if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
fi

backup_dir="$(mktemp -d)"
trap 'rm -rf "$backup_dir"' EXIT
cp lib/main.dart "$backup_dir/main.dart"
cp pubspec.yaml "$backup_dir/pubspec.yaml"
cp flutter_rust_bridge.yaml "$backup_dir/flutter_rust_bridge.yaml"
cp core/bridge/Cargo.toml "$backup_dir/bridge-Cargo.toml"
cp core/bridge/src/lib.rs "$backup_dir/bridge-lib.rs"
cp -a core/bridge/src/api "$backup_dir/api"

# The integration command creates rust_builder/ and may overlay sample files.
flutter_rust_bridge_codegen integrate \
  --integration-backend cargokit \
  --rust-crate-dir core/bridge

# Restore the real NEXUS application and bridge sources; keep generated Cargokit.
cp "$backup_dir/main.dart" lib/main.dart
cp "$backup_dir/pubspec.yaml" pubspec.yaml
cp "$backup_dir/flutter_rust_bridge.yaml" flutter_rust_bridge.yaml
cp "$backup_dir/bridge-Cargo.toml" core/bridge/Cargo.toml
cp "$backup_dir/bridge-lib.rs" core/bridge/src/lib.rs
rm -rf core/bridge/src/api
cp -a "$backup_dir/api" core/bridge/src/api

test -s rust_builder/pubspec.yaml
grep -Fx 'name: rust_lib_nexus_app' rust_builder/pubspec.yaml
grep -A1 -F '  rust_lib_nexus_app:' pubspec.yaml | grep -F 'path: rust_builder'

flutter pub get
flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
python3 scripts/allow_generated_ffi.py
cargo fmt --all

echo "Bridge integration and code generation commands completed."
