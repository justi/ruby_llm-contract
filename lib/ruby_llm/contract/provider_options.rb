# frozen_string_literal: true

module RubyLLM
  module Contract
    # Options in the provider's own request vocabulary, passed to
    # `chat.with_provider_options` and merged into the request as-is. Keys the
    # contract itself sets are refused: an override would make the call differ
    # from what max_cost, max_output and the schema were checked against.
    # Only top-level keys are checked; a provider that nests these settings
    # (Gemini's generationConfig, for one) is not.
    module ProviderOptions
      RESERVED_KEYS = %w[model messages input instructions system temperature stream
                         max_tokens max_output_tokens max_completion_tokens].freeze
      # Where OpenAI's protocols put the structured-output schema.
      SCHEMA_KEYS = %w[response_format text].freeze

      def self.validate!(options, schema: false)
        raise ArgumentError, "provider_options must be a Hash, got #{options.class}" unless options.is_a?(Hash)

        reserved = schema ? RESERVED_KEYS + SCHEMA_KEYS : RESERVED_KEYS
        clashes = options.keys.map(&:to_s) & reserved
        return options if clashes.empty?

        raise ArgumentError, "provider_options cannot set #{clashes.join(", ")}: the step sets " \
                             "#{clashes.one? ? "it" : "them"} (use the step DSL or context instead)"
      end

      # A frozen deep copy, so a hash the caller keeps mutating cannot change
      # a step definition shared across threads.
      def self.frozen_copy(object)
        case object
        when Hash then object.to_h { |key, value| [key, frozen_copy(value)] }.freeze
        when Array then object.map { |value| frozen_copy(value) }.freeze
        else object.frozen? ? object : object.dup.freeze
        end
      end

      # Context keys win over the class-level ones; nil when nothing is set.
      def self.merge(class_level, context_level)
        merged = (class_level || {}).merge(context_level || {})
        merged.empty? ? nil : merged
      end
    end
  end
end
