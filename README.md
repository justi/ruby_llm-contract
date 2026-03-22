# ruby_llm-contract

Contracts for LLM calls. Validate every response, retry with smarter models, catch bad answers before production.

Companion gem for [ruby_llm](https://github.com/crmne/ruby_llm).

## The problem

```ruby
response = RubyLLM.chat(model: "gpt-4.1-mini").ask(prompt)
parsed = JSON.parse(response.content)  # crashes when LLM returns prose
priority = parsed["priority"]          # "urgent"? "CRITICAL"? nil?
```

JSON parsing crashes. Wrong values slip through. You switch models and quality drops silently.

## The fix

Same prompt, wrapped in a contract:

```ruby
class ClassifyTicket < RubyLLM::Contract::Step::Base
  prompt <<~PROMPT
    Classify this support ticket by priority.
    Return JSON with a "priority" field.

    {input}
  PROMPT

  validate("valid priority") { |o| %w[low medium high urgent].include?(o[:priority]) }
  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini gpt-4.1]
end

result = ClassifyTicket.run(ticket_text)
result.ok?               # => true
result.parsed_output     # => {priority: "high"}
result.trace[:attempts]  # => [{model: "gpt-4.1-nano", status: :ok}]
```

Bad JSON? `:parse_error`. Wrong value? `:validation_failed` and auto-retry on a smarter model. Network timeout? Auto-retry. All with cost tracking.

> `{input}` is a gem placeholder (not Ruby `#{}`). Replaced at runtime with the value you pass to `run()`.

## Install

```ruby
gem "ruby_llm-contract"
```

```ruby
RubyLLM.configure { |c| c.openai_api_key = ENV["OPENAI_API_KEY"] }
RubyLLM::Contract.configure { |c| c.default_model = "gpt-4.1-mini" }
```

Works with any ruby_llm provider (OpenAI, Anthropic, Gemini, etc).

## What you get

- **Validated responses** — `validate` blocks catch wrong answers; `output_schema` enforces JSON structure via provider AND client-side
- **Model escalation** — `retry_policy models: %w[nano mini full]` starts cheap, auto-escalates when contract fails. 90% of requests succeed on nano. ~$40/mo instead of ~$200 at 10k requests.
- **Cost control** — `max_input`, `max_cost` refuse before calling the LLM. Zero tokens spent on oversized input.
- **Eval in CI** — `add_case input:, expected:` defines regression tests. `pass_eval("regression").with_minimum_score(0.8)` gates merges. `rake ruby_llm_contract:eval` runs all evals. No other Ruby gem does this.
- **Defensive parsing** — code fences, BOM, prose wrapping, `null` responses — 14 edge cases handled
- **Pipeline** — chain steps with fail-fast. Hallucination in step 1 stops before step 2 runs.
- **Testing** — `RubyLLM::Contract::Adapters::Test` for deterministic specs, `satisfy_contract` RSpec matcher

## Gotchas

**`output_schema` vs `with_schema`:** `with_schema` asks the provider to return specific JSON. `output_schema` does the same (calls `with_schema` under the hood) **plus** validates client-side. Cheap models sometimes ignore schema — `output_schema` catches that.

**Nested schema needs `object do...end`:**
```ruby
# WRONG — array of strings:
array :groups do; string :who; end

# RIGHT — array of objects:
array :groups do; object do; string :who; end; end
```

**Schema validates shape, not meaning.** LLM returns `{"priority": "low"}` for a data loss incident — valid JSON, wrong answer. Always add `validate` blocks.

## Docs

| Guide | |
|-------|-|
| [Getting Started](docs/guide/getting_started.md) | Features walkthrough, model escalation, eval, structured/dynamic prompts |
| [Best Practices](docs/guide/best_practices.md) | 6 patterns for bulletproof validates |
| [Output Schema](docs/guide/output_schema.md) | Full schema reference + constraints |
| [Pipeline](docs/guide/pipeline.md) | Multi-step composition, timeout, fail-fast |
| [Testing](docs/guide/testing.md) | Test adapter, RSpec matchers |
| [Prompt AST](docs/guide/prompt_ast.md) | Node types, interpolation |
| [Architecture](docs/architecture.md) | Module diagram |

## Roadmap

**v0.2 (current) — eval that matters:**
- [x] Dataset eval with `add_case input:, expected:` (partial matching)
- [x] Online eval — real LLM calls, compare output vs expected
- [x] CI gate — `pass_eval("regression").with_minimum_score(0.8)` + Rake task
- [x] Model comparison — same dataset on nano vs mini vs full
- [x] `CaseResult` value objects with `.name`, `.passed?`, `.mismatches`
- [x] `RubyLLM::Contract.run_all_evals` — discover and run all evals
- [x] Rails Railtie — auto-load eval files from `app/steps/eval/`

**v0.3:**
- [ ] Regression baselines — compare eval results with previous run
- [ ] Eval persistence — store history for drift detection

**v0.4:**
- [ ] Auto-routing — learn which model works for which input patterns
- [ ] Contract-level dashboard

## License

MIT
