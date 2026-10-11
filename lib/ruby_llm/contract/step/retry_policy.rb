# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class RetryPolicy
        attr_reader :max_attempts, :retryable_statuses, :retryable_errors

        # Breaking (0.7.0): :adapter_error removed from defaults. ruby_llm's Faraday
        # middleware already retries transport errors (RateLimitError, ServerError,
        # ServiceUnavailableError, OverloadedError, timeouts). Retrying on
        # :adapter_error against the same model re-runs what transport already did.
        # Opt in explicitly with `retry_on :adapter_error` — only meaningful paired
        # with `escalate "model_a", "model_b"` (a different model may bypass what
        # transport retry could not).
        DEFAULT_RETRY_ON = %i[validation_failed parse_error].freeze

        # Internal, not a documented override value: keeps a Step's own policy
        # unless it picks models, so compare_models runs a candidate on its
        # own model with the same-model retries the Step would give it.
        WITHOUT_MODEL_CHAIN = :without_model_chain

        def initialize(models: nil, attempts: nil, retry_on: nil, &block)
          @configs = []
          @retryable_statuses = DEFAULT_RETRY_ON.dup
          @retryable_errors = []

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

        # Statuses, and exception classes for adapter errors:
        # `retry_on :validation_failed, RubyLLM::RateLimitError` retries an
        # adapter error only when it was a RateLimitError (or a subclass), while
        # `:adapter_error` retries any. Replaces the defaults, as before.
        def retry_on(*conditions)
          @retryable_statuses, @retryable_errors = split_conditions(conditions.flatten)
        end

        def retryable?(result)
          return true if retryable_statuses.include?(result.status)
          return false unless result.status == :adapter_error && retryable_errors.any?

          error_type = result.trace.respond_to?(:error_type) ? result.trace.error_type : nil
          !error_type.nil? && retryable_errors.any? { |klass| error_type <= klass }
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
          @retryable_statuses, @retryable_errors = split_conditions(Array(retry_on)) if retry_on
        end

        # Symbols are statuses; exception classes match adapter errors. Anything
        # else (a String status among them) would never match, so it raises
        # instead of quietly turning retries off.
        def split_conditions(conditions)
          invalid = conditions.reject { |condition| condition.is_a?(Symbol) || exception_class?(condition) }
          unless invalid.empty?
            raise ArgumentError,
                  "retry_on takes status symbols and exception classes, got #{invalid.map(&:inspect).join(", ")}"
          end

          conditions.partition { |condition| condition.is_a?(Symbol) }
        end

        def exception_class?(condition)
          condition.is_a?(Class) && condition <= Exception
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
