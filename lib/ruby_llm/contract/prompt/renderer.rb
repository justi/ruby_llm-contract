# frozen_string_literal: true

require "json"

module RubyLLM
  module Contract
    module Prompt
      class Renderer
        def render(ast, variables: {})
          ast.each_with_object([]) do |node, messages|
            render_node(node, variables, messages)
          end
        end

        def self.render(ast, variables: {})
          new.render(ast, variables: variables)
        end

        private

        def render_node(node, variables, messages)
          case node
          when Nodes::SystemNode, Nodes::RuleNode
            append_message(messages, :system, node.content, variables)
          when Nodes::ExampleNode
            append_message(messages, :user, node.input, variables)
            append_message(messages, :assistant, node.output, variables)
          when Nodes::UserNode
            append_message(messages, :user, node.content, variables)
          when Nodes::SectionNode
            render_section_node(node, variables, messages)
          end
        end

        def append_message(messages, role, raw_content, variables)
          content = interpolate(raw_content, variables)
          messages << { role: role, content: content } if content_present?(content)
        end

        def render_section_node(node, variables, messages)
          section_content = node.content.is_a?(Hash) || node.content.is_a?(Array) ? node.content.to_json : node.content
          return unless content_present?(section_content)

          safe_name = sanitize_section_name(node.name)
          body = interpolate(section_content, variables)
          messages << { role: :system, content: "[#{safe_name}]\n#{body}" }
        end

        def content_present?(content)
          content.to_s.strip != ""
        end

        def sanitize_section_name(name)
          name.to_s.gsub(/[\[\]\n\r]/, " ").strip
        end

        def interpolate(text, variables)
          return text if text.nil?
          return text.to_json if text.is_a?(Hash) || text.is_a?(Array)

          # Coerce non-String content (Integer, Symbol, etc.) to String before gsub
          text = text.to_s unless text.is_a?(String)

          text.gsub(/\{(\w+)\}/) do |match|
            key = ::Regexp.last_match(1).to_sym
            variables.key?(key) ? serialize_value(variables[key]) : match
          end
        end

        def serialize_value(value)
          value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s
        end
      end
    end
  end
end
