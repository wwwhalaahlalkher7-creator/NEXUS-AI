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
  bool failUnload = false;
  int? returnedContextTokens;
  int? lastContextTokens;
  int? lastThreads;

  @override
  bool get isAvailable => available;

  @override
  Future<int> load(
    ModelRecord model, {
    required int contextTokens,
    required int threads,
  }) async {
    loadCalls++;
    lastContextTokens = contextTokens;
    lastThreads = threads;
    if (failLoad) {
      throw StateError('backend load failed');
    }
    return returnedContextTokens ?? contextTokens;
  }

  @override
  Future<void> unload() async {
    unloadCalls++;
    if (failUnload) {
      throw StateError('backend unload failed');
    }
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

_FakeVerifier _validVerifier() => _FakeVerifier(const ModelFileVerification(
      isValid: true,
      actualSizeBytes: 1024,
      message: 'valid',
    ));

void main() {
  test('preflight prepares a verified model without claiming it is loaded', () async {
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    final result = await manager.prepare(_model());

    expect(result.state, ModelSessionState.readyToLoad);
    expect(result.modelId, 'model-1');
    expect(result.modelFileBytes, 1024);
    expect(result.contextTokens, 2048);
    expect(result.isLoaded, isFalse);
    expect(backend.loadCalls, 0);
  });

  test('uses the smaller of the default and model training context limits', () async {
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: _FakeBackend(),
    );

    final result = await manager.prepare(_model(contextLength: 1024));

    expect(result.state, ModelSessionState.readyToLoad);
    expect(result.contextTokens, 1024);
  });

  test('training context larger than the policy is not incorrectly rejected', () async {
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: _FakeBackend(),
      policy: const ModelRuntimePolicy(maxContextTokens: 4096),
    );

    final result = await manager.prepare(_model(contextLength: 32768));

    expect(result.state, ModelSessionState.readyToLoad);
    expect(result.contextTokens, 2048);
  });

  test('rejects an unusably small training context', () async {
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: _FakeBackend(),
    );

    final result = await manager.prepare(_model(contextLength: 256));

    expect(result.state, ModelSessionState.failed);
    expect(result.message, contains('512'));
  });

  test('production unavailable backend never reports a model as loaded', () async {
    final manager = ModelRuntimeManager(verifier: _validVerifier());

    await manager.prepare(_model());
    final result = await manager.loadPrepared(_model());

    expect(result.state, ModelSessionState.readyToLoad);
    expect(result.isLoaded, isFalse);
    expect(result.message, contains('غير متاح'));
  });

  test('backend load and unload produce explicit lifecycle transitions', () async {
    final backend = _FakeBackend()..returnedContextTokens = 1536;
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    await manager.prepare(_model());
    final loaded = await manager.loadPrepared(_model());
    expect(loaded.state, ModelSessionState.loaded);
    expect(loaded.contextTokens, 1536);
    expect(loaded.isLoaded, isTrue);
    expect(backend.loadCalls, 1);
    expect(backend.lastContextTokens, 2048);
    expect(backend.lastThreads, 4);

    final unloaded = await manager.unload();
    expect(unloaded.state, ModelSessionState.idle);
    expect(backend.unloadCalls, 1);
  });

  test('retains loaded state if cleanup fails after an invalid context', () async {
    final backend = _FakeBackend()
      ..returnedContextTokens = 8192
      ..failUnload = true;
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    await manager.prepare(_model());
    final result = await manager.loadPrepared(_model());

    expect(result.state, ModelSessionState.loaded);
    expect(result.isLoaded, isTrue);
    expect(result.contextTokens, 8192);
    expect(result.message, contains('ما زالت الجلسة محمّلة'));
  });

  test('backend failure never leaves a false loaded state', () async {
    final backend = _FakeBackend()..failLoad = true;
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    await manager.prepare(_model());
    final result = await manager.loadPrepared(_model());

    expect(result.state, ModelSessionState.failed);
    expect(result.isLoaded, isFalse);
    expect(result.message, contains('backend load failed'));
  });

  test('rejects a model file that exceeds the configured byte ceiling', () async {
    final manager = ModelRuntimeManager(
      verifier: _FakeVerifier(const ModelFileVerification(
        isValid: true,
        actualSizeBytes: 2048,
        message: 'valid',
      )),
      backend: _FakeBackend(),
      policy: const ModelRuntimePolicy(maxModelFileBytes: 1024),
    );

    final result = await manager.prepare(_model());

    expect(result.state, ModelSessionState.failed);
    expect(result.message, contains('يتجاوز حد السياسة'));
  });

  test('rejects external models from the local llama.cpp runtime path', () async {
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: _FakeBackend(),
    );

    final result = await manager.prepare(_model(runtime: ModelRuntime.external));

    expect(result.state, ModelSessionState.failed);
    expect(result.message, contains('llama.cpp'));
  });

  test('does not replace a different model while a model is loaded', () async {
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: _FakeBackend(),
    );

    await manager.prepare(_model());
    final loaded = await manager.loadPrepared(_model());
    expect(loaded.state, ModelSessionState.loaded);

    await expectLater(
      manager.prepare(_model(id: 'model-2')),
      throwsA(isA<StateError>()),
    );

    expect(manager.snapshot.state, ModelSessionState.loaded);
    expect(manager.snapshot.modelId, 'model-1');
  });

  test('prevents overlapping runtime operations', () async {
    final verifier = _validVerifier()
      ..completer = Completer<ModelFileVerification>();
    final manager = ModelRuntimeManager(verifier: verifier);

    final firstOperation = manager.prepare(_model());
    await Future<void>.delayed(Duration.zero);
    expect(manager.isBusy, isTrue);
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
    expect(manager.isBusy, isFalse);
  });
}
