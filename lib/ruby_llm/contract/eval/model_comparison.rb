# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class ModelComparison
        attr_reader :eval_name, :reports, :configs

        def self.candidate_label(config)
          effort = config[:reasoning_effort]
          effort ? "#{config[:model]} (effort: #{effort})" : config[:model]
        end

        def initialize(eval_name:, reports:, configs: nil)
          @eval_name = eval_name
          @reports = reports.dup.freeze
          @configs = (configs || default_configs_from_reports).freeze
          freeze
        end

        def models
          @reports.keys
        end

        def score_for(candidate)
          @reports[resolve_key(candidate)]&.score
        end

        def cost_for(candidate)
          @reports[resolve_key(candidate)]&.total_cost
        end

        def best_for(min_score: 0.0)
          eligible = @reports.select { |_, report| report.score > 0.0 && report.score >= min_score }
          return nil if eligible.empty?

          eligible.min_by { |_, report| report.total_cost }&.first
        end

        def cost_per_point
          @reports.transform_values do |report|
            report.score.positive? ? report.total_cost / report.score : Float::INFINITY
          end
        end

        def table
          max_label = [@reports.keys.map(&:length).max || 0, 25].max
          lines = [format("  %-#{max_label}s  Score       Cost  Avg Latency", "Candidate")]
          lines << "  #{"-" * (max_label + 36)}"

          @reports.each do |label, report|
            latency = report.avg_latency_ms ? "#{report.avg_latency_ms.round}ms" : "n/a"
            cost = report.total_cost.positive? ? "$#{format("%.4f", report.total_cost)}" : "n/a"
            lines << format("  %-#{max_label}s %6.2f %10s %12s", label, report.score, cost, latency)
          end

          lines.join("\n")
        end

        def print_summary(io = $stdout)
          io.puts "#{@eval_name} — model comparison"
          io.puts
          io.puts table
          io.puts

          best = best_for(min_score: 0.0)
          io.puts "  Best overall: #{best}" if best

          cheapest_passing = best_for(min_score: 1.0)
          io.puts "  Cheapest at 100%: #{cheapest_passing}" if cheapest_passing
        end

        def to_h
          @reports.transform_values do |report|
            {
              score: report.score,
              total_cost: report.total_cost,
              avg_latency_ms: report.avg_latency_ms,
              pass_rate: report.pass_rate,
              pass_rate_ratio: report.pass_rate_ratio,
              passed: report.passed?
            }
          end
        end

        private

        def resolve_key(candidate)
          case candidate
          when String then candidate
          when Hash then self.class.candidate_label(candidate)
          else candidate.to_s
          end
        end

        def default_configs_from_reports
          @reports.each_with_object({}) { |(key, _), h| h[key] = { model: key } }
        end
      end
    end
  end
end
