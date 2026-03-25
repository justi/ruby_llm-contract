# frozen_string_literal: true

require "forwardable"

module RubyLLM
  module Contract
    module Eval
      class PromptDiff
        extend Forwardable

        attr_reader :candidate_report, :baseline_report
        def_delegators :@diff, :improvements, :regressions, :score_delta, :removed_passing_cases
        def_delegators :@comparator, :safe_to_switch?, :case_names_match?, :cases_comparable?, :mismatched_cases,
                       :input_mismatches, :expected_mismatches, :score_regressions, :candidate_score, :baseline_score,
                       :baseline_empty?, :candidate_empty?
        def_delegators :@presenter, :print_summary

        def initialize(candidate:, baseline:)
          @candidate_report = candidate
          @baseline_report = baseline
          serializer = PromptDiffSerializer.new
          candidate_cases = serializer.call(candidate)
          baseline_cases = serializer.call(baseline)
          @diff = BaselineDiff.new(
            baseline_cases: baseline_cases,
            current_cases: candidate_cases
          )
          @comparator = PromptDiffComparator.new(
            candidate_cases: candidate_cases,
            baseline_cases: baseline_cases,
            diff: @diff
          )
          @presenter = PromptDiffPresenter.new(prompt_diff: self, comparator: @comparator)
          freeze
        end
      end
    end
  end
end
