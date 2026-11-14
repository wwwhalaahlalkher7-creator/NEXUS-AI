#!/usr/bin/env python3
"""Static contract checks for the sequential multi-agent orchestration boundary."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
plan = (ROOT / "lib/src/features/orchestration/agent_task_plan.dart").read_text(encoding="utf-8")
runner = (ROOT / "lib/src/features/orchestration/agent_task_orchestrator.dart").read_text(encoding="utf-8")
executor = (ROOT / "lib/src/features/orchestration/local_llama_agent_executor.dart").read_text(encoding="utf-8")
page = (ROOT / "lib/src/features/orchestration/agent_tasks_page.dart").read_text(encoding="utf-8")

checks = {
    "strict JSON plan schema": "schema_version" in plan and "jsonDecode(source.trim())" in plan,
    "ready-agent validation": "AgentRecordStatus.ready" in plan,
    "dependency cycle detection": "!visiting.add(id)" in plan,
    "topological dependency ordering": "ordered.add(step)" in plan,
    "shared task cancellation": "AgentTaskCancellationToken" in runner,
    "step reservation prevents duplicate execution": "_repository.startStep(taskId, step.stepKey)" in runner,
    "dependency outputs are explicit handoffs": "AgentTaskDependencyOutput" in runner,
    "sequential single-session execution": "await _executor.execute" in runner,
    "model-switch routing": "_runtimeManager.switchTo(target)" in executor,
    "restore pre-task model session": "restorePreviousSession()" in executor and "await executor.restorePreviousSession()" in page,
    "planner restores pre-planning model session": "await executor.createPlan(" in page and "await executor.restorePreviousSession()" in page,
    "task detail futures are cached": "_stepsFuture(task.id)" in page and "_eventsFuture(task.id)" in page,
    "native generation lease": "_runtimeManager.beginGeneration()" in executor and "_runtimeManager.endGeneration()" in executor,
    "sub-agent cannot recursively delegate": "لا تنشئ خططاً فرعية ولا تفوض لوكلاء آخرين" in executor,
    "previous step outputs marked untrusted": "غير موثوقة" in executor,
    "user approval before task execution": "تنفيذ خطة الوكلاء؟" in page and "confirmed != true" in page,
    "task execution cancellation UI": "إيقاف التنفيذ" in page,
    "execution event trace is visible in task history": "سجل التنفيذ" in page and "_eventsFuture(task.id)" in page,
    "cancel-before-model-switch is checked": executor.find("cancellationToken.throwIfCancelled();") < executor.find("await _ensureAgentModel(agent)"),
    "cancel-before-generate race is checked": "cancellationToken.throwIfCancelled();" in executor[executor.find("cancellationToken.bind"):],
    "planning and execution cannot overlap": "if (_planning || _executing)" in page and "if (_executing || _planning)" in page,
    "planner cannot silently rewrite user goal": "expectedGoal: goal" in page and "goal != expectedGoal.trim()" in plan,
    "handoff trimming preserves prompt tail": "runes.skip(runes.length - suffixLength)" in executor,
}
failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Orchestration contract failures: " + ", ".join(failed))
print(f"Agent orchestration contract PASS: {len(checks)} checks")
