# frozen_string_literal: true

module RubyLLM
  module Contract
    module Pipeline
      class Base
        def self.inherited(subclass)
          super
          Contract.register_eval_host(subclass) if respond_to?(:eval_defined?) && eval_defined?
        end

        class << self
          include Concerns::EvalHost

          # depends_on is accepted for forward compatibility with DAG pipelines (v0.3).
          # Currently, execution is always linear in declaration order.
          def step(step_class, as:, depends_on: nil, model: nil)
            validate_dependency!(depends_on) if depends_on
            steps_registry << { step_class: step_class, alias: as, depends_on: depends_on, model: model }
          end

          def steps
            steps_registry.map { |s| s.dup.freeze }.freeze
          end

          # Internal mutable steps list for registration
          def steps_registry
            @steps_registry ||= begin
              inherited_steps =
                if superclass.respond_to?(:steps_registry, true)
                  superclass.send(:steps_registry).map(&:dup)
                else
                  []
                end

              inherited_steps
            end
          end

          def token_budget(limit = nil)
            if limit
              raise ArgumentError, "token_budget must be positive, got #{limit}" unless limit.positive?

              return @token_budget = limit
            end

            @token_budget
          end

          def run(input, context: {}, timeout_ms: nil)
            Runner.new(steps: steps, context: context, timeout_ms: timeout_ms, token_budget: token_budget).call(input)
          end

          def test(input, responses: {}, timeout_ms: nil)
            ordered_responses = steps.map { |step_entry| responses.fetch(step_entry[:alias], "") }
            adapter = Adapters::Test.new(responses: ordered_responses)
            run(input, context: { adapter: adapter }, timeout_ms: timeout_ms)
          end

          private

          def known_step_aliases
            steps_registry.map { |step_entry| step_entry[:alias] }
          end

          def validate_dependency!(dep)
            return if known_step_aliases.include?(dep)

            raise ArgumentError, "Unknown dependency: #{dep.inspect}. Known steps: #{known_step_aliases.inspect}"
          end
        end
      end
    end
  end
end
