# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class BaselineDiff
        attr_reader :baseline_score, :current_score

        def initialize(baseline_cases:, current_cases:)
          @baseline = index_by_name(baseline_cases)
          @current = index_by_name(current_cases)
          @baseline_score = compute_score(baseline_cases)
          @current_score = compute_score(current_cases)
          freeze
        end

        def regressions
          @baseline.filter_map do |name, baseline|
            current = @current[name]
            next unless current
            next unless baseline[:passed] && !current[:passed]
            next if skipped?(current)

            {
              case: name,
              baseline: { passed: baseline[:passed], score: baseline[:score] },
              current: { passed: current[:passed], score: current[:score] },
              detail: current[:details]
            }
          end
        end

        def improvements
          @baseline.filter_map do |name, baseline|
            current = @current[name]
            next unless current
            next unless !baseline[:passed] && current[:passed]

            {
              case: name,
              baseline: { passed: baseline[:passed], score: baseline[:score] },
              current: { passed: current[:passed], score: current[:score] }
            }
          end
        end

        def score_delta
          (current_score - baseline_score).round(4)
        end

        # Passed in the baseline, not run now (no adapter): not evidence of a
        # regression, but not evidence it still passes either, so the gate fails.
        def skipped_passing_cases
          @baseline.filter_map do |name, baseline|
            current = @current[name]
            next unless current && baseline[:passed] && skipped?(current)

            { case: name, detail: current[:details] }
          end
        end

        def regressed?
          regressions.any? || removed_passing_cases.any? || skipped_passing_cases.any?
        end

        def removed_passing_cases
          removed_cases.select { |name| @baseline[name]&.dig(:passed) }
        end

        def improved?
          improvements.any?
        end

        def new_cases
          (@current.keys - @baseline.keys)
        end

        def removed_cases
          (@baseline.keys - @current.keys)
        end

        def to_s
          lines = ["Score: #{baseline_score.round(2)} → #{current_score.round(2)} (#{format_delta})"]
          regressions.each { |r| lines << "  REGRESSED  #{r[:case]}: #{r[:detail]}" }
          skipped_passing_cases.each { |s| lines << "  SKIPPED    #{s[:case]}: #{s[:detail]}" }
          improvements.each { |r| lines << "  IMPROVED   #{r[:case]}" }
          new_cases.each { |c| lines << "  NEW        #{c}" }
          removed_cases.each { |c| lines << "  REMOVED    #{c}" }
          lines.join("\n")
        end

        private

        def compute_score(cases)
          # Asymmetric on purpose: the baseline side arrives already filtered by
          # ReportStats#evaluated_results, the current side does not, so this
          # string check is the only skip filter on one of the two sides.
          evaluated = cases.reject { |c| skipped?(c) }
          return 0.0 if evaluated.empty?

          evaluated.sum { |c| c[:score] } / evaluated.length
        end

        def skipped?(serialized_case)
          serialized_case[:details]&.start_with?(CaseResult::SKIPPED_DETAILS_PREFIX)
        end

        def index_by_name(cases)
          cases.each_with_object({}) { |c, h| h[c[:name]] = c }
        end

        def format_delta
          d = score_delta
          d >= 0 ? "+#{d}" : d.to_s
        end
      end
    end
  end
end
