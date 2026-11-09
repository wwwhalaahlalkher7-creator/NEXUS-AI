# Model runtime adapter

## Current status — Alpha 0.8
The Flutter application now reaches the Rust core through Flutter Rust Bridge and reads a runtime diagnostics snapshot. The bridge reports that inference is unavailable because no native inference backend is attached.

## Planned llama.cpp adapter contract
- Discover whether the native backend is available on this ABI.
- Validate a model file and its metadata before loading.
- Load/unload with explicit memory and context limits.
- Report lifecycle state only after backend confirmation.
- Stream generated tokens and support cancellation.
- Surface structured errors without exposing filesystem paths unnecessarily.

GGUF files can be imported and their bounded metadata directory inspected in Alpha 0.8. No model is loaded or executed.
