# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class InputValidator
        def initialize(input_type:)
          @input_type = input_type
        end

        def call(input)
          validate(input)
          nil
        rescue Dry::Types::CoercionError, TypeError, ArgumentError => error
          Result.new(status: :input_error, raw_output: nil, parsed_output: nil, validation_errors: [error.message])
        end

        private

        def validate(input)
          if ruby_class_input?
            raise TypeError, "#{input.inspect} is not a #{@input_type}" unless input.is_a?(@input_type)
          else
            @input_type[input]
          end
        end

        def ruby_class_input?
          @input_type.is_a?(Class) && !@input_type.respond_to?(:[])
        end
      end
    end
  end
end
