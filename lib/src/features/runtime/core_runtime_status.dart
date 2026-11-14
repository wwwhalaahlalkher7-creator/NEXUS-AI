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
    this.nativeMemoryAvailable = false,
    this.nativeMemoryReadable = false,
    this.nativeContextLoaded = false,
    this.nativeGenerationActive = false,
    this.nativeResidentBytes = 0,
    this.nativePeakResidentBytes = 0,
    this.nativeVirtualBytes = 0,
    this.nativeKvCacheClearCount = 0,
    this.nativeModelLoadCount = 0,
    this.nativeModelUnloadCount = 0,
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

  /// /proc/self/status values describe the complete app process, not just
  /// llama.cpp. They may remain high after native free() due to allocator reuse.
  final bool nativeMemoryAvailable;
  final bool nativeMemoryReadable;
  final bool nativeContextLoaded;
  final bool nativeGenerationActive;
  final int nativeResidentBytes;
  final int nativePeakResidentBytes;
  final int nativeVirtualBytes;
  final int nativeKvCacheClearCount;
  final int nativeModelLoadCount;
  final int nativeModelUnloadCount;

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

class MemoryLifecycleResult {
  const MemoryLifecycleResult({required this.success, required this.message});

  final bool success;
  final String message;
}
