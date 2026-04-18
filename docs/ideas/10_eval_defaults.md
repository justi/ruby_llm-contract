# Proposal: eval_defaults on Step

## Problem

Steps with dynamic prompts (`system input[:system_message]`) force evals to provide the full system_message in `default_input`. This creates two sources of truth — the production method that builds the system_message (in a service/concern) and a hardcoded copy in the eval. When the prompt changes, the eval drifts silently.

Real incident: `InsertPromoLink` eval had a stripped-down system_message missing WHEN TO SKIP rules. The model always inserted links, even in unrelated comments (tramwaj → Arduino link). Live `optimize` reported 0.00 on the eval while manual tests with the production prompt passed 5/5. Root cause took 30 minutes to find.

## Proposed API

```ruby
class InsertPromoLink < RubyLLM::Contract::Step::Base
  prompt do |input|
    system input[:system_message]
    user input[:prompt_text]
  end

  eval_defaults do
    { system_message: MyApp::Prompts.link_insertion_system_message }
  end
end
```

Eval definitions inherit `eval_defaults` merged into `default_input`:

```ruby
InsertPromoLink.define_eval("smoke") do
  # system_message automatically provided by eval_defaults — no duplication
  default_input({
    prompt_text: "[ORIGINAL COMMENT]\n...",
    original_comment: "...",
    allowed_urls: ["https://example.com/page"]
  })

  sample_response({ comment: "...", link_inserted: true, ... })
  verify "link inserted", expect: ->(o) { o[:link_inserted] }
end
```

Eval can still override `system_message` in `default_input` if needed (explicit wins over default).

## When this helps

- **Step has `system input[:system_message]`** — prompt comes from a service, not from the step itself. The service builds it from persona, language, voice rules, etc. Eval needs the same prompt but has no access to the service.
- **Multiple evals per step** — each eval would otherwise duplicate the same system_message. With `eval_defaults`, it's defined once on the step.
- **Prompt iteration** — when you change the production prompt, evals automatically pick up the change. No manual sync.

## When this is unnecessary

- **Step has a static prompt** — `system "You classify tickets..."` or `system RUBRIC_CONSTANT`. The prompt lives on the step, not in external services. Eval already tests the real prompt without needing `eval_defaults`.
- **Step has `prompt "Classify: {input}"`** — simple string prompt, no system_message in input. Nothing to default.
- **One eval per step** — the duplication cost is low. A support module (current workaround) is fine.

## Data from reddit_promo_planner

11 steps total. Prompt patterns:

| pattern | count | examples | eval_defaults needed? |
|---|---|---|---|
| `system input[:system_message]` (dynamic) | 4 | GeneratePromoComment, InsertPromoLink, SelectPromoReplyTarget, GenerateFillerComment | yes |
| `system <<~SYS` (inline static) | 3 | AnalyzePromotedPage, MatchProblemsToPages, ScoreProblemCoverage | no |
| `system CONSTANT` | 2 | CheckCommentQuality, MapProblemsToLanguage | no |
| `system "string"` (one-liner) | 1 | TagSubreddits | no |

4/11 steps would benefit. The 3 that already have evals use a workaround (support module that extends the prompts concern). It works but is boilerplate that `eval_defaults` would eliminate.

## Current workaround

```ruby
# app/steps/eval/support/comment_eval_host.rb
module CommentEvalSupport
  class CommentEvalHost
    include RedditPlanner::CommentPrompts  # production module
    
    def promo_input
      { system_message: system_message_for_promo, ... }
    end
  end
end
```

This works but requires one support module per prompt source, and eval authors must know to use it instead of hardcoding.

## Implementation sketch

```ruby
# In Step::Base
def self.eval_defaults(&block)
  @eval_defaults_block = block
end

def self.resolved_eval_defaults
  @eval_defaults_block&.call || {}
end

# In EvalDefinition#build_dataset
def effective_default_input
  step.resolved_eval_defaults.merge(@default_input || {})
end
```

Lazy evaluation (block, not hash) so production methods are called at eval time, not at class load time.

## Decision

Not blocking — workaround exists and is used in production. Consider for 0.7 if more projects report the same drift issue.
