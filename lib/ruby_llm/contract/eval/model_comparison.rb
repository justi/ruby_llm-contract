# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class ModelComparison
        attr_reader :eval_name, :reports, :configs, :fallback

        def self.candidate_label(config)
          effort = config[:reasoning_effort]
          effort ? "#{config[:model]} (effort: #{effort})" : config[:model]
        end

        def initialize(eval_name:, reports:, configs: nil, fallback: nil)
          @eval_name = eval_name
          @reports = reports.dup.freeze
          @configs = (configs || default_configs_from_reports).freeze
          @fallback = fallback
          freeze
        end

        def production_mode?
          !@fallback.nil?
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
          return production_mode_table if production_mode?

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

        def production_mode_table
          fallback_label = self.class.candidate_label(@fallback)
          rows = @reports.map do |label, report|
            chain = chain_label(label, fallback_label)
            { chain: chain, report: report, same: chain_same_as_fallback?(label, fallback_label) }
          end

          chain_width = [rows.map { |r| r[:chain].length }.max || 0, 20].max
          lines = [format("  %-#{chain_width}s  %-11s  %-10s  %-14s  %-9s  %s",
                          "Chain", "single-shot", "escalation", "effective cost", "latency", "score")]
          lines << "  #{"-" * (chain_width + 60)}"

          rows.each do |row|
            lines << format_production_row(row, chain_width)
          end

          lines.join("\n")
        end

        private

        def chain_label(label, fallback_label)
          label == fallback_label ? label : "#{label} → #{fallback_label}"
        end

        def chain_same_as_fallback?(label, fallback_label)
          label == fallback_label
        end

        def format_production_row(row, chain_width)
          report = row[:report]
          format("  %-#{chain_width}s  %-11s  %-10s  %-14s  %-9s  %6.2f",
                 row[:chain],
                 format_money(report.single_shot_cost || report.total_cost),
                 format_escalation(row, report),
                 format_money(report.effective_cost),
                 format_latency(report.effective_latency_ms),
                 report.score)
        end

        def format_money(value)
          value&.positive? ? "$#{format("%.4f", value)}" : "n/a"
        end

        def format_latency(value)
          value ? "#{value.round}ms" : "n/a"
        end

        def format_escalation(row, report)
          return "—" if row[:same]

          format("%d%%", ((report.escalation_rate || 0) * 100).round)
        end

        public

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
            base = {
              score: report.score,
              total_cost: report.total_cost,
              avg_latency_ms: report.avg_latency_ms,
              pass_rate: report.pass_rate,
              pass_rate_ratio: report.pass_rate_ratio,
              passed: report.passed?
            }
            production_mode_metrics(report, base)
          end
        end

        private

        def production_mode_metrics(report, base)
          return base unless report.respond_to?(:production_mode?) && report.production_mode?

          base.merge(
            escalation_rate: report.escalation_rate,
            single_shot_cost: report.single_shot_cost,
            effective_cost: report.effective_cost,
            single_shot_latency_ms: report.single_shot_latency_ms,
            effective_latency_ms: report.effective_latency_ms,
            latency_percentiles: report.latency_percentiles
          )
        end

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
