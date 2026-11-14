import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';

/// User-selected resource posture. It changes policy budgets, never safety
/// permissions: the local tool allow-list and approval checks remain intact.
enum ResourceMode { balanced, performance, unrestricted }

class ResourceSettings {
  const ResourceSettings({this.mode = ResourceMode.balanced});

  final ResourceMode mode;

  String get label => switch (mode) {
        ResourceMode.balanced => 'متوازن',
        ResourceMode.performance => 'الأداء',
        ResourceMode.unrestricted => 'مفتوح',
      };

  String get description => switch (mode) {
        ResourceMode.balanced =>
          'يوازن بين الاستجابة واستهلاك الذاكرة والبطارية.',
        ResourceMode.performance =>
          'يخصص حصة أكبر من الموارد المتاحة للاستيراد والبحث والأدوات.',
        ResourceMode.unrestricted =>
          'يلغي السقوف البرمجية الثابتة. يظل الاستهلاك تابعاً لذاكرة الجهاز '
              'وتخزينه، ويمكن إيقاف المهام يدوياً.',
      };

  /// Share of currently available RAM reserved in Balanced/Performance modes.
  /// Unrestricted mode returns null and opts out of importer pre-budgets.
  double? get workingMemoryFraction => switch (mode) {
        ResourceMode.balanced => 0.02,
        ResourceMode.performance => 0.04,
        ResourceMode.unrestricted => null,
      };

  int? importBudgetBytes(ResourceSnapshot? snapshot) {
    if (mode == ResourceMode.unrestricted) return null;
    final available = snapshot?.availableMemoryBytes;
    if (available == null || available <= 0) {
      return switch (mode) {
        ResourceMode.balanced => 8 * 1024 * 1024,
        ResourceMode.performance => 32 * 1024 * 1024,
        ResourceMode.unrestricted => null,
      };
    }
    return (available * workingMemoryFraction!).floor().clamp(1, available).toInt();
  }

  int? searchCandidateBudget(ResourceSnapshot? snapshot) {
    if (mode == ResourceMode.unrestricted) return null;
    final available = snapshot?.availableMemoryBytes;
    if (available == null || available <= 0) {
      return switch (mode) {
        ResourceMode.balanced => 800,
        ResourceMode.performance => 4000,
        ResourceMode.unrestricted => null,
      };
    }
    final bytesPerCandidate = switch (mode) {
      ResourceMode.balanced => 128 * 1024,
      ResourceMode.performance => 64 * 1024,
      ResourceMode.unrestricted => 32 * 1024,
    };
    return (available ~/ bytesPerCandidate).clamp(1, 0x7fffffff).toInt();
  }

  int? get retrievalResultLimit => switch (mode) {
        ResourceMode.balanced => 5,
        ResourceMode.performance => 16,
        ResourceMode.unrestricted => null,
      };

  int? get maxResultsPerDocument => switch (mode) {
        ResourceMode.balanced => 2,
        ResourceMode.performance => 4,
        ResourceMode.unrestricted => null,
      };

  int? get maxAgentPlanSteps => switch (mode) {
        ResourceMode.balanced => 8,
        ResourceMode.performance => 24,
        ResourceMode.unrestricted => null,
      };

  int get agentPlanningOutputTokens => switch (mode) {
        ResourceMode.balanced => 512,
        ResourceMode.performance => 768,
        // The current native generation ABI accepts at most 1,024 tokens.
        ResourceMode.unrestricted => 1024,
      };

  int get agentStepOutputTokens => switch (mode) {
        ResourceMode.balanced => 256,
        ResourceMode.performance => 512,
        // The current native generation ABI accepts at most 1,024 tokens.
        ResourceMode.unrestricted => 1024,
      };

  int? get maxToolCallsPerTurn => switch (mode) {
        ResourceMode.balanced => 3,
        ResourceMode.performance => 16,
        ResourceMode.unrestricted => null,
      };

