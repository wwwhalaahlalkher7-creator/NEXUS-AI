import 'core_runtime_status.dart';

abstract interface class CoreRuntimeService {
  Future<CoreRuntimeStatus> inspect();
}
