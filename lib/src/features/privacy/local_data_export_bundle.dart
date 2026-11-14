import 'dart:convert';

/// Builds a portable user-data export without leaking device-local paths,
/// paired-peer network identities, or secure-storage material.
class LocalDataExportBundle {
  const LocalDataExportBundle._();

  static const int formatVersion = 1;

  static Map<String, Object?> build({
    required DateTime exportedAt,
    required Map<String, List<Map<String, Object?>>> tables,
  }) {
    final models = (tables['models'] ?? const <Map<String, Object?>>[])
        .map(_withoutLocalModelPath)
        .toList(growable: false);

    // Only the user-selectable resource mode is portable. Device identity and
    // device display-name settings are deliberately excluded.
    final settings = (tables['app_settings'] ??
            const <Map<String, Object?>>[])
        .where((row) => row['key'] == 'resource_mode')
        .toList(growable: false);

    final exported = <String, List<Map<String, Object?>>>{
      'agents': tables['agents'] ?? const [],
      'models': models,
      'conversations': tables['conversations'] ?? const [],
      'messages': tables['messages'] ?? const [],
      'knowledge_documents': tables['knowledge_documents'] ?? const [],
      'knowledge_chunks': tables['knowledge_chunks'] ?? const [],
      'agent_tasks': tables['agent_tasks'] ?? const [],
      'agent_task_steps': tables['agent_task_steps'] ?? const [],
      'agent_task_events': tables['agent_task_events'] ?? const [],
      'benchmark_runs': tables['benchmark_runs'] ?? const [],
      'app_settings': settings,
    };

    return {
      'format': 'nexus-local-data-export',
      'format_version': formatVersion,
      'encrypted': false,
      'exported_at_utc': exportedAt.toUtc().toIso8601String(),
      'privacy': {
        'local_model_paths_included': false,
        'model_weight_files_included': false,
        'paired_device_addresses_and_fingerprints_included': false,
        'peer_transfer_and_execution_ledgers_included': false,
        'secure_storage_secrets_included': false,
        'device_identity_settings_included': false,
      },
      'record_counts': {
        for (final entry in exported.entries) entry.key: entry.value.length,
      },
      'data': exported,
    };
  }

  static String encode(Map<String, Object?> bundle) =>
      const JsonEncoder.withIndent('  ').convert(bundle);

  static Map<String, Object?> _withoutLocalModelPath(
    Map<String, Object?> model,
  ) {
    final sanitized = Map<String, Object?>.from(model);
    sanitized.remove('local_path');
    return sanitized;
  }
}
