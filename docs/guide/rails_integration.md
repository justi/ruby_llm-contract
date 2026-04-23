# Rails integration

> Read this when you've seen the `SummarizeArticle` example and want to know where contract steps fit in an actual Rails app — directory, initializer, jobs, logging, tests, CI. Skip if you're writing a non-Rails script.

Seven pre-emptive answers to the questions that come up first.

## 1. Where do step classes live?

**Recommended: `app/contracts/`.** The gem's Railtie auto-reloads eval files under `app/contracts/eval/` and `app/steps/eval/` in development, so picking `app/contracts/` aligns with the default reload paths.

```
app/contracts/summarize_article.rb   # class SummarizeArticle
```

Any autoloaded directory works (`app/llm_steps/`, `app/services/llm/`, etc.) — Rails 7/8 autoloading resolves them all, and the step class itself does not depend on the path. Pick the default if you have no stronger convention.

Keep evals in the same file as the step (`define_eval` block at the bottom of the class) — one source of truth per contract. If your evals grow too large for the class file, move them to `app/contracts/eval/summarize_article_eval.rb` — the Railtie reloads that directory explicitly in development.

## 2. Initializer configuration

```ruby
# config/initializers/ruby_llm_contract.rb
RubyLLM.configure do |c|
  c.openai_api_key    = ENV.fetch("OPENAI_API_KEY", nil)
  c.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY", nil)
end

RubyLLM::Contract.configure do |c|
  c.default_model   = Rails.env.production? ? "gpt-5-mini" : "gpt-5-nano"
  c.default_adapter = RubyLLM::Contract::Adapters::RubyLLM.new
end
```

In specs, override the default adapter to `Adapters::Test` in `spec_helper.rb` (or use `stub_step` per-example — see §5).

Evals defined inside a step class (the recommended pattern) are picked up as soon as Rails autoloads the class — you do not need the eval file in any special directory. If you move evals into separate files under `app/contracts/eval/` or `app/steps/eval/`, the gem's Railtie reloads those two directories explicitly on each request in development; other directories follow standard Rails autoloading rules.

## 3. Background jobs — never call LLMs inline in a controller

LLM calls take 0.8–5 seconds and can fail. Wrap every step invocation in an ActiveJob:

```ruby
class SummarizeArticleJob < ApplicationJob
  queue_as :llm

  def perform(article_id)
    article = Article.find(article_id)
    result  = SummarizeArticle.run(article.body)

    if result.ok?
      # parsed_output uses symbol keys in memory. jsonb/json columns round-trip
      # as strings on reload, so either use deep_stringify_keys before write or
      # access downstream with string keys — pick one convention and stick to it.
      article.update!(summary: result.parsed_output.deep_stringify_keys)
    else
      article.update!(summary_error: result.validation_errors.join("; "))
    end
  end
end
```

`SummarizeArticleJob.perform_later(article.id)` returns in milliseconds; the controller stays responsive. If you use Sidekiq, pair `queue_as :llm` with a dedicated concurrency cap in `sidekiq.yml` so long-running LLM calls do not starve other job queues (mailers, webhooks, cleanups).

## 4. Logging and observability

`around_call` runs once per `run()` with the final `Result` (after all retries). Use it to write one row per LLM call:

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  # ... prompt, schema, validates ...

  around_call do |step, input, result|
    AiCallLog.create!(
      step: step.name,
      model: result.trace[:model],
      status: result.status.to_s,
      latency_ms: result.trace[:latency_ms],
      input_tokens: result.trace[:usage]&.dig(:input_tokens),
      output_tokens: result.trace[:usage]&.dig(:output_tokens),
      cost: result.trace[:cost],
      validation_errors: result.validation_errors
    )
  end
end
```

The `AiCallLog` model assumed above is a thin audit record. One possible migration:

```ruby
# rails g model AiCallLog step:string model:string status:string ...
create_table :ai_call_logs do |t|
  t.string  :step, null: false
  t.string  :model
  t.string  :status, null: false
  t.integer :latency_ms
  t.integer :input_tokens
  t.integer :output_tokens
  t.decimal :cost, precision: 10, scale: 6
  t.jsonb   :validation_errors, default: []
  t.timestamps
