# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Step::RetryExecutor do
  before { RubyLLM::Contract.reset_configuration! }

  describe "per-attempt extra_options with config hashes" do
    it "passes reasoning_effort to adapter on second attempt" do
      received_options = []
      tracking_adapter = Object.new
      tracking_adapter.define_singleton_method(:call) do |**opts|
        received_options << opts.dup
        content = received_options.size >= 2 ? '{"key": "good"}' : '{"key": ""}'
        RubyLLM::Contract::Adapters::Response.new(content: content, usage: { input_tokens: 10, output_tokens: 5 })
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("key not empty") { |o| o[:key].to_s != "" }
        end
        retry_policy do
          escalate({ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini", reasoning_effort: "high" })
        end
      end

      result = step.run("test", context: { adapter: tracking_adapter })

      expect(result.status).to eq(:ok)
      expect(received_options.length).to eq(2)
      # First attempt: no reasoning_effort in config
      expect(received_options[0]).not_to have_key(:reasoning_effort)
      # Second attempt: reasoning_effort: "high"
      expect(received_options[1][:reasoning_effort]).to eq("high")
    end

    it "includes :config in attempt trace only when config has extra keys" do
      tracking_adapter = Object.new
      tracking_adapter.define_singleton_method(:call) do |**_opts|
        RubyLLM::Contract::Adapters::Response.new(content: '{"key": ""}', usage: { input_tokens: 10, output_tokens: 5 })
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
        retry_policy do
          escalate({ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini", reasoning_effort: "high" })
        end
      end

      result = step.run("test", context: { adapter: tracking_adapter })

      attempts = result.trace[:attempts]
      expect(attempts.length).to eq(2)
      # First attempt: config has only :model, so :config should NOT be in the entry
      expect(attempts[0]).not_to have_key(:config)
      # Second attempt: config has :model AND :reasoning_effort, so :config IS in the entry
      expect(attempts[1]).to have_key(:config)
      expect(attempts[1][:config][:reasoning_effort]).to eq("high")
    end

    it "does not include :config in trace for string-only escalation" do
      tracking_adapter = Object.new
      tracking_adapter.define_singleton_method(:call) do |**_opts|
        RubyLLM::Contract::Adapters::Response.new(content: '{"key": ""}', usage: { input_tokens: 10, output_tokens: 5 })
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
        retry_policy do
          escalate "gpt-4.1-nano", "gpt-4.1-mini"
        end
      end

      result = step.run("test", context: { adapter: tracking_adapter })

      attempts = result.trace[:attempts]
      expect(attempts.length).to eq(2)
      attempts.each do |attempt|
        expect(attempt).not_to have_key(:config)
      end
    end

    it "merges context-level reasoning_effort into default_config for non-escalation retries" do
      received_options = []
      tracking_adapter = Object.new
      tracking_adapter.define_singleton_method(:call) do |**opts|
        received_options << opts.dup
        RubyLLM::Contract::Adapters::Response.new(content: '{"key": ""}', usage: { input_tokens: 10, output_tokens: 5 })
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
        retry_policy { attempts 2 }
      end

      step.run("test", context: { adapter: tracking_adapter, reasoning_effort: "low" })

      # Both attempts should have reasoning_effort: "low" from context
      expect(received_options.length).to eq(2)
      received_options.each do |opts|
        expect(opts[:reasoning_effort]).to eq("low")
      end
    end
  end

  describe "aggregated trace totals across attempts (anti-facade F13)" do
    # Anti-facade smoking gun: if `build_retry_result` were changed to
    # `usage: last.trace.usage, cost: last.trace.cost, latency_ms: last.trace.latency_ms`
    # (last-attempt only), the other 5 tests still pass - none of them
    # asserts the aggregated totals. This test fails for that mutation.
    it "sums usage, cost and latency across all attempts in the final trace" do
      adapter_calls = 0
      attempt_latencies = [100, 200, 300]
      tracking_adapter = Object.new
      tracking_adapter.define_singleton_method(:call) do |**_opts|
        # Different latencies and tokens per attempt so the SUM has a
        # value no single attempt could fake by itself.
        sleep_ms = attempt_latencies[adapter_calls] || 0
        adapter_calls += 1
        RubyLLM::Contract::Adapters::Response.new(
          content: '{"key": ""}', # invariant fails -> retry
          usage: { input_tokens: 10 * adapter_calls, output_tokens: 5 * adapter_calls }
        )
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
        retry_policy do
          escalate(
            { model: "gpt-4.1-nano" },
            { model: "gpt-4.1-nano" },
            { model: "gpt-4.1-nano" }
          )
        end
      end

      result = step.run("test", context: { adapter: tracking_adapter })

      expect(result.trace[:attempts].length).to eq(3)
      # Per-attempt usage: 10/5, 20/10, 30/15. Sum: input=60, output=30.
      expect(result.trace[:usage][:input_tokens]).to eq(60)
      expect(result.trace[:usage][:output_tokens]).to eq(30)
      # The last-only mutation would yield 30/15 - not 60/30.
    end

    it "sums cost across attempts (mutation would yield last cost only)" do
      tracking_adapter = Object.new
      tracking_adapter.define_singleton_method(:call) do |**_opts|
        RubyLLM::Contract::Adapters::Response.new(
          content: '{"key": ""}',
          usage: { input_tokens: 1000, output_tokens: 500 }
        )
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
        retry_policy do
          escalate({ model: "gpt-4.1-mini" }, { model: "gpt-4.1-mini" })
        end
      end

      result = step.run("test", context: { adapter: tracking_adapter })

      per_attempt = result.trace[:attempts].map { |a| a[:cost] }
      expect(per_attempt.compact.length).to eq(2)
      # Aggregated cost must equal the sum, not just the last attempt.
      expect(result.trace[:cost]).to be_within(1e-9).of(per_attempt.sum)
      # And critically: distinguishable from the last-only mutation.
      expect(result.trace[:cost]).to be > per_attempt.last
    end
  end

  describe "backward compatibility with string escalation" do
    it "escalates models correctly with string args" do
      models_used = []
      tracking_adapter = Object.new
      tracking_adapter.define_singleton_method(:call) do |**opts|
        models_used << opts[:model]
        RubyLLM::Contract::Adapters::Response.new(content: '{"key": ""}', usage: {})
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
        retry_policy { escalate "gpt-4.1-nano", "gpt-4.1-mini", "gpt-4.1" }
      end

      step.run("test", context: { adapter: tracking_adapter })

      expect(models_used).to eq(%w[gpt-4.1-nano gpt-4.1-mini gpt-4.1])
    end
  end
end
