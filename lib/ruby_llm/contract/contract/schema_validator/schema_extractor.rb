# frozen_string_literal: true

module RubyLLM
  module Contract
    class SchemaValidator
      class SchemaExtractor
        include Concerns::DeepSymbolize

        def call(schema)
          schema_payload = schema.is_a?(Class) ? schema.new : schema
          raw_schema = if schema_payload.respond_to?(:to_json_schema)
                         json_schema = schema_payload.to_json_schema
                         json_schema[:schema] || json_schema["schema"] || json_schema
                       else
                         schema
                       end

          deep_symbolize(raw_schema)
        end
      end
    end
  end
end
