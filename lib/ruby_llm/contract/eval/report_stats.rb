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
      end
    end
  end
end
