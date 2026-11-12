# Alpha 1.1 — Local model assignment

## Included
- Agents can be linked to a locally installed `llama.cpp` model.
- The picker only lists records marked installed with a non-empty app-local path.
- The selected model ID is persisted in the existing `agents.model_id` SQLite column.
- A user can remove an existing assignment.
- Assignment is explicitly metadata/configuration; it does not load the model or run inference.

## Not included
- Automatic model loading, inference, generation, tool execution, or background agents.
- Remote model assignment or network device pairing.
- Deep verification of tensor payloads or proof that a model fits device memory.

## Validation expectation
GitHub Actions remains authoritative for Flutter tests, Rust tests/Clippy, and Android debug APK compilation. This environment does not contain Flutter, Dart, or Cargo, so those commands were not executed locally.
