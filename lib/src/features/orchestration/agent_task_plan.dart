import 'dart:convert';

import '../agents/agent_record.dart';

enum AgentTaskStatus {
  planned,
  running,
  completed,
  failed,
  cancelled,
  interrupted,
}

enum AgentTaskStepStatus {
  pending,
  running,
  succeeded,
  failed,
  blocked,
  cancelled,
  interrupted,
}

class AgentTaskPlanStep {
  const AgentTaskPlanStep({
    required this.id,
    required this.agentId,
    required this.objective,
    required this.expectedOutput,
    this.dependsOn = const [],
  });

  final String id;
  final String agentId;
  final String objective;
  final String expectedOutput;
  final List<String> dependsOn;

  Map<String, Object?> toMap() => {
        'id': id,
        'agent_id': agentId,
        'objective': objective,
        'expected_output': expectedOutput,
        'depends_on': dependsOn,
      };
}

class AgentTaskPlan {
  const AgentTaskPlan({required this.goal, required this.steps});

  final String goal;
  final List<AgentTaskPlanStep> steps;

  String toJson() => jsonEncode({
        'schema_version': 1,
        'goal': goal,
        'steps': steps.map((step) => step.toMap()).toList(growable: false),
      });
}

class AgentTaskPlanException implements Exception {
  const AgentTaskPlanException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Strictly validates model-authored plans before they become executable.
/// A plan is a DAG and is reordered into dependency-safe execution order.
class AgentTaskPlanParser {
  const AgentTaskPlanParser._();

