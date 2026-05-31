# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      # Extracted from Base to reduce class length.
      # DSL accessor methods for step definition (input_type, output_type, prompt, etc.).
      module Dsl # rubocop:disable Metrics/ModuleLength
        # Sentinel signalling "explicitly reset" (`some_attr(:default)`).
        # Distinguishes reset (lookup stops at this class, returns nil) from
        # "never set" (lookup falls through to superclass).
        UNSET = Object.new
        def UNSET.inspect = "Step::Dsl::UNSET"
        UNSET.freeze

        # Walks the inheritance chain for a class-level DSL attribute.
        # Returns the first explicitly-set value found, or nil.
        def inherited_value(name)
          ivar = :"@#{name}"
          return instance_variable_get(ivar) if instance_variable_defined?(ivar)

          superclass.public_send(name) if superclass.respond_to?(name)
        end

        # Like `inherited_value`, but honours the `UNSET` sentinel — when this
        # class has been reset via `some_attr(:default)`, returns nil without
        # falling through to the superclass.
        def inherited_value_with_reset(name)
          ivar = :"@#{name}"
          if instance_variable_defined?(ivar)
            value = instance_variable_get(ivar)
            return value unless value.equal?(UNSET)

            return nil
          end

          superclass.public_send(name) if superclass.respond_to?(name)
        end

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

        def observe(description, &block)
          (@class_observers ||= []) << Invariant.new(description, block)
        end

        def class_observers
          own = defined?(@class_observers) ? @class_observers : []
          inherited = superclass.respond_to?(:class_observers) ? superclass.class_observers : []
          inherited + own
        end

        def max_output(tokens = nil)
          if tokens
            validate_positive!("max_output", tokens)
            return @max_output = tokens
          end

          inherited_value(:max_output)
        end

        def max_input(tokens = nil)
          if tokens
            validate_positive!("max_input", tokens)
            return @max_input = tokens
          end

          inherited_value(:max_input)
        end

        def max_cost(amount = nil, on_unknown_pricing: nil)
          if amount == :default
            @max_cost = UNSET
            @on_unknown_pricing = nil
            return nil
          end

          if amount
            validate_positive!("max_cost", amount)

            if on_unknown_pricing && !%i[refuse warn].include?(on_unknown_pricing)
              raise ArgumentError, "on_unknown_pricing must be :refuse or :warn, got #{on_unknown_pricing.inspect}"
            end

            @max_cost = amount
            @on_unknown_pricing = on_unknown_pricing || :refuse
            return @max_cost
          end

          inherited_value_with_reset(:max_cost)
        end

        def on_unknown_pricing
          inherited_value(:on_unknown_pricing) || :refuse
        end

        def attachment_token_estimate(n = nil)
          if n == :default
            @attachment_token_estimate = UNSET
            return nil
          end

          if n
            validate_positive!("attachment_token_estimate", n)
            return @attachment_token_estimate = n
          end

          inherited_value_with_reset(:attachment_token_estimate)
        end

        def on_unknown_attachment_size(mode = nil)
          if mode
            unless %i[refuse warn].include?(mode)
              raise ArgumentError,
                    "on_unknown_attachment_size must be :refuse or :warn, got #{mode.inspect}"
            end

            return @on_unknown_attachment_size = mode
          end

          inherited_value(:on_unknown_attachment_size) || :refuse
        end

        def model(name = nil)
          if name == :default
            @model = UNSET
            return nil
          end

          return @model = name if name

          inherited_value_with_reset(:model)
        end

        def temperature(value = nil)
          if value == :default
            @temperature = UNSET
            return nil
          end

          # NOTE: `value` may be 0 (a legitimate setting); use `nil?` rather
          # than truthiness to distinguish "no arg passed" from "explicit 0".
          unless value.nil?
            unless value.is_a?(Numeric) && value >= 0 && value <= 2
              raise ArgumentError, "temperature must be 0.0-2.0, got #{value}"
            end

            return @temperature = value
          end

          inherited_value_with_reset(:temperature)
        end

        def thinking(effort: nil, budget: nil)
          if effort == :default
            @thinking = UNSET
            return nil
          end

          return @thinking = { effort: effort, budget: budget }.compact if effort || budget

          inherited_value_with_reset(:thinking)
        end

        def reasoning_effort(value = nil)
          return (thinking && thinking[:effort]) if value.nil?

          # Alias is scoped to the effort dimension only. `:default` on the
          # alias clears effort but PRESERVES any previously-set budget — the
          # name does not suggest "wipe the whole thinking config." Use the
          # full `thinking(effort: :default)` to clear everything.
          if value == :default
            current_budget = thinking && thinking[:budget]
            if current_budget
              @thinking = { budget: current_budget }
              return nil
            end
            return thinking(effort: :default)
          end

          thinking(effort: value)
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

        private

        # Shared positivity guard for `max_input`, `max_output`, `max_cost`,
        # `attachment_token_estimate`. Mirrors `CostCalculator.validate_price!`.
        def validate_positive!(name, value)
          return if value.is_a?(Numeric) && value.positive?

          raise ArgumentError, "#{name} must be positive, got #{value}"
        end
      end
    end
  end
end
