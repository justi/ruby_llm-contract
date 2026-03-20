# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class RetryPolicy
        attr_reader :max_attempts, :retryable_statuses

        DEFAULT_RETRY_ON = %i[validation_failed parse_error adapter_error].freeze

        def initialize(models: nil, attempts: nil, retry_on: nil, &block)
          @models = []
          @retryable_statuses = DEFAULT_RETRY_ON.dup

          if block
            @max_attempts = 1
            instance_eval(&block)
          else
            apply_keywords(models: models, attempts: attempts, retry_on: retry_on)
          end

          validate_max_attempts!
        end

        def attempts(count)
          @max_attempts = count
          validate_max_attempts!
        end

        def escalate(*model_list)
          @models = model_list.flatten
          @max_attempts = @models.length if @max_attempts < @models.length
        end
        alias models escalate

        def model_list
          @models
        end

        def retry_on(*statuses)
          @retryable_statuses = statuses
        end

        def retryable?(result)
          retryable_statuses.include?(result.status)
        end

        def model_for_attempt(attempt, default_model)
          if @models.any?
            @models[attempt] || @models.last
          else
            default_model
          end
        end

        private

        def apply_keywords(models:, attempts:, retry_on:)
          if models
            @models = Array(models).dup.freeze
            @max_attempts = @models.length
          else
            @max_attempts = attempts || 1
          end
          @retryable_statuses = Array(retry_on).dup if retry_on
        end

        def validate_max_attempts!
          return if @max_attempts.is_a?(Integer) && @max_attempts >= 1

          raise ArgumentError, "attempts must be at least 1, got #{@max_attempts.inspect}"
        end
      end
    end
  end
end
