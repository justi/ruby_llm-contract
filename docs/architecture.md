# Architecture

```
RubyLLM::Contract::Pipeline::Base   # optional: compose steps
  └── Pipeline::Runner           # sequential execution, fail-fast, trace, timeout

RubyLLM::Contract::Step::Base       # single contracted step
  ├── Step::Dsl                  # DSL macros (prompt, validate, output_schema, etc.)
  ├── Step::RetryExecutor        # retry with model escalation
  ├── Step::LimitChecker         # preflight cost/token checks
  ├── Prompt::AST                # structured prompt (immutable)
  │     ├── Prompt::Builder      # DSL: system, rule, example, user, section
  │     └── Prompt::Renderer     # AST → messages array
  ├── Contract::Definition       # parse strategy + validates
  │     ├── Contract::Parser     # :json / :text (auto-inferred from output type)
  │     ├── Contract::Validator  # runs parse + schema + validates
  │     └── Contract::SchemaValidator  # JSON Schema validation (nested)
  ├── Step::Runner               # runtime flow
  ├── Step::Result               # status + outputs + errors + trace
  ├── Step::Trace                # model, latency, tokens, cost
  └── Adapters::Base             # provider interface
        ├── Adapters::RubyLLM    # real LLM calls via ruby_llm
        └── Adapters::Test       # canned responses for specs

RubyLLM::Contract::Eval             # quality measurement
  ├── Eval::EvalDefinition       # define_eval DSL (verify, default_input, sample_response)
  ├── Eval::TraitEvaluator       # trait-based evaluation (Range, Regexp, Proc)
  ├── Eval::Dataset              # test cases
  ├── Eval::Runner               # execution
  └── Eval::Report               # score, pass_rate, per-case results
```