  int? get maxConversationMessages => switch (mode) {
        ResourceMode.balanced => 64,
        ResourceMode.performance => 256,
        ResourceMode.unrestricted => null,
      };

  int? get maxConversationBytes => switch (mode) {
        ResourceMode.balanced => 48 * 1024,
        ResourceMode.performance => 256 * 1024,
        ResourceMode.unrestricted => null,
      };

  int? get maxToolEnvelopeBytes => switch (mode) {
        ResourceMode.balanced => 8 * 1024,
        ResourceMode.performance => 32 * 1024,
        ResourceMode.unrestricted => null,
      };

  int? get maxToolArgumentBytes => switch (mode) {
        ResourceMode.balanced => 4 * 1024,
        ResourceMode.performance => 32 * 1024,
        ResourceMode.unrestricted => null,
      };

  int? get maxToolOutputCharacters => switch (mode) {
        ResourceMode.balanced => 4000,
        ResourceMode.performance => 16000,
        ResourceMode.unrestricted => null,
      };

  static ResourceSettings fromValue(String? value) {
    for (final mode in ResourceMode.values) {
      if (mode.name == value) return ResourceSettings(mode: mode);
    }
    return const ResourceSettings();
  }
}

class ResourceSnapshot {
  const ResourceSnapshot({
    required this.availableMemoryBytes,
    this.totalMemoryBytes,
    this.cpuLogicalCores = 1,
    this.cpuUtilizationPercent,
    this.batteryLevelPercent,
    this.isCharging,
    this.thermalStatus,
  });

  final int availableMemoryBytes;
  final int? totalMemoryBytes;
  final int cpuLogicalCores;
  final int? cpuUtilizationPercent;
  final int? batteryLevelPercent;
  final bool? isCharging;
  /// Android PowerManager thermal status (0..6); null when unavailable.
  final int? thermalStatus;
}

typedef CpuStatReader = Future<List<String>> Function();
typedef PowerThermalReader = Future<Map<String, Object?>?> Function();
typedef TelemetryDelay = Future<void> Function(Duration duration);

/// Android/Linux expose RAM and aggregate CPU counters through procfs.
/// Battery and thermal readings use the generated Android host's platform
/// channel. Unsupported metrics remain null; no synthetic values are used.
class DeviceResourceMonitor {
  DeviceResourceMonitor({
    CpuStatReader? cpuStatReader,
    PowerThermalReader? powerThermalReader,
    TelemetryDelay? delay,
  })  : _cpuStatReader = cpuStatReader ?? _readCpuStat,
        _powerThermalReader = powerThermalReader ?? _readPowerThermal,
        _delay = delay ?? ((duration) => Future<void>.delayed(duration));

  static const MethodChannel _powerChannel =
      MethodChannel('com.nexusai/device_telemetry');
  final CpuStatReader _cpuStatReader;
  final PowerThermalReader _powerThermalReader;
  final TelemetryDelay _delay;

