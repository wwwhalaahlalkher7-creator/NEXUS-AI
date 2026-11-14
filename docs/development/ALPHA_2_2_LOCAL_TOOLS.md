# Alpha 2.2.0 — Offline local tool registry

## Scope delivered

Alpha 2.2.0 adds a small, allow-listed local tool runtime. It is deliberately an explicit user-invoked tool surface, not an autonomous model tool-calling loop.

### Registered tools

| Tool | Command | Input | Output |
|---|---|---|---|
| Calculator | `/احسب ١٢ × (٣ + ٢)` or `/calc 12 * (3 + 2)` | Bounded arithmetic expression; Arabic/Persian numerals and common math glyphs are normalized | Display text plus original/normalized expression and numeric value |
| Local date/time | `/وقت` or `/time` | No arguments | Device-local ISO-8601 timestamp, UTC offset minutes, and time-zone label |
| Text statistics | `/إحصاء النص` or `/stats text` | Text up to 4,000 characters | Character/code-point, word and line counts |
| Registry help | `/الأدوات` or `/tools` | No arguments | List of supported commands |

The calculator uses a recursive-descent parser; it does not evaluate Dart, shell, JavaScript, or arbitrary source code. Supported operators are `+`, `-`, `*`, `/`, `%`, `^`, parentheses, and unary signs. Arabic-Indic and Persian digits, the Arabic decimal/thousands separators, and common multiplication/division/minus glyphs are normalized before parsing. Division by zero, malformed tokens, non-finite results, expressions over 256 characters and exponents with an absolute value above 12 are rejected.

### Execution contract

- Every tool has a stable identifier, schema version, description, risk class, timeout and typed parameter schema.
- The registry validates allowed parameter names, required fields, value types, string limits and JSON-encoded input bytes before calling a tool.
- The standard registry is allow-listed; no arbitrary shell, network client or unrestricted filesystem tool is registered.
- Per-session attempts are capped at three. Attempts count even when rejected or failed.
- Each tool has a timeout. A cooperative cancellation token is sent to the tool on timeout or explicit cancellation. The session remains locked until the source task actually exits, because Dart `Future.timeout` does not forcibly terminate its source future.
- Output text is truncated to the configured Unicode code-point budget without splitting surrogate pairs, and structured JSON data is discarded when it exceeds its separate encoded-size budget.
- Cancellation is recorded separately from a policy/schema rejection; a busy execution session rejects overlapping calls until the active source task exits.
- Tools classified as modifying local data or using external access require `userApproved=true`. The initial tools are read-only; no approval UI for future mutating tools is claimed by this milestone.
- Tool results are persisted as `MessageRole.tool` records with a versioned audit envelope; the existing SQLite `tool` role is reused, so database schema version 5 remains unchanged.

### Chat commands

Local commands are evaluated before the model-loaded check, so they work on Android even when no GGUF session is active. The input remains disabled on unsupported platforms. Ordinary text continues to the selected model as before. Any leading slash is reserved for local commands; unknown commands fail closed and show `/tools` guidance.

### Tests

`test/local_tool_registry_test.dart` covers arithmetic precedence, exponent associativity, Arabic/Persian numeral normalization, malformed expressions, type/schema rejection, confirmation policy, argument/output limits, Unicode-safe truncation, timeouts, cooperative cancellation, overlapping-call rejection, session call budgets, audit round trips, local clock injection and text statistics. `test/local_tool_command_parser_test.dart` covers explicit command parsing and fail-closed unknown commands. `scripts/test_local_tools_contract.py` checks the allow-list, execution limits, persistence role and absence of shell/network execution primitives in the default tool layer.

## Explicit limitations

- The model does not yet autonomously emit tool calls. Users invoke the commands directly in the chat composer.
- The current local tools are deterministic and read-only.
- A timeout is not hard preemption. Future tools that can modify files or access devices must implement cooperative cancellation and idempotency before being exposed.
- File search/RAG, network tools, shell execution, background jobs, multi-agent planning and delegation are not included.
- Host-side and static checks do not prove Android runtime behavior. CI and a physical ARM64 device remain the acceptance gates.
