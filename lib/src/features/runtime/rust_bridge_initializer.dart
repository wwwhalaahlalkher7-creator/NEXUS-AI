import '../../rust/frb_generated.dart';

/// Shares one retryable flutter_rust_bridge initialization across all features.
class RustBridgeInitializer {
  RustBridgeInitializer._();

  static Future<void>? _initialization;

  static Future<void> ensureInitialized() async {
    final pending = _initialization ??= RustLib.init();
    try {
      await pending;
    } catch (_) {
      if (identical(_initialization, pending)) {
        _initialization = null;
      }
      rethrow;
    }
  }
}
