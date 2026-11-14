# Alpha 2.6.1 — Local network discovery and QR pairing

**Flutter package:** `2.6.1+42`  
**Rust workspace:** `2.6.1`  
**SQLite schema:** `9` (unchanged)  
**Network protocol:** TCP peer protocol v1 + independent UDP discovery v1

## Scope

Alpha 2.6.1 improves local device onboarding without changing the authenticated TCP peer handshake introduced in Alpha 2.6.0. It adds user-initiated LAN discovery, QR invitations, camera scanning, trusted-device reconnect at a refreshed address, and network-interface change detection.

## LAN discovery

- TCP pairing remains on `47831`; UDP discovery uses `47832`.
- The user explicitly starts a 30-second discovery scan. Probes are sent to the IPv4 limited-broadcast address every two seconds.
- Each probe carries a random 96-bit nonce that is accepted only for a short window.
- A peer advertises only if its TCP listener is active and an unexpired, unclaimed invitation exists.
- Advertisements carry the nonce, stable device ID, display label, platform and TCP port. They do **not** include the invitation code, a long-term secret, or model/task data.
- The source IPv4 address is taken from the datagram metadata, not the payload. Only private or link-local IPv4 addresses are accepted. Packets over 1 KiB and malformed packets are ignored.
- Discovery entries are labelled unverified and expire from the in-memory list after 15 seconds without an update. Discovery never creates a pairing record and never triggers a TCP connection by itself.

This implementation uses LAN IPv4 broadcast rather than mDNS. Some routers, guest Wi-Fi networks, client isolation settings, VPNs, or Android hotspot configurations may suppress broadcast packets. Manual IPv4 entry and QR/manual invite sharing remain fallbacks.

## QR invitation

The versioned QR payload contains:

- the host's stable NEXUS device ID and display name;
- one or more validated private IPv4 addresses and the TCP port;
- the same 256-bit, single-use pairing secret already used by Alpha 2.6.0;
- an absolute expiry timestamp.

The scanner validates the scheme/version, field types, peer ID, address list, port, 32-byte secret and invitation expiry before presenting a confirmation page. The same payload can also be pasted from the clipboard, so a device without a working camera can use the same QR invitation flow. The user sees the inviter identity/address list and confirms before any network attempt. The TCP challenge/HMAC/X25519/HKDF/AES-GCM handshake then runs unchanged; the client also checks that the authenticated remote ID matches the QR invite. First-time pairing still requires host approval and the existing two-phase commit.

**Security note:** The QR code contains a bearer pairing secret. Treat the displayed image and copied payload as confidential; do not post it publicly. It expires after ten minutes and can be claimed once by a new peer.

## Network lifecycle

The service fingerprints the local non-loopback IPv4 interfaces every eight seconds only while scanning or hosting an active invitation, not while the feature is idle. When the interface/address set changes, it clears ephemeral discovery nonces/results, recreates the UDP socket when scanning or hosting, emits a network-change event, and refreshes the displayed invite address list without changing the invite secret or expiry. Existing TCP sessions may still drop during Wi-Fi/hotspot handover; the user can reconnect using a fresh discovery result or manual address. This is not a background always-on service.

## Android permissions and dependencies

- `INTERNET` and `ACCESS_NETWORK_STATE` remain required for local TCP/UDP sockets and interface awareness.
- `CAMERA` is added for the optional QR scanner; camera hardware is declared optional so devices without a camera can still install and use manual pairing.
- Android `targetSdk` remains 36. This milestone does not implement Android 17/API 37 `ACCESS_LOCAL_NETWORK` runtime permission handling.
- `qr` generates QR modules locally. `mobile_scanner` uses the bundled Android ML Kit scanner by default; upstream package documentation estimates an additional 3–10 MB. No QR service, online image API, or account is used.

## Explicitly not included

- mDNS or IPv6 discovery;
- Internet relay or remote-network pairing;
- distributed task execution, RPC, shell, or arbitrary command dispatch;
- file/model transfer or distributed inference;
- always-on/background discovery.

## Verification

Source-level validation includes Dart tests for QR decoding and discovery packet validation, Python contracts for secret separation/nonce/source validation/identity checks, Android manifest idempotency tests, existing peer-network tests, and all previous host contract/migration scripts.

GitHub Actions must still run `dart format`, `flutter analyze --no-pub`, `flutter test --no-pub`, Rust formatting/tests/Clippy, Android ARM64 native compilation, and Debug APK assembly. Real Android checks are required for camera permission, QR scan, UDP discovery over Wi-Fi and hotspot, interface handover, two-device first-time pairing, block/unpair, and trusted reconnect. No physical-device success is implied by host contracts.


### Reliability hardening

UDP discovery is best-effort and is not a dependency of secure pairing: if the discovery socket cannot bind or broadcast, the host keeps its active TCP invitation and the QR/manual address path remains available. Probe replies are rate-limited per LAN source (500 ms) and the source-tracking cache is bounded; malformed or oversized probes are ignored.
