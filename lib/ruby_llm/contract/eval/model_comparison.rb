# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class ModelComparison
        attr_reader :eval_name, :reports

        def initialize(eval_name:, reports:)
          @eval_name = eval_name
          @reports = reports.freeze # { "model_name" => Report }
          freeze
        end

        def models
          @reports.keys
        end

        def score_for(model)
          @reports[model]&.score
        end

        def cost_for(model)
          @reports[model]&.total_cost
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
          lines = ["  Model                      Score       Cost  Avg Latency"]
          lines << "  #{"-" * 57}"

          @reports.each do |model, report|
            latency = report.avg_latency_ms ? "#{report.avg_latency_ms.round}ms" : "n/a"
            cost = report.total_cost.positive? ? "$#{format("%.4f", report.total_cost)}" : "n/a"
            lines << format("  %-25s %6.2f %10s %12s", model, report.score, cost, latency)
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
              passed: report.passed?
            }
          end
        end
      end
    end
  end
end