end
add_index :ai_call_logs, :step
add_index :ai_call_logs, :status
```

For Appsignal / Honeybadger / Datadog, emit an `ActiveSupport::Notifications` event from inside the same `around_call` and subscribe in an initializer:

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  # ... prompt, schema, validates ...

  around_call do |step, _input, result|
    ActiveSupport::Notifications.instrument(
      "ruby_llm_contract.run",
      step: step.name, model: result.trace[:model], status: result.status
    )
  end
end

# config/initializers/observability.rb
ActiveSupport::Notifications.subscribe("ruby_llm_contract.run") do |*, payload|
  Appsignal.increment_counter("llm.run.#{payload[:status]}", 1, step: payload[:step])
end
```

Trace inspection in an admin UI: `result.trace[:attempts]` gives you per-attempt model, status, cost, latency — render it in a partial to debug production failures without re-running.

## 5. Testing — RSpec and Minitest

Add to `spec/spec_helper.rb` (or `test_helper.rb`):

```ruby
require "ruby_llm/contract/rspec"    # or ruby_llm/contract/minitest
```

Then in specs:

```ruby
RSpec.describe ArticlesController do
  it "saves the summary when the step passes" do
    stub_step(SummarizeArticle, response: {
      tldr: "...", takeaways: %w[a b c], tone: "analytical"
    })

    post :summarize, params: { id: article.id }

    # NOTE: jsonb/json column round-trips as string keys on reload.
    expect(article.reload.summary["tldr"]).to eq("...")
  end
end
```

For the step itself, use the `satisfy_contract` and `pass_eval` matchers — details in the [Testing guide](testing.md).

## 6. Error handling in controllers

Never raise on `result.failed?` — that crashes the request. Branch instead:

```ruby
class ArticlesController < ApplicationController
  def summarize
    SummarizeArticleJob.perform_later(params[:id])
    head :accepted
  end

  # For synchronous cases (admin tools, small content):
  def preview
    result = SummarizeArticle.run(@article.body)

    if result.ok?
      render json: result.parsed_output
    else
      Rails.logger.warn "[llm] #{SummarizeArticle.name} failed: #{result.status}"
      render json: { error: "Could not summarize; try again shortly." }, status: :service_unavailable
    end
  end
end
```

When `retry_policy` exhausts and all models fail, `result.failed?` is true but `result.parsed_output` still contains the last attempt's output — useful for logging what the model *did* return before the validate rejected it.

## 7. CI gate — block regressions before merge

Add to your `Rakefile`:

```ruby
require "ruby_llm/contract/rake_task"

RubyLLM::Contract::RakeTask.new do |t|
  t.minimum_score      = 0.8
  t.maximum_cost       = 0.05
  t.fail_on_regression = true
  t.save_baseline      = false # read-only in CI; refresh baselines manually
end
```

Then wire it in GitHub Actions:

```yaml
- name: LLM contract evals
  env:
    OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
  run: bundle exec rake ruby_llm_contract:eval
```

The job fails when a previously-passing eval case now fails, when the average score drops below the threshold, or when total cost exceeds the cap. That is the signal that blocks a prompt regression or an accidental model upgrade from shipping.

**Two practical notes:**

- **Live evals spend real money on every run** — provider tokens per case × number of cases × every merge. Keep the dataset small and targeted (5–15 high-value cases), use cheap models where quality allows, and rely on offline `sample_response` smoke tests in the bulk of CI runs. Live evals belong on merge-candidate branches and scheduled nightly runs, not on every commit.
- **Baselines are checkout-managed** — commit them to git under `.eval_baselines/`. Refresh them in a separate manual workflow (or locally + a dedicated PR) rather than from the merge gate, which would dirty the checkout and race with the regression check it is supposed to run.

## See also

- [Getting Started](getting_started.md) — the feature walkthrough the step above is built on
- [Migration](migration.md) — before/after for replacing a raw `LlmClient.new.call` service with a contract
- [Eval-First](eval_first.md) — the workflow behind the CI gate above
- [Testing](testing.md) — `satisfy_contract` and `pass_eval` matcher chains
