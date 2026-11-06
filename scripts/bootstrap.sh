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

echo "Fetching Flutter dependencies..."
flutter pub get

echo "Checking Rust formatting..."
cargo fmt --all -- --check

echo "Running Rust tests..."
cargo test --workspace

echo "Bootstrap checks completed."
