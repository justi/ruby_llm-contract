# frozen_string_literal: true

require "set"

module RubyLLM
  module Contract
    module Eval
      # Runs compare_models on ALL evals for a step, builds a score matrix,
      # identifies the constraining eval, and suggests an escalation chain.
      #
      #   optimizer = RetryOptimizer.new(step: MyStep, candidates: [...], context: {})
      #   result = optimizer.call
      #   result.print_summary
      #   result.to_dsl  # => copy-paste retry_policy
      class RetryOptimizer
        Result = Struct.new(:step_name, :eval_names, :candidate_labels, :score_matrix,
                            :constraining_eval, :chain, :chain_details, keyword_init: true) do
          # Terminology alias — `hardest_eval` is the narrative name used in docs;
          # `constraining_eval` is preserved as the original field name.
          alias_method :hardest_eval, :constraining_eval

          def print_summary(io = $stdout)
            io.puts "#{step_name} — retry chain optimization"
            io.puts
            print_table(io)
            io.puts
            print_chain(io)
            io.puts
            print_dsl(io)
          end

          def to_dsl
            return "# No viable chain — no candidate passes all evals" if chain.empty?

            if chain.all? { |c| c.keys == [:model] }
              models_str = chain.map { |c| c[:model] }.join(" ")
              "retry_policy models: %w[#{models_str}]"
            else
              args = chain.map { |c| config_to_ruby(c) }.join(",\n    ")
              "retry_policy do\n  escalate(\n    #{args}\n  )\nend"
            end
          end

          private

          def print_table(io)
            short_labels = candidate_labels.map { |l| short_candidate_label(l) }
            col_width = [short_labels.map(&:length).max || 0, 8].max
            eval_width = [eval_names.map { |e| e.to_s.length }.max || 0, 12].max

            header = format("  %-#{eval_width}s", "eval") + short_labels.map { |l| format("  %#{col_width}s", l) }.join
            io.puts header
            io.puts "  #{"-" * (eval_width + (col_width + 2) * short_labels.size)}"

            eval_names.each do |eval_name|
              row = format("  %-#{eval_width}s", eval_name.to_s)
              candidate_labels.each do |label|
                score = score_matrix.dig(eval_name, label) || 0.0
                marker = eval_name == constraining_eval && score < 1.0 ? " ←" : "  "
                row += format("  %#{col_width - 2}.2f%s", score, marker)
              end
              io.puts row
            end

            io.puts
            io.puts "  Hardest eval: #{constraining_eval}" if constraining_eval
          end

          def print_chain(io)
            if chain.empty?
              io.puts "  No viable chain."
              return
            end

            io.puts "  Suggested fallback list:"
            chain_details.each_with_index do |detail, i|
              suffix = i == chain_details.size - 1 ? "passes all #{eval_names.size} evals" : "covers #{detail[:passes]} eval(s)"
              io.puts "    #{detail[:label]} — #{suffix}"
            end
          end

          def short_candidate_label(label)
            label
              .sub("gpt-5-", "")
              .sub("gpt-4.1", "4.1")
              .sub(" (effort: ", "@")
              .sub(")", "")
          end

          def print_dsl(io)
            io.puts "  DSL:"
            to_dsl.each_line { |line| io.puts "    #{line}" }
          end

          def config_to_ruby(config)
            pairs = config.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
            "{ #{pairs} }"
          end
        end

        def initialize(step:, candidates:, context: {}, min_score: 0.95, runs: 1, production_mode: nil)
          @step = step
          @candidates = candidates
          @context = context
          @min_score = min_score
          @runs = runs
          @production_mode = production_mode
        end

        def call
          evals = @step.eval_names
          return empty_result(evals) if evals.empty?

          score_matrix = {}
          evals.each do |eval_name|
            comparison = with_retry_disabled do
              @step.compare_models(eval_name, candidates: @candidates, context: @context,
                                              runs: @runs, production_mode: @production_mode)
            end
            score_matrix[eval_name] = extract_scores(comparison)
          end

          labels = score_matrix.values.flat_map(&:keys).uniq
          constraining = find_constraining_eval(score_matrix, labels)
          chain, details = build_chain(score_matrix, labels, evals)

          Result.new(
            step_name: @step.name || @step.to_s,
            eval_names: evals,
            candidate_labels: labels,
            score_matrix: score_matrix,
            constraining_eval: constraining,
            chain: chain,
            chain_details: details
          )
        end

        private

        def extract_scores(comparison)
          comparison.reports.transform_values(&:score)
        end

        def find_constraining_eval(matrix, labels)
          matrix.max_by do |_eval_name, scores|
            cheapest_passing = labels.find { |l| (scores[l] || 0) >= @min_score }
            cheapest_passing ? labels.index(cheapest_passing) : labels.size
          end&.first
        end

        # Retry escalates on validation_failed/parse_error, NOT on low eval
        # score. A model that returns :ok with semantically wrong output won't
        # trigger retry. Therefore the LAST model in the chain must pass ALL
        # evals — it's the safety net. Cheaper models are prepended as
        # first-try optimization (they handle easy inputs cheaply; when they
        # fail validation, retry escalates to the safe fallback).
        #
        # Known limitation: intermediate models are assumed safe if their eval
        # failures correspond to validation failures (retryable). If an
        # intermediate model returns :ok with semantically wrong output on
        # some eval, retry won't fire and the safe fallback won't run. This
        # requires step validates to cover the same semantics as eval verify
        # checks. A future version could inspect per-case step_status from
        # compare_models to verify failures are actually retryable.
        def build_chain(matrix, labels, evals)
          total = evals.size

          # Find cheapest model that passes every eval — the safe fallback.
          safe_fallback = labels.find { |l| evals.all? { |e| (matrix.dig(e, l) || 0) >= @min_score } }
          return [[], []] unless safe_fallback

          # Prepend cheaper models that pass a strict subset.
          chain = []
          details = []
          covered_evals = Set.new

          labels.each do |label|
            break if label == safe_fallback

            newly_covered = evals.select { |e| (matrix.dig(e, label) || 0) >= @min_score }
            new_additions = newly_covered.to_set - covered_evals
            next if new_additions.empty?

            covered_evals.merge(new_additions)
            chain << parse_label_to_config(label)
            details << { label: label, passes: new_additions.size, cost: label }
          end

          # Always end with the safe fallback.
          chain << parse_label_to_config(safe_fallback)
          details << { label: safe_fallback, passes: total, cost: safe_fallback }

          [chain, details]
        end

        def parse_label_to_config(label)
          if label.match?(/\(effort: (\w+)\)/)
            model = label.sub(/\s*\(effort:.*/, "").strip
            effort = label.match(/\(effort: (\w+)\)/)[1]
            { model: model, reasoning_effort: effort }
          else
            { model: label }
          end
        end

        def with_retry_disabled(&block)
          original = @step.retry_policy if @step.respond_to?(:retry_policy)
          @step.define_singleton_method(:retry_policy) { nil }
          block.call
        ensure
          @step.define_singleton_method(:retry_policy) { original }
        end

        def empty_result(evals)
          Result.new(
            step_name: @step.name || @step.to_s,
            eval_names: evals,
            candidate_labels: [],
            score_matrix: {},
            constraining_eval: nil,
            chain: [],
            chain_details: []
          )
        end
      end
    end
  end
end
