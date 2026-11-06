#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/nexus_app"
command -v cargo >/dev/null 2>&1 || { echo "ERROR: Rust/Cargo is required." >&2; exit 1; }
command -v flutter >/dev/null 2>&1 || { echo "ERROR: Flutter SDK is required." >&2; exit 1; }
if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
fi
cd "$APP_DIR"
flutter pub get
flutter_rust_bridge_codegen integrate --rust-crate-dir ../../core/bridge
flutter_rust_bridge_codegen generate
echo "Bridge integration and code generation commands completed."
echo "Inspect generated Android integration and run the verification checklist before committing."
