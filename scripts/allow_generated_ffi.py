#!/usr/bin/env python3
"""Confine FRB-generated unsafe FFI code to its generated Rust module."""
from pathlib import Path
import os
import re

ROOT = Path(__file__).resolve().parents[1]
crate = Path(os.environ.get("NEXUS_BRIDGE_SRC", ROOT / "core" / "bridge" / "src"))
lib_rs = crate / "lib.rs"
generated = crate / "frb_generated.rs"

if not generated.is_file() or generated.stat().st_size == 0:
    raise SystemExit("FRB generated Rust module is missing or empty")

text = lib_rs.read_text(encoding="utf-8")
lines = text.splitlines()

# FRB may inject a declaration with a trailing explanatory block comment.
# Match that complete line so it is recognized instead of duplicated.
pattern = re.compile(
    r"^(?P<indent>\s*)(?P<visibility>pub(?:\([^)]*\))?\s+)?"
    r"mod\s+frb_generated\s*;"
    r"(?:\s*(?://.*|/\*.*\*/))?\s*$"
)

# Keep crate-level docs before all Rust items. FRB's add_mod_to_lib can
# otherwise put an injected module declaration above these comments.
doc_lines = [line for line in lines if line.lstrip().startswith("//!")]
if doc_lines:
    lines = [line for line in lines if not line.lstrip().startswith("//!")]
    while lines and not lines[0].strip():
        lines.pop(0)
    lines = doc_lines + ([""] if lines else []) + lines

indices = [i for i, line in enumerate(lines) if pattern.match(line)]
if not indices:
    anchor = next(
        (i for i, line in enumerate(lines) if line.strip() == "pub mod api;"),
        len(lines),
    )
    lines.insert(anchor, "mod frb_generated;")
    module_index = anchor
else:
    # FRB owns the first declaration. Remove later duplicates (including
    # declarations left by older versions of this fixer), preserving the
    # original injected comment and declaration visibility.
    module_index = indices[0]
    for duplicate_index in reversed(indices[1:]):
        del lines[duplicate_index]
        if duplicate_index < module_index:
            module_index -= 1

# Put the narrow unsafe allowance directly on the one module declaration.
if module_index == 0 or lines[module_index - 1].strip() != "#[allow(unsafe_code)]":
    lines.insert(module_index, "#[allow(unsafe_code)]")

lib_rs.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
print("FRB generated FFI has one module declaration with a scoped unsafe allowance.")
