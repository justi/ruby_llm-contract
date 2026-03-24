# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      class Dataset
        attr_reader :name, :cases

        def initialize(name = "unnamed", &block)
          @name = name
          @cases = []
          instance_eval(&block) if block
        end

        def self.define(name = "unnamed", &)
          new(name, &)
        end

        private

        # DSL: define a test case
        # dataset.case "name", input: {...}, expected: {...}
        # dataset.case "name", input: {...}, expected_traits: {...}
        # dataset.case "name", input: {...}, evaluator: proc
        def add_case(name = nil, input:, expected: nil, expected_traits: nil, evaluator: nil, step_expectations: nil)
          case_name = name || "case_#{@cases.length + 1}"
          if @cases.any? { |c| c.name == case_name }
            raise ArgumentError, "Duplicate case name '#{case_name}'. Case names must be unique within a dataset."
          end

          @cases << Case.new(
            name: case_name,
            input: input,
            expected: expected,
            expected_traits: expected_traits,
            evaluator: evaluator,
            step_expectations: step_expectations
          )
        end

        # Allow using `add_case` in DSL
        public :add_case
      end

      class Case
        include Concerns::DeepFreeze

        attr_reader :name, :input, :expected, :expected_traits, :evaluator, :step_expectations

        def initialize(name:, input:, expected: nil, expected_traits: nil, evaluator: nil, step_expectations: nil)
          @name = name
          @input = deep_dup_freeze(input)
          @expected = deep_dup_freeze(expected)
          @expected_traits = deep_dup_freeze(expected_traits)
          @evaluator = evaluator
          @step_expectations = deep_dup_freeze(step_expectations)
          freeze
        end
      end
    end
  end
end
