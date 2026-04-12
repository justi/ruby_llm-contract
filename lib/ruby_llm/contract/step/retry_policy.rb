# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class RetryPolicy
        attr_reader :max_attempts, :retryable_statuses

        DEFAULT_RETRY_ON = %i[validation_failed parse_error adapter_error].freeze

        def initialize(models: nil, attempts: nil, retry_on: nil, &block)
          @configs = []
          @retryable_statuses = DEFAULT_RETRY_ON.dup

          if block
            @max_attempts = 1
            instance_eval(&block)
            warn_no_retry! if @max_attempts == 1 && @configs.empty?
          else
            apply_keywords(models: models, attempts: attempts, retry_on: retry_on)
          end

          validate_max_attempts!
        end

        def attempts(count)
          @max_attempts = count
          validate_max_attempts!
        end

        def escalate(*config_list)
          @configs = config_list.flatten.map { |c| normalize_config(c).freeze }.freeze
          @max_attempts = @configs.length if @max_attempts < @configs.length
        end
        alias models escalate

        def model_list
          @configs.map { |c| c[:model] }.freeze
        end

        def config_list
          @configs
        end

        def retry_on(*statuses)
          @retryable_statuses = statuses.flatten
        end

        def retryable?(result)
          retryable_statuses.include?(result.status)
        end

        def config_for_attempt(attempt, default_config)
          if @configs.any?
            @configs[attempt] || @configs.last
          else
            default_config
          end
        end

        def model_for_attempt(attempt, default_model)
          config_for_attempt(attempt, { model: default_model })[:model]
        end

        private

        def apply_keywords(models:, attempts:, retry_on:)
          if models
            @configs = Array(models).map { |m| normalize_config(m).freeze }.freeze
            @max_attempts = @configs.length
          else
            @max_attempts = attempts || 1
          end
          @retryable_statuses = Array(retry_on).dup if retry_on
        end

        def normalize_config(entry)
          RubyLLM::Contract.normalize_candidate_config(entry)
        end

        def warn_no_retry!
          warn "[ruby_llm-contract] retry_policy has max_attempts=1 with no configs. " \
               "This means no actual retry will happen. Add `attempts 2` or " \
               '`escalate "model1", "model2"`.'
        end

        def validate_max_attempts!
          return if @max_attempts.is_a?(Integer) && @max_attempts >= 1

          raise ArgumentError, "attempts must be at least 1, got #{@max_attempts.inspect}"
        end
      end
    end
  end
end
