# Model runtime adapter

This directory reserves the integration boundary for local inference engines.

Planned contract:
- discover runtime availability;
- inspect model metadata;
- load/unload a model with explicit resource limits;
- stream generated tokens;
- cancel a running generation.

**Current status:** documentation only. llama.cpp is not linked, no model is bundled, and no inference is available in Alpha 0.1.
