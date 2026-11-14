# Alpha 2.1.1 — Agent model routing and protected native sessions

## Scope

This milestone extends Alpha 2.0's agent personas and conversation binding with an explicit one-model-at-a-time routing path.

- The model library offers an explicit, user-confirmed switch to another installed GGUF model.
- The target model is verified before the current session is touched.
- The previous native session is unloaded before the target is loaded.
- If target loading fails, the manager attempts to restore the previous model and its prior context size.
- If cleanup or rollback cannot be confirmed, the manager enters `recoveryRequired`; generation is blocked and the model library exposes an explicit unload/recovery action.
- A generation lease is acquired synchronously before the inference flow performs asynchronous persistence and bridge setup. Lifecycle operations are blocked until the native stream reaches a terminal event or error.
- Manager operations remain mutually exclusive; overlapping requests are rejected rather than allowed to race the process-global llama.cpp session.

## State contract

- `idle`: no session is claimed active.
- `checking`: target file and policy are being checked; this does not claim the native model was loaded.
- `readyToLoad`: preflight succeeded; native weights are not loaded.
- `loading`: native load is in progress.
- `loaded`: a model load succeeded and returned a context within the configured policy.
- `switching`: the current session is being replaced; inference cannot start.
- `unloading`: cleanup is in progress.
- `recoveryRequired`: native session state could not be confirmed; generation is blocked and explicit unload is required.
- `failed`: the last requested operation failed without claiming a loaded session.

## Safety boundaries

- The manager owns one active model record and one native session.
- A failed target-file verification leaves the current loaded model untouched.
- A failed unload prevents the target load from starting.
- A failed target load triggers rollback when a previous model existed.
- A failed rollback does not report the previous model as loaded.
- `beginGeneration()` is synchronous and requires a loaded model; `endGeneration()` is idempotent.
- The backend's native memory preflight remains authoritative. File-size and context policy checks are additional conservative gates, not proof that RAM is sufficient.

## Tests added

`test/model_runtime_manager_test.dart` covers successful switching, target preflight rejection without unloading, target load rollback, recovery-required cleanup, and generation-lease protection. `test/conversation_context_builder_test.dart` also verifies that the selected agent persona survives trimming of older turns. Existing load/unload, context bounds, backend failure, and operation-overlap tests remain in place.

## Verification limitations

Host-side fake backend tests do not prove Android memory behavior or real llama.cpp restoration. CI must still pass Dart formatting, Flutter analysis/tests, Rust formatting/tests/Clippy, and Android ARM64 Debug packaging. A physical device must verify real GGUF load, switch, rollback after a controlled failure, generation cancellation, and recovery unload.
