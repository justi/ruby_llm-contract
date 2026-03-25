# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # Encapsulates the safety and mismatch rules for prompt A/B comparison.
      class PromptDiffComparator
        def initialize(candidate_cases:, baseline_cases:, diff:)
          @candidate_cases = candidate_cases
          @baseline_cases = baseline_cases
          @diff = diff
          @baseline_case_index = baseline_cases.to_h { |case_data| [case_data[:name], case_data] }
        end

        def safe_to_switch?
          return false if empty_comparison?
          return false unless cases_comparable?
          return false if score_regressions.any?

          !@diff.regressed?
        end

        def case_names_match?
          case_names(@baseline_cases) == case_names(@candidate_cases)
        end

        def cases_comparable?
          case_signatures(@baseline_cases) == case_signatures(@candidate_cases)
        end

        def mismatched_cases
          baseline_names = case_names(@baseline_cases)
          candidate_names = case_names(@candidate_cases)

          {
            only_in_baseline: baseline_names - candidate_names,
            only_in_candidate: candidate_names - baseline_names
          }
        end

        def input_mismatches
          attribute_mismatches(:input, :baseline_input, :candidate_input)
        end

        def expected_mismatches
          attribute_mismatches(:expected, :baseline_expected, :candidate_expected)
        end

        def score_regressions
          @candidate_cases.filter_map do |candidate_case|
            baseline_case = @baseline_case_index[candidate_case[:name]]
            next unless baseline_case

            baseline_score = baseline_case[:score]
            candidate_score = candidate_case[:score]
            next unless candidate_score < baseline_score

            {
              case: candidate_case[:name],
              baseline_score: baseline_score,
              candidate_score: candidate_score,
              delta: (candidate_score - baseline_score).round(4)
            }
          end
        end

        def candidate_score
          @diff.current_score
        end

        def baseline_score
          @diff.baseline_score
        end

        def candidate_empty?
          @candidate_cases.empty?
        end

        def baseline_empty?
          @baseline_cases.empty?
        end

        def empty_comparison?
          baseline_empty? || candidate_empty?
        end

        private

        def case_names(cases)
          cases.map { |case_data| case_data[:name] }.sort
        end

        def case_signatures(cases)
          cases.map { |case_data| [case_data[:name], case_data[:input], case_data[:expected]] }.sort_by(&:first)
        end

        def attribute_mismatches(attribute, baseline_key, candidate_key)
          @candidate_cases.filter_map do |candidate_case|
            baseline_case = @baseline_case_index[candidate_case[:name]]
            next unless baseline_case

            baseline_value = baseline_case[attribute]
            candidate_value = candidate_case[attribute]
            next if baseline_value == candidate_value

            {
              case: candidate_case[:name],
              baseline_key => baseline_value,
              candidate_key => candidate_value
            }
          end
        end
      end
    end
  end
end
