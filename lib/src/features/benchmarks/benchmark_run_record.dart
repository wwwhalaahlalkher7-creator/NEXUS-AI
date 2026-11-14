class BenchmarkRunRecord {
  const BenchmarkRunRecord({
    required this.id,
    required this.modelId,
    required this.modelName,
    required this.contextTokens,
    required this.cpuThreads,
    required this.startedAtUnixMs,
    required this.completedAtUnixMs,
    required this.generatedTokens,
    required this.cancellationObserved,
    required this.status,
    this.modelArchitecture,
    this.modelFileBytes,
    this.firstLoadMs,
    this.repeatLoadMs,
    this.generationElapsedMs,
    this.tokensPerSecond,
    this.peakResidentBytes,
    this.cancelLatencyMs,
    this.startingThermalStatus,
    this.endingThermalStatus,
    this.peakThermalStatus,
    this.startingBatteryPercent,
    this.endingBatteryPercent,
    this.runtimeVersion,
    this.error,
  });

  final String id;
  final String modelId;
  final String modelName;
  final String? modelArchitecture;
  final int? modelFileBytes;
  final int contextTokens;
  final int cpuThreads;
  final int startedAtUnixMs;
  final int completedAtUnixMs;
  final int? firstLoadMs;
  final int? repeatLoadMs;
  final int? generationElapsedMs;
  final int generatedTokens;
  final double? tokensPerSecond;
  /// Process-wide VmHWM observed during this run, not model-only allocation.
  final int? peakResidentBytes;
  final int? cancelLatencyMs;
  final bool cancellationObserved;
  final int? startingThermalStatus;
  final int? endingThermalStatus;
  final int? peakThermalStatus;
  final int? startingBatteryPercent;
  final int? endingBatteryPercent;
  final String? runtimeVersion;
  final String status;
  final String? error;

  Map<String, Object?> toMap() => {
        'id': id,
        'model_id': modelId,
        'model_name': modelName,
        'model_architecture': modelArchitecture,
        'model_file_bytes': modelFileBytes,
        'context_tokens': contextTokens,
        'cpu_threads': cpuThreads,
        'started_at_unix_ms': startedAtUnixMs,
        'completed_at_unix_ms': completedAtUnixMs,
        'first_load_ms': firstLoadMs,
        'repeat_load_ms': repeatLoadMs,
        'generation_elapsed_ms': generationElapsedMs,
        'generated_tokens': generatedTokens,
        'tokens_per_second': tokensPerSecond,
        'peak_resident_bytes': peakResidentBytes,
        'cancel_latency_ms': cancelLatencyMs,
        'cancellation_observed': cancellationObserved ? 1 : 0,
        'starting_thermal_status': startingThermalStatus,
        'ending_thermal_status': endingThermalStatus,
        'peak_thermal_status': peakThermalStatus,
        'starting_battery_percent': startingBatteryPercent,
        'ending_battery_percent': endingBatteryPercent,
        'runtime_version': runtimeVersion,
        'status': status,
        'error': error,
      };

  factory BenchmarkRunRecord.fromMap(Map<String, Object?> map) {
    return BenchmarkRunRecord(
      id: map['id']! as String,
      modelId: map['model_id']! as String,
      modelName: map['model_name']! as String,
      modelArchitecture: map['model_architecture'] as String?,
      modelFileBytes: map['model_file_bytes'] as int?,
      contextTokens: map['context_tokens']! as int,
      cpuThreads: map['cpu_threads']! as int,
      startedAtUnixMs: map['started_at_unix_ms']! as int,
      completedAtUnixMs: map['completed_at_unix_ms']! as int,
      firstLoadMs: map['first_load_ms'] as int?,
      repeatLoadMs: map['repeat_load_ms'] as int?,
      generationElapsedMs: map['generation_elapsed_ms'] as int?,
      generatedTokens: map['generated_tokens']! as int,
      tokensPerSecond: (map['tokens_per_second'] as num?)?.toDouble(),
      peakResidentBytes: map['peak_resident_bytes'] as int?,
      cancelLatencyMs: map['cancel_latency_ms'] as int?,
      cancellationObserved: (map['cancellation_observed']! as int) == 1,
      startingThermalStatus: map['starting_thermal_status'] as int?,
      endingThermalStatus: map['ending_thermal_status'] as int?,
      peakThermalStatus: map['peak_thermal_status'] as int?,
      startingBatteryPercent: map['starting_battery_percent'] as int?,
      endingBatteryPercent: map['ending_battery_percent'] as int?,
      runtimeVersion: map['runtime_version'] as String?,
      status: map['status']! as String,
      error: map['error'] as String?,
    );
  }
}
