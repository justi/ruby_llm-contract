# frozen_string_literal: true

require "ruby_llm/contract"

module RubyLLM
  module Contract
    module MinitestHelpers
      def assert_satisfies_contract(result, msg = nil)
        assert result.ok?, msg || "Expected step result to satisfy contract, " \
          "but got status: #{result.status}. Errors: #{result.validation_errors.join(", ")}"
      end

      def refute_satisfies_contract(result, msg = nil)
        refute result.ok?, msg || "Expected step result NOT to satisfy contract, but it passed"
      end

      def assert_eval_passes(step, eval_name, minimum_score: nil, maximum_cost: nil, context: {}, msg: nil)
        report = step.run_eval(eval_name, context: context)

        if minimum_score
          assert report.score >= minimum_score,
                 msg || "Expected #{eval_name} eval score >= #{minimum_score}, got #{report.score.round(2)} (#{report.pass_rate})"
        else
          assert report.passed?,
                 msg || "Expected #{eval_name} eval to pass, got #{report.score.round(2)} (#{report.pass_rate})"
        end

        if maximum_cost
          assert report.total_cost <= maximum_cost,
                 msg || "Expected #{eval_name} eval cost <= $#{format("%.4f", maximum_cost)}, got $#{format("%.4f", report.total_cost)}"
        end

        report
      end

      def stub_step(step_class, response: nil, responses: nil)
        adapter = if responses
                    Adapters::Test.new(responses: responses)
                  else
                    Adapters::Test.new(response: response)
                  end
        RubyLLM::Contract.configure { |c| c.default_adapter = adapter }
      end
    end
  end
end
