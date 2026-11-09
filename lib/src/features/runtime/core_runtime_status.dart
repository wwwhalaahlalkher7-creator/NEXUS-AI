class CoreRuntimeStatus {
  const CoreRuntimeStatus({
    required this.coreName,
    required this.coreVersion,
    required this.stage,
    required this.bridgeConnected,
    required this.runtimeEngine,
    required this.inferenceAvailable,
    required this.modelRegistry,
    required this.agentRegistry,
    this.message,
  });

  final String coreName;
  final String coreVersion;
  final String stage;
  final bool bridgeConnected;
  final String runtimeEngine;
  final bool inferenceAvailable;
  final String modelRegistry;
  final String agentRegistry;
  final String? message;

  factory CoreRuntimeStatus.fromJson(Map<String, dynamic> json) {
    return CoreRuntimeStatus(
      coreName: json['core_name'] as String,
      coreVersion: json['core_version'] as String,
      stage: json['stage'] as String,
      bridgeConnected: json['bridge_connected'] as bool,
      runtimeEngine: json['runtime_engine'] as String,
      inferenceAvailable: json['inference_available'] as bool,
      modelRegistry: json['model_registry'] as String,
      agentRegistry: json['agent_registry'] as String,
    );
  }

  factory CoreRuntimeStatus.unavailable(String message) => CoreRuntimeStatus(
        coreName: 'NEXUS AI',
        coreVersion: '—',
        stage: 'unavailable',
        bridgeConnected: false,
        runtimeEngine: 'unknown',
        inferenceAvailable: false,
        modelRegistry: 'unknown',
        agentRegistry: 'unknown',
        message: message,
      );
}
