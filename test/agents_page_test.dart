import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexus_app/src/features/agents/agent_record.dart';
import 'package:nexus_app/src/features/agents/agent_repository.dart';
import 'package:nexus_app/src/features/agents/agents_page.dart';
import 'package:nexus_app/src/features/models/model_file_verifier.dart';
import 'package:nexus_app/src/features/models/model_record.dart';
import 'package:nexus_app/src/features/models/model_repository.dart';

class _FakeModelFileVerifier implements ModelFileVerifier {
  const _FakeModelFileVerifier(this.result);

  final ModelFileVerification result;

  @override
  Future<ModelFileVerification> verify(ModelRecord model) async => result;
}

class _MemoryModelStore implements ModelStore {
  _MemoryModelStore(this.records);
  final List<ModelRecord> records;

  @override
  Future<void> delete(String id) async => records.removeWhere((m) => m.id == id);
  @override
  Future<List<ModelRecord>> list() async => List<ModelRecord>.of(records);
  @override
  Future<void> register(ModelRecord model) async => records.add(model);
  @override
  Future<void> updateInstallState(
    String id, {
    required ModelInstallStatus status,
    String? localPath,
    int? sizeBytes,
    String? architecture,
    String? ggufModelName,
    String? tokenizerModel,
    int? contextLength,
    int? blockCount,
    int? embeddingLength,
    int? attentionHeadCount,
    int? attentionHeadCountKv,
    int? attentionKeyLength,
    int? attentionValueLength,
    int? fileType,
    int? parameterCount,
  }) async {}
}

class _MemoryAgentStore implements AgentStore {
  final List<AgentRecord> records = <AgentRecord>[];

  @override
  Future<void> create(AgentRecord agent) async {
    records.add(agent);
  }

  @override
  Future<void> updateModel(String id, String? modelId) async {
    final index = records.indexWhere((agent) => agent.id == id);
    if (index < 0) throw StateError('Agent does not exist: $id');
    final current = records[index];
    records[index] = AgentRecord(
      id: current.id,
      name: current.name,
      description: current.description,
      status: current.status,
      modelId: modelId,
      systemPrompt: current.systemPrompt,
      createdAtUnixMs: current.createdAtUnixMs,
    );
  }

  @override
  Future<void> updateSystemPrompt(String id, String systemPrompt) async {
    final index = records.indexWhere((agent) => agent.id == id);
    if (index < 0) throw StateError('Agent does not exist: $id');
    final current = records[index];
    records[index] = AgentRecord(
      id: current.id,
      name: current.name,
      description: current.description,
      status: current.status,
      modelId: current.modelId,
      systemPrompt: systemPrompt,
      createdAtUnixMs: current.createdAtUnixMs,
    );
  }

  @override
  Future<void> delete(String id) async {
    records.removeWhere((agent) => agent.id == id);
  }

  @override
  Future<AgentRecord?> getById(String id) async {
    for (final agent in records) {
      if (agent.id == id) {
        return agent;
      }
    }
    return null;
  }

  @override
  Future<List<AgentRecord>> list() async => List<AgentRecord>.of(records);

  @override
  Future<void> updateStatus(String id, AgentRecordStatus status) async {
    final index = records.indexWhere((agent) => agent.id == id);
    if (index < 0) {
      throw StateError('Agent does not exist: $id');
    }
    final current = records[index];
    records[index] = AgentRecord(
      id: current.id,
      name: current.name,
      description: current.description,
      status: status,
      modelId: current.modelId,
      systemPrompt: current.systemPrompt,
      createdAtUnixMs: current.createdAtUnixMs,
    );
  }
}

