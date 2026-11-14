# Alpha 2.7.2 — GGUF model-fit estimator (`2.7.2+54`)

## Scope

This milestone adds a local, advisory memory estimate for an already imported and verified single-file GGUF model. It does not load weights, execute inference, auto-select a peer, or change a runtime session.

## GGUF metadata

The bounded Rust GGUF metadata reader now extracts architecture-prefixed numeric values for:

- `<architecture>.attention.head_count`
- `<architecture>.attention.head_count_kv`
- `<architecture>.attention.key_length`
- `<architecture>.attention.value_length`

These values are returned through the FRB `GgufInspectionDto`, stored in `ModelRecord`, and persisted in SQLite schema v14. Existing records migrate with all four fields set to `NULL`; the migration does not rebuild the models table.

## Estimate formula

When exact head dimensions are present:

`KV bytes = context × layers × KV heads × (K head length + V head length) × 2`

The final factor of 2 assumes F16 cache elements. If both K/V lengths are absent but attention head counts are present, the per-head dimension is derived from `embedding_length / attention_head_count`. If metadata is incomplete but the architecture is a recognized attention-transformer family, the estimator uses the full embedding width for both K and V as a conservative aggregate MHA upper bound. Unsupported/state-space architectures, inconsistent metadata, unverified files, and invalid context requests return `unknown`.

Weight residency starts from the verified GGUF file size and is presented with 12.5% and 25% planning margins. KV cache is shown with 25% and 50% margins. The runtime reserve mirrors the current native preflight's 384 MiB base reserve plus 128 MiB per 2,048-token context unit. The UI displays the minimum, recommended and upper planning thresholds rather than presenting one value as exact.

## UX behaviour

The Models page adds **تقدير ملاءمة الذاكرة** for installed llama.cpp models. It re-verifies the local file before estimating and reads current available RAM. The dialog lets the user compare context sizes in the native 512–4096 token range, constrained by the GGUF training context when known. The chosen context in this dialog changes the estimate only; it does not persist a runtime override or alter an active session.

## Safety boundary

The estimate is advisory, not a load guarantee. The native llama.cpp loader performs a separate live `/proc/meminfo` preflight and remains authoritative. The current estimator does not measure actual RSS, mmap page residency, allocator fragmentation, quantized KV overrides, or model-specific activation workspace. The native loader's preflight formula has not yet been changed by this milestone.

## Verification

Added Dart tests cover exact GQA calculation, full-width fallback, memory classifications, unavailable telemetry, unsupported state-space architectures, inconsistent dimensions, and context/file validation. Python contract tests verify metadata transport and the SQLite v13→v14 additive migration. Rust parser unit coverage verifies attention metadata extraction.

GitHub Actions must still run FRB generation, Dart format/analyze/tests, Rust fmt/test/clippy, the real Android NDK build, and the ARM64 Debug APK build. Physical-device telemetry and load comparisons remain outstanding.

## Exact remaining work

1. Alpha 2.7.3 — adaptive inference policy, including explicit saved overrides and context/CPU-thread suggestions.
2. Alpha 2.7.4 — memory lifecycle and measured cache cleanup.
3. Alpha 2.7.5 — benchmark harness on physical Android hardware.
4. Alpha 2.7.6 — explainable peer placement using fresh resource telemetry and model-fit estimates.
5. Beta acceptance tests across low-memory, offline, recovery, accessibility, long-session, two-device and thermal conditions.
6. Release: clean CI pass, real llama.cpp Android ARM64 compilation, signed Release APK, signature/version/upgrade verification and checksum.
