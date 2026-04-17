# frozen_string_literal: true

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
            label_width = [candidate_labels.map(&:length).max || 0, 10].max
            header = format("  %-20s", "eval") + candidate_labels.map { |l| format("  %#{label_width}s", l) }.join
            io.puts header
            io.puts "  #{"-" * (20 + (label_width + 2) * candidate_labels.size)}"

            eval_names.each do |eval_name|
              row = format("  %-20s", eval_name.to_s.truncate(20))
              candidate_labels.each do |label|
                score = score_matrix.dig(eval_name, label) || 0.0
                marker = eval_name == constraining_eval && score < 1.0 ? " ←" : "  "
                row += format("  %#{label_width - 2}.2f%s", score, marker)
              end
              io.puts row
            end

            io.puts
            io.puts "  Constraining eval: #{constraining_eval}" if constraining_eval
          end

          def print_chain(io)
            if chain.empty?
              io.puts "  No viable chain."
              return
            end

            io.puts "  Suggested chain:"
            chain_details.each do |detail|
              io.puts "    #{detail[:label]} — passes #{detail[:passes]}/#{eval_names.size} evals (#{detail[:cost]})"
            end
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

        def initialize(step:, candidates:, context: {}, min_score: 0.95)
          @step = step
          @candidates = candidates
          @context = context
          @min_score = min_score
        end

        def call
          evals = @step.eval_names
          return empty_result(evals) if evals.empty?

          score_matrix = {}
          evals.each do |eval_name|
            comparison = with_retry_disabled do
              @step.compare_models(eval_name, candidates: @candidates, context: @context)
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

        def build_chain(matrix, labels, evals)
          total = evals.size
          chain = []
          details = []
          covered = 0

          labels.each do |label|
            passes = evals.count { |e| (matrix.dig(e, label) || 0) >= @min_score }
            next if passes <= covered

            config = parse_label_to_config(label)
            cost_str = matrix.values.filter_map { |scores| scores[label] }.first ? label : "?"
            chain << config
            details << { label: label, passes: passes, cost: cost_str }
            covered = passes
            break if covered >= total
          end

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