void main() {
  testWidgets('agent can move from draft to ready without claiming inference',
      (tester) async {
    final store = _MemoryAgentStore();
    await tester.pumpWidget(
      MaterialApp(home: AgentsPage(repository: store)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('إنشاء وكيل'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'وكيل البحث');
    await tester.tap(find.text('إنشاء').last);
    await tester.pumpAndSettle();

    expect(find.text('وكيل البحث'), findsOneWidget);
    expect(find.text('مسودة'), findsOneWidget);

    await tester.tap(find.byTooltip('إجراءات الوكيل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تحديد كجاهز'));
    await tester.pumpAndSettle();

    expect(find.text('جاهز'), findsOneWidget);
    expect(
      find.text('يمكن استخدام تعليماته في المحادثة عند اختياره.'),
      findsOneWidget,
    );
    expect(store.records.single.status, AgentRecordStatus.ready);
    expect(tester.takeException(), isNull);
  });

  testWidgets('agent can be paused and resumed through status actions',
      (tester) async {
    final store = _MemoryAgentStore()
      ..records.add(
        AgentRecord(
          id: 'agent-1',
          name: 'مساعد محلي',
          description: '',
          status: AgentRecordStatus.ready,
          createdAtUnixMs: 1,
        ),
      );
    await tester.pumpWidget(
      MaterialApp(home: AgentsPage(repository: store)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('إجراءات الوكيل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إيقاف مؤقت'));
    await tester.pumpAndSettle();
    expect(find.text('متوقف مؤقتاً'), findsOneWidget);

    await tester.tap(find.byTooltip('إجراءات الوكيل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تحديد كجاهز'));
    await tester.pumpAndSettle();
    expect(find.text('جاهز'), findsOneWidget);
  });

  testWidgets('only installed local llama.cpp models can be assigned',
      (tester) async {
    final agents = _MemoryAgentStore()
      ..records.add(AgentRecord(
        id: 'agent-2',
        name: 'وكيل محلي',
        description: '',
        status: AgentRecordStatus.draft,
        createdAtUnixMs: 2,
      ));
    final models = _MemoryModelStore([
      ModelRecord(
        id: 'model-ready',
        displayName: 'نموذج مثبت',
        runtime: ModelRuntime.llamaCpp,
        status: ModelInstallStatus.installed,
        localPath: '/models/ready.gguf',
        createdAtUnixMs: 1,
        updatedAtUnixMs: 1,
      ),
      ModelRecord(
        id: 'model-pending',
        displayName: 'نموذج غير مثبت',
        runtime: ModelRuntime.llamaCpp,
        status: ModelInstallStatus.registered,
        localPath: '/models/pending.gguf',
        createdAtUnixMs: 1,
        updatedAtUnixMs: 1,
      ),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: AgentsPage(
        repository: agents,
        modelRepository: models,
        modelFileVerifier: const _FakeModelFileVerifier(
          ModelFileVerification(
            isValid: true,
            actualSizeBytes: 4096,
            message: 'verified',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('إجراءات الوكيل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ربط نموذج محلي'));
    await tester.pumpAndSettle();
    expect(find.text('نموذج مثبت'), findsOneWidget);
    expect(find.text('نموذج غير مثبت'), findsNothing);
    await tester.tap(find.text('نموذج مثبت'));
    await tester.pumpAndSettle();
    expect(agents.records.single.modelId, 'model-ready');
    expect(find.text('مرتبط بنموذج محلي'), findsOneWidget);
  });

  testWidgets('rejects an assigned model when its local file audit fails',
      (tester) async {
    final agents = _MemoryAgentStore()
      ..records.add(AgentRecord(
        id: 'agent-audit',
        name: 'وكيل الفحص',
        description: '',
        status: AgentRecordStatus.draft,
        createdAtUnixMs: 3,
      ));
    final models = _MemoryModelStore([
      ModelRecord(
        id: 'model-broken',
        displayName: 'ملف غير صالح',
        runtime: ModelRuntime.llamaCpp,
        status: ModelInstallStatus.installed,
        localPath: '/models/broken.gguf',
        createdAtUnixMs: 1,
        updatedAtUnixMs: 1,
      ),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: AgentsPage(
        repository: agents,
        modelRepository: models,
        modelFileVerifier: const _FakeModelFileVerifier(
          ModelFileVerification(
            isValid: false,
            message: 'ملف النموذج غير موجود في مساره المحلي.',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('إجراءات الوكيل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ربط نموذج محلي'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ملف غير صالح'));
    await tester.pumpAndSettle();

    expect(agents.records.single.modelId, isNull);
    expect(
      find.textContaining('لم يتم الربط؛ فشل التحقق من ملف النموذج'),
      findsOneWidget,
    );
  });

  testWidgets('agent system instructions can be edited and saved',
      (tester) async {
    final store = _MemoryAgentStore()
      ..records.add(AgentRecord(
        id: 'agent-instructions',
        name: 'وكيل التلخيص',
        description: '',
        status: AgentRecordStatus.ready,
        createdAtUnixMs: 10,
      ));
    await tester.pumpWidget(
      MaterialApp(home: AgentsPage(repository: store)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('إجراءات الوكيل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تعليمات الوكيل'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'لخّص النصوص بالعربية، واذكر النقاط الرئيسية فقط.',
    );
    await tester.tap(find.text('حفظ التعليمات'));
    await tester.pumpAndSettle();

    expect(
      store.records.single.systemPrompt,
      'لخّص النصوص بالعربية، واذكر النقاط الرئيسية فقط.',
    );
    expect(find.text('له تعليمات مخصصة'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling agent creation closes the form cleanly',
      (tester) async {
    final store = _MemoryAgentStore();
    await tester.pumpWidget(
      MaterialApp(home: AgentsPage(repository: store)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('إنشاء وكيل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();

    expect(store.records, isEmpty);
    expect(tester.takeException(), isNull);
  });

}
