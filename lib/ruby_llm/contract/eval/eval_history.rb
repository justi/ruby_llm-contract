# frozen_string_literal: true

require "json"
require "fileutils"

module RubyLLM
  module Contract
    module Eval
      class EvalHistory
        attr_reader :runs

        def initialize(runs:)
          @runs = runs.freeze
          freeze
        end

        def self.load(path)
          return new(runs: []) unless File.exist?(path)

          runs = File.readlines(path).filter_map do |line|
            JSON.parse(line.strip, symbolize_names: true)
          rescue JSON::ParserError
            nil
          end
          new(runs: runs)
        end

        def self.append(path, run_data)
          FileUtils.mkdir_p(File.dirname(path))
          File.open(path, "a") { |f| f.puts(run_data.to_json) }
        end

        def score_trend
          return :unknown if runs.length < 2

          scores = runs.map { |r| r[:score] }
          recent = scores.last(3)
          if recent.all? { |s| s >= scores.first }
            :stable_or_improving
          elsif recent.last < scores.max * 0.9
            :declining
          else
            :stable_or_improving
          end
        end

        def drift?(threshold: 0.1)
          return false if runs.length < 2

          baseline_score = runs.first[:score]
          current_score = runs.last[:score]
          (baseline_score - current_score) > threshold
        end

        def scores
          runs.map { |r| r[:score] }
        end

        def dates
          runs.map { |r| r[:date] }
        end

        def latest
          runs.last
        end

        def to_s
          return "No history" if runs.empty?

          lines = ["#{runs.length} runs"]
          runs.last(5).each do |r|
            lines << "  #{r[:date]} score=#{r[:score].round(2)} cost=$#{format("%.6f", r[:cost] || 0)}"
          end
          lines.join("\n")
        end
      end
    end
  end
end
