# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # Wraps N Reports from repeated runs of the same eval to reduce sampling
      # variance in live mode (temperature=1 on gpt-5 family). Exposes the same
      # duck-type as Report — mean score, mean cost per run, mean latency.
      #
      # pass_rate reports how many runs passed cleanly (x/N), not case-level
      # pass rate, since the question is "does this candidate reliably pass?".
      class AggregatedReport
        attr_reader :runs

        def initialize(runs)
          raise ArgumentError, "runs must not be empty" if runs.empty?

          @runs = runs.freeze
          freeze
        end

        def dataset_name
          @runs.first.dataset_name
        end

        def step_name
          @runs.first.step_name
        end

        def score
          @runs.sum(&:score) / @runs.length.to_f
        end

        def score_min
          @runs.map(&:score).min
        end

        def score_max
          @runs.map(&:score).max
        end

        def total_cost
          @runs.sum(&:total_cost) / @runs.length.to_f
        end

        def avg_latency_ms
          latencies = @runs.filter_map(&:avg_latency_ms)
          return nil if latencies.empty?

          latencies.sum / latencies.length.to_f
        end

        def pass_rate
          "#{clean_passes}/#{@runs.length}"
        end

        def pass_rate_ratio
          @runs.sum(&:pass_rate_ratio) / @runs.length.to_f
        end

        def passed?
          @runs.all?(&:passed?)
        end

        def clean_passes
          @runs.count(&:passed?)
        end

        def failures
          @runs.flat_map(&:failures)
        end
      end
    end
  end
end
