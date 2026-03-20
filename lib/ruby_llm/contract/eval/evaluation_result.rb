# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class EvaluationResult
        attr_reader :score, :passed, :label, :details

        def initialize(score:, passed:, label: nil, details: nil)
          @score = score.to_f.clamp(0.0, 1.0)
          @passed = passed
          @label = label || (passed ? "PASS" : "FAIL")
          @details = details
          freeze
        end

        def failed?
          !@passed
        end

        def to_s
          "#{@label} (score: #{@score}#{" — #{@details}" if @details})"
        end
      end
    end
  end
end
