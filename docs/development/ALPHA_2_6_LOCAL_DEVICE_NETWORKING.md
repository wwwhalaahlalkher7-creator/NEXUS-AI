# Alpha 2.6.0 — Local device connectivity

**Flutter package:** `2.6.0+41`  
**Rust workspace:** `2.6.0`  
**SQLite schema:** `v9`  
**First transport:** IPv4 TCP over a shared private LAN / Wi-Fi hotspot

## Scope delivered in source

Alpha 2.6.0 adds an opt-in local device listener and manually initiated peer pairing. The user opens **الأجهزة المتصلة**, creates a time-limited invitation, and shares the IPv4 address, port, and pairing code through a channel they trust. The receiving device enters those values and requests pairing. The host must approve the incoming device; there is no automatic pairing of unknown peers.

The listener uses TCP port `47831` and accepts only private or link-local IPv4 source addresses. Public IPv4 endpoints and IPv6 addresses are rejected in this first implementation. No listener starts until the user explicitly creates an invitation. An invitation expires after ten minutes and is consumed after a successful first pairing.

## Handshake and session security

- Generate a 256-bit random pairing secret locally. The secret is not sent over TCP and is not stored in SQLite.
- Exchange ephemeral X25519 public keys and random nonces.
- The server supplies a fresh challenge; the client proves knowledge of the invitation/paired secret with HMAC-SHA-256 over the hello and challenge. The server authenticates the complete transcript with a second HMAC.
- Derive the session key from the X25519 shared secret plus the pairing secret using HKDF-SHA-256 with a transcript-derived salt and peer identities in the info field.
- Encrypt each session message with AES-256-GCM. Authenticated data binds protocol version, sender ID, receiver ID, and a strictly increasing sequence number. Replayed or reordered frames are rejected.
- Pairing is a two-phase commit (`pair_result` → `pair_commit` → `pair_commit_result`) so both sides confirm persistence before reporting the new pairing as complete.
- Store long-lived peer secrets through Android-backed secure storage. Persist device metadata, trust status, capabilities, addresses, and audit events in SQLite schema v9 only.
- Exclude the secure-storage shared-preferences domain from Android cloud backup and device-transfer restore; restoring device-bound encrypted preferences onto another device must not be treated as restoring the original peer identity.

The cryptographic operations use the `cryptography` package; long-lived secrets use `flutter_secure_storage`. The implementation must still receive package resolution, Flutter tests, Android compilation, and physical-device security review before release.

## Resource and lifecycle controls

- At most four **unauthenticated handshakes** are processed concurrently. This is a listener resource guard, not a cap on the number of paired devices or connected sessions.
- Socket handshake reads have explicit 12-second timeouts; the two-phase commit has a 30-second timeout, and the client waits up to 75 seconds for the host decision. The host approval dialog itself expires after 60 seconds and denies by default. Each frame has a strict size ceiling. Stopping reception invalidates the listener generation and closes pending handshake sockets; late handshakes cannot complete pairing after reception stops. Leaving the devices page stops the listener automatically while established peer sessions remain connected.
- Existing trusted devices reconnect using their saved key. If a device record exists but its secure key is missing, the device must go through host approval again.
- Blocking a peer prevents reconnection. Unpairing removes the secure key and local metadata.

## Capability exchange only

A paired peer can exchange a read-only capability snapshot: platform, app version, native runtime, single-model-session concurrency, protocol version, and best-effort available/total memory. Ping/pong checks channel health. `task_execution` is explicitly false. No GGUF weights, files, conversations, or agent tasks are transmitted; there is no remote shell, arbitrary command RPC, or distributed inference in this milestone.

## Current UX limitations

- Peer discovery is manual IPv4 entry; mDNS/automatic discovery and a QR-code invite are not included.
- This milestone establishes secure peer identity and connectivity only. Distributed task ownership, model-aware scheduling, transfer/resume, and cross-device execution are later work.
- The first supported network is a private IPv4 LAN or Wi-Fi hotspot. Mobile carrier NAT / public Internet relay is not supported.

## Android local-network permission compatibility

The CI scaffold pins `minSdk = 28` for the native runtime and `targetSdk = 36` for this release. Android's official guidance says apps targeting SDK 36 or lower receive local-network access implicitly from `INTERNET`; apps targeting SDK 37 or higher must declare and request `ACCESS_LOCAL_NETWORK` at runtime for direct TCP local-network access. Do not raise `targetSdk` to 37 until the permission flow (rationale, request, denial, and revocation recovery) or an appropriate system-mediated discovery/picker flow is implemented and tested.

## Validation status

Host-side Python contract tests validate schema v9, local-network policy, pairing-state flow, Android manifest patch idempotency and backup XML, and cross-feature compatibility. Dart unit tests cover X25519/HKDF key agreement, challenge-dependent HMAC proofs, transcript fingerprints, encrypted socket messages, sequence rejection, and private IPv4 filtering. A host C++ fake-llama adapter contract remains separate.

A passing source/contract suite does not prove Flutter plugin compatibility, Android permission behavior, device-to-device interoperability, Wi-Fi hotspot routing, or cryptographic implementation correctness under an external security review. Required GitHub Actions gates and physical Android device tests remain release blockers.
