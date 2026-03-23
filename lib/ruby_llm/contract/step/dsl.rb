# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      # Extracted from Base to reduce class length.
      # DSL accessor methods for step definition (input_type, output_type, prompt, etc.).
      module Dsl # rubocop:disable Metrics/ModuleLength
        def input_type(type = nil)
          return @input_type = type if type

          if defined?(@input_type)
            @input_type
          elsif superclass.respond_to?(:input_type)
            superclass.input_type
          else
            String
          end
        end

        def output_type(type = nil)
          return @output_type = type if type

          if defined?(@output_type)
            @output_type
          elsif defined?(@output_schema) && @output_schema
            RubyLLM::Contract::Types::Hash
          elsif superclass.respond_to?(:output_type)
            superclass.output_type
          else
            Hash
          end
        end

        def output_schema(&block)
          if block
            require "ruby_llm/schema"
            @output_schema = ::RubyLLM::Schema.create(&block)
          elsif defined?(@output_schema)
            @output_schema
          elsif superclass.respond_to?(:output_schema)
            superclass.output_schema
          end
        end

        def prompt(text = nil, &block)
          if text
            @prompt_block = proc { user text }
          elsif block
            @prompt_block = block
          elsif defined?(@prompt_block) && @prompt_block
            @prompt_block
          elsif superclass.respond_to?(:prompt)
            superclass.prompt
          else
            raise(ArgumentError, "prompt has not been set")
          end
        end

        def contract(&block)
          return @contract_definition = Definition.new(&block) if block

          if defined?(@contract_definition) && @contract_definition
            @contract_definition
          elsif superclass.respond_to?(:contract)
            superclass.contract
          else
            Definition.new
          end
        end

        def validate(description, &block)
          (@class_validates ||= []) << Invariant.new(description, block)
        end

        def class_validates
          own = defined?(@class_validates) ? @class_validates : []
          inherited = superclass.respond_to?(:class_validates) ? superclass.class_validates : []
          inherited + own
        end

        def max_output(tokens = nil)
          if tokens
            unless tokens.is_a?(Numeric) && tokens.positive?
              raise ArgumentError, "max_output must be positive, got #{tokens}"
            end

            return @max_output = tokens
          end

          if defined?(@max_output)
            @max_output
          elsif superclass.respond_to?(:max_output)
            superclass.max_output
          end
        end

        def max_input(tokens = nil)
          if tokens
            unless tokens.is_a?(Numeric) && tokens.positive?
              raise ArgumentError, "max_input must be positive, got #{tokens}"
            end

            return @max_input = tokens
          end

          if defined?(@max_input)
            @max_input
          elsif superclass.respond_to?(:max_input)
            superclass.max_input
          end
        end

        def max_cost(amount = nil)
          if amount
            unless amount.is_a?(Numeric) && amount.positive?
              raise ArgumentError, "max_cost must be positive, got #{amount}"
            end

            return @max_cost = amount
          end

          if defined?(@max_cost)
            @max_cost
          elsif superclass.respond_to?(:max_cost)
            superclass.max_cost
          end
        end

        def temperature(value = nil)
          if value
            unless value.is_a?(Numeric) && value >= 0 && value <= 2
              raise ArgumentError, "temperature must be 0.0-2.0, got #{value}"
            end

            return @temperature = value
          end

          if defined?(@temperature)
            @temperature
          elsif superclass.respond_to?(:temperature)
            superclass.temperature
          end
        end

        def around_call(&block)
          if block
            return @around_call = block
          end

          if defined?(@around_call) && @around_call
            @around_call
          elsif superclass.respond_to?(:around_call)
            superclass.around_call
          end
        end

        def retry_policy(models: nil, attempts: nil, retry_on: nil, &block)
          if block || models || attempts
            return @retry_policy = RetryPolicy.new(models: models, attempts: attempts, retry_on: retry_on, &block)
          end

          if defined?(@retry_policy) && @retry_policy
            @retry_policy
          elsif superclass.respond_to?(:retry_policy)
            superclass.retry_policy
          end
        end
      end
    end
  end
end
