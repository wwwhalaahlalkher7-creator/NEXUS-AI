#!/usr/bin/env python3
"""Static security and integration contracts for local peer networking."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
protocol = (ROOT / "lib/src/features/devices/peer_protocol.dart").read_text(encoding="utf-8")
service = (ROOT / "lib/src/features/devices/device_network_service.dart").read_text(encoding="utf-8")
repository = (ROOT / "lib/src/features/devices/device_repository.dart").read_text(encoding="utf-8")
page = (ROOT / "lib/src/features/devices/devices_page.dart").read_text(encoding="utf-8")
app = (ROOT / "lib/src/app.dart").read_text(encoding="utf-8")
pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")

checks = {
    "protocol uses ephemeral X25519": "X25519().newKeyPair()" in service and "X25519().sharedSecretKey" in protocol,
    "pair secret is proven with HMAC": "Hmac.sha256()" in protocol and "peerHmac(secret" in service,
    "fresh server challenge prevents replay": "hello_challenge" in service and "jsonEncode([helloCore, serverChallenge])" in service,
    "pairing uses a two-phase commit on both peers": "pair_commit" in service and "pair_commit_result" in service,
    "missing secure key always requires user approval": "final requiresApproval = storedSecret == null" in service and "if (requiresApproval)" in service,
    "pending unauthenticated handshakes have a small concurrency guard": "_maximumPendingHandshakes = 4" in service and "_pendingHandshakes >= _maximumPendingHandshakes" in service,
    "stopping listener cancels pending handshakes": "_pendingConnections" in service and "_listenerGeneration++" in service and "_ensureListenerActive(generation)" in service,
    "listener restart waits for an in-flight stop": "await _stoppingListener" in service and "_performStopListening().whenComplete" in service,
    "failed invite address discovery closes the listener": "if (addresses.isEmpty)" in service and "await stopListening();" in service,
    "session payloads use AES-GCM": "AesGcm.with256bits()" in protocol and "_cipher.encrypt" in protocol and "_cipher.decrypt" in protocol,
    "sequence validation rejects replay or reordering": "frame['sequence'] != _incomingSequence" in protocol,
    "binary framing validates maximum payload size": "peerMaximumFrameBytes" in protocol and "length > maximumBytes" in protocol,
    "pairing secret not sent or stored in SQLite": "'proof': base64UrlEncode(clientProof)" in service and "_secureStorage.write" in service and "Pairing secrets are never stored in" in (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8"),
    "secure platform storage dependency exists": "flutter_secure_storage: ^11.2.0" in pubspec,
    "cryptographic library dependency exists": "cryptography:" in pubspec,
    "public Internet addresses are rejected": "isPrivatePeerAddress(address)" in service and "IPv4 الخاصة بالشبكة المحلية فقط" in service,
    "listener requires explicit user action": "createInvite()" in page and "startListening()" in service,
    "listener does not share its TCP port with other processes": "shared: false" in service,
    "self-pairing and malformed ephemeral key material are rejected": "remoteId == localId" in service and "_validatePeerMaterial(remotePublic, remoteNonce)" in service and "_decodeBase64(publicKey).length != 32" in service,
    "invite QR payload carries all validated addresses": "PairingInvitePayload" in (ROOT / "lib/src/features/devices/peer_discovery.dart").read_text(encoding="utf-8") and "addresses: addresses" in service,
    "RFC1918 addresses are preferred over link-local": "leftLinkLocal != rightLinkLocal" in service,
    "new peer requires host confirmation": "onPairingRequest?.call" in service and "موافقة واقتران" in page,
    "blocked peers cannot reconnect": "existing?.isBlocked == true" in service and "record.isBlocked" in service,
    "user can block and unblock peers": "Future<void> setBlocked(String deviceId, bool blocked)" in service and "_toggleBlock(device)" in page,
    "single-use invite rejects parallel first-time claims": "_inviteClaimed" in service and "claimedInviteState" in service,
    "unpair deletes secure key": "_secureStorage.delete(key: '$_secretPrefix$deviceId')" in service,
    "no remote shell or arbitrary command dispatch": "Process.start" not in service and "Process.run" not in service and "shell" not in service,
    "network peers do not receive raw internal exception details": "error.toString()" not in service[service.index("Future<void> _acceptIncoming"):service.index("Future<String> sendTaskProposal")],
    "capability exchange is read-only": "'kind': 'capabilities'" in service and "'task_execution': false" in service,
    "Android target is pinned below local-network runtime-permission boundary": "targetSdk = 36" in (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"),
    "device screen is reachable in app shell": "DevicesPage(service: _deviceNetworkService)" in app,
    "leaving the device page stops the listener": "unawaited(widget.service.stopListening())" in page,
    "incoming approval expires and defaults to deny": "Timer(const Duration(seconds: 60)" in page and "Navigator.of(dialogContext).pop(false)" in page,
    "schema stores trust metadata and events": "CREATE TABLE paired_devices" in (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8") and "CREATE TABLE device_events" in (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8"),
}
failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Device network contract failures: " + ", ".join(failed))
print(f"Device network contract PASS: {len(checks)} checks")
