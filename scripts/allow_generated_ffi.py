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

# FRB's `add_mod_to_lib` can prepend `mod frb_generated;` to lib.rs.
# If the source file starts with crate-level `//!` documentation, that
# insertion moves the docs below a Rust item and causes E0753. Keep every
# crate-level line doc at the top before adding the module-scoped allow.
crate_doc_lines = [line for line in lines if line.lstrip().startswith("//!")]
if crate_doc_lines:
    lines = [line for line in lines if not line.lstrip().startswith("//!")]
    while lines and not lines[0].strip():
        lines.pop(0)
    lines = crate_doc_lines + ([""] if lines else []) + lines

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
