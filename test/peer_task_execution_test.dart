import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/devices/peer_task_execution.dart';

const requestId = 'execution_0123456789abcdef';
const sourceTaskId = 'task-012345';
const sourceStepId = 'step_2';

void main() {
  const dependencies = [
    PeerTaskDependencyResult(
      stepId: 'step_1',
      agentName: 'Researcher',
      output: 'Verified local research notes.',
    ),
  ];

  test('execution request round-trips with a canonical payload digest', () async {
    final request = await PeerTaskExecutionRequest.create(
      executionId: requestId,
      sourceTaskId: sourceTaskId,
      sourceStepId: sourceStepId,
      goal: 'Prepare a local research report',
      objective: 'Synthesize the verified notes',
      expectedOutput: 'A concise structured summary',
      dependencies: dependencies,
      createdAtUnixMs: 1700000000000,
      expiresAtUnixMs: 1700000900000,
    );
    final decoded = await PeerTaskExecutionRequest.fromMessage(
      request.toMessage(),
      now: DateTime.fromMillisecondsSinceEpoch(1700000001000, isUtc: true),
    );
    expect(decoded.executionId, requestId);
    expect(decoded.dependencies.single.output, dependencies.single.output);
    expect(decoded.payloadSha256, request.payloadSha256);
  });

  test('execution request rejects a changed objective digest', () async {
    final request = await PeerTaskExecutionRequest.create(
      executionId: requestId,
      sourceTaskId: sourceTaskId,
      sourceStepId: sourceStepId,
      goal: 'Goal',
      objective: 'Original objective',
      expectedOutput: 'Report',
      createdAtUnixMs: 1700000000000,
      expiresAtUnixMs: 1700000900000,
    );
    final altered = request.toMessage()..['objective'] = 'Injected objective';
    await expectLater(
      PeerTaskExecutionRequest.fromMessage(altered),
      throwsA(isA<PeerTaskExecutionException>()),
    );
  });

  test('execution request rejects expired invitations', () async {
    final request = await PeerTaskExecutionRequest.create(
      executionId: requestId,
      sourceTaskId: sourceTaskId,
      sourceStepId: sourceStepId,
      goal: 'Goal',
      objective: 'Objective',
      expectedOutput: 'Report',
      createdAtUnixMs: 1700000000000,
      expiresAtUnixMs: 1700000900000,
    );
    await expectLater(
      PeerTaskExecutionRequest.fromMessage(
        request.toMessage(),
        now: DateTime.fromMillisecondsSinceEpoch(1700000900000, isUtc: true),
      ),
      throwsA(isA<PeerTaskExecutionException>()),
    );
  });

  test('execution request rejects a far-future creation timestamp', () async {
    final request = await PeerTaskExecutionRequest.create(
      executionId: requestId,
      sourceTaskId: sourceTaskId,
      sourceStepId: sourceStepId,
      goal: 'Goal',
      objective: 'Objective',
      expectedOutput: 'Report',
      createdAtUnixMs: 1700001000000,
      expiresAtUnixMs: 1700001900000,
    );
    await expectLater(
      PeerTaskExecutionRequest.fromMessage(
        request.toMessage(),
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
      ),
      throwsA(isA<PeerTaskExecutionException>()),
    );
  });

  test('execution request rejects an excessive lifetime', () async {
    await expectLater(
      PeerTaskExecutionRequest.create(
        executionId: requestId,
        sourceTaskId: sourceTaskId,
        sourceStepId: sourceStepId,
        goal: 'Goal',
        objective: 'Objective',
        expectedOutput: 'Report',
        createdAtUnixMs: 1700000000000,
        expiresAtUnixMs: 1700000900001,
      ),
      throwsA(isA<PeerTaskExecutionException>()),
    );
  });

  test('execution request rejects duplicate dependency identifiers', () async {
    await expectLater(
      PeerTaskExecutionRequest.create(
        executionId: requestId,
        sourceTaskId: sourceTaskId,
        sourceStepId: sourceStepId,
        goal: 'Goal',
        objective: 'Objective',
        expectedOutput: 'Report',
        dependencies: const [
          PeerTaskDependencyResult(
            stepId: 'step_1',
            agentName: 'A',
            output: 'one',
          ),
          PeerTaskDependencyResult(
            stepId: 'step_1',
            agentName: 'B',
            output: 'two',
          ),
        ],
        createdAtUnixMs: 1700000000000,
        expiresAtUnixMs: 1700000900000,
      ),
      throwsA(isA<PeerTaskExecutionException>()),
    );
  });

  test('execution result round-trips success and authenticates output', () async {
    final result = await PeerTaskExecutionResult.create(
      executionId: requestId,
      outcome: 'succeeded',
      outputText: 'Completed local step output.',
      completedAtUnixMs: 1700000300000,
    );
    final decoded = await PeerTaskExecutionResult.fromMessage(result.toMessage());
    expect(decoded.outputText, result.outputText);
    expect(decoded.payloadSha256, result.payloadSha256);
  });

  test('execution result rejects a modified output', () async {
    final result = await PeerTaskExecutionResult.create(
      executionId: requestId,
      outcome: 'succeeded',
      outputText: 'Original output',
      completedAtUnixMs: 1700000300000,
    );
    final altered = result.toMessage()..['output_text'] = 'Modified output';
    await expectLater(
      PeerTaskExecutionResult.fromMessage(altered),
      throwsA(isA<PeerTaskExecutionException>()),
    );
  });

  test('successful execution result cannot carry an error', () async {
    await expectLater(
      PeerTaskExecutionResult.create(
        executionId: requestId,
        outcome: 'succeeded',
        outputText: 'Valid result',
        error: 'contradictory error',
        completedAtUnixMs: 1700000300000,
      ),
      throwsA(isA<PeerTaskExecutionException>()),
    );
  });

  test('failed and cancelled execution results require a reason', () async {
    for (final outcome in ['failed', 'cancelled']) {
      await expectLater(
        PeerTaskExecutionResult.create(
          executionId: requestId,
          outcome: outcome,
          outputText: '',
          completedAtUnixMs: 1700000300000,
        ),
        throwsA(isA<PeerTaskExecutionException>()),
      );
    }
  });

  test('execution state machine rejects approval bypass and terminal rewrites', () {
    expect(
      canTransitionPeerTaskExecution(
        PeerTaskExecutionStatus.awaitingApproval,
        PeerTaskExecutionStatus.running,
      ),
      isFalse,
    );
    expect(
      canTransitionPeerTaskExecution(
        PeerTaskExecutionStatus.awaitingApproval,
        PeerTaskExecutionStatus.approved,
      ),
      isTrue,
    );
    expect(
      canTransitionPeerTaskExecution(
        PeerTaskExecutionStatus.running,
        PeerTaskExecutionStatus.succeeded,
      ),
      isTrue,
    );
    expect(
      canTransitionPeerTaskExecution(
        PeerTaskExecutionStatus.approved,
        PeerTaskExecutionStatus.running,
      ),
      isTrue,
    );
    expect(
      canTransitionPeerTaskExecution(
        PeerTaskExecutionStatus.running,
        PeerTaskExecutionStatus.cancelled,
      ),
      isTrue,
    );
    expect(
      canTransitionPeerTaskExecution(
        PeerTaskExecutionStatus.awaitingApproval,
        PeerTaskExecutionStatus.cancelled,
      ),
      isTrue,
    );
    expect(
      canTransitionPeerTaskExecution(
        PeerTaskExecutionStatus.succeeded,
        PeerTaskExecutionStatus.running,
      ),
      isFalse,
    );
  });

  test('execution status has stable database wire names', () {
    expect(PeerTaskExecutionStatus.awaitingApproval.wireName, 'awaiting_approval');
    expect(
      parsePeerTaskExecutionStatus('awaiting_approval'),
      PeerTaskExecutionStatus.awaitingApproval,
    );
  });
}
