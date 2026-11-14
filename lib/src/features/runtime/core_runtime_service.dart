import 'core_runtime_status.dart';

abstract interface class CoreRuntimeService {
  Future<CoreRuntimeStatus> inspect();

  /// Clears only transient KV state. Model weights and the llama context remain loaded.
  Future<MemoryLifecycleResult> clearContextMemory();
}
