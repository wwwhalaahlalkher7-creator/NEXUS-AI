import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/models/model_file_verifier.dart';
import 'package:nexus_app/src/features/models/model_record.dart';
import 'package:nexus_app/src/features/runtime/model_runtime_manager.dart';

class _FakeVerifier implements ModelFileVerifier {
  _FakeVerifier(this.result);

  final ModelFileVerification result;
  Completer<ModelFileVerification>? completer;

  @override
  Future<ModelFileVerification> verify(ModelRecord model) =>
      completer?.future ?? Future.value(result);
}

class _FakeBackend implements ModelRuntimeBackend {
  bool available = true;
  int loadCalls = 0;
  int unloadCalls = 0;
  bool failLoad = false;

  @override
  bool get isAvailable => available;

  @override
  Future<void> load(ModelRecord model) async {
    loadCalls++;
    if (failLoad) {
      throw StateError('backend load failed');
    }
  }

  @override
  Future<void> unload() async {
    unloadCalls++;
  }
}

ModelRecord _model({
  String id = 'model-1',
  ModelRuntime runtime = ModelRuntime.llamaCpp,
  int? contextLength = 4096,
}) =>
    ModelRecord(
      id: id,
      displayName: 'نموذج اختبار',
      runtime: runtime,
      status: ModelInstallStatus.installed,
      localPath: '/models/test.gguf',
      sizeBytes: 1024,
      contextLength: contextLength,
      createdAtUnixMs: 1,
      updatedAtUnixMs: 1,
    );

void main() {
  test('preflight prepares a verified model without claiming it is loaded', () async {
    final verifier = _FakeVerifier(const ModelFileVerification(
      isValid: true,
      actualSizeBytes: 1024,
      message: 'valid',
    ));
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(verifier: verifier, backend: backend);

    final result = await manager.prepare(_model());

    expect(result.state, ModelSessionState.readyToLoad);
    expect(result.modelId, 'model-1');
    expect(result.modelFileBytes, 1024);
    expect(result.isLoaded, isFalse);
    expect(backend.loadCalls, 0);
  });

  test('production unavailable backend never reports a model as loaded', () async {
    final manager = ModelRuntimeManager(
      verifier: _FakeVerifier(const ModelFileVerification(
        isValid: true,
        actualSizeBytes: 1024,
        message: 'valid',
      )),
    );

    await manager.prepare(_model());
    final result = await manager.loadPrepared(_model());

    expect(result.state, ModelSessionState.readyToLoad);
    expect(result.isLoaded, isFalse);
    expect(result.message, contains('غير متاح'));
  });

  test('backend load and unload produce explicit lifecycle transitions', () async {
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(
      verifier: _FakeVerifier(const ModelFileVerification(
        isValid: true,
        actualSizeBytes: 1024,
        message: 'valid',
      )),
      backend: backend,
    );

    await manager.prepare(_model());
    final loaded = await manager.loadPrepared(_model());
    expect(loaded.state, ModelSessionState.loaded);
    expect(backend.loadCalls, 1);

    final unloaded = await manager.unload();
    expect(unloaded.state, ModelSessionState.idle);
    expect(backend.unloadCalls, 1);
  });


  test('backend failure never leaves a false loaded state', () async {
    final backend = _FakeBackend()..failLoad = true;
    final manager = ModelRuntimeManager(
      verifier: _FakeVerifier(const ModelFileVerification(
        isValid: true,
        actualSizeBytes: 1024,
        message: 'valid',
      )),
      backend: backend,
    );

    await manager.prepare(_model());
    final result = await manager.loadPrepared(_model());

    expect(result.state, ModelSessionState.failed);
    expect(result.isLoaded, isFalse);
    expect(result.message, contains('backend load failed'));
  });

  test('rejects a model that exceeds the configured context policy', () async {
    final manager = ModelRuntimeManager(
      verifier: _FakeVerifier(const ModelFileVerification(
        isValid: true,
        actualSizeBytes: 1024,
        message: 'valid',
      )),
      policy: const ModelRuntimePolicy(maxContextTokens: 2048),
    );

    final result = await manager.prepare(_model(contextLength: 4096));

    expect(result.state, ModelSessionState.failed);
    expect(result.message, contains('يتجاوز حد السياسة'));
  });

  test('rejects external models from the local llama.cpp runtime path', () async {
    final verifier = _FakeVerifier(const ModelFileVerification(
      isValid: true,
      actualSizeBytes: 1024,
      message: 'valid',
    ));
    final manager = ModelRuntimeManager(verifier: verifier);

    final result = await manager.prepare(_model(runtime: ModelRuntime.external));

    expect(result.state, ModelSessionState.failed);
    expect(result.message, contains('llama.cpp'));
  });

  test('prevents overlapping runtime operations', () async {
    final verifier = _FakeVerifier(const ModelFileVerification(
      isValid: true,
      actualSizeBytes: 1024,
      message: 'valid',
    ))..completer = Completer<ModelFileVerification>();
    final manager = ModelRuntimeManager(verifier: verifier);

    final firstOperation = manager.prepare(_model());
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      manager.prepare(_model(id: 'model-2')),
      throwsA(isA<StateError>()),
    );
    verifier.completer!.complete(const ModelFileVerification(
      isValid: true,
      actualSizeBytes: 1024,
      message: 'valid',
    ));
    expect((await firstOperation).state, ModelSessionState.readyToLoad);
  });
}
