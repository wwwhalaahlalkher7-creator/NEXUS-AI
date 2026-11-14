# Alpha 2.7.5 — Local benchmark harness (`2.7.5+57`)

## Purpose

Provide a repeatable, user-initiated local benchmark for an installed GGUF model. The benchmark is diagnostic, not a promise that a different device or future run will produce the same numbers.

## Run sequence

1. Require Android native inference availability and an installed local `llamaCpp` model.
2. Refuse to run while the runtime manager is busy, generating, loaded with another session, or marked `recoveryRequired`. The runner never silently switches a session that the user already has active.
3. Capture the initial process/device telemetry snapshot.
4. Prepare and measure the first app-managed model load.
5. Unload, prepare again, and measure a repeat load. Android cannot reliably flush Linux page cache without elevated privileges; this second result may be warm from OS file caching and is therefore labelled repeat load, not a guaranteed warm-cache or cold-cache timing.
6. Generate one short warm-up response and exclude it from throughput.
7. Generate two measured responses. Aggregate actual token counts and elapsed wall time; `tokens/s = total generated tokens / total measured seconds`.
8. Run a separate long-output cancellation probe. Record cancellation latency only when the native adapter accepts the cancellation and the stream reports terminal cancellation. If generation completes before the timer, keep this metric unavailable.
9. Sample telemetry during/after stages. Persist any readable process-wide RSS high-water mark, thermal status, battery percent, runtime version and the model/runtime configuration.
10. Release the generation lease and unload only after the native stream reaches a terminal event. If the three-minute generation timeout fires, request cancellation and wait up to 30 additional seconds. If no terminal event arrives, retain the lease, skip unload and persist a partial/failed run; the user must restart the app to restore a known-safe process.

## Metric definitions and caveats

- **First load:** elapsed time around the first load after this benchmark begins. It is not guaranteed to be a cold OS file-cache load.
- **Repeat load:** elapsed time around the second app-managed load after unloading the first. It can benefit from OS page cache; it is not guaranteed to be a warm cache in every environment.
- **Tokens/s:** actual emitted tokens divided by wall-clock generation time for the measured passes; warm-up and cancellation run are excluded.
- **VmHWM:** process-wide `/proc/self/status` high-water mark since app process start. It includes Flutter, Rust, llama.cpp and other libraries; it is neither a model-only allocation nor an incremental peak attributable to this benchmark.
- **Cancellation latency:** time from accepted native cancellation request until the terminal stream result. If cancellation was not accepted or the run completed first, the metric is null.
- **Thermal/battery:** endpoint and sampled status readings exposed by the OS. No Celsius temperature is inferred from Android thermal status; unavailable values remain null.

## Persistence

SQLite schema v15 adds `benchmark_runs`. Model references are intentionally not foreign keys, so run history survives deletion of a model catalog row. The table stores model metadata, context/thread settings, timing/throughput, process peak RSS, cancellation outcome, thermal/battery readings, runtime version, run status and error detail.

## Safety and UX

- The user explicitly confirms before running because the suite loads a model and performs CPU-intensive generation that can consume battery and raise device temperature.
- The current loaded model is never silently unloaded or replaced; the runner requires an idle session.
- The benchmark model is unloaded at the end only after native generation has reached a terminal state. A missing terminal event after the cancellation drain keeps the generation lease held and intentionally skips native unload.
- The benchmark page remains accessible from the model library, displays actual context/thread values returned by the runtime, and displays unavailable metrics as unavailable, never as zero or a fabricated estimate. It labels VmHWM as a process-lifetime watermark.

## Verification included

- Pure Dart tests for throughput calculation, missing telemetry, and record round-trip.
- Python SQLite v15 migration execution and constraints test.
- Python source contract checks for load labels, generation lease cleanup, cancellation semantics, process-wide RSS caveat, user confirmation, model-session guard and UI discoverability.

## Still required

- `dart format`, `flutter analyze`, `flutter test`, Rust workspace tests/Clippy, FRB generation and Android NDK build in GitHub Actions.
- Physical Android runs on multiple representative devices to establish repeatability and sustained thermal behaviour.
- A later placement milestone must not use benchmark values as guaranteed capability; benchmark age, model/context identity, thermal state and current free memory must be considered.
