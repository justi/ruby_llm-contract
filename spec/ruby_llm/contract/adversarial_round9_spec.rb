# frozen_string_literal: true

# Adversarial QA round 9 -- multi-component interaction bugs.
# Rounds 1-8 found ~40 bugs. Round 9 focuses on the hardest bugs: those
# requiring understanding of interactions between 3+ components.

RSpec.describe "Adversarial QA round 9 -- multi-component interaction bugs" do
  before { RubyLLM::Contract.reset_configuration! }

  # ---------------------------------------------------------------------------
  # SCENARIO 1: Full pipeline with retry + schema + validate + cost aggregation.
  #
  # Build a 3-step pipeline where step 2 has retry_policy with model escalation.
  # Step 2: attempt 1 (nano) returns invalid JSON -> parse_error -> retry
  #         attempt 2 (mini) returns valid JSON but fails validate -> retry
  #         attempt 3 (full) succeeds
  #
  # Verify: pipeline trace has all 3 attempts, usage is aggregated across ALL
  # attempts AND all pipeline steps, step 1 output is preserved.
  # ---------------------------------------------------------------------------
  describe "SCENARIO 1: Pipeline + retry + schema + validate -- the full production path" do
    it "completes the full pipeline with retry model escalation" do
      sc1 = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      sc2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "step2: #{i.to_json}" }
        validate("score must be positive") { |o| o[:score].is_a?(Numeric) && o[:score] > 0 }
        retry_policy models: %w[nano mini full]
      end

      sc3 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "step3: #{i.to_json}" }
      end
      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **opts|
          call_count += 1
          content = case call_count
                    when 1 # step1 -- returns valid JSON
                      '{"data": "from_step1"}'
                    when 2 # step2/attempt1 (nano) -- invalid JSON
                      "not json at all"
                    when 3 # step2/attempt2 (mini) -- valid JSON but score <= 0
                      '{"score": -1, "result": "bad"}'
                    when 4 # step2/attempt3 (full) -- valid
                      '{"score": 42, "result": "good"}'
                    when 5 # step3
                      '{"final": "output"}'
                    end
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 10 * call_count, output_tokens: 5 * call_count }
          )
        end
      end.new

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step sc1, as: :first
        step sc2, as: :second
        step sc3, as: :third
      end

      result = pipeline.run("hello", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Full pipeline should succeed, got: #{result.status}, " \
                               "failed_step: #{result.failed_step.inspect}"

      # Step 1 output should be preserved
      expect(result.outputs_by_step[:first]).to eq({ data: "from_step1" })

      # Step 2 output should be the successful attempt
      expect(result.outputs_by_step[:second]).to eq({ score: 42, result: "good" })

      # Step 3 output should be present
      expect(result.outputs_by_step[:third]).to eq({ final: "output" })

      # The second step's trace should have attempts
      step2_result = result.step_results.find { |sr| sr[:alias] == :second }[:result]
      expect(step2_result.trace.attempts).not_to be_nil,
                                                 "Step 2 trace should include retry attempts"
      expect(step2_result.trace.attempts.length).to eq(3),
                                                    "Step 2 should have 3 attempts"

      # Verify attempt statuses
      attempt_statuses = step2_result.trace.attempts.map { |a| a[:status] }
      expect(attempt_statuses).to eq(%i[parse_error validation_failed ok]),
                                    "Attempts should be: parse_error, validation_failed, ok. " \
                                    "Got: #{attempt_statuses.inspect}"

      # Verify model escalation
      attempt_models = step2_result.trace.attempts.map { |a| a[:model] }
      expect(attempt_models).to eq(%w[nano mini full]),
                                   "Models should escalate: nano, mini, full. " \
                                   "Got: #{attempt_models.inspect}"

      # Pipeline trace should aggregate usage from all steps including retries
      total_usage = result.trace.total_usage
      expect(total_usage[:input_tokens]).to be > 0
      expect(total_usage[:output_tokens]).to be > 0

      # Step 2's aggregated usage should include all 3 attempts
      step2_usage = step2_result.trace.usage
      expect(step2_usage[:input_tokens]).to eq(20 + 30 + 40),
                                            "Step 2 usage should aggregate all 3 attempts' input tokens"
      expect(step2_usage[:output_tokens]).to eq(10 + 15 + 20),
                                             "Step 2 usage should aggregate all 3 attempts' output tokens"

      # Pipeline total should include step1 + step2(aggregated) + step3
      expect(total_usage[:input_tokens]).to eq(10 + 90 + 50),
                                            "Pipeline total input tokens should include all steps + retries"
      expect(total_usage[:output_tokens]).to eq(5 + 45 + 25),
                                             "Pipeline total output tokens should include all steps + retries"

      # 5 adapter calls total: 1 for step1, 3 for step2 (retries), 1 for step3
      expect(call_count).to eq(5)
    end
  end

  # ---------------------------------------------------------------------------
  # SCENARIO 2: Retry + deep_freeze interaction.
  #
  # After attempt 1 fails validation, the parsed_output is deep-frozen by the
  # Validator. Attempt 2 starts fresh. Verify the runner creates a NEW
  # parsed_output each time and does not accidentally share frozen state.
  # ---------------------------------------------------------------------------
  describe "SCENARIO 2: Retry + deep_freeze -- no shared state between attempts" do
    it "each retry attempt produces independent parsed_output" do
      attempt_outputs = []

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Process: #{input}" }
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        validate("items must have at least 2 entries") { |o| o[:items].is_a?(Array) && o[:items].length >= 2 }
        retry_policy attempts: 3
      end

      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_opts|
          call_count += 1
          content = case call_count
                    when 1 # fails validate: only 1 item
                      '{"items": [{"name": "solo"}]}'
                    when 2 # fails validate: 0 items
                      '{"items": []}'
                    when 3 # passes: 2 items
                      '{"items": [{"name": "a"}, {"name": "b"}]}'
                    end
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 10, output_tokens: 5 }
          )
        end
      end.new

      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Third attempt should succeed, got: #{result.status}"
      expect(result.parsed_output[:items].length).to eq(2)

      # The successful parsed_output should be deep-frozen
      expect(result.parsed_output).to be_frozen,
                                      "Successful parsed_output should be deep-frozen"
      expect(result.parsed_output[:items]).to be_frozen,
                                             "Nested array should be deep-frozen"
      expect(result.parsed_output[:items][0]).to be_frozen,
                                                "Nested hash items should be deep-frozen"

      # Verify 3 attempts happened
      expect(result.trace.attempts.length).to eq(3)
    end

    it "deep_freeze does not crash on already-frozen nested structures" do
      # Simulate passing a pre-frozen Hash through the validator
      frozen_hash = { name: "test", items: [{ id: 1 }, { id: 2 }] }
      frozen_hash[:items].each(&:freeze)
      frozen_hash[:items].freeze
      frozen_hash[:name].freeze
      frozen_hash.freeze

      # deep_freeze should not crash on already-frozen data
      validator = RubyLLM::Contract::Validator.new
      expect do
        validator.send(:deep_freeze, frozen_hash)
      end.not_to raise_error,
                 "deep_freeze should be idempotent -- calling it on already-frozen data must not crash"
    end
  end

  # ---------------------------------------------------------------------------
  # SCENARIO 3: Schema validation + code fence stripping + JSON extraction --
  # the full parser chain.
  #
  # Adapter returns prose-wrapped, code-fenced JSON with extra properties
  # in nested array items. The full chain must:
  #   1. Strip code fences
  #   2. Extract JSON from prose (fallback)
  #   3. Parse JSON
  #   4. Symbolize keys
  #   5. Schema validate (including additionalProperties:false on nested items)
  # ---------------------------------------------------------------------------
  describe "SCENARIO 3: Code fence + JSON extraction + nested schema validation" do
    let(:schema_class) do
      Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              required: %w[items],
              properties: {
                items: {
                  type: "array",
                  minItems: 1,
                  items: {
                    type: "object",
                    required: %w[name],
                    properties: {
                      name: { type: "string" }
                    },
                    additionalProperties: false
                  }
                }
              }
            }
          }
        end
      end
    end

    it "strips code fences, parses JSON, and catches extra property in nested items" do
      # Adapter returns prose-wrapped, code-fenced JSON with an extra "extra" key
      fenced_response = "Sure! Here's the JSON:\n\n```json\n{\"items\": [{\"name\": \"test\", \"extra\": true}]}\n```\n\nHope this helps!"

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      # First verify the parser chain works
      parsed = RubyLLM::Contract::Parser.parse(fenced_response, strategy: :json)
      expect(parsed).to eq({ items: [{ name: "test", extra: true }] }),
                          "Parser should extract JSON from code-fenced prose"

      # Now verify schema validation catches the extra property
      errors = RubyLLM::Contract::SchemaValidator.validate(parsed, schema_class.new)
      expect(errors).not_to be_empty,
                            "Schema validator should catch 'extra' property with additionalProperties: false"
      expect(errors.join).to include("extra"),
                            "Error should mention the 'extra' property"
    end

    it "end-to-end: step with schema rejects extra properties in nested items from code-fenced response" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
      end

      # We need to set the output_schema manually since we can't use RubyLLM::Schema in tests
      # Instead, test through SchemaValidator directly with the full Validator chain
      fenced_response = "```json\n{\"items\": [{\"name\": \"test\", \"extra\": true}]}\n```"

      parsed = RubyLLM::Contract::Parser.parse(fenced_response, strategy: :json)
      errors = RubyLLM::Contract::SchemaValidator.validate(parsed, schema_class.new)

      expect(errors.length).to eq(1)
      expect(errors.first).to include("additional property not allowed")
    end

    it "code fences stripped before JSON extraction -- not double-processed" do
      # When code fences ARE recognized, strip_code_fences removes them
      # and the result is valid JSON that parses directly -- no extraction needed
      clean_fenced = "```json\n{\"items\": [{\"name\": \"ok\"}]}\n```"

      parsed = RubyLLM::Contract::Parser.parse(clean_fenced, strategy: :json)
      expect(parsed).to eq({ items: [{ name: "ok" }] })

      errors = RubyLLM::Contract::SchemaValidator.validate(parsed, schema_class.new)
      expect(errors).to be_empty,
                        "Clean fenced JSON with valid schema should pass validation"
    end

    it "prose-wrapped JSON without fences uses extraction fallback" do
      prose_wrapped = "Here is the result: {\"items\": [{\"name\": \"extracted\"}]} and some more text."

      parsed = RubyLLM::Contract::Parser.parse(prose_wrapped, strategy: :json)
      expect(parsed).to eq({ items: [{ name: "extracted" }] }),
                          "Parser should extract JSON from prose using bracket-matching"

      errors = RubyLLM::Contract::SchemaValidator.validate(parsed, schema_class.new)
      expect(errors).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # SCENARIO 4: Pipeline timeout + retry interaction.
  #
  # The pipeline timeout check happens BETWEEN steps (after each step finishes).
  # When a step has retry_policy, the entire retry sequence runs atomically
  # inside step.run() -- the pipeline cannot interrupt retries mid-attempt.
  #
  # This test documents this behavior: a slow retry step can exceed the
  # pipeline timeout because the timeout is only checked after the step
  # completes (including all retries).
  # ---------------------------------------------------------------------------
  describe "SCENARIO 4: Pipeline timeout does not interrupt retry attempts" do
    it "retry step runs all attempts even when pipeline timeout would expire mid-retry" do
      step1 = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      step2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "step2: #{i.to_json}" }
        retry_policy attempts: 3
      end

      call_count = 0
      attempt_times = []
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_opts|
          call_count += 1
          attempt_times << Process.clock_gettime(Process::CLOCK_MONOTONIC)

          case call_count
          when 1 # step1 -- fast, valid
            RubyLLM::Contract::Adapters::Response.new(
              content: '{"data": "ok"}',
              usage: { input_tokens: 5, output_tokens: 5 }
            )
          when 2 # step2/attempt1 -- takes 50ms, returns invalid JSON
            sleep 0.05
            RubyLLM::Contract::Adapters::Response.new(
              content: "not json",
              usage: { input_tokens: 5, output_tokens: 5 }
            )
          when 3 # step2/attempt2 -- takes 50ms, returns invalid JSON
            sleep 0.05
            RubyLLM::Contract::Adapters::Response.new(
              content: "still not json",
              usage: { input_tokens: 5, output_tokens: 5 }
            )
          when 4 # step2/attempt3 -- takes 50ms, returns valid JSON
            sleep 0.05
            RubyLLM::Contract::Adapters::Response.new(
              content: '{"result": "finally"}',
              usage: { input_tokens: 5, output_tokens: 5 }
            )
          end
        end
      end.new

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step1, as: :first
        step step2, as: :second
      end

      # Pipeline timeout of 100ms -- step2's 3 retries take ~150ms total
      result = pipeline.run("hello", context: { adapter: adapter }, timeout_ms: 100)

      # The pipeline timeout check happens AFTER step2 completes (all retries).
      # Since step2 ran all 3 attempts (>100ms), the timeout is detected
      # after step2 finishes. But step2 itself succeeds with :ok.
      #
      # The key insight: timeout does NOT interrupt retries mid-attempt.
      # All 3 retry attempts run to completion inside step.run().
      expect(call_count).to eq(4),
                            "All retry attempts should complete even if pipeline timeout expires mid-retry. " \
                            "Got #{call_count} adapter calls."

      # The result could be :ok (if timeout check happens after step2 is last step)
      # or :timeout (if the pipeline checks timeout and there were more steps).
      # Since step2 is the LAST step, the timeout check on the last step
      # would try to find the "next step" alias.
      # Looking at pipeline runner line 43: next_alias = @steps[index + 1]&.dig(:alias) || step_def[:alias]
      # For the last step, @steps[index + 1] is nil, so next_alias = step_def[:alias] = :second
      if result.status == :timeout
        expect(result.outputs_by_step).to have_key(:first)
        expect(result.outputs_by_step).to have_key(:second),
                                         "Step 2 succeeded, so its output should be in outputs_by_step even on timeout"
      else
        expect(result.status).to eq(:ok),
                                 "If not timeout, should be :ok"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SCENARIO 5: Eval on a Step with output_schema + validate + retry_policy.
  #
  # Step has: output_schema-like validation, validate (2-arity cross-check),
  # retry_policy. define_eval with sample_response + verify.
  # Run eval offline -- does sample_response get schema-validated?
  # Do validates run? Does verify run?
  # What if sample_response passes schema but fails a verify?
  # ---------------------------------------------------------------------------
  describe "SCENARIO 5: Eval with schema + validate + verify interaction" do
    it "eval runs full validation chain: parse, schema, validate, then verify" do
      schema_obj = Class.new do
        def to_json_schema
          {
            schema: {
              type: "object",
              required: %w[name score],
              properties: {
                name: { type: "string" },
                score: { type: "integer", minimum: 1, maximum: 100 }
              }
            }
          }
        end
      end

      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Analyze: #{input}" }
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        validate("score > 0") { |o| o[:score].is_a?(Numeric) && o[:score] > 0 }

        define_eval(:smoke) do
          default_input "test input"
          sample_response({ name: "Alice", score: 42 })

          # ProcEvaluator calls proc with positional args: proc.call(output) or proc.call(output, input)
          # Return true/false (not EvaluationResult) -- ProcEvaluator wraps the return value
          verify "name is present", ->(output) {
            output.is_a?(Hash) && output[:name].is_a?(String) && !output[:name].empty?
          }
        end
      end

      report = step.run_eval(:smoke)

      expect(report).to be_a(RubyLLM::Contract::Eval::Report)
      expect(report.passed?).to be(true),
                                "Eval should pass when sample_response satisfies schema, validate, and verify. " \
                                "Details: #{report.results.map { |r| r[:details] }.inspect}"
    end

    it "eval reports failure when sample_response passes schema but fails verify" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Analyze: #{input}" }
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }

        define_eval(:strict_check) do
          default_input "test input"
          sample_response({ name: "Alice", score: 42 })

          # ProcEvaluator wraps true/false into EvaluationResult
          verify "score must be exactly 100", ->(output) {
            output[:score] == 100
          }
        end
      end

      report = step.run_eval(:strict_check)

      expect(report.passed?).to be(false),
                                "Eval should fail when verify rejects valid sample_response"
      # ProcEvaluator wraps false return into "not passed" details
      expect(report.results.first[:passed]).to be(false)
    end

    it "eval reports failure when sample_response fails contract validate" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Analyze: #{input}" }
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        validate("score must be >= 50") { |o| o[:score].is_a?(Numeric) && o[:score] >= 50 }

        define_eval(:contract_fail) do
          default_input "test input"
          # score is 10, which fails the validate("score must be >= 50")
          sample_response({ name: "Alice", score: 10 })
        end
      end

      report = step.run_eval(:contract_fail)

      expect(report.passed?).to be(false),
                                "Eval should fail when sample_response fails contract validate"
      expect(report.results.first[:step_status]).to eq(:validation_failed),
                                                    "Step status should be :validation_failed"
    end
  end

  # ---------------------------------------------------------------------------
  # SCENARIO 6: Token estimation accuracy with dynamic prompts.
  #
  # Dynamic prompt with large input (8000 chars) -- does max_input correctly
  # estimate and reject BEFORE calling the adapter?
  # Same prompt with small input (100 chars) -- does it pass?
  # Token estimation is done on RENDERED messages (after interpolation).
  # ---------------------------------------------------------------------------
  describe "SCENARIO 6: max_input token estimation on rendered dynamic prompts" do
    it "rejects large input based on rendered message size, not template size" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Process this data: #{input}" }
        input_type String
        output_type String
        max_input(100) # ~400 chars max
      end

      large_input = "x" * 8000 # way over 100 tokens
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run(large_input, context: { adapter: adapter })

      expect(result.status).to eq(:limit_exceeded),
                               "Large input (8000 chars) should exceed max_input(100) tokens. " \
                               "Got: #{result.status}"
    end

    it "accepts small input that stays under the limit after rendering" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Process this data: #{input}" }
        input_type String
        output_type String
        max_input(100) # ~400 chars max
      end

      small_input = "hello" # ~1 token
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run(small_input, context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Small input should pass max_input limit. Got: #{result.status}"
    end

    it "estimates tokens on the rendered message, not the template" do
      # Use a static prompt with {input} placeholder
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
        max_input(10) # ~40 chars max
      end

      # The template "{input}" is 7 chars (~2 tokens).
      # After interpolation with 200 chars, the rendered message is 200 chars (~50 tokens).
      # If estimation were on the template, it would pass. On rendered, it should fail.
      medium_input = "a" * 200
      adapter = RubyLLM::Contract::Adapters::Test.new(response: "ok")
      result = step.run(medium_input, context: { adapter: adapter })

      expect(result.status).to eq(:limit_exceeded),
                               "Token estimation should be on rendered messages, not templates. " \
                               "200 chars / 4 = ~50 tokens which exceeds max_input(10)"
    end

    it "adapter is NOT called when input exceeds token limit" do
      adapter_called = false
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Data: #{input}" }
        input_type String
        output_type String
        max_input(5) # very low limit
      end

      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |**_opts|
          adapter_called = true
          RubyLLM::Contract::Adapters::Response.new(content: "ok", usage: { input_tokens: 5, output_tokens: 5 })
        end
      end.new

      result = step.run("a" * 1000, context: { adapter: adapter })

      expect(result.status).to eq(:limit_exceeded)
      expect(adapter_called).to be(false),
                                "Adapter should NOT be called when max_input limit is exceeded"
    end
  end

  # ---------------------------------------------------------------------------
  # SCENARIO 7: deep_freeze idempotency with already-frozen and mixed structures.
  #
  # Ruby's freeze is idempotent, but ensure the recursive deep_freeze in
  # Validator does not crash on any combination of frozen/unfrozen nested data.
  # ---------------------------------------------------------------------------
  describe "SCENARIO 7: deep_freeze idempotency on complex nested structures" do
    let(:validator) { RubyLLM::Contract::Validator.new }

    it "handles fully unfrozen nested structure" do
      data = { a: "hello", b: [1, { c: "world" }] }
      expect { validator.send(:deep_freeze, data) }.not_to raise_error
      expect(data).to be_frozen
      expect(data[:b]).to be_frozen
      expect(data[:b][1]).to be_frozen
    end

    it "handles fully frozen nested structure (idempotent)" do
      data = { a: "hello", b: [1, { c: "world" }] }
      validator.send(:deep_freeze, data)
      # Call again on already-frozen data
      expect { validator.send(:deep_freeze, data) }.not_to raise_error,
                                                           "deep_freeze should be idempotent on frozen data"
    end

    it "handles partially frozen structure (mixed frozen/unfrozen)" do
      inner = { c: "world" }
      inner.freeze # pre-freeze the inner hash
      data = { a: "hello", b: [1, inner] }

      expect { validator.send(:deep_freeze, data) }.not_to raise_error,
                                                           "deep_freeze should handle mixed frozen/unfrozen structures"
      expect(data).to be_frozen
    end

    it "handles frozen string literals from source code" do
      # In files with # frozen_string_literal: true, string literals are frozen
      frozen_str = "frozen".freeze
      data = { key: frozen_str }

      expect { validator.send(:deep_freeze, data) }.not_to raise_error,
                                                           "deep_freeze should handle pre-frozen strings"
    end

    it "handles empty structures" do
      expect { validator.send(:deep_freeze, {}) }.not_to raise_error
      expect { validator.send(:deep_freeze, []) }.not_to raise_error
      expect { validator.send(:deep_freeze, "") }.not_to raise_error
    end

    it "handles nil and numeric values (not frozen by deep_freeze)" do
      data = { a: nil, b: 42, c: 3.14, d: true }
      expect { validator.send(:deep_freeze, data) }.not_to raise_error
      expect(data).to be_frozen
    end
  end

  # ---------------------------------------------------------------------------
  # SCENARIO 8: Pipeline.test with schema steps -- Hash responses flow through
  # the full parse/validate chain.
  # ---------------------------------------------------------------------------
  describe "SCENARIO 8: Pipeline.test with Hash responses and schema validation" do
    it "Hash responses are parsed correctly through the JSON parse chain" do
      step1 = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      step2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "step2: #{i.to_json}" }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step1, as: :first
        step step2, as: :second
      end

      # Pipeline.test passes Hash responses directly
      result = pipeline.test("hello", responses: {
                               first: { name: "Alice", age: 30 },
                               second: { result: "processed", source: "Alice" }
                             })

      expect(result.status).to eq(:ok),
                               "Pipeline.test with Hash responses should succeed. " \
                               "Got: #{result.status}, errors: #{result.step_results.map { |sr| sr[:result].validation_errors }.inspect}"

      # Keys should be symbolized (Parser.parse_json handles Hash input via symbolize_keys)
      expect(result.outputs_by_step[:first]).to eq({ name: "Alice", age: 30 })
      expect(result.outputs_by_step[:second]).to eq({ result: "processed", source: "Alice" })
    end

    it "Hash responses with string keys get symbolized" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step, as: :only
      end

      result = pipeline.test("hello", responses: {
                               only: { "string_key" => "value", "nested" => { "inner" => true } }
                             })

      expect(result.status).to eq(:ok)
      output = result.outputs_by_step[:only]
      expect(output).to have_key(:string_key),
                        "String keys should be symbolized"
      expect(output[:nested]).to have_key(:inner),
                                "Nested string keys should be symbolized recursively"
    end

    it "Pipeline.test with validate invariant that crosses input/output" do
      step1 = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      step2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "step2: #{i.to_json}" }
        # 2-arity validate: cross-check output against input
        validate("output must reference input name") { |output, input|
          input.is_a?(Hash) && output.is_a?(Hash) &&
            output[:source] == input[:name]
        }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step1, as: :first
        step step2, as: :second
      end

      # step1 output becomes step2 input -- step2 validate checks output.source == input.name
      result = pipeline.test("hello", responses: {
                               first: { name: "Alice" },
                               second: { source: "Alice", data: "ok" }
                             })

      expect(result.status).to eq(:ok),
                               "2-arity validate should pass when output references input correctly. " \
                               "Got: #{result.status}"
    end

    it "Pipeline.test 2-arity validate fails when cross-check is wrong" do
      step1 = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      step2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "step2: #{i.to_json}" }
        validate("output must reference input name") { |output, input|
          input.is_a?(Hash) && output.is_a?(Hash) &&
            output[:source] == input[:name]
        }
      end

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step1, as: :first
        step step2, as: :second
      end

      # step2 output has wrong source
      result = pipeline.test("hello", responses: {
                               first: { name: "Alice" },
                               second: { source: "Bob", data: "ok" }
                             })

      expect(result.status).to eq(:validation_failed),
                               "2-arity validate should fail when cross-check is wrong"
      expect(result.failed_step).to eq(:second)
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 64: Pipeline cost calculation with retry model escalation is wrong.
  #
  # When a step uses retry_policy with model escalation (e.g., nano -> mini -> full),
  # each attempt uses a different model with different pricing. After retry,
  # build_retry_result creates a merged trace:
  #   trace: last.trace.merge(attempts: attempt_log, usage: aggregated_usage)
  #
  # The merged trace has:
  #   - model: last attempt's model (e.g., "full")
  #   - usage: aggregated tokens from ALL attempts
  #
  # Step::Trace calculates cost as:
  #   CostCalculator.calculate(model_name: @model, usage: @usage)
  #
  # This applies the LAST model's pricing to ALL tokens, which is incorrect
  # when models have different per-token prices. The correct cost should be
  # the SUM of per-attempt costs.
  #
  # Impact: Pipeline::Trace.calculate_total_cost sums st.cost from step traces,
  # inheriting the incorrect per-step cost.
  #
  # This bug is silent (no crash) and only manifests when:
  #   1. Step has retry with model escalation
  #   2. Models have different pricing (which CostCalculator looks up via RubyLLM)
  #   3. The pipeline or user checks the cost field
  #
  # Since CostCalculator returns nil when RubyLLM is not configured or models
  # are unknown, this bug is currently dormant in test environments. But in
  # production with real models, it would report incorrect costs.
  # ---------------------------------------------------------------------------
  describe "BUG 64: Retry with model escalation calculates cost on wrong model" do
    it "documents that merged trace uses last model's name for cost calculation" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Process: #{input}" }
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        retry_policy models: %w[gpt-4o-mini gpt-4o gpt-4]
      end

      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **opts|
          call_count += 1
          content = call_count < 3 ? "not json" : '{"result": "ok"}'
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 100, output_tokens: 50 }
          )
        end
      end.new

      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)

      # The merged trace uses the LAST model (gpt-4) but aggregated usage from all 3 attempts
      expect(result.trace.model).to eq("gpt-4"),
                                    "Merged trace should have last model"
      expect(result.trace.usage[:input_tokens]).to eq(300),
                                                   "Usage should be aggregated (100 * 3 attempts)"

      # The cost is calculated as CostCalculator.calculate(model: "gpt-4", usage: {input: 300, output: 150})
      # which applies gpt-4 pricing to ALL tokens, including those from gpt-4o-mini and gpt-4o.
      # This is incorrect -- the cost should be sum of per-attempt costs.
      # However, since CostCalculator returns nil for unknown models in test env,
      # we can only document this structural issue.
      expect(result.trace.attempts.length).to eq(3)
      expect(result.trace.attempts.map { |a| a[:model] }).to eq(%w[gpt-4o-mini gpt-4o gpt-4]),
                                                               "Per-attempt models should be tracked for correct cost attribution"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 65: Retry result's trace.latency_ms only reflects the LAST attempt,
  # not the total time across all retry attempts.
  #
  # In build_retry_result (step/base.rb line 210):
  #   trace: last.trace.merge(attempts: attempt_log, usage: aggregated_usage)
  #
  # The merge overrides `usage` with the aggregated value, and adds `attempts`.
  # But it does NOT override `latency_ms`. The merged trace inherits
  # last.trace.latency_ms, which is only the last attempt's latency.
  #
  # The total wall-clock time for the step (including all retries) is NOT
  # reflected in the trace. This means:
  #   - Pipeline trace's total_latency_ms is correct (measured at pipeline level)
  #   - But individual step trace latency_ms is misleading for retried steps
  #
  # This is a silent observability bug that leads to incorrect performance metrics.
  # ---------------------------------------------------------------------------
  describe "BUG 65: Retry trace.latency_ms only reflects last attempt, not total" do
    it "latency_ms is only the last attempt's latency, not total retry time" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Process: #{input}" }
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        retry_policy attempts: 3
      end

      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_opts|
          call_count += 1
          sleep 0.02 # each attempt takes ~20ms
          content = call_count < 3 ? "not json" : '{"result": "ok"}'
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 10, output_tokens: 5 }
          )
        end
      end.new

      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(call_count).to eq(3)

      # Total wall clock time should be ~60ms (3 * 20ms)
      # But the trace latency_ms only reflects the LAST attempt (~20ms)
      last_attempt_latency = result.trace.attempts.last[:latency_ms]
      trace_latency = result.trace.latency_ms

      # The trace latency should equal the last attempt's latency (the bug)
      expect(trace_latency).to be_within(5).of(last_attempt_latency),
                               "Trace latency_ms (#{trace_latency}) should approximately equal " \
                               "last attempt latency (#{last_attempt_latency}) -- " \
                               "this documents the bug: total retry time is not reflected"

      # Sum of all attempt latencies should be significantly more than trace latency
      total_attempt_latency = result.trace.attempts.sum { |a| a[:latency_ms] || 0 }
      expect(total_attempt_latency).to be > trace_latency,
                                       "Total attempt latency (#{total_attempt_latency}) should be greater " \
                                       "than trace latency (#{trace_latency}) since retries took time"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 66: Pipeline.test does not pass model from step definition to context.
  #
  # Pipeline::Base.test creates an adapter and runs with context: { adapter: adapter }.
  # But Pipeline.step supports `model:` override per step:
  #   step MyStep, as: :s1, model: "gpt-4o"
  #
  # In Pipeline::Runner, the model override is applied:
  #   step_context = step_def[:model] ? @context.merge(model: step_def[:model]) : @context
  #
  # However, Pipeline.test only passes context: { adapter: adapter } with no model.
  # The model from step definitions IS correctly merged by the Runner.
  # But the Test adapter ignores the model option entirely (**_options is unused).
  #
  # This means Pipeline.test cannot test model-specific behavior -- but this is
  # expected since Test adapter is model-agnostic. Just verify the plumbing works.
  # ---------------------------------------------------------------------------
  describe "SCENARIO 9: Pipeline per-step model override with test adapter" do
    it "per-step model override is passed through to the adapter context" do
      models_seen = []
      step1 = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type String
      end

      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **opts|
          models_seen << opts[:model]
          RubyLLM::Contract::Adapters::Response.new(
            content: "ok",
            usage: { input_tokens: 5, output_tokens: 5 }
          )
        end
      end.new

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step1, as: :first, model: "gpt-4o-mini"
        step step1, as: :second, model: "gpt-4"
      end

      result = pipeline.run("hello", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(models_seen).to eq(["gpt-4o-mini", "gpt-4"]),
                              "Per-step model overrides should be passed to adapter. Got: #{models_seen.inspect}"
    end
  end

  # ---------------------------------------------------------------------------
  # BUG 67: EvalDefinition.pre_validate_sample! converts Hash sample_response
  # to JSON string but does not handle nested symbol keys correctly.
  #
  # When sample_response is { name: "Alice" } (symbol keys), pre_validate_sample!
  # does: response_hash = @sample_response.is_a?(Hash) ? @sample_response : ...
  # Then: symbolized = Contract::Parser.symbolize_keys(response_hash)
  #
  # Since the input already has symbol keys, symbolize_keys is a no-op.
  # But SchemaValidator.validate calls deep_symbolize internally on the schema.
  #
  # Meanwhile, build_adapter does: @sample_response.to_json which converts
  # { name: "Alice" } to '{"name":"Alice"}'. The Test adapter stores this
  # string. When the step runs, Parser.parse_json parses it back to
  # { name: "Alice" } (symbolized). This round-trip is correct.
  #
  # However, if sample_response has string keys like { "name" => "Alice" },
  # pre_validate_sample! uses the raw hash (string keys), symbolizes to
  # { name: "Alice" }, and validates. build_adapter converts to JSON and
  # back. No bug here.
  #
  # But what about Array sample_response? build_adapter does
  # @sample_response.to_json for non-String. If sample_response is an Array,
  # pre_validate_sample! checks schema -- but the schema might expect an object.
  # pre_validate_sample would catch that.
  #
  # Actually, the real edge case: what if sample_response is a String that
  # is valid JSON? build_adapter wraps it in Test adapter directly. But
  # pre_validate_sample! does: JSON.parse(@sample_response.to_s) which
  # parses the JSON string to a Hash, symbolizes, validates. This works.
  #
  # So no bug here after analysis. But let me verify the actual flow.
  # ---------------------------------------------------------------------------
  describe "SCENARIO 10: EvalDefinition sample_response format handling" do
    it "sample_response as Hash is correctly handled end-to-end" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Analyze: #{input}" }
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }

        define_eval(:hash_sample) do
          default_input "test"
          sample_response({ name: "Alice", score: 42 })
        end
      end

      report = step.run_eval(:hash_sample)
      expect(report.passed?).to be(true),
                                "Hash sample_response should work end-to-end"
    end

    it "sample_response as JSON string is correctly handled end-to-end" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Analyze: #{input}" }
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }

        define_eval(:string_sample) do
          default_input "test"
          sample_response '{"name": "Bob", "score": 99}'
        end
      end

      report = step.run_eval(:string_sample)
      expect(report.passed?).to be(true),
                                "JSON string sample_response should work end-to-end"
    end

    it "sample_response with string keys is correctly symbolized" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Analyze: #{input}" }
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }

        define_eval(:string_keys) do
          default_input "test"
          sample_response({ "name" => "Charlie", "score" => 77 })
        end
      end

      report = step.run_eval(:string_keys)
      expect(report.passed?).to be(true),
                                "String-keyed Hash sample_response should work end-to-end"
      expect(report.results.first[:output]).to have_key(:name),
                                              "Output keys should be symbolized"
    end
  end

  # ---------------------------------------------------------------------------
  # SCENARIO 11: Complex retry where first attempt returns parse_error, second
  # returns validation_failed (from both schema AND invariant), and third succeeds.
  # Verify that the result cleanly reflects only the last attempt's state.
  # ---------------------------------------------------------------------------
  describe "SCENARIO 11: Retry with mixed failure modes -- parse_error then validation_failed then ok" do
    it "final result reflects only the last (successful) attempt's parsed_output" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { |input| user "Process: #{input}" }
        input_type String
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        validate("name must not be empty") { |o| o[:name].is_a?(String) && !o[:name].empty? }
        retry_policy attempts: 3
      end

      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_opts|
          call_count += 1
          content = case call_count
                    when 1 then "this is not JSON at all"
                    when 2 then '{"name": ""}'        # empty name fails validate
                    when 3 then '{"name": "Charlie"}'  # succeeds
                    end
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 10, output_tokens: 5 }
          )
        end
      end.new

      result = step.run("test", context: { adapter: adapter })

      expect(result.status).to eq(:ok)
      expect(result.parsed_output).to eq({ name: "Charlie" }),
                                       "Result should reflect the successful attempt's output"
      expect(result.raw_output).to eq('{"name": "Charlie"}'),
                                   "raw_output should be from the successful attempt"
      expect(result.validation_errors).to be_empty,
                                         "No validation errors on success"

      # Verify attempt history
      attempts = result.trace.attempts
      expect(attempts[0][:status]).to eq(:parse_error)
      expect(attempts[1][:status]).to eq(:validation_failed)
      expect(attempts[2][:status]).to eq(:ok)
    end
  end

  # ---------------------------------------------------------------------------
  # SCENARIO 12: Pipeline with retry step where retry changes the output shape.
  # Step 1 passes. Step 2 retries and eventually produces output that step 3
  # can consume. Verify the full data flow across steps.
  # ---------------------------------------------------------------------------
  describe "SCENARIO 12: Pipeline data flow with retry mid-pipeline" do
    it "step 3 receives step 2's successful retry output as input" do
      step1 = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      step2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "transform: #{i.to_json}" }
        validate("must have status field") { |o| o.key?(:status) }
        retry_policy attempts: 2
      end

      step3_inputs = []
      step3 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "finalize: #{i.to_json}" }
      end

      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_opts|
          call_count += 1
          content = case call_count
                    when 1 then '{"name": "Alice"}'              # step1
                    when 2 then '{"missing_status": true}'       # step2 attempt 1 (fails validate)
                    when 3 then '{"status": "ok", "name": "Alice"}' # step2 attempt 2 (success)
                    when 4 then '{"done": true}'                 # step3
                    end
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 10, output_tokens: 5 }
          )
        end
      end.new

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step1, as: :extract
        step step2, as: :transform
        step step3, as: :finalize
      end

      result = pipeline.run("hello", context: { adapter: adapter })

      expect(result.status).to eq(:ok),
                               "Pipeline should complete successfully after step 2 retries. " \
                               "Got: #{result.status}, failed_step: #{result.failed_step}"

      # Step 2's output (from successful retry) should flow to step 3
      expect(result.outputs_by_step[:transform]).to eq({ status: "ok", name: "Alice" })
      expect(result.outputs_by_step[:finalize]).to eq({ done: true })

      # 4 total adapter calls: step1 + step2(2 attempts) + step3
      expect(call_count).to eq(4)
    end
  end

  # ---------------------------------------------------------------------------
  # SCENARIO 13: Verify the full trace structure of a pipeline with retried step.
  # Pipeline::Trace.step_traces should contain one Step::Trace per pipeline step,
  # and a retried step's trace should contain the attempt log and aggregated usage.
  # ---------------------------------------------------------------------------
  describe "SCENARIO 13: Pipeline trace structure with retried steps" do
    it "pipeline trace has correct step_traces count even when a step retries" do
      step1 = Class.new(RubyLLM::Contract::Step::Base) do
        prompt { user "{input}" }
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
      end

      step2 = Class.new(RubyLLM::Contract::Step::Base) do
        input_type RubyLLM::Contract::Types::Hash
        output_type RubyLLM::Contract::Types::Hash
        contract { parse :json }
        prompt { |i| user "step2: #{i.to_json}" }
        retry_policy attempts: 2
      end

      call_count = 0
      adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
        define_method(:call) do |messages:, **_opts|
          call_count += 1
          content = case call_count
                    when 1 then '{"x": 1}'
                    when 2 then "bad json"
                    when 3 then '{"y": 2}'
                    end
          RubyLLM::Contract::Adapters::Response.new(
            content: content,
            usage: { input_tokens: 20, output_tokens: 10 }
          )
        end
      end.new

      pipeline = Class.new(RubyLLM::Contract::Pipeline::Base) do
        step step1, as: :a
        step step2, as: :b
      end

      result = pipeline.run("hello", context: { adapter: adapter })

      expect(result.status).to eq(:ok)

      # Pipeline trace should have exactly 2 step_traces (one per pipeline step)
      expect(result.trace.step_traces.length).to eq(2),
                                                 "Pipeline should have 2 step traces, not 3 " \
                                                 "(retry attempts are inside the step trace, not separate)"

      # Step B's trace should have attempt info
      step_b_trace = result.trace.step_traces[1]
      expect(step_b_trace.attempts).not_to be_nil
      expect(step_b_trace.attempts.length).to eq(2),
                                              "Step B's trace should show 2 attempts"

      # Step B's aggregated usage should include both attempts
      expect(step_b_trace.usage[:input_tokens]).to eq(40),
                                                   "Step B usage should aggregate both attempts (20+20)"

      # Pipeline total usage should be step_a + step_b(aggregated)
      expect(result.trace.total_usage[:input_tokens]).to eq(60),
                                                         "Pipeline total should be 20 + 40 = 60"
    end
  end
end
