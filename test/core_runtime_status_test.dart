import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_status.dart';

void main() {
  test(
    'stores strongly typed Rust runtime diagnostics',
    () {
      final status = CoreRuntimeStatus(
        coreName: 'NEXUS AI',
        coreVersion: '0.9.0',
        stage: 'alpha-1.7-real-text-generation',
        bridgeConnected: true,
        runtimeEngine: 'llama.cpp-native-initialized',
        inferenceAvailable: false,
        modelLoaded: false,
        modelRegistry: 'flutter_sqlite',
        agentRegistry: 'rust_in_memory',
        nativeEngineAvailable: true,
        nativeEngineVersion: '0.9.0',
        nativeEngineMessage: 'native initialized',
        modelContextTokens: 2048,
      );

      expect(status.bridgeConnected, isTrue);
      expect(status.inferenceAvailable, isFalse);
      expect(status.modelLoaded, isFalse);
      expect(status.runtimeEngine, 'llama.cpp-native-initialized');
      expect(status.nativeEngineAvailable, isTrue);
      expect(status.nativeEngineVersion, '0.9.0');
      expect(status.modelContextTokens, 2048);
    },
  );

  test('unavailable status never reports an active inference engine', () {
    final status = CoreRuntimeStatus.unavailable('not supported');
    expect(status.bridgeConnected, isFalse);
    expect(status.inferenceAvailable, isFalse);
    expect(status.modelLoaded, isFalse);
    expect(status.message, 'not supported');
  });
}
