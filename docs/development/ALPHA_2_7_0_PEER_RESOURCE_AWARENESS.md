# Alpha 2.7.0 — Peer resource awareness (`2.7.0+52`)

Status: implemented in source. Flutter/Dart CI, Rust CI, Android ARM64 build, and physical-device measurements remain mandatory before acceptance.

## Scope delivered

- Add a versioned peer resource profile (v1) to the existing authenticated capability exchange.
- Report available and total RAM when `/proc/meminfo` is readable; missing memory is sent as unknown, never as zero capacity.
- Report the runtime's logical processor count using `Platform.numberOfProcessors`.
- Report active inbound peer-execution occupancy. The current local llama.cpp runtime has a single model-session slot, so an active inbound approval/execution marks the peer busy.
- Timestamp each resource profile and treat profiles older than five minutes, or implausibly future-dated profiles, as stale.
- Refresh capability snapshots when a peer is pinged and when an inbound execution enters or leaves the local single execution slot.
- Add a deterministic placement advisor. It excludes blocked, offline, incompatible, busy, stale, and unknown-resource peers. Eligible peers are ordered by available RAM, then logical CPU count, with a stable name tie-break.
- Mark only the first eligible peer as the current recommendation. The user still chooses the device and confirms the remote execution on the receiving device; the advisor never auto-dispatches.
- Add an Arabic device-card resource summary and make the refresh action explicitly refresh capabilities and connection status.
- Keep SQLite at v13. Resource metrics are ephemeral capability metadata in the paired-device JSON; no local schema migration is needed.

## Deliberate limitations

This profile does not claim to measure CPU utilization, battery level, battery temperature, device thermal throttling, GPU availability, model-specific peak RAM, or KV-cache footprint. Logical CPU count is not CPU load. Available RAM is a point-in-time system measurement, not a guarantee that a particular GGUF model will fit. The advisor is a general peer ranking, not a model-fit estimator or a scheduling guarantee.

No automatic whole-plan distribution, concurrent model sessions, background execution, model transfer, or distributed inference is added here.

## Verification added

- Dart tests for RAM/CPU ranking, stable tie-breaks, busy-slot exclusion, stale/missing profiles, blocked/offline/incompatible peers, and malformed measurements.
- Python source contract for versioning, freshness, capability timestamps, busy-state updates, manual dispatch, and the absence of unmeasured battery/thermal claims.
- CI runs the new source contract alongside the existing device and execution contracts.

Not verified in this environment: Dart formatting, `flutter analyze`, `flutter test`, `cargo test`, FRB integration, Android NDK build, APK build, or real multi-device capability refresh. These remain open gates.
