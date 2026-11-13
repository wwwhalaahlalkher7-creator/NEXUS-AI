class CoreRuntimeStatus {
  const CoreRuntimeStatus({
    required this.coreName,
    required this.coreVersion,
    required this.stage,
    required this.bridgeConnected,
    required this.runtimeEngine,
    required this.inferenceAvailable,
    required this.modelLoaded,
    required this.modelRegistry,
    required this.agentRegistry,
    required this.nativeEngineAvailable,
    this.nativeEngineVersion,
    this.nativeEngineMessage,
    this.modelContextTokens,
    this.message,
  });

  final String coreName;
  final String coreVersion;
  final String stage;
  final bool bridgeConnected;
  final String runtimeEngine;
  final bool inferenceAvailable;
  final bool modelLoaded;
  final String modelRegistry;
  final String agentRegistry;
  final bool nativeEngineAvailable;
  final String? nativeEngineVersion;
  final String? nativeEngineMessage;
  final int? modelContextTokens;
  final String? message;

  factory CoreRuntimeStatus.unavailable(String message) => CoreRuntimeStatus(
        coreName: 'NEXUS AI',
        coreVersion: '—',
        stage: 'unavailable',
        bridgeConnected: false,
        runtimeEngine: 'unknown',
        inferenceAvailable: false,
        modelLoaded: false,
        modelRegistry: 'unknown',
        agentRegistry: 'unknown',
        nativeEngineAvailable: false,
        nativeEngineVersion: null,
        nativeEngineMessage: null,
        modelContextTokens: null,
        message: message,
      );
}
