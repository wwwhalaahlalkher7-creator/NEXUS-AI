import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/agents/agent_record.dart';

void main() {
  test('agent record serializes stable status and identifiers', () {
    final agent = AgentRecord(
      id: 'agent-01',
      name: 'Research',
      description: 'Local research agent',
      status: AgentRecordStatus.draft,
      createdAtUnixMs: 1000,
    );

    final restored = AgentRecord.fromMap(agent.toMap());

    expect(restored.id, 'agent-01');
    expect(restored.name, 'Research');
    expect(restored.status, AgentRecordStatus.draft);
    expect(restored.modelId, isNull);
  });
}
