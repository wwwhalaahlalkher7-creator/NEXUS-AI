#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/apps/nexus_app"
command -v flutter_rust_bridge_codegen >/dev/null 2>&1 || {
  echo "ERROR: Install flutter_rust_bridge_codegen 2.13.0 first." >&2
  exit 1
}
flutter_rust_bridge_codegen generate
