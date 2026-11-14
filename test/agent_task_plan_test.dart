import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/agents/agent_record.dart';
import 'package:nexus_app/src/features/orchestration/agent_task_plan.dart';

void main() {
  final agents = [
    AgentRecord(
      id: 'researcher',
      name: 'باحث',
      description: 'جمع المعلومات',
      status: AgentRecordStatus.ready,
      createdAtUnixMs: 1,
    ),
    AgentRecord(
      id: 'writer',
      name: 'كاتب',
      description: 'صياغة النتائج',
      status: AgentRecordStatus.ready,
      createdAtUnixMs: 2,
    ),
    AgentRecord(
      id: 'paused',
      name: 'متوقف',
      description: '',
      status: AgentRecordStatus.paused,
      createdAtUnixMs: 3,
    ),
  ];

  String planJson(List<Map<String, Object?>> steps) => jsonEncode({
        'schema_version': 1,
        'goal': 'إعداد تقرير',
        'steps': steps,
      });

  test('reorders dependency graph into executable topological order', () {
    final plan = AgentTaskPlanParser.parse(
      planJson([
        {
          'id': 'write',
          'agent_id': 'writer',
          'objective': 'اكتب التقرير',
          'expected_output': 'تقرير',
          'depends_on': ['research'],
        },
        {
          'id': 'research',
          'agent_id': 'researcher',
          'objective': 'اجمع المعلومات',
          'expected_output': 'ملخص المصادر',
          'depends_on': [],
        },
      ]),
      agents: agents,
      maxSteps: 8,
    );

    expect(plan.steps.map((step) => step.id), ['research', 'write']);
    expect(plan.goal, 'إعداد تقرير');
  });

  test('rejects cyclic dependencies', () {
    expect(
      () => AgentTaskPlanParser.parse(
        planJson([
          {
            'id': 'a',
            'agent_id': 'researcher',
            'objective': 'أ',
            'depends_on': ['b'],
          },
          {
            'id': 'b',
            'agent_id': 'writer',
            'objective': 'ب',
            'depends_on': ['a'],
          },
        ]),
        agents: agents,
      ),
      throwsA(isA<AgentTaskPlanException>()),
    );
  });

  test('rejects unknown or non-ready agent assignments', () {
    expect(
      () => AgentTaskPlanParser.parse(
        planJson([
          {
            'id': 'a',
            'agent_id': 'paused',
            'objective': 'مهمة',
            'depends_on': [],
          },
        ]),
        agents: agents,
      ),
      throwsA(isA<AgentTaskPlanException>()),
    );
  });

  test('rejects duplicate step identifiers and budget overflow', () {
    final duplicate = [
      {
        'id': 'same',
        'agent_id': 'researcher',
        'objective': 'الأولى',
        'depends_on': [],
      },
      {
        'id': 'same',
        'agent_id': 'writer',
        'objective': 'الثانية',
        'depends_on': [],
      },
    ];
    expect(
      () => AgentTaskPlanParser.parse(planJson(duplicate), agents: agents),
      throwsA(isA<AgentTaskPlanException>()),
    );

    expect(
      () => AgentTaskPlanParser.parse(
        planJson([duplicate.first]),
        agents: agents,
        maxSteps: 0,
      ),
      throwsArgumentError,
    );
  });

  test('rejects a planner that changes the user goal', () {
    final source = planJson([
      {
        'id': 'research',
        'agent_id': 'researcher',
        'objective': 'اجمع المعلومات',
        'depends_on': [],
      },
    ]);
    expect(
      () => AgentTaskPlanParser.parse(
        source,
        agents: agents,
        expectedGoal: 'هدف مختلف',
      ),
      throwsA(isA<AgentTaskPlanException>()),
    );
  });

  test('open planning prompt has no fixed step quota', () {
    final prompt = buildAgentPlanningPrompt(
      goal: 'حلل موضوعاً',
      agents: agents,
      maxSteps: null,
    );
    expect(prompt, contains('دون افتراض سقف عددي ثابت'));
    expect(prompt, isNot(contains('الوكيل المتوقف')));
  });
}
