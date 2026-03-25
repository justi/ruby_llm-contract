# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # Renders a prompt diff as a readable console summary.
      class PromptDiffPresenter
        VARIANT_LABEL_WIDTH = 12
        TABLE_WIDTH = 26
        CASE_SET_MISMATCH_TITLE = "  Case set mismatch (safe_to_switch? = NO):"
        INPUT_MISMATCH_TITLE = "  Input mismatch (safe_to_switch? = NO):"
        EXPECTED_MISMATCH_TITLE = "  Expected mismatch (safe_to_switch? = NO):"
        REGRESSIONS_TITLE = "  Regressions (PASS -> FAIL):"
        SCORE_DROPS_TITLE = "  Score drops:"
        IMPROVEMENTS_TITLE = "  Improvements:"
        REMOVED_PASSING_TITLE = "  Removed (were passing in baseline):"

        def initialize(prompt_diff:, comparator:)
          @prompt_diff = prompt_diff
          @comparator = comparator
        end

        def print_summary(io = $stdout)
          print_header(io)
          print_warning(io, "one side has no evaluated cases (all skipped?)") if @comparator.empty_comparison?
          print_case_set_mismatch(io)
          print_formatted_section(io, INPUT_MISMATCH_TITLE, @comparator.input_mismatches) do |mismatch|
            "#{mismatch[:case]}: inputs differ between candidate and baseline"
          end
          print_formatted_section(io, EXPECTED_MISMATCH_TITLE, @comparator.expected_mismatches) do |mismatch|
            "#{mismatch[:case]}: expected values differ between candidate and baseline"
          end
          print_formatted_section(io, REGRESSIONS_TITLE, @prompt_diff.regressions) do |regression|
            "#{regression[:case]}: was PASS, now FAIL -- #{regression[:detail]}"
          end
          print_formatted_section(io, SCORE_DROPS_TITLE, @comparator.score_regressions) do |regression|
            "#{regression[:case]}: #{regression[:baseline_score]} -> #{regression[:candidate_score]} (#{regression[:delta]})"
          end
          print_formatted_section(io, IMPROVEMENTS_TITLE, @prompt_diff.improvements) do |improvement|
            "#{improvement[:case]}: was FAIL, now PASS"
          end
          print_formatted_section(io, REMOVED_PASSING_TITLE, @prompt_diff.removed_passing_cases, &:to_s)
          io.puts "  Safe to switch: #{@comparator.safe_to_switch? ? "YES" : "NO"}"
        end

        private

        def print_header(io)
          lines = [
            "Prompt A/B comparison",
            nil,
            format("  %-#{VARIANT_LABEL_WIDTH}s  Score", "Variant"),
            "  #{"-" * TABLE_WIDTH}",
            format("  %-#{VARIANT_LABEL_WIDTH}s  %.2f", "Candidate", @comparator.candidate_score),
            format("  %-#{VARIANT_LABEL_WIDTH}s  %.2f", "Baseline", @comparator.baseline_score),
            nil,
            "  Score delta: #{format_delta(@prompt_diff.score_delta)}",
            nil
          ]
          emit_lines(io, lines)
        end

        def print_warning(io, message)
          emit_lines(io, ["  WARNING: #{message}", nil])
        end

        def print_case_set_mismatch(io)
          return if @comparator.case_names_match?

          mismatches = @comparator.mismatched_cases
          lines = mismatches[:only_in_baseline].map { |name| "only in baseline: #{name}" } +
            mismatches[:only_in_candidate].map { |name| "only in candidate: #{name}" }
          emit_section(io, CASE_SET_MISMATCH_TITLE, lines)
        end

        def print_formatted_section(io, title, collection)
          return if collection.empty?

          lines = collection.map { |entry| yield(entry) }
          emit_section(io, title, lines)
        end

        def emit_section(io, title, lines)
          emit_lines(io, [title, *lines.map { |line| "    #{line}" }, nil])
        end

        def emit_lines(io, lines)
          lines.each do |line|
            line.nil? ? io.puts : io.puts(line)
          end
        end

        def format_delta(delta)
          delta >= 0 ? "+#{delta}" : delta.to_s
        end
      end
    end
  end
end
