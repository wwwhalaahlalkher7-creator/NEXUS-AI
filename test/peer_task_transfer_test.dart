import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/devices/peer_task_transfer.dart';

void main() {
  const validPlan = {
    'schema_version': 1,
    'goal': 'Prepare a local research summary',
    'steps': [
      {
        'id': 'step_1',
        'agent_id': 'researcher',
        'objective': 'Collect local notes',
        'expected_output': 'A concise summary',
        'depends_on': [],
      },
      {
        'id': 'step_2',
        'agent_id': 'writer',
        'objective': 'Draft the summary',
        'expected_output': 'Markdown text',
        'depends_on': ['step_1'],
      },
    ],
  };

  test('proposal envelope round-trips and authenticates its payload hash', () async {
    final envelope = await PeerTaskProposalEnvelope.create(
      transferId: 'transfer_0123456789abcdef',
      sourceTaskId: 'task-123456',
      goal: 'Prepare a local research summary',
      planJson: jsonEncode(validPlan),
      createdAtUnixMs: 1700000000000,
    );
    final restored = await PeerTaskProposalEnvelope.fromMessage(
      envelope.toMessage(),
    );
    expect(restored.payloadSha256, envelope.payloadSha256);
    expect(restored.goal, envelope.goal);
    expect(restored.transferId, envelope.transferId);
  });

  test('proposal rejects a modified payload hash', () async {
    final envelope = await PeerTaskProposalEnvelope.create(
      transferId: 'transfer_0123456789abcdef',
      sourceTaskId: 'task-123456',
      goal: 'Prepare a local research summary',
      planJson: jsonEncode(validPlan),
      createdAtUnixMs: 1700000000000,
    );
    final tampered = envelope.toMessage()..['goal'] = 'changed';
    await expectLater(
      PeerTaskProposalEnvelope.fromMessage(tampered),
      throwsA(isA<PeerTaskTransferException>()),
    );
  });

  test('proposal rejects dependency cycles before it reaches local storage', () async {
    final cyclePlan = {
      ...validPlan,
      'steps': [
        {
          'id': 'a',
          'agent_id': 'agent-a',
          'objective': 'A',
          'expected_output': 'A',
          'depends_on': ['b'],
        },
        {
          'id': 'b',
          'agent_id': 'agent-b',
          'objective': 'B',
          'expected_output': 'B',
          'depends_on': ['a'],
        },
      ],
    };
    await expectLater(
      PeerTaskProposalEnvelope.create(
        transferId: 'transfer_0123456789abcdef',
        sourceTaskId: 'task-123456',
        goal: 'Prepare a local research summary',
        planJson: jsonEncode(cyclePlan),
        createdAtUnixMs: 1700000000000,
      ),
      throwsA(isA<PeerTaskTransferException>()),
    );
  });

  test('proposal rejects payloads larger than one secure frame budget', () async {
    final oversized = {
      ...validPlan,
      'steps': [
        {
          'id': 'large',
          'agent_id': 'agent',
          'objective': 'large result',
          'expected_output': List.filled(600000, 'z').join(),
          'depends_on': [],
        },
      ],
    };
    await expectLater(
      PeerTaskProposalEnvelope.create(
        transferId: 'transfer_0123456789abcdef',
        sourceTaskId: 'task-123456',
        goal: 'Prepare a local research summary',
        planJson: jsonEncode(oversized),
        createdAtUnixMs: 1700000000000,
      ),
      throwsA(isA<PeerTaskTransferException>()),
    );
  });
  test('remapper replaces every remote agent with a selected local agent', () {
    final remapped = RemoteTaskPlanRemapper.remap(
      jsonEncode(validPlan),
      const {'researcher': 'local-research', 'writer': 'local-writer'},
    );
    final decoded = jsonDecode(remapped) as Map<String, dynamic>;
    final steps = decoded['steps'] as List<dynamic>;
    expect((steps[0] as Map<String, dynamic>)['agent_id'], 'local-research');
    expect((steps[1] as Map<String, dynamic>)['agent_id'], 'local-writer');
    expect(decoded['goal'], validPlan['goal']);
  });

  test('remapper rejects any remote agent without an explicit mapping', () {
    expect(
      () => RemoteTaskPlanRemapper.remap(
        jsonEncode(validPlan),
        const {'researcher': 'local-research'},
      ),
      throwsA(isA<PeerTaskTransferException>()),
    );
  });

  test('remapper rejects malformed plan envelopes', () {
    expect(
      () => RemoteTaskPlanRemapper.remap('{not-json', const {}),
      throwsA(isA<PeerTaskTransferException>()),
    );
  });

}
