# Architecture

```
RubyLLM::Contract::Pipeline::Base   # optional: compose steps
  ├── Pipeline::Runner           # sequential execution, fail-fast, trace, timeout
  └── Pipeline::Result           # per-step outputs + aggregated trace

RubyLLM::Contract::Step::Base       # single contracted step
  ├── Step::Dsl                  # DSL macros (prompt, validate, output_schema, etc.)
  ├── Step::RetryPolicy          # attempts, models, reasoning_effort, retry_on
  ├── Step::RetryExecutor        # retry loop driven by RetryPolicy
  ├── Step::LimitChecker         # preflight cost / input / output checks
  ├── Step::Runner               # runtime flow (single attempt)
  ├── Step::Result               # status + outputs + errors + trace
  ├── Step::Trace                # model, latency, tokens, cost, attempts
  ├── Prompt::AST                # structured prompt (immutable)
  │     ├── Prompt::Builder      # DSL: system, rule, example, user, section
  │     └── Prompt::Renderer     # AST → messages array
  ├── Contract::Definition       # parse strategy + validates
  │     ├── Contract::Parser     # :json / :text (auto-inferred from output type)
  │     ├── Contract::Validator  # runs parse + schema + validates + observations
  │     └── Contract::SchemaValidator  # JSON Schema validation (nested)
  ├── CostCalculator             # per-step cost estimation from model pricing
  ├── TokenEstimator             # input-token count estimation for limit checks
  ├── estimate_cost              # single-call cost estimate (class method)
  ├── estimate_eval_cost         # cost estimate for a full eval across models
  └── Adapters::Base             # provider interface
        ├── Adapters::RubyLLM    # real LLM calls via ruby_llm (any provider)
        └── Adapters::Test       # canned responses for specs and examples

RubyLLM::Contract::Eval             # quality measurement
  ├── Eval::EvalDefinition       # define_eval DSL (verify, add_case, default_input, sample_response)
  ├── Eval::Dataset              # test cases
  ├── Eval::Runner               # sequential or concurrent execution
  ├── Eval::Report               # score, pass_rate, per-case results
  ├── Eval::AggregatedReport     # merged reports across models or runs
  ├── Eval::CaseResult           # value object (name, passed?, output, expected, mismatches, cost)
  ├── Eval::ExpectationEvaluator # expected / expected_traits / evaluator proc
  ├── Eval::ModelComparison      # compare_models result (table, best_for, candidate configs)
  ├── Eval::Recommender          # model recommendation algorithm (candidates → optimal config)
  ├── Eval::Recommendation       # recommendation result (best, retry_chain, savings, to_dsl)
  ├── Eval::RetryOptimizer       # optimize_retry_policy result (per-eval breakdown, fallback list)
  ├── Eval::BaselineDiff         # save_baseline! + without_regressions comparison
  ├── Eval::PromptDiffComparator # compare_with prompt A/B diff
  └── Eval::EvalHistory          # time-series view across saved reports

RubyLLM::Contract::RakeTask         # rake ruby_llm_contract:eval
RubyLLM::Contract::OptimizeRakeTask # rake ruby_llm_contract:optimize
RubyLLM::Contract::Railtie          # auto-loads eval files in Rails
```
