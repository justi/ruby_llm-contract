# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class RetryPolicy
        attr_reader :max_attempts, :retryable_statuses

        DEFAULT_RETRY_ON = %i[validation_failed parse_error adapter_error].freeze

        ADAPTER_ERROR_DEPRECATION_MESSAGE = "#{<<~MSG.tr("\n", " ").strip}\n".freeze
          [ruby_llm-contract] DEPRECATION: :adapter_error will be removed from
          DEFAULT_RETRY_ON in 0.7.0. Without a model escalation chain this retries
          the same model on transport errors that ruby_llm's Faraday middleware
          already retried with backoff.
          Keep current behavior: `retry_on :validation_failed, :parse_error, :adapter_error`.
          Adopt new default: `retry_on :validation_failed, :parse_error`.
          Use :adapter_error with `escalate "model_a", "model_b"` for meaningful fallback.
        MSG

        @adapter_error_default_warned = false
        @deprecation_mutex = Mutex.new

        class << self
          # Emitted once per process to avoid stderr noise from inherited Step
          # classes, Rails reload cycles, or CI configurations that fail on
          # stderr. Tests may reset this flag via #reset_deprecation_warnings!.
          # Thread-safety: check-then-set is guarded by @deprecation_mutex so
          # concurrent RetryPolicy.new calls (e.g. production_mode eval
          # candidates) cannot race past the flag.
          attr_accessor :adapter_error_default_warned
          attr_reader :deprecation_mutex

          def reset_deprecation_warnings!
            @deprecation_mutex.synchronize { @adapter_error_default_warned = false }
          end
        end

        def initialize(models: nil, attempts: nil, retry_on: nil, &block)
          @configs = []
          @retryable_statuses = DEFAULT_RETRY_ON.dup
          @retry_on_explicit = false

          if block
            @max_attempts = 1
            instance_eval(&block)
            warn_no_retry! if @max_attempts == 1 && @configs.empty?
          else
            apply_keywords(models: models, attempts: attempts, retry_on: retry_on)
          end

          validate_max_attempts!
          warn_adapter_error_default_deprecated!
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
          @retry_on_explicit = true
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
          return unless retry_on

          @retryable_statuses = Array(retry_on).dup
          @retry_on_explicit = true
        end

        def normalize_config(entry)
          RubyLLM::Contract.normalize_candidate_config(entry)
        end

        def warn_no_retry!
          warn "[ruby_llm-contract] retry_policy has max_attempts=1 with no configs. " \
               "This means no actual retry will happen. Add `attempts 2` or " \
               '`escalate "model1", "model2"`.'
        end

        def warn_adapter_error_default_deprecated!
          return unless should_warn_adapter_error_default?
          return if self.class.adapter_error_default_warned

          self.class.deprecation_mutex.synchronize do
            return if self.class.adapter_error_default_warned

            self.class.adapter_error_default_warned = true
            Warning.warn(ADAPTER_ERROR_DEPRECATION_MESSAGE)
          end
        end

        def should_warn_adapter_error_default?
          return false if @retry_on_explicit
          return false if @max_attempts <= 1
          return false if @configs.size >= 2

          @retryable_statuses.include?(:adapter_error)
        end

        def validate_max_attempts!
          return if @max_attempts.is_a?(Integer) && @max_attempts >= 1

          raise ArgumentError, "attempts must be at least 1, got #{@max_attempts.inspect}"
        end
      end
    end
  end
end
