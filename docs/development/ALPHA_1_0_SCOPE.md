# NEXUS AI — Alpha 1.0: Agent lifecycle

## Goal
Provide reliable local lifecycle management for agent definitions without implying that agents can execute tasks yet.

## Included
- AgentStore interface to allow deterministic UI tests and future storage adapters.
- SQLite-backed create/list/get/update-status/delete operations.
- Draft, Ready, and Paused status controls in the agent list.
- Status-specific labels; Ready explicitly states that no inference engine is attached.
- Busy-state protection, duplicate action prevention, error feedback, refresh, and delete confirmation.
- Input limits for agent names and descriptions.
- Widget tests for draft-to-ready and ready-to-paused-to-ready transitions.

## Not included
- Agent execution, tool invocation, model assignment, scheduling, permissions, or background work.
- Distributed agents or network transport.

## Acceptance criteria
- Status changes persist through AgentStore and render after reload.
- Invalid empty names cannot be saved.
- UI never reports an agent as executing or an inference engine as active.
- Existing Rust, Flutter, and APK CI gates remain enabled.
