import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/agents/agent_record.dart';

void main() {
  test('agent record serializes stable status, identifiers and persona', () {
    final agent = AgentRecord(
      id: 'agent-01',
      name: 'Research',
      description: 'Local research agent',
      status: AgentRecordStatus.draft,
      systemPrompt: 'Answer in Arabic and cite uncertainty.',
      createdAtUnixMs: 1000,
    );

    final restored = AgentRecord.fromMap(agent.toMap());

    expect(restored.id, 'agent-01');
    expect(restored.name, 'Research');
    expect(restored.status, AgentRecordStatus.draft);
    expect(restored.modelId, isNull);
    expect(restored.systemPrompt, agent.systemPrompt);
  });

  test('legacy agent rows default to an empty persona', () {
    final restored = AgentRecord.fromMap({
      'id': 'legacy-agent',
      'name': 'Legacy',
      'description': '',
      'status': 'ready',
      'model_id': null,
      'created_at_unix_ms': 500,
    });

    expect(restored.systemPrompt, isEmpty);
  });
}

