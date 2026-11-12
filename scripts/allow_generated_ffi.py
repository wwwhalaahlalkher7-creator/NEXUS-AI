#!/usr/bin/env python3
"""Confine FRB-generated unsafe FFI code to its generated Rust module."""
from pathlib import Path
import re

crate = Path(__file__).resolve().parents[1] / "core" / "bridge" / "src"
lib_rs = crate / "lib.rs"
generated = crate / "frb_generated.rs"

if not generated.is_file() or generated.stat().st_size == 0:
    raise SystemExit("FRB generated Rust module is missing or empty")

text = lib_rs.read_text(encoding="utf-8")
lines = text.splitlines()
pattern = re.compile(r"^(?P<indent>\s*)(?P<visibility>pub(?:\([^)]*\))?\s+)?mod\s+frb_generated\s*;\s*$")
indices = [index for index, line in enumerate(lines) if pattern.match(line)]
if len(indices) > 1:
    raise SystemExit("Multiple frb_generated module declarations found")

if not indices:
    anchor = next((i for i, line in enumerate(lines) if line.strip() == "pub mod api;"), len(lines))
    lines.insert(anchor, "mod frb_generated;")
    module_index = anchor
else:
    module_index = indices[0]

if module_index == 0 or lines[module_index - 1].strip() != "#[allow(unsafe_code)]":
    lines.insert(module_index, "#[allow(unsafe_code)]")

lib_rs.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
print("FRB generated FFI is isolated behind #[allow(unsafe_code)] in frb_generated.")