  static AgentTaskPlan parse(
    String source, {
    required List<AgentRecord> agents,
    int? maxSteps,
    String? expectedGoal,
  }) {
    if (maxSteps != null && maxSteps < 1) {
      throw ArgumentError.value(maxSteps, 'maxSteps');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(source.trim());
    } on FormatException {
      throw const AgentTaskPlanException(
        'لم يُرجع النموذج خطة JSON صالحة. أعد التخطيط بصيغة JSON فقط.',
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['schema_version'] != 1 ||
        decoded['goal'] is! String ||
        decoded['steps'] is! List) {
      throw const AgentTaskPlanException('بنية الخطة أو إصدارها غير صالح.');
    }
    final goal = (decoded['goal'] as String).trim();
    if (goal.isEmpty) {
      throw const AgentTaskPlanException('هدف الخطة فارغ.');
    }
    if (expectedGoal != null && goal != expectedGoal.trim()) {
      throw const AgentTaskPlanException(
        'غيّر النموذج الهدف الأصلي أثناء التخطيط. أعد إنشاء الخطة دون تعديل طلب المستخدم.',
      );
    }
    final rawSteps = decoded['steps'] as List;
    if (rawSteps.isEmpty) {
      throw const AgentTaskPlanException('الخطة لا تحتوي خطوات تنفيذ.');
    }
    if (maxSteps != null && rawSteps.length > maxSteps) {
      throw AgentTaskPlanException(
        'الخطة تحتوي ${rawSteps.length} خطوات، بينما وضع الموارد الحالي يسمح بـ $maxSteps خطوة. قلّص الخطة أو غيّر وضع الموارد.',
      );
    }
    final readyAgents = {
      for (final agent in agents)
        if (agent.status == AgentRecordStatus.ready) agent.id: agent,
    };
    final parsed = <AgentTaskPlanStep>[];
    final ids = <String>{};
    for (final raw in rawSteps) {
      if (raw is! Map<String, dynamic>) {
        throw const AgentTaskPlanException('إحدى خطوات الخطة ليست كائناً صالحاً.');
      }
      final id = raw['id'];
      final agentId = raw['agent_id'];
      final objective = raw['objective'];
      final expected = raw['expected_output'] ?? '';
      final dependencies = raw['depends_on'] ?? const <Object?>[];
      if (id is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id) ||
          !ids.add(id) ||
          agentId is! String ||
          objective is! String ||
          expected is! String ||
          dependencies is! List ||
          dependencies.any((item) => item is! String)) {
        throw const AgentTaskPlanException('حقول خطوة في الخطة غير صالحة أو مكررة.');
      }
      if (!readyAgents.containsKey(agentId)) {
        throw AgentTaskPlanException(
          'الوكيل المحدد للخطوة "$id" غير موجود أو ليس جاهزاً.',
        );
      }
      final normalizedObjective = objective.trim();
      if (normalizedObjective.isEmpty) {
        throw AgentTaskPlanException('هدف الخطوة "$id" فارغ.');
      }
      final deps = (dependencies as List).cast<String>();
      if (deps.toSet().length != deps.length || deps.contains(id)) {
        throw AgentTaskPlanException(
          'اعتماديات الخطوة "$id" مكررة أو ذاتية.',
        );
      }
      parsed.add(AgentTaskPlanStep(
        id: id,
        agentId: agentId,
        objective: normalizedObjective,
        expectedOutput: expected.trim(),
        dependsOn: List.unmodifiable(deps),
      ));
    }

    final byId = {for (final step in parsed) step.id: step};
    for (final step in parsed) {
      for (final dependency in step.dependsOn) {
        if (!byId.containsKey(dependency)) {
          throw AgentTaskPlanException(
            'الخطوة "${step.id}" تعتمد على خطوة غير موجودة "$dependency".',
          );
        }
      }
    }
    final ordered = <AgentTaskPlanStep>[];
    final visiting = <String>{};
    final visited = <String>{};
    void visit(String id) {
      if (visited.contains(id)) {
        return;
      }
      if (!visiting.add(id)) {
        throw const AgentTaskPlanException(
          'الخطة تحتوي دورة اعتماد تمنع التنفيذ.',
        );
      }
      final step = byId[id]!;
      for (final dependency in step.dependsOn) {
        visit(dependency);
      }
      visiting.remove(id);
      visited.add(id);
      ordered.add(step);
    }
    for (final step in parsed) {
      visit(step.id);
    }
    return AgentTaskPlan(goal: goal, steps: List.unmodifiable(ordered));
  }
}

String buildAgentPlanningPrompt({
  required String goal,
  required List<AgentRecord> agents,
  int? maxSteps,
}) {
  final catalog = agents
      .where((agent) => agent.status == AgentRecordStatus.ready)
      .map((agent) => {
            'id': agent.id,
            'name': agent.name,
            'description': agent.description,
          })
      .toList(growable: false);
  final countInstruction = maxSteps == null
      ? 'أنشئ جميع الخطوات اللازمة دون افتراض سقف عددي ثابت.'
      : 'اجعل عدد الخطوات $maxSteps أو أقل.';
  return '''أنت مخطط مهام محلي داخل NEXUS AI. حوّل الهدف إلى خطة قابلة للتنفيذ بواسطة الوكلاء الجاهزين فقط.
أعد JSON فقط، دون Markdown أو مقدمة، وفق البنية:
{"schema_version":1,"goal":"...","steps":[{"id":"step_1","agent_id":"معرّف وكيل من القائمة","objective":"مهمة محددة","expected_output":"شكل الناتج المتوقع","depends_on":[]}]}
قواعد إلزامية:
- $countInstruction
- استخدم معرّفات الوكلاء الموجودة حرفياً في كتالوج الوكلاء.
- اجعل كل خطوة قابلة للتحقق، وحدد الاعتماديات عند الحاجة فقط.
- يجب أن تكون الاعتماديات بلا دورات، ولا تشر إلى خطوات غير موجودة.
- لا تخترع وكلاء أو أدوات أو قدرات غير مذكورة.
- لا تطلب تشغيل shell أو شبكة أو الوصول غير المصرح به للملفات.
- خطط لوكلاء يعملون بالتتابع على نموذج محلي واحد؛ لا تفترض تنفيذًا متوازيًا.

كتالوج الوكلاء:
${jsonEncode(catalog)}

هدف المستخدم:
${jsonEncode(goal)}''';
}
