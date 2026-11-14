# Alpha 2.3.0 — Autonomous local tool calling

Historical protocol baseline. Alpha 2.4.1 makes the envelope and per-turn budgets mode-aware: Balanced keeps 8 KiB / 3 attempts, Performance expands them, and Unrestricted removes those application-level ceilings. The read-only allow-list, schema validation, cancellation, and per-operation timeout remain.

## Scope

Alpha 2.3 connects model-emitted requests to the Alpha 2.2 allow-listed local tool registry. The model cannot invoke arbitrary Dart code, shell commands, native commands, network requests, or unrestricted filesystem operations.

## Protocol

A request must be the complete assistant response and match this JSON envelope exactly:

```json
{"nexus_tool_call":{"name":"calculator","arguments":{"expression":"2+2"},"reason":"Compute the sum"}}
```

The envelope has one top-level key (`nexus_tool_call`). Its payload permits only `name`, `arguments`, and optional `reason`. Names are syntactically bounded and then checked against the registry. Arguments must be a JSON object and pass the same typed schema, required-field, length and encoded-byte validation as explicit local commands. The entire envelope is capped at 8 KiB. Prose before/after the JSON, Markdown fences, partial JSON, extra fields and malformed payloads are not executed.

The system prompt advertises only read-only tools and includes their exact schema. Tools that require user confirmation are not advertised in this milestone. An unknown but well-formed tool name reaches the registry and is rejected by the allow-list.

## Execution lifecycle

1. Stream a normal model response.
2. At terminal completion only, attempt strict envelope parsing.
3. Persist the assistant request as a completed assistant message.
4. Execute through one `LocalToolExecutionSession` shared by the user turn.
5. Persist the versioned result as a `tool` role message.
6. Rebuild bounded role-aware context and resume model generation.
7. When the model returns ordinary text, persist it as the final assistant response.

Each user turn permits at most three tool attempts. Rejected and failed attempts count toward the budget. A fourth request is recorded as rejected but never executed. The follow-up system instruction disables further requests after the budget is spent. Tool calls run sequentially; overlapping executions are rejected. Timeout and user cancellation use the existing cooperative cancellation contract; timeouts do not falsely claim that Dart has forcibly preempted a tool.

## Context behavior

The context builder supports a tool result as the end of an intermediate turn and inserts the selected agent persona plus a separate tool-protocol system instruction. When trimming, it removes complete earlier interactions and preserves the latest user turn together with its assistant tool-call and tool-result chain. It fails closed if the current interaction alone exceeds the transport budget. Both the Rust boundary and the native adapter validate that a continuation ends with a tool result immediately after an assistant tool request, while still requiring a user turn earlier in the payload. If a model's embedded chat template rejects the generic `tool` role, the native adapter retries that bounded result as a user message prefixed as data-only tool output; the database continues to preserve the original `tool` role.

## UI behavior

A valid assistant tool-call envelope is rendered as a localized request summary, not raw JSON. Tool results remain distinct cards with execution status. While a tool is running, the user can request cooperative cancellation; agent switching, conversation navigation and new prompts remain disabled until the operation exits.

## Tests and limitations

`test/model_tool_call_test.dart` covers strict envelopes, ordinary prose, Markdown/partial/malformed responses, schema prompt filtering, execution routing and per-turn budget behavior. `test/conversation_context_builder_test.dart` covers tool-continuation messages and trimming without orphaning the current tool cycle. `scripts/test_local_tools_contract.py` asserts the model protocol is wired to the existing local allow-list.

These are source-level and host contract checks. The native adapter test exercises the role validation and chat-template compatibility retry against a fake llama API, not an actual model or template. The actual model's willingness to emit the exact JSON protocol is model-dependent; CI compilation and a physical Android ARM64 test with real GGUF models are required before claiming end-to-end tool use. No tool calling or inference claim is based on the fake host llama adapter test.