  Future<ResourceSnapshot?> readSnapshot({
    bool includeExtendedTelemetry = false,
  }) async {
    final cpuLogicalCores = Platform.numberOfProcessors.clamp(1, 256).toInt();
    if (!Platform.isAndroid && !Platform.isLinux) {
      return ResourceSnapshot(
        availableMemoryBytes: 0,
        cpuLogicalCores: cpuLogicalCores,
      );
    }

    var availableBytes = 0;
    int? totalBytes;
    try {
      final content = await File('/proc/meminfo').readAsString();
      int? readKilobytes(String key) {
        final match = RegExp('^$key:\\s+(\\d+)\\s+kB', multiLine: true)
            .firstMatch(content);
        return match == null ? null : int.tryParse(match.group(1)!);
      }

      final availableKb = readKilobytes('MemAvailable') ??
          ((readKilobytes('MemFree') ?? 0) +
              (readKilobytes('Buffers') ?? 0) +
              (readKilobytes('Cached') ?? 0));
      final totalKb = readKilobytes('MemTotal');
      if (availableKb > 0) availableBytes = availableKb * 1024;
      if (totalKb != null && totalKb > 0) totalBytes = totalKb * 1024;
    } on Object {
      // Keep optional measurements unknown if procfs is unavailable.
    }

    if (!includeExtendedTelemetry) {
      return ResourceSnapshot(
        availableMemoryBytes: availableBytes,
        totalMemoryBytes: totalBytes,
        cpuLogicalCores: cpuLogicalCores,
      );
    }

    final cpuUtilization = await _sampleCpuUtilization();
    final power = await _readPowerSafely();
    final chargingValue = power?['is_charging'];
    final charging = chargingValue is bool ? chargingValue : null;
    return ResourceSnapshot(
      availableMemoryBytes: availableBytes,
      totalMemoryBytes: totalBytes,
      cpuLogicalCores: cpuLogicalCores,
      cpuUtilizationPercent: cpuUtilization,
      batteryLevelPercent: _boundedInt(power?['battery_level_percent'], 0, 100),
      isCharging: charging,
      thermalStatus: _boundedInt(power?['thermal_status'], 0, 6),
    );
  }

  Future<int?> _sampleCpuUtilization() async {
    if (!Platform.isAndroid && !Platform.isLinux) return null;
    try {
      final before = _parseAggregateCpu(await _cpuStatReader());
      if (before == null) return null;
      await _delay(const Duration(milliseconds: 400));
      final after = _parseAggregateCpu(await _cpuStatReader());
      if (after == null) return null;
      final totalDelta = after.total - before.total;
      final idleDelta = after.idle - before.idle;
      if (totalDelta <= 0 || idleDelta < 0 || idleDelta > totalDelta) {
        return null;
      }
      final busy = totalDelta - idleDelta;
      return ((busy * 100) / totalDelta).round().clamp(0, 100).toInt();
    } on Object {
      return null;
    }
  }

  static _CpuCounters? _parseAggregateCpu(List<String> lines) {
    if (lines.isEmpty) return null;
    final parts = lines.first.trim().split(RegExp(r'\s+'));
    if (parts.length < 5 || parts.first != 'cpu') return null;
    final values = <int>[];
    for (final value in parts.skip(1).take(8)) {
      final parsed = int.tryParse(value);
      if (parsed == null || parsed < 0) return null;
      values.add(parsed);
    }
    if (values.length < 4) return null;
    final total = values.fold<int>(0, (sum, value) => sum + value);
    final idle = values[3] + (values.length > 4 ? values[4] : 0);
    return _CpuCounters(total: total, idle: idle);
  }

  Future<Map<String, Object?>?> _readPowerSafely() async {
    try {
      return await _powerThermalReader();
    } on Object {
      return null;
    }
  }

  static Future<Map<String, Object?>?> _readPowerThermal() async {
    if (!Platform.isAndroid) return null;
    return _powerChannel.invokeMapMethod<String, Object?>('readPowerThermal');
  }

  static Future<List<String>> _readCpuStat() async =>
      File('/proc/stat').readAsLines();

  static int? _boundedInt(Object? value, int minimum, int maximum) =>
      value is int && value >= minimum && value <= maximum ? value : null;
}

class _CpuCounters {
  const _CpuCounters({required this.total, required this.idle});
  final int total;
  final int idle;
}

class ResourceSettingsRepository {
  ResourceSettingsRepository({LocalDatabase? database})
      : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;
  static const _modeKey = 'resource_mode';

  Future<ResourceSettings> load() async {
    final db = await _database.database;
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_modeKey],
      limit: 1,
    );
    return ResourceSettings.fromValue(
      rows.isEmpty ? null : rows.single['value'] as String?,
    );
  }

  Future<void> save(ResourceSettings settings) async {
    final db = await _database.database;
    await db.insert(
      'app_settings',
      {
        'key': _modeKey,
        'value': settings.mode.name,
        'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
