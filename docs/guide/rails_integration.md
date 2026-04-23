# Rails integration

> Read this when you've seen the `SummarizeArticle` example and want to know where contract steps fit in an actual Rails app — directory, initializer, jobs, logging, tests, CI. Skip if you're writing a non-Rails script.

Seven pre-emptive answers to the questions that come up first.

## 1. Where do step classes live?

Any autoloaded directory works; most teams pick one of:

```
app/llm_steps/summarize_article.rb   # class SummarizeArticle
app/contracts/summarize_article.rb   # class SummarizeArticle
app/services/llm/summarize_article.rb # class Llm::SummarizeArticle
```

Pick the convention that matches the rest of your `app/` — Rails 7/8 autoloading resolves all three. `app/llm_steps/` reads cleanest when you have more than two or three steps; `app/services/llm/` fits shops that already namespace service objects.

Keep evals in the same file as the step (`define_eval` block at the bottom of the class) — one source of truth per contract.

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

The gem ships a `Railtie` that autoloads `app/**/*_eval.rb` files so a `SummarizeArticle.run_eval("regression")` picks up the eval you defined inside the step.

## 3. Background jobs — never call LLMs inline in a controller

LLM calls take 0.8–5 seconds and can fail. Wrap every step invocation in an ActiveJob:

```ruby
class SummarizeArticleJob < ApplicationJob
  queue_as :llm

  def perform(article_id)
    article = Article.find(article_id)
    result  = SummarizeArticle.run(article.body)

    if result.ok?
      article.update!(summary: result.parsed_output)
    else
      article.update!(summary_error: result.validation_errors.join("; "))
    end
  end
end
```

`SummarizeArticleJob.perform_later(article.id)` returns in milliseconds; the controller stays responsive. If you use Sidekiq, pair `queue_as :llm` with a dedicated concurrency cap in `sidekiq.yml` so LLM calls do not starve your web workers.

## 4. Logging and observability

`around_call` runs once per `run()` with the final `Result` (after all retries). Use it to write one row per LLM call:

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  # ... prompt, schema, validates ...

  around_call do |step, input, result|
    AiCallLog.create!(
      step: step.name,
      model: result.trace[:model],
      status: result.status,
      latency_ms: result.trace[:latency_ms],
      input_tokens: result.trace[:usage]&.dig(:input_tokens),
      output_tokens: result.trace[:usage]&.dig(:output_tokens),
      cost: result.trace[:cost],
      validation_errors: result.validation_errors
    )
  end
end
```

For Appsignal / Honeybadger / Datadog — emit an `ActiveSupport::Notifications` event from inside `around_call` and subscribe in an initializer:

```ruby
ActiveSupport::Notifications.instrument("ruby_llm_contract.run",
  step: step.name, model: result.trace[:model], status: result.status)
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

    post :summarize, params: { article_id: article.id }

    expect(article.reload.summary[:tldr]).to eq("...")
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
  t.minimum_score        = 0.8
  t.maximum_cost         = 0.05
  t.fail_on_regression   = true
  t.save_baseline        = true
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

## See also

- [Getting Started](getting_started.md) — the feature walkthrough the step above is built on
- [Migration](migration.md) — before/after for replacing a raw `LlmClient.new.call` service with a contract
- [Eval-First](eval_first.md) — the workflow behind the CI gate above
- [Testing](testing.md) — `satisfy_contract` and `pass_eval` matcher chains
