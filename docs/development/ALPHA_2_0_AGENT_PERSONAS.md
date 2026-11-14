# Alpha 2.0.0 — Agent personas and conversation binding

## Scope

This milestone moves local agents from saved metadata into the inference path.

- Add a bounded `system_prompt` field (maximum 3,000 characters) to each agent.
- Add an agent-instructions editor to the agent list and allow instructions during agent creation.
- Add nullable `agent_id` to conversations. Existing conversations remain unassigned.
- Store the selected agent when creating a conversation and persist later agent changes.
- Restore the selected agent when reopening a conversation.
- Prepend the selected agent persona as a system message to the role-aware request sent to the Rust bridge.
- Do not duplicate persona instructions in the visible transcript or SQLite messages.
- Require the selected agent to be `ready` before generation.
- When an agent has a model assigned, require that same model ID to be the active loaded model. This milestone does not switch model sessions automatically.
- When an agent is deleted, SQLite `ON DELETE SET NULL` preserves its conversations as general chats.

## Persistence

SQLite schema version 5 adds `agents.system_prompt TEXT NOT NULL DEFAULT ''` and nullable `conversations.agent_id` with an index and `ON DELETE SET NULL`. The migration retains all existing agent and conversation rows.

## Context contract

The persona is inserted as the first `system` message. Existing durable completed messages retain chronological order. The existing transport limits and native tokenizer-aware trim remain authoritative; system messages and the current user message are preserved by the context builder/native adapter.

## Verification

- `scripts/test_agent_persona_migration.py` verifies the v5 migration against SQLite, including old-row preservation and safe unbinding on agent deletion.
- Flutter unit/widget tests cover record round-tripping, prompt injection, prompt bounds, and editing an agent's instructions.
- Flutter analyze and test remain mandatory parallel CI gates.
- Rust formatting, workspace tests and Clippy remain strict.
- CI builds an Android ARM64 debug APK at this development stage. A signed Release APK and real-device performance / inference checks remain release milestones.

## Explicit non-goals

Tool execution, agent-to-agent delegation, planning loops, remote discovery/pairing, distributed inference, GPU backends, vision/audio, model auto-switching and cloud synchronization are not included in Alpha 2.0.0.
