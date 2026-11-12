import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/models/model_file_verifier.dart';
import 'package:nexus_app/src/features/models/model_record.dart';

void main() {
  late LocalModelFileVerifier verifier;

  setUp(() {
    verifier = LocalModelFileVerifier();
  });

  test('reports a missing local model file without calling the Rust bridge', () async {
    final model = ModelRecord(
      id: 'missing-model',
      displayName: 'Missing model',
      runtime: ModelRuntime.llamaCpp,
      status: ModelInstallStatus.installed,
      localPath: '${Directory.systemTemp.path}/nexus-missing-${DateTime.now().microsecondsSinceEpoch}.gguf',
      sizeBytes: 1024,
      createdAtUnixMs: 1,
      updatedAtUnixMs: 1,
    );

    final result = await verifier.verify(model);

    expect(result.isValid, isFalse);
    expect(result.message, contains('غير موجود'));
  });

  test('detects a stored file size mismatch before GGUF inspection', () async {
    final directory = await Directory.systemTemp.createTemp('nexus-model-audit-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/model.gguf');
    await file.writeAsBytes(List<int>.filled(128, 0));

    final model = ModelRecord(
      id: 'size-mismatch',
      displayName: 'Size mismatch',
      runtime: ModelRuntime.llamaCpp,
      status: ModelInstallStatus.installed,
      localPath: file.path,
      sizeBytes: 256,
      createdAtUnixMs: 1,
      updatedAtUnixMs: 1,
    );

    final result = await verifier.verify(model);

    expect(result.isValid, isFalse);
    expect(result.actualSizeBytes, 128);
    expect(result.message, contains('لا يطابق'));
  });
}
