# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class PromptDiffSerializer
        def call(report)
          report.results.reject { |result| result.step_status == CaseResult::SKIPPED_STATUS }.map do |result|
            {
              name: result.name,
              input: result.input,
              expected: result.expected,
              passed: result.passed?,
              score: result.score,
              details: result.details
            }
          end
        end
      end
    end
  end
end
