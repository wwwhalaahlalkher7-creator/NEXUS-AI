import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/models/model_file_verifier.dart';
import 'package:nexus_app/src/features/models/model_record.dart';
import 'package:nexus_app/src/features/models/rust_gguf_inspector.dart';
import 'package:nexus_app/src/features/runtime/model_runtime_manager.dart';

class _FakeVerifier implements ModelFileVerifier {
  _FakeVerifier(this.result);

  final ModelFileVerification result;
  final Map<String, ModelFileVerification> resultsByModelId = {};
  Completer<ModelFileVerification>? completer;

  @override
  Future<ModelFileVerification> verify(ModelRecord model) =>
      completer?.future ?? Future.value(resultsByModelId[model.id] ?? result);
}

class _FakeBackend implements ModelRuntimeBackend {
  bool available = true;
  int loadCalls = 0;
  int unloadCalls = 0;
  bool failLoad = false;
  bool failUnload = false;
  final Set<String> failLoadModelIds = {};
  String? loadedModelId;
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
    if (failLoad || failLoadModelIds.contains(model.id)) {
      throw StateError('backend load failed for ${model.id}');
    }
    loadedModelId = model.id;
    return returnedContextTokens ?? contextTokens;
  }

  @override
  Future<void> unload() async {
    unloadCalls++;
    if (failUnload) {
      throw StateError('backend unload failed');
    }
    loadedModelId = null;
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

  test('does not impose a default model-file byte ceiling', () async {
    final manager = ModelRuntimeManager(
      verifier: _FakeVerifier(const ModelFileVerification(
        isValid: true,
        actualSizeBytes: 9 * 1024 * 1024 * 1024,
        message: 'valid',
      )),
      backend: _FakeBackend(),
    );

    final result = await manager.prepare(_model());

    expect(result.state, ModelSessionState.readyToLoad);
    expect(result.modelFileBytes, 9 * 1024 * 1024 * 1024);
  });

  test('honors an explicit model-file byte ceiling when configured', () async {
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
    expect(result.message, contains('حد السياسة المخصص'));
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


  test('switchTo loads an assigned model when no session is active', () async {
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    final loaded = await manager.switchTo(_model());

    expect(loaded.state, ModelSessionState.loaded);
    expect(loaded.modelId, 'model-1');
    expect(backend.loadedModelId, 'model-1');
    expect(backend.loadCalls, 1);
    expect(backend.unloadCalls, 0);
    expect(manager.isBusy, isFalse);
  });

  test('switchTo unloads the old session and loads the verified target', () async {
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    await manager.prepare(_model());
    await manager.loadPrepared(_model());
    final switched = await manager.switchTo(_model(id: 'model-2'));

    expect(switched.state, ModelSessionState.loaded);
    expect(switched.modelId, 'model-2');
    expect(backend.loadedModelId, 'model-2');
    expect(backend.unloadCalls, 1);
    expect(backend.loadCalls, 2);
  });

  test('switchTo keeps the same model without unloading or reloading it', () async {
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    await manager.prepare(_model());
    final loaded = await manager.loadPrepared(_model());
    final same = await manager.switchTo(_model());

    expect(same.modelId, loaded.modelId);
    expect(same.state, ModelSessionState.loaded);
    expect(backend.loadCalls, 1);
    expect(backend.unloadCalls, 0);
  });

  test('failed old-session unload prevents the target load', () async {
    final backend = _FakeBackend()..failUnload = true;
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    await manager.prepare(_model());
    await manager.loadPrepared(_model());
    final result = await manager.switchTo(_model(id: 'model-2'));

    expect(result.state, ModelSessionState.loaded);
    expect(result.modelId, 'model-1');
    expect(result.message, contains('تعذر تفريغ النموذج الحالي'));
    expect(backend.loadCalls, 1);
    expect(backend.loadedModelId, 'model-1');
  });

  test('invalid target is rejected before unloading the current model', () async {
    final verifier = _validVerifier()
      ..resultsByModelId['model-2'] = const ModelFileVerification(
        isValid: false,
        actualSizeBytes: 1024,
        message: 'invalid target file',
      );
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(
      verifier: verifier,
      backend: backend,
    );

    await manager.prepare(_model());
    await manager.loadPrepared(_model());
    final result = await manager.switchTo(_model(id: 'model-2'));

    expect(result.state, ModelSessionState.loaded);
    expect(result.modelId, 'model-1');
    expect(result.message, contains('invalid target file'));
    expect(backend.unloadCalls, 0);
    expect(backend.loadedModelId, 'model-1');
  });

  test('failed target load restores the previous model session', () async {
    final backend = _FakeBackend()..failLoadModelIds.add('model-2');
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    await manager.prepare(_model());
    await manager.loadPrepared(_model());
    final result = await manager.switchTo(_model(id: 'model-2'));

    expect(result.state, ModelSessionState.loaded);
    expect(result.modelId, 'model-1');
    expect(
      result.message,
      contains('تمت استعادة النموذج السابق'),
    );
    expect(backend.loadedModelId, 'model-1');
    expect(backend.loadCalls, 3);
  });

  test('generation lease requires a loaded model and rejects a second lease', () async {
    final manager = ModelRuntimeManager(verifier: _validVerifier());

    expect(() => manager.beginGeneration(), throwsA(isA<StateError>()));
    expect(manager.isGenerating, isFalse);

    await manager.prepare(_model());
    expect(() => manager.beginGeneration(), throwsA(isA<StateError>()));

    // No native model was loaded by preflight, so the manager still denies
    // generation until loadPrepared has completed successfully.
    expect(manager.snapshot.isLoaded, isFalse);
  });

  test('generation lease blocks unload and model switching until released', () async {
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    await manager.prepare(_model());
    await manager.loadPrepared(_model());
    manager.beginGeneration();

    expect(manager.isGenerating, isTrue);
    await expectLater(manager.prepare(_model()), throwsA(isA<StateError>()));
    await expectLater(
      manager.loadPrepared(_model()),
      throwsA(isA<StateError>()),
    );
    await expectLater(manager.unload(), throwsA(isA<StateError>()));
    await expectLater(
      manager.switchTo(_model(id: 'model-2')),
      throwsA(isA<StateError>()),
    );
    expect(backend.unloadCalls, 0);
    expect(manager.snapshot.modelId, 'model-1');

    manager.endGeneration();
    manager.endGeneration();
    expect(manager.isGenerating, isFalse);
    expect((await manager.unload()).state, ModelSessionState.idle);
  });

  test('recoveryRequired can be cleared after the backend is unloaded', () async {
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    await manager.prepare(_model());
    await manager.loadPrepared(_model());
    backend.failLoadModelIds.addAll({'model-1', 'model-2'});
    final failedSwitch = await manager.switchTo(_model(id: 'model-2'));
    expect(failedSwitch.state, ModelSessionState.recoveryRequired);
    await expectLater(
      manager.prepare(_model(id: 'model-3')),
      throwsA(isA<StateError>()),
    );
    expect(manager.snapshot.state, ModelSessionState.recoveryRequired);

    backend.failLoadModelIds.clear();
    final cleared = await manager.unload();
    expect(cleared.state, ModelSessionState.idle);
    expect(backend.loadedModelId, isNull);
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
  test('prepared adaptive context and CPU threads are passed to the backend', () async {
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    final prepared = await manager.prepare(
      _model(),
      contextTokens: 1024,
      cpuThreads: 2,
    );
    expect(prepared.state, ModelSessionState.readyToLoad);
    expect(prepared.contextTokens, 1024);
    expect(prepared.cpuThreads, 2);

    final loaded = await manager.loadPrepared(_model());
    expect(loaded.state, ModelSessionState.loaded);
    expect(loaded.contextTokens, 1024);
    expect(loaded.cpuThreads, 2);
    expect(backend.lastContextTokens, 1024);
    expect(backend.lastThreads, 2);
  });

  test('adaptive runtime overrides reject values outside native limits', () async {
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: _FakeBackend(),
    );

    await expectLater(
      manager.prepare(_model(), cpuThreads: 9),
      throwsArgumentError,
    );
    await expectLater(
      manager.prepare(_model(), contextTokens: 8192),
      throwsArgumentError,
    );
  });

  test('switch restores previous CPU thread selection after target load failure', () async {
    final backend = _FakeBackend();
    final verifier = _validVerifier()
      ..resultsByModelId['model-2'] = const ModelFileVerification(
        isValid: true,
        actualSizeBytes: 2048,
        message: 'valid target',
      );
    final manager = ModelRuntimeManager(
      verifier: verifier,
      backend: backend,
    );

    await manager.prepare(_model(), contextTokens: 1024, cpuThreads: 3);
    await manager.loadPrepared(_model());
    backend.failLoadModelIds.add('model-2');

    final target = _model(id: 'model-2');
    final result = await manager.switchTo(
      target,
      contextTokens: 2048,
      cpuThreads: 6,
    );

    expect(result.state, ModelSessionState.loaded);
    expect(result.modelId, 'model-1');
    expect(result.contextTokens, 1024);
    expect(result.cpuThreads, 3);
    expect(backend.lastThreads, 3);
  });

  test('switchTo can explicitly reload the active model with new adaptive settings', () async {
    final backend = _FakeBackend();
    final manager = ModelRuntimeManager(
      verifier: _validVerifier(),
      backend: backend,
    );

    await manager.prepare(_model(), contextTokens: 1024, cpuThreads: 2);
    await manager.loadPrepared(_model());
    final result = await manager.switchTo(
      _model(),
      contextTokens: 2048,
      cpuThreads: 5,
    );

    expect(result.state, ModelSessionState.loaded);
    expect(result.contextTokens, 2048);
    expect(result.cpuThreads, 5);
    expect(backend.unloadCalls, 1);
    expect(backend.lastContextTokens, 2048);
    expect(backend.lastThreads, 5);
  });

  test('prepare rejects context above fresh GGUF limit instead of stale model metadata', () async {
    final verifier = _FakeVerifier(const ModelFileVerification(
      isValid: true,
      actualSizeBytes: 1024,
      message: 'verified fresh file',
      inspection: GgufInspection(
        validHeader: true,
        fileName: 'fresh.gguf',
        sizeBytes: 1024,
        formatVersion: 3,
        tensorCount: 1,
        metadataCount: 1,
        contextLength: 1024,
        message: 'fresh',
      ),
    ));
    final manager = ModelRuntimeManager(
      verifier: verifier,
      backend: _FakeBackend(),
    );

    final result = await manager.prepare(_model(contextLength: 8192), contextTokens: 2048);

    expect(result.state, ModelSessionState.failed);
    expect(result.message, contains('نافذة GGUF المعلنة'));
  });

  test('fresh GGUF without context metadata does not reuse a stale catalog limit', () async {
    final verifier = _FakeVerifier(const ModelFileVerification(
      isValid: true,
      actualSizeBytes: 1024,
      message: 'verified fresh file',
      inspection: GgufInspection(
        validHeader: true,
        fileName: 'fresh.gguf',
        sizeBytes: 1024,
        formatVersion: 3,
        tensorCount: 1,
        metadataCount: 1,
        contextLength: null,
        message: 'fresh context unavailable',
      ),
    ));
    final manager = ModelRuntimeManager(
      verifier: verifier,
      backend: _FakeBackend(),
    );

    final result = await manager.prepare(_model(contextLength: 8192));

    expect(result.state, ModelSessionState.readyToLoad);
    expect(result.contextTokens, 2048);
  });

}
