import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/privacy/local_data_export_bundle.dart';

void main() {
  group('LocalDataExportBundle', () {
    test('exports portable records but strips local model paths', () {
      final bundle = LocalDataExportBundle.build(
        exportedAt: DateTime.utc(2026, 11, 14, 12),
        tables: {
          'agents': [
            {'id': 'agent-1', 'name': 'Researcher', 'system_prompt': 'Local prompt'},
          ],
          'models': [
            {
              'id': 'model-1',
              'display_name': 'Local GGUF',
              'local_path': '/private/models/model.gguf',
            },
          ],
          'app_settings': [
            {'key': 'resource_mode', 'value': 'balanced'},
            {'key': 'local_device_id', 'value': 'private-device-id'},
            {'key': 'local_device_name', 'value': 'Private device'},
          ],
          'conversations': [
            {'id': 'conversation-1', 'title': 'Private chat'},
          ],
        },
      );

      final data = bundle['data']! as Map<String, Object?>;
      final models = data['models']! as List<Map<String, Object?>>;
      final settings = data['app_settings']! as List<Map<String, Object?>>;

      expect(bundle['format'], 'nexus-local-data-export');
      expect(bundle['format_version'], 1);
      expect(bundle['encrypted'], isFalse);
      expect(models.single.containsKey('local_path'), isFalse);
      expect(settings, [
        {'key': 'resource_mode', 'value': 'balanced'},
      ]);
      expect(data.containsKey('conversations'), isTrue);
      expect(data.containsKey('paired_devices'), isFalse);
      expect(data.containsKey('peer_task_executions'), isFalse);
      expect(data.containsKey('remote_task_transfers'), isFalse);
    });

    test('records the privacy omissions in the exported manifest', () {
      final bundle = LocalDataExportBundle.build(
        exportedAt: DateTime.utc(2026),
        tables: const {},
      );
      final privacy = bundle['privacy']! as Map<String, Object?>;

      expect(privacy['local_model_paths_included'], isFalse);
      expect(privacy['model_weight_files_included'], isFalse);
      expect(privacy['paired_device_addresses_and_fingerprints_included'], isFalse);
      expect(privacy['secure_storage_secrets_included'], isFalse);
      expect(privacy['device_identity_settings_included'], isFalse);
    });

    test('encodes a valid readable JSON document', () {
      final bundle = LocalDataExportBundle.build(
        exportedAt: DateTime.utc(2026, 11, 14),
        tables: const {},
      );
      final encoded = LocalDataExportBundle.encode(bundle);

      expect(encoded, contains('"format_version": 1'));
      expect(encoded, contains('"data"'));
      expect(encoded, contains('\n'));
    });
  });
}
