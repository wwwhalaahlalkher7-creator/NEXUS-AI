#!/usr/bin/env python3
"""Static privacy and integration contracts for local discovery and QR pairing."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
protocol = (ROOT / "lib/src/features/devices/peer_discovery.dart").read_text(encoding="utf-8")
service = (ROOT / "lib/src/features/devices/device_network_service.dart").read_text(encoding="utf-8")
page = (ROOT / "lib/src/features/devices/devices_page.dart").read_text(encoding="utf-8")
scanner = (ROOT / "lib/src/features/devices/pairing_qr_scanner_page.dart").read_text(encoding="utf-8")
pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
manifest_patch = (ROOT / "scripts/patch_android_manifest.py").read_text(encoding="utf-8")
bootstrap = (ROOT / "scripts/bootstrap.sh").read_text(encoding="utf-8")

checks = {
    "discovery uses a separate UDP port and bounded packets": "peerDiscoveryPort = 47832" in protocol and "peerDiscoveryPacketLimit = 1024" in protocol and "RawDatagramSocket.bind" in service,
    "probe uses a fresh random nonce and short expiry": "_randomToken(12)" in service and "_nonceLifetime = Duration(seconds: 12)" in service,
    "advertisement acceptance requires a nonce issued by this scanner": "validNonces: _validDiscoveryNonces.keys.toSet()" in service and "validNonces.contains(nonce)" in protocol and "{16}" in protocol,
    "source address is validated and derived from the datagram rather than the payload": "sourceAddress: datagram.address" in service and "isPrivatePeerAddress(address)" in protocol,
    "advertisement schema contains no pairing secret": "createAdvertisement" in protocol and "pairing_code" not in protocol[protocol.index("static Map<String, Object?> createAdvertisement"):protocol.index("static DiscoveredPeer? parseAdvertisement")],
    "host is discoverable only with an unexpired unclaimed invitation": "_isDiscoverableInvite(invite)" in service and "invite.expiresAt.isAfter(DateTime.now())" in service,
    "UDP discovery is optional and QR/manual pairing survive a blocked broadcast socket": "Discovery is an optional convenience" in service and "الاقتران عبر QR أو العنوان والرمز متاحاً" in service,
    "LAN discovery responses are rate-limited and bounded per source": "_lastDiscoveryReplyAt[source]" in service and "Duration(milliseconds: 500)" in service and "_lastDiscoveryReplyAt.length > 256" in service,
    "delayed UDP close events cannot clear a replacement socket": "identical(_discoverySocket, socket)" in service and "_discoverySubscription = null" in service,
    "concurrent UDP socket binds are serialized": "_discoverySocketOpening" in service and "final opening = _discoverySocketOpening" in service,
    "discovery requires an explicit user action and automatically stops": "startDiscovery()" in page and "Timer(duration" in service and "stopDiscovery()" in page,
    "unknown discovered devices are not auto-paired": "لم يتم توثيق الأجهزة المكتشفة بعد" in service and "امسح دعوة QR" in service,
    "QR payload validates identity, private addresses, secret length, and expiry": all(item in protocol for item in ("pairingQrPrefix", "isPrivatePeerAddress(value)", "secret.length != 32", "expiresAt <= nowMilliseconds", "expiresAt > latestAllowedExpiry", "safeDisplayName")),
    "QR connection verifies the expected remote device id": "expectedRemoteDeviceId: invite.deviceId" in service and "remoteId != expectedRemoteDeviceId" in service,
    "paired reconnect checks stored secure key and expected identity": "_secureStorage.read(key: '$_secretPrefix${peer.deviceId}')" in service and "expectedRemoteDeviceId: peer.deviceId" in service,
    "interface changes clear stale peers, nonce cache and restart discovery": "_refreshNetworkFingerprint" in service and "_discoveredPeers.clear()" in service and "_validDiscoveryNonces.clear()" in service and "_lastDiscoveryReplyAt.clear()" in service and "_ensureDiscoverySocket()" in service and "networkChanged" in service,
    "network watcher runs only while scanning or hosting an invitation": "final shouldWatch = _isDiscovering || _isDiscoverableInvite(_activeInvite)" in service and "_syncNetworkWatcher();" in service,
    "invite expiry closes its advertisement eligibility": "_inviteExpiryTimer" in service and "_isDiscoverableInvite" in service,
    "claimed or rejected invites synchronize discovery and watcher lifecycle": "_inviteClaimed = true" in service and "_inviteClaimed = false" in service and "unawaited(_syncDiscoverySocket())" in service and "_syncNetworkWatcher();" in service,
    "scanner uses the dedicated mobile camera scanner": "MobileScanner(onDetect: _handleDetection)" in scanner and "mobile_scanner: ^7.5.0" in pubspec,
    "QR code is rendered locally without a hosted QR service": "package:qr/qr.dart" in page and "QrPayload.fromString(payload)" in page,
    "camera-free pairing can decode the copied invite payload": "Clipboard.getData('text/plain')" in page and "_pasteQrInvite" in page and "PairingInvitePayload.decode(raw)" in page,
    "camera permission is explicit but camera hardware remains optional": "android.permission.CAMERA" in manifest_patch and 'android:required="false"' in manifest_patch,
    "local bootstrap applies the same Android permission patch as CI": "python3 scripts/patch_android_manifest.py" in bootstrap,
}
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
failed = [name for name, passed in checks.items() if not passed]
if failed:
    raise SystemExit("Peer discovery contract failures: " + ", ".join(failed))
print(f"Peer discovery contract PASS: {len(checks)} checks")
