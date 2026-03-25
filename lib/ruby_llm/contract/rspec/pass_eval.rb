# frozen_string_literal: true

module RubyLLM
  module Contract
    module RSpec
      # Helper methods for the pass_eval matcher to keep the block short.
      module PassEvalHelpers
        def format_failure_message(eval_name, error, report, minimum_score, maximum_cost)
          return format_error_message(eval_name, error) if error

          format_report_message(eval_name, report, minimum_score, maximum_cost)
        end

        def format_error_message(eval_name, error)
          "expected #{eval_name} eval to pass, but it raised an error:\n  #{error.class}: #{error.message}"
        end

        def format_report_message(eval_name, report, minimum_score, maximum_cost)
          lines = build_header(eval_name, report, minimum_score, maximum_cost)
          lines << ""

          report.results.each do |result|
            cost_str = result.cost ? " $#{format("%.4f", result.cost)}" : ""
            lines << "  #{result.label}  #{result.name} (score: #{result.score})#{cost_str}"
            lines << "        #{result.details}" if result.details && result.failed?
          end

          lines.join("\n")
        end

        private

        def build_header(eval_name, report, minimum_score, maximum_cost)
          cost_str = report.total_cost.positive? ? ", cost: $#{format("%.4f", report.total_cost)}" : ""

          if maximum_cost && report.total_cost > maximum_cost
            ["expected #{eval_name} eval cost <= $#{format("%.4f", maximum_cost)}, " \
             "but got: $#{format("%.4f", report.total_cost)} (#{report.pass_rate})"]
          elsif minimum_score
            ["expected #{eval_name} eval score >= #{minimum_score}, " \
             "but got: #{report.score.round(2)} (#{report.pass_rate}#{cost_str})"]
          else
            ["expected #{eval_name} eval to pass, " \
             "but got score: #{report.score.round(2)} (#{report.pass_rate}#{cost_str})"]
          end
        end
      end
    end
  end
end

RSpec::Matchers.define :pass_eval do |eval_name|
  include RubyLLM::Contract::RSpec::PassEvalHelpers

  chain :with_context do |ctx|
    @context = ctx
  end

  chain :with_minimum_score do |score|
    @minimum_score = score
  end

  chain :with_maximum_cost do |cost|
    @maximum_cost = cost
  end

  chain :without_regressions do
    @check_regressions = true
  end

  chain :compared_with do |other_step|
    @comparison_step = other_step
    @check_regressions = true # compared_with implies regression check
  end

  match do |step_or_pipeline|
    @eval_name = eval_name
    @context ||= {}
    @minimum_score ||= nil
    @maximum_cost ||= nil
    @check_regressions ||= false
    @comparison_step ||= nil
    @error = nil
    @diff = nil
    @prompt_diff = nil

    if @comparison_step && @check_regressions
      @prompt_diff = step_or_pipeline.compare_with(@comparison_step, eval: eval_name, context: @context)
      @report = @prompt_diff.candidate_report
    else
      @report = step_or_pipeline.run_eval(eval_name, context: @context)
    end

    score_ok = if @minimum_score
                 @report.score >= @minimum_score
               else
                 @report.passed?
               end

    cost_ok = @maximum_cost ? @report.total_cost <= @maximum_cost : true

    regression_ok = if @prompt_diff
                      @prompt_diff.safe_to_switch?
                    elsif @check_regressions && @report.baseline_exists?
                      @diff = @report.compare_with_baseline
                      !@diff.regressed?
                    else
                      true
                    end

    score_ok && cost_ok && regression_ok
  rescue StandardError => e
    @error = e
    false
  end

  failure_message do
    if @prompt_diff && !@prompt_diff.safe_to_switch?
      msg = "expected #{@eval_name} eval to be safe to switch from baseline prompt\n"

      # Check empty sides first — most fundamental problem
      bl_empty = @prompt_diff.baseline_empty?
      cd_empty = @prompt_diff.candidate_empty?
      if bl_empty || cd_empty
        msg += "  One side has no evaluated cases (all skipped or no adapter?)\n"
        if sample_response_only_compare?
          msg += "  compare_with ignores sample_response; pass model: or with_context(adapter: ...)\n"
        end
        msg += "  Candidate score: #{@prompt_diff.candidate_score}, Baseline score: #{@prompt_diff.baseline_score}"
        next msg
      end

      # Check dataset comparability — names, inputs, AND expected must match
      unless @prompt_diff.cases_comparable?
        unless @prompt_diff.case_names_match?
          mm = @prompt_diff.mismatched_cases
          msg += "  Case set mismatch — candidate and baseline must have identical cases:\n"
          mm[:only_in_baseline].each { |n| msg += "    only in baseline: #{n}\n" }
          mm[:only_in_candidate].each { |n| msg += "    only in candidate: #{n}\n" }
        end
        @prompt_diff.input_mismatches.each do |m|
          msg += "  Input mismatch for '#{m[:case]}' — same name but different inputs\n"
        end
        @prompt_diff.expected_mismatches.each do |m|
          msg += "  Expected mismatch for '#{m[:case]}' — same name/input but different expected values\n"
        end
        next msg
      end

      # Check per-case score regressions (even if global average is flat)
      if @prompt_diff.score_regressions.any?
        msg += "  Per-case score regressions (#{@prompt_diff.score_regressions.length}):\n"
        @prompt_diff.score_regressions.each do |r|
          msg += "    #{r[:case]}: #{r[:baseline_score]} -> #{r[:candidate_score]} (#{r[:delta]})\n"
        end
        msg += "  Score delta: #{@prompt_diff.score_delta}"
        next msg
      end

      # Check pass/fail regressions and removed cases
      removed = @prompt_diff.removed_passing_cases
      reg_count = @prompt_diff.regressions.length + removed.length
      msg += "  Found #{reg_count} regression(s):\n"
      @prompt_diff.regressions.each do |r|
        msg += "    #{r[:case]}: was PASS, now FAIL -- #{r[:detail]}\n"
      end
      removed.each do |name|
        msg += "    #{name}: REMOVED (was passing in baseline)\n"
      end
      msg += "  Score delta: #{@prompt_diff.score_delta}"
      next msg
    end

    msg = format_failure_message(@eval_name, @error, @report, @minimum_score, @maximum_cost)
    if @diff&.regressed?
      msg += "\n\nRegressions from baseline:\n"
      @diff.regressions.each do |r|
        msg += "  #{r[:case]}: was PASS, now FAIL -- #{r[:detail]}\n"
      end
      msg += "  Score delta: #{@diff.score_delta}"
    end
    msg
  end

  failure_message_when_negated do
    "expected #{@eval_name} eval NOT to pass, but it passed with score: #{@report.score.round(2)}"
  end

  def sample_response_only_compare?
    return false unless @comparison_step
    return false if @context[:adapter] || @context[:model]

    defn = @comparison_step.send(:all_eval_definitions)[@eval_name.to_s]
    defn&.build_adapter
  rescue StandardError
    false
  end
end
