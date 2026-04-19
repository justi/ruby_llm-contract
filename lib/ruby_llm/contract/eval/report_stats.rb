# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # Computes aggregate metrics for an eval report.
      class ReportStats
        def initialize(results:)
          @results = results
        end

        def score
          return 0.0 if evaluated_results.empty?

          evaluated_results.sum(&:score) / evaluated_results.length
        end

        def passed
          evaluated_results.count(&:passed?)
        end

        def failed
          evaluated_results.count(&:failed?)
        end

        def skipped
          @results.count { |result| result.step_status == :skipped }
        end

        def failures
          evaluated_results.select(&:failed?)
        end

        def pass_rate
          "#{passed}/#{evaluated_results.length}"
        end

        def pass_rate_ratio
          return 0.0 if evaluated_results.empty?

          passed.to_f / evaluated_results.length
        end

        def total_cost
          @results.sum { |result| result.cost || 0.0 }
        end

        def avg_latency_ms
          latencies = @results.filter_map(&:duration_ms)
          return nil if latencies.empty?

          latencies.sum.to_f / latencies.length
        end

        def passed?
          return false if evaluated_results.empty?

          evaluated_results.all?(&:passed?)
        end

        def evaluated_results
          @evaluated_results ||= @results.reject { |result| result.step_status == :skipped }
        end

        def evaluated_results_count
          evaluated_results.length
        end

        def production_mode?
          evaluated_results.any? { |r| r.respond_to?(:attempts) && r.attempts }
        end

        def escalation_rate
          return nil unless production_mode?
          return 0.0 if evaluated_results.empty?

          escalated = evaluated_results.count { |r| (r.attempts || []).length > 1 }
          escalated.to_f / evaluated_results.length
        end

        def single_shot_cost
          return nil unless production_mode?

          evaluated_results.sum { |r| first_attempt_cost(r) || r.cost || 0.0 }
        end

        def effective_cost
          total_cost
        end

        def single_shot_latency_ms
          return nil unless production_mode?

          latencies = evaluated_results.filter_map { |r| first_attempt_latency(r) || r.duration_ms }
          return nil if latencies.empty?

          latencies.sum.to_f / latencies.length
        end

        def effective_latency_ms
          avg_latency_ms
        end

        def latency_percentiles
          return nil unless production_mode?

          latencies = evaluated_results.filter_map(&:duration_ms).sort
          return nil if latencies.empty?

          { p50: percentile(latencies, 0.50), p95: percentile(latencies, 0.95), max: latencies.last.to_f }
        end

        private

        def first_attempt_cost(result)
          first = (result.attempts || []).first
          first && first[:cost]
        end

        def first_attempt_latency(result)
          first = (result.attempts || []).first
          first && first[:latency_ms]
        end

        def percentile(sorted, fraction)
          return nil if sorted.empty?

          idx = (fraction * (sorted.length - 1)).round
          sorted[idx].to_f
        end
      end
    end
  end
end
