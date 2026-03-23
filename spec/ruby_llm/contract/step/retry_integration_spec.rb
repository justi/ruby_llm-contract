# frozen_string_literal: true

RSpec.describe "retry_policy integration" do
  before { RubyLLM::Contract.reset_configuration! }

  describe "step with retry_policy" do
    it "returns :ok on first attempt if step succeeds" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("has key") { |o| o[:key].to_s != "" }
        end
        retry_policy { attempts 3 }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"key": "value"}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
    end

    it "does not retry on :input_error (bad input won't improve)" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
        retry_policy { attempts 3 }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"k": "v"}')
      result = step.run(42, context: { adapter: adapter })

      expect(result.status).to eq(:input_error)
    end

    it "retries on :validation_failed and returns last result if all fail" do
      call_count = 0
      tracking_adapter = Object.new
      tracking_adapter.define_singleton_method(:call) do |**_opts|
        call_count += 1
        RubyLLM::Contract::Adapters::Response.new(content: '{"key": ""}', usage: {})
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("key not empty") { |o| o[:key].to_s != "" }
        end
        retry_policy { attempts 3 }
      end

      result = step.run("test", context: { adapter: tracking_adapter })

      expect(result.status).to eq(:validation_failed)
      expect(call_count).to eq(3)
      expect(result.trace[:attempts].length).to eq(3)
    end

    it "stops retrying when a successful attempt occurs" do
      call_count = 0
      improving_adapter = Object.new
      improving_adapter.define_singleton_method(:call) do |**_opts|
        call_count += 1
        response = call_count >= 2 ? '{"key": "good"}' : '{"key": ""}'
        RubyLLM::Contract::Adapters::Response.new(content: response, usage: {})
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("key not empty") { |o| o[:key].to_s != "" }
        end
        retry_policy { attempts 5 }
      end

      result = step.run("test", context: { adapter: improving_adapter })

      expect(result.status).to eq(:ok)
      expect(call_count).to eq(2)
    end
  end

  describe "model escalation" do
    it "uses escalation models in order" do
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
          invariant("key not empty") { |o| o[:key].to_s != "" }
        end
        retry_policy { escalate "nano", "mini", "full" }
      end

      step.run("test", context: { adapter: tracking_adapter })

      expect(models_used).to eq(%w[nano mini full])
    end

    it "stops at first successful model" do
      models_used = []
      escalating_adapter = Object.new
      escalating_adapter.define_singleton_method(:call) do |**opts|
        models_used << opts[:model]
        response = opts[:model] == "mini" ? '{"key": "good"}' : '{"key": ""}'
        RubyLLM::Contract::Adapters::Response.new(content: response, usage: {})
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("key not empty") { |o| o[:key].to_s != "" }
        end
        retry_policy { escalate "nano", "mini", "full" }
      end

      result = step.run("test", context: { adapter: escalating_adapter })

      expect(result.status).to eq(:ok)
      expect(models_used).to eq(%w[nano mini])
    end

    it "records all attempts in trace when all fail" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("always fails") { |_o| false }
        end
        retry_policy { escalate "nano", "mini" }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"k": "v"}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:validation_failed)
      attempts = result.trace[:attempts]
      expect(attempts.length).to eq(2)
      expect(attempts[0]).to include(attempt: 1, model: "nano", status: :validation_failed)
      expect(attempts[1]).to include(attempt: 2, model: "mini", status: :validation_failed)
    end
  end

  describe "adapter_error retry" do
    it "retries on :adapter_error (transient network/timeout failures)" do
      call_count = 0
      flaky_adapter = Object.new
      flaky_adapter.define_singleton_method(:call) do |**_opts|
        call_count += 1
        raise StandardError, "connection timeout" if call_count < 3

        RubyLLM::Contract::Adapters::Response.new(content: '{"key": "good"}', usage: {})
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("key not empty") { |o| o[:key].to_s != "" }
        end
        retry_policy { attempts 3 }
      end

      result = step.run("test", context: { adapter: flaky_adapter })

      expect(result.status).to eq(:ok)
      expect(call_count).to eq(3)
    end

    it "returns :adapter_error after all retries exhausted" do
      failing_adapter = Object.new
      failing_adapter.define_singleton_method(:call) do |**_opts|
        raise StandardError, "connection refused"
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
        retry_policy { attempts 3 }
      end

      result = step.run("test", context: { adapter: failing_adapter })

      expect(result.status).to eq(:adapter_error)
      expect(result.trace[:attempts].length).to eq(3)
      expect(result.trace[:attempts].map { |a| a[:status] }).to eq(%i[adapter_error adapter_error adapter_error])
    end

    it "escalates model on adapter_error" do
      models_used = []
      flaky_adapter = Object.new
      flaky_adapter.define_singleton_method(:call) do |**opts|
        models_used << opts[:model]
        raise StandardError, "timeout" if opts[:model] == "nano"

        RubyLLM::Contract::Adapters::Response.new(content: '{"key": "ok"}', usage: {})
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("key not empty") { |o| o[:key].to_s != "" }
        end
        retry_policy { escalate "nano", "mini", "full" }
      end

      result = step.run("test", context: { adapter: flaky_adapter })

      expect(result.status).to eq(:ok)
      expect(models_used).to eq(%w[nano mini])
    end
  end

  describe "progressive model escalation — full production scenarios" do
    it "handles mixed failure types across attempts (parse_error → validation_failed → ok)" do
      call_count = 0
      models_used = []
      mixed_adapter = Object.new
      mixed_adapter.define_singleton_method(:call) do |**opts|
        call_count += 1
        models_used << opts[:model]
        case call_count
        when 1 then RubyLLM::Contract::Adapters::Response.new(content: "not json",
                                                              usage: {
                                                                input_tokens: 10, output_tokens: 5
                                                              })
        when 2 then RubyLLM::Contract::Adapters::Response.new(content: '{"key": ""}',
                                                              usage: {
                                                                input_tokens: 20, output_tokens: 10
                                                              })
        when 3 then RubyLLM::Contract::Adapters::Response.new(content: '{"key": "good"}',
                                                              usage: {
                                                                input_tokens: 30, output_tokens: 15
                                                              })
        end
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("key not empty") { |o| o[:key].to_s != "" }
        end
        retry_policy { escalate "nano", "mini", "full" }
      end

      result = step.run("test", context: { adapter: mixed_adapter })

      expect(result.status).to eq(:ok)
      expect(models_used).to eq(%w[nano mini full])
      expect(result.parsed_output).to eq({ key: "good" })

      attempts = result.trace[:attempts]
      expect(attempts.length).to eq(3)
      expect(attempts[0]).to include(attempt: 1, model: "nano", status: :parse_error)
      expect(attempts[1]).to include(attempt: 2, model: "mini", status: :validation_failed)
      expect(attempts[2]).to include(attempt: 3, model: "full", status: :ok)
    end

    it "works with duplicate models in escalation (real pattern: nano, nano, mini)" do
      models_used = []
      improving_adapter = Object.new
      improving_adapter.define_singleton_method(:call) do |**opts|
        models_used << opts[:model]
        response = models_used.size >= 3 ? '{"key": "ok"}' : '{"key": ""}'
        RubyLLM::Contract::Adapters::Response.new(content: response, usage: { input_tokens: 10, output_tokens: 5 })
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("key not empty") { |o| o[:key].to_s != "" }
        end
        retry_policy models: %w[gpt-5-nano gpt-5-nano gpt-5-mini]
      end

      result = step.run("test", context: { adapter: improving_adapter })

      expect(result.status).to eq(:ok)
      expect(models_used).to eq(%w[gpt-5-nano gpt-5-nano gpt-5-mini])

      attempts = result.trace[:attempts]
      expect(attempts[0]).to include(model: "gpt-5-nano", status: :validation_failed)
      expect(attempts[1]).to include(model: "gpt-5-nano", status: :validation_failed)
      expect(attempts[2]).to include(model: "gpt-5-mini", status: :ok)
    end

    it "successful attempt's parsed_output is returned (not last attempt's)" do
      call_count = 0
      adapter = Object.new
      adapter.define_singleton_method(:call) do |**_opts|
        call_count += 1
        content = call_count == 2 ? '{"value": "from_attempt_2"}' : '{"value": ""}'
        RubyLLM::Contract::Adapters::Response.new(content: content, usage: {})
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract do
          parse :json
          invariant("value present") { |o| o[:value].to_s != "" }
        end
        retry_policy { escalate "nano", "mini", "full" }
      end

      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ value: "from_attempt_2" })
      expect(call_count).to eq(2)
    end

    it "per-attempt usage is tracked in attempt log" do
      call_count = 0
      adapter = Object.new
      adapter.define_singleton_method(:call) do |**_opts|
        call_count += 1
        tokens = call_count * 100
        RubyLLM::Contract::Adapters::Response.new(
          content: '{"key": ""}',
          usage: { input_tokens: tokens, output_tokens: tokens / 2 }
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
        retry_policy { escalate "nano", "mini" }
      end

      result = step.run("test", context: { adapter: adapter })

      attempts = result.trace[:attempts]
      expect(attempts[0][:usage]).to eq({ input_tokens: 100, output_tokens: 50 })
      expect(attempts[1][:usage]).to eq({ input_tokens: 200, output_tokens: 100 })

      # Aggregated usage should sum all attempts
      expect(result.trace.usage[:input_tokens]).to eq(300)
      expect(result.trace.usage[:output_tokens]).to eq(150)
    end

    it "keyword API and block API produce identical behavior" do
      make_adapter = lambda {
        count = 0
        adapter = Object.new
        adapter.define_singleton_method(:call) do |**_opts|
          count += 1
          content = count >= 2 ? '{"ok": true}' : '{"ok": false}'
          RubyLLM::Contract::Adapters::Response.new(content: content, usage: { input_tokens: 10, output_tokens: 5 })
        end
        adapter
      }

      make_step = lambda { |policy_config|
        Class.new(RubyLLM::Contract::Step::Base) do
          input_type RubyLLM::Contract::Types::String
          output_type RubyLLM::Contract::Types::Hash
          prompt { user "{input}" }
          contract do
            parse :json
            invariant("ok must be true") { |o| o[:ok] == true }
          end
          instance_exec(&policy_config)
        end
      }

      keyword_step = make_step.call(-> { retry_policy models: %w[nano mini full] })
      block_step = make_step.call(-> { retry_policy { escalate "nano", "mini", "full" } })

      keyword_result = keyword_step.run("test", context: { adapter: make_adapter.call })
      block_result = block_step.run("test", context: { adapter: make_adapter.call })

      expect(keyword_result.status).to eq(block_result.status)
      expect(keyword_result.trace[:attempts].map { |a| a[:model] })
        .to eq(block_result.trace[:attempts].map { |a| a[:model] })
    end

    it "schema validation failure triggers escalation" do
      models_used = []
      schema_adapter = Object.new
      schema_adapter.define_singleton_method(:call) do |**opts|
        models_used << opts[:model]
        content = opts[:model] == "full" ? '{"status": "active", "count": 5}' : '{"status": "unknown", "count": 0}'
        RubyLLM::Contract::Adapters::Response.new(content: content, usage: {})
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String

        output_schema do
          string :status, enum: %w[active inactive]
          integer :count, minimum: 1
        end

        prompt { user "{input}" }

        validate("status is active") { |o| o[:status] == "active" }

        retry_policy { escalate "nano", "mini", "full" }
      end

      result = step.run("test", context: { adapter: schema_adapter })

      expect(result.status).to eq(:ok)
      expect(models_used).to eq(%w[nano mini full])
      expect(result.parsed_output).to eq({ status: "active", count: 5 })
    end
  end

  describe "without retry_policy (backward compatible)" do
    it "behaves exactly as before" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::String
        output_type RubyLLM::Contract::Types::Hash
        prompt { user "{input}" }
        contract { parse :json }
      end

      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"k": "v"}')
      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.trace).not_to have_key(:attempts)
    end
  end
end
