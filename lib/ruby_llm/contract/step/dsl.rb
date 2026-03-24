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

        def max_cost(amount = nil, on_unknown_pricing: nil)
          if amount == :default
            @max_cost = nil
            @max_cost_explicitly_unset = true
            @on_unknown_pricing = nil
            return nil
          end

          if amount
            unless amount.is_a?(Numeric) && amount.positive?
              raise ArgumentError, "max_cost must be positive, got #{amount}"
            end

            if on_unknown_pricing && !%i[refuse warn].include?(on_unknown_pricing)
              raise ArgumentError, "on_unknown_pricing must be :refuse or :warn, got #{on_unknown_pricing.inspect}"
            end

            @max_cost_explicitly_unset = false
            @max_cost = amount
            @on_unknown_pricing = on_unknown_pricing || :refuse
            return @max_cost
          end

          return @max_cost if defined?(@max_cost) && !@max_cost_explicitly_unset
          return nil if @max_cost_explicitly_unset

          superclass.max_cost if superclass.respond_to?(:max_cost)
        end

        def on_unknown_pricing
          if defined?(@on_unknown_pricing)
            @on_unknown_pricing
          elsif superclass.respond_to?(:on_unknown_pricing)
            superclass.on_unknown_pricing
          else
            :refuse
          end
        end

        def model(name = nil)
          if name == :default
            @model = nil
            @model_explicitly_unset = true
            return nil
          end

          if name
            @model_explicitly_unset = false
            return @model = name
          end

          return @model if defined?(@model) && !@model_explicitly_unset
          return nil if @model_explicitly_unset

          superclass.model if superclass.respond_to?(:model)
        end

        def temperature(value = nil)
          if value == :default
            @temperature = nil
            @temperature_explicitly_unset = true
            return nil
          end

          if value
            unless value.is_a?(Numeric) && value >= 0 && value <= 2
              raise ArgumentError, "temperature must be 0.0-2.0, got #{value}"
            end

            @temperature_explicitly_unset = false
            return @temperature = value
          end

          return @temperature if defined?(@temperature) && !@temperature_explicitly_unset
          return nil if @temperature_explicitly_unset

          superclass.temperature if superclass.respond_to?(:temperature)
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
          if block || models || attempts || retry_on
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
