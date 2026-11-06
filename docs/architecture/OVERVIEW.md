# NEXUS AI architecture — initial boundary

```text
Flutter UI
   |
   | (bridge is intentionally deferred)
   v
Rust Core
   |-- Shared domain types
   |-- Agent registry (in-memory in this phase)
   |-- Model registry contract (next phase)
   |
   +-- Future local persistence: SQLite
   +-- Future inference adapter: llama.cpp
   +-- Future node services: identity / resource monitor / network
```

## Key decision
The first distributed unit will be an **agent task**, not a shard of one model. Each device should remain useful independently when disconnected.

## Trust boundaries
- The UI requests operations; it does not decide authorization.
- The model/LLM is untrusted input to the policy layer.
- Remote devices are untrusted until paired and authenticated.
- Filesystem, shell, network and device-control tools require scoped permissions.
- Destructive or externally visible actions require explicit confirmation.

## Deferred engineering decisions
- Flutter-Rust bridge mechanism and code generation.
- SQLite schema and migration strategy.
- llama.cpp build strategy for Android ABIs.
- Device discovery transport and authenticated pairing.
