import 'dart:io';

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
  });

  final int availableMemoryBytes;
  final int? totalMemoryBytes;
}

/// Android exposes MemAvailable through procfs. Failure is non-fatal: policy
/// falls back to conservative profiles, while unrestricted mode keeps no
/// artificial application-level ceiling.
class DeviceResourceMonitor {
  const DeviceResourceMonitor();

  Future<ResourceSnapshot?> readSnapshot() async {
    if (!Platform.isAndroid && !Platform.isLinux) return null;
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
      if (availableKb <= 0) return null;
      return ResourceSnapshot(
        availableMemoryBytes: availableKb * 1024,
        totalMemoryBytes: totalKb == null ? null : totalKb * 1024,
      );
    } on Object {
      return null;
    }
  }
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
