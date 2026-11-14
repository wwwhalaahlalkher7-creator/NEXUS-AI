#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

command -v flutter >/dev/null 2>&1 || {
  echo "ERROR: Flutter SDK is not installed or not on PATH." >&2
  exit 1
}
command -v cargo >/dev/null 2>&1 || {
  echo "ERROR: Rust/Cargo is not installed or not on PATH." >&2
  exit 1
}

if [[ ! -d android ]]; then
  echo "Generating the Android platform scaffold..."
  flutter create --platforms=android --project-name nexus_app .
fi

# Keep local Android permissions aligned with the CI-generated scaffold.
python3 scripts/patch_android_manifest.py

echo "Integrating Flutter Rust Bridge and resolving dependencies..."
bash scripts/integrate_bridge.sh

echo "Checking Rust formatting..."
cargo fmt --all -- --check

echo "Running Rust tests..."
cargo test --workspace

echo "Bootstrap checks completed."
