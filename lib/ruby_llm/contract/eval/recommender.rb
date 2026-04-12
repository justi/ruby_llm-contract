# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class Recommender
        def initialize(comparison:, min_score:, min_first_try_pass_rate: 0.8, current_config: nil)
          @comparison = comparison
          @min_score = min_score
          @min_first_try_pass_rate = min_first_try_pass_rate
          @current_config = current_config
        end

        def recommend
          scored = build_scored_candidates
          best = select_best(scored)
          chain = build_retry_chain(scored, best)
          rationale = build_rationale(scored, best)
          warnings = build_warnings(scored)
          savings = best ? calculate_savings(best) : {}

          Recommendation.new(
            best: best&.dig(:config),
            retry_chain: chain,
            score: best&.dig(:score) || 0.0,
            cost_per_call: best&.dig(:cost_per_call) || 0.0,
            rationale: rationale,
            current_config: @current_config,
            savings: savings,
            warnings: warnings
          )
        end

        private

        def build_scored_candidates
          @comparison.configs.filter_map do |label, config|
            report = @comparison.reports[label]
            next nil unless report

            evaluated_count = report.results.count { |r| r.step_status != :skipped }
            cases_count = [evaluated_count, 1].max
            cost_per_call = report.total_cost.to_f / cases_count

            {
              label: label,
              config: config,
              score: report.score,
              cost_per_call: cost_per_call,
              latency: report.avg_latency_ms || 0,
              pass_rate_ratio: report.pass_rate_ratio,
              total_cost: report.total_cost
            }
          end
        end

        def select_best(scored)
          eligible = scored.select { |s| s[:score] >= @min_score && cost_known?(s) }
          eligible.min_by { |s| [s[:cost_per_call], s[:latency], s[:label]] }
        end

        def build_retry_chain(scored, best)
          return [] unless best

          first_try = scored
            .select { |s| s[:pass_rate_ratio] >= @min_first_try_pass_rate && cost_known?(s) }
            .min_by { |s| [s[:cost_per_call], s[:latency], s[:label]] }

          if first_try.nil? || first_try[:label] == best[:label]
            [best[:config]]
          else
            [first_try[:config], best[:config]]
          end
        end

        def build_rationale(scored, best)
          sorted = scored.sort_by { |s| [s[:cost_per_call], s[:latency], s[:label]] }
          sorted.map { |s| rationale_line(s, best) }
        end

        def rationale_line(candidate, best)
          header = "#{candidate[:label]}, score #{format("%.2f", candidate[:score])}, at $#{format("%.4f", candidate[:cost_per_call])}/call"
          notes = rationale_notes(candidate, best)
          notes.any? ? "#{header} — #{notes.join(", ")}" : header
        end

        def rationale_notes(candidate, best)
          notes = []
          pass_pct = (candidate[:pass_rate_ratio] * 100).round
          below_threshold = candidate[:score] < @min_score

          if below_threshold && candidate[:pass_rate_ratio] >= @min_first_try_pass_rate
            notes << "below #{@min_score} threshold, but good first-try (#{pass_pct}% pass rate)"
          elsif below_threshold
            notes << "below #{@min_score} threshold"
          elsif candidate[:pass_rate_ratio] < 1.0
            notes << "#{pass_pct}% pass rate"
          end
          notes << "recommended" if best && candidate[:label] == best[:label]
          notes << "unknown pricing" unless cost_known?(candidate)
          notes
        end

        def build_warnings(scored)
          scored.reject { |s| cost_known?(s) }
                .map { |s| "#{s[:label]}: unknown pricing — cost ranking may be inaccurate" }
        end

        def calculate_savings(best)
          return {} unless @current_config

          current_label = ModelComparison.candidate_label(@current_config)
          current_report = @comparison.reports[current_label]
          return {} unless current_report

          current_evaluated = current_report.results.count { |r| r.step_status != :skipped }
          current_cases = [current_evaluated, 1].max
          current_cost = current_report.total_cost.to_f / current_cases
          diff = current_cost - best[:cost_per_call]
          return {} unless diff.positive?

          { per_call: diff.round(6), monthly_at: { 10_000 => (diff * 10_000).round(2) } }
        end

        def cost_known?(scored_candidate)
          scored_candidate[:cost_per_call]&.positive?
        end
      end
    end
  end
end
