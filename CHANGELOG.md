# Changelog

## 0.1.0 (2026-03-20)

Initial release.

### Features

- **Step abstraction** — `RubyLLM::Contract::Step::Base` with prompt DSL, typed input/output
- **Output schema** — declarative structure via ruby_llm-schema, sent to provider for enforcement
- **Validate** — business logic checks (1-arity and 2-arity with input cross-validation)
- **Retry with model escalation** — start cheap, auto-escalate on contract failure or network error
- **Preflight limits** — `max_input`, `max_cost`, `max_output` refuse before calling the LLM
- **Pipeline** — multi-step composition with fail-fast, timeout, token budget
- **Eval** — offline contract verification with `define_eval`, `run_eval`, zero-verify auto-case
- **Adapters** — RubyLLM (production), Test (deterministic specs)
- **RSpec matchers** — `satisfy_contract`, `pass_eval`
- **Structured trace** — model, latency, tokens, cost, attempt log per step

### Robustness

- 1005 tests, 0 failures
- 42 bugs found and fixed via 10 rounds of adversarial testing
- 0 RuboCop offenses
- Parser handles: markdown code fences, UTF-8 BOM, JSON extraction from prose
- SchemaValidator: full nested validation, additionalProperties, minItems/maxItems, minLength/maxLength
- Deep-frozen parsed_output prevents mutation via shared references
