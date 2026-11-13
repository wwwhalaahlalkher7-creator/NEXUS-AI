# Alpha 1.4.6 — Parallel Flutter verification gates

## Change

The CI workflow now starts these required checks concurrently:

- `flutter analyze --no-pub`
- `flutter test --no-pub`

Each process writes to a separate log file. The workflow captures both process exit codes independently, waits for both processes, and prints both logs for diagnosis.

## Failure behavior

- If analysis fails, the combined step fails.
- If tests fail, the combined step fails.
- If both fail, both failures and logs are retained.
- The APK build and artifact upload cannot run unless both checks pass.
- No `continue-on-error`, failure suppression, or advisory-only analysis is used.

Both checks are allowed to finish rather than terminating the sibling process at the first failure; this gives a complete diagnostic report while still stopping the workflow before packaging.

## Expected timing

The verification duration should approach the slower of the two checks rather than their sum, subject to runner CPU and memory contention. This is a structural expectation, not a measured benchmark.

## Validation status

The workflow script was statically inspected and YAML-parsed, and the archive was integrity-checked. Flutter commands were not run in this environment; GitHub Actions must confirm the runtime result.
