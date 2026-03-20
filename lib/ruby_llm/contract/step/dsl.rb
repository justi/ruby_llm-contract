# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      # Extracted from Base to reduce class length.
      # DSL accessor methods for step definition (input_type, output_type, prompt, etc.).
      module Dsl
        def input_type(type = nil)
          return @input_type = type if type

          @input_type || String
        end

        def output_type(type = nil)
          return @output_type = type if type
          return @output_type if @output_type
          return RubyLLM::Contract::Types::Hash if @output_schema

          Hash
        end

        def output_schema(&block)
          if block
            require "ruby_llm/schema"
            @output_schema = ::RubyLLM::Schema.create(&block)
          else
            @output_schema
          end
        end

        def prompt(text = nil, &block)
          if text
            @prompt_block = proc { user text }
          elsif block
            @prompt_block = block
          else
            @prompt_block || raise(ArgumentError, "prompt has not been set")
          end
        end

        def contract(&block)
          return @contract_definition = Definition.new(&block) if block

          @contract_definition || Definition.new
        end

        def validate(description, &block)
          (@class_validates ||= []) << Invariant.new(description, block)
        end

        def max_output(tokens = nil)
          return @max_output = tokens if tokens

          @max_output
        end

        def max_input(tokens = nil)
          return @max_input = tokens if tokens

          @max_input
        end

        def max_cost(amount = nil)
          return @max_cost = amount if amount

          @max_cost
        end

        def retry_policy(models: nil, attempts: nil, retry_on: nil, &block)
          if block || models || attempts
            return @retry_policy = RetryPolicy.new(models: models, attempts: attempts, retry_on: retry_on, &block)
          end

          @retry_policy
        end
      end
    end
  end
end
