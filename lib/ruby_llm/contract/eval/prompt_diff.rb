# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class PromptDiff
        attr_reader :candidate_report, :baseline_report

        def initialize(candidate:, baseline:)
          @candidate_report = candidate
          @baseline_report = baseline
          @candidate_cases = serialize_results(candidate)
          @baseline_cases = serialize_results(baseline)
          @diff = BaselineDiff.new(
            baseline_cases: @baseline_cases,
            current_cases: @candidate_cases
          )
          freeze
        end

        def improvements
          @diff.improvements
        end

        def regressions
          @diff.regressions
        end

        def score_delta
          @diff.score_delta
        end

        # A/B switch is safe only when:
        # 1. Both sides have evaluated cases (no empty/skipped sides)
        # 2. Case sets are identical (same names, inputs, AND expected)
        # 3. No pass→fail regressions and no removed passing cases
        # 4. No per-case score drops (even if global average stays flat)
        def safe_to_switch?
          return false if @baseline_cases.empty? || @candidate_cases.empty?
          return false unless cases_comparable?
          return false if score_regressions.any?

          !@diff.regressed?
        end

        def removed_passing_cases
          @diff.removed_passing_cases
        end

        # Checks that case names match (ignoring input content)
        def case_names_match?
          extract_names(@baseline_cases) == extract_names(@candidate_cases)
        end

        # Checks that case names AND inputs are identical
        def cases_comparable?
          extract_signatures(@baseline_cases) == extract_signatures(@candidate_cases)
        end

        def mismatched_cases
          baseline_names = extract_names(@baseline_cases)
          candidate_names = extract_names(@candidate_cases)
          {
            only_in_baseline: baseline_names - candidate_names,
            only_in_candidate: candidate_names - baseline_names
          }
        end

        # Cases where names match but inputs differ
        def input_mismatches
          baseline_sigs = @baseline_cases.to_h { |c| [c[:name], c[:input]] }
          @candidate_cases.filter_map do |c|
            next unless baseline_sigs.key?(c[:name])

            bl_input = baseline_sigs[c[:name]]
            next if bl_input == c[:input]

            { case: c[:name], baseline_input: bl_input, candidate_input: c[:input] }
          end
        end

        # Cases where names and inputs match but expected values differ
        def expected_mismatches
          baseline_sigs = @baseline_cases.to_h { |c| [c[:name], c[:expected]] }
          @candidate_cases.filter_map do |c|
            next unless baseline_sigs.key?(c[:name])

            bl_expected = baseline_sigs[c[:name]]
            next if bl_expected == c[:expected]

            { case: c[:name], baseline_expected: bl_expected, candidate_expected: c[:expected] }
          end
        end

        # Cases where score dropped (even if both pass/fail status unchanged)
        def score_regressions
          baseline_idx = @baseline_cases.to_h { |c| [c[:name], c] }
          @candidate_cases.filter_map do |c|
            bl = baseline_idx[c[:name]]
            next unless bl
            next unless c[:score] < bl[:score]

            {
              case: c[:name],
              baseline_score: bl[:score],
              candidate_score: c[:score],
              delta: (c[:score] - bl[:score]).round(4)
            }
          end
        end

        def candidate_score
          @diff.current_score
        end

        def baseline_score
          @diff.baseline_score
        end

        def baseline_empty?
          @baseline_cases.empty?
        end

        def candidate_empty?
          @candidate_cases.empty?
        end

        def print_summary(io = $stdout)
          io.puts "Prompt A/B comparison"
          io.puts
          io.puts format("  %-12s  Score", "Variant")
          io.puts "  #{"-" * 26}"
          io.puts format("  %-12s  %.2f", "Candidate", candidate_score)
          io.puts format("  %-12s  %.2f", "Baseline", baseline_score)
          io.puts
          io.puts "  Score delta: #{format_delta}"
          io.puts

          if @baseline_cases.empty? || @candidate_cases.empty?
            io.puts "  WARNING: one side has no evaluated cases (all skipped?)"
            io.puts
          end

          unless case_names_match?
            mm = mismatched_cases
            io.puts "  Case set mismatch (safe_to_switch? = NO):"
            mm[:only_in_baseline].each { |n| io.puts "    only in baseline: #{n}" }
            mm[:only_in_candidate].each { |n| io.puts "    only in candidate: #{n}" }
            io.puts
          end

          if input_mismatches.any?
            io.puts "  Input mismatch (safe_to_switch? = NO):"
            input_mismatches.each do |m|
              io.puts "    #{m[:case]}: inputs differ between candidate and baseline"
            end
            io.puts
          end

          if expected_mismatches.any?
            io.puts "  Expected mismatch (safe_to_switch? = NO):"
            expected_mismatches.each do |m|
              io.puts "    #{m[:case]}: expected values differ between candidate and baseline"
            end
            io.puts
          end

          if regressions.any?
            io.puts "  Regressions (PASS -> FAIL):"
            regressions.each do |r|
              io.puts "    #{r[:case]}: was PASS, now FAIL -- #{r[:detail]}"
            end
            io.puts
          end

          if score_regressions.any?
            io.puts "  Score drops:"
            score_regressions.each do |r|
              io.puts "    #{r[:case]}: #{r[:baseline_score]} -> #{r[:candidate_score]} (#{r[:delta]})"
            end
            io.puts
          end

          if improvements.any?
            io.puts "  Improvements:"
            improvements.each do |r|
              io.puts "    #{r[:case]}: was FAIL, now PASS"
            end
            io.puts
          end

          if removed_passing_cases.any?
            io.puts "  Removed (were passing in baseline):"
            removed_passing_cases.each do |name|
              io.puts "    #{name}"
            end
            io.puts
          end

          io.puts "  Safe to switch: #{safe_to_switch? ? "YES" : "NO"}"
        end

        private

        def serialize_results(report)
          report.results.reject { |r| r.step_status == :skipped }.map do |r|
            {
              name: r.name,
              input: r.input,
              expected: r.expected,
              passed: r.passed?,
              score: r.score,
              details: r.details
            }
          end
        end

        def extract_names(cases)
          cases.map { |c| c[:name] }.sort
        end

        # Full signature: name + input + expected — all must match for comparable A/B
        def extract_signatures(cases)
          cases.map { |c| [c[:name], c[:input], c[:expected]] }.sort_by(&:first)
        end

        def format_delta
          d = score_delta
          d >= 0 ? "+#{d}" : d.to_s
        end
      end
    end
  end
end
