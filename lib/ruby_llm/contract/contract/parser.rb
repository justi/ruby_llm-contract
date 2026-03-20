# frozen_string_literal: true

require "json"

module RubyLLM
  module Contract
    class Parser
      extend Concerns::DeepSymbolize

      def self.symbolize_keys(obj)
        deep_symbolize(obj)
      end

      def self.parse(raw_output, strategy:)
        case strategy
        when :json then parse_json(raw_output)
        when :text then raw_output
        else raise ArgumentError, "Unknown parse strategy: #{strategy}"
        end
      end

      def self.parse_json(raw_output)
        return deep_symbolize(raw_output) if raw_output.is_a?(Hash) || raw_output.is_a?(Array)

        # Coerce non-String scalars (boolean, numeric) to their JSON representation
        # to prevent TypeError from JSON.parse on non-string input.
        coerced = raw_output.is_a?(String) ? raw_output : raw_output&.to_s
        text = strip_code_fences(strip_bom(coerced))
        raise RubyLLM::Contract::ParseError.new("Failed to parse JSON: nil content", details: raw_output) if text.nil?

        parse_json_text(text, raw_output)
      end

      def self.parse_json_text(text, raw_output)
        JSON.parse(text, symbolize_names: true)
      rescue JSON::ParserError
        parse_json_with_extraction(text, raw_output)
      end
      private_class_method :parse_json_text

      # Fallback: attempt to extract the first JSON object or array from prose
      def self.parse_json_with_extraction(text, raw_output)
        extracted = extract_json(text)
        unless extracted
          raise RubyLLM::Contract::ParseError.new(
            "Failed to parse JSON: no valid JSON found in output", details: raw_output
          )
        end

        JSON.parse(extracted, symbolize_names: true)
      rescue JSON::ParserError => e
        raise RubyLLM::Contract::ParseError.new("Failed to parse JSON: #{e.message}", details: raw_output)
      end
      private_class_method :parse_json_with_extraction

      # Strip UTF-8 BOM (Byte Order Mark) that some LLMs/APIs prepend to output
      UTF8_BOM = "\xEF\xBB\xBF"
      def self.strip_bom(text)
        return text unless text.is_a?(String)

        text.delete_prefix(UTF8_BOM)
      end

      # Strip markdown code fences that LLMs commonly wrap around JSON output
      # Handles ```json ... ```, ``` ... ```, with optional trailing whitespace
      CODE_FENCE_PATTERN = /\A\s*```(?:json|JSON)?\s*\n(.*?)\n\s*```\s*\z/m

      def self.strip_code_fences(text)
        return text unless text.is_a?(String)

        match = text.match(CODE_FENCE_PATTERN)
        match ? match[1] : text
      end

      # Extract the first JSON object or array from text that may contain prose.
      # Uses bracket-matching to find the outermost balanced { } or [ ] block.
      JSON_START_PATTERN = /[{\[]/

      def self.extract_json(text)
        return nil unless text.is_a?(String)

        start_idx = text.index(JSON_START_PATTERN)
        return nil unless start_idx

        scan_for_balanced_json(text, start_idx)
      end

      def self.scan_for_balanced_json(text, start_idx)
        opening = text[start_idx]
        closing = opening == "{" ? "}" : "]"
        state = { depth: 0, in_string: false, escape_next: false }

        (start_idx...text.length).each do |pos|
          result = process_json_char(text[pos], opening, closing, state)
          return text[start_idx..pos] if result == :matched
        end

        nil
      end
      private_class_method :scan_for_balanced_json

      def self.process_json_char(char, opening, closing, state)
        if state[:escape_next]
          state[:escape_next] = false
          return nil
        end

        return handle_backslash(state) if char == "\\"
        return handle_quote(state) if char == '"'
        return nil if state[:in_string]

        handle_bracket(char, opening, closing, state)
      end
      private_class_method :process_json_char

      def self.handle_backslash(state)
        state[:escape_next] = true if state[:in_string]
        nil
      end
      private_class_method :handle_backslash

      def self.handle_quote(state)
        state[:in_string] = !state[:in_string]
        nil
      end
      private_class_method :handle_quote

      def self.handle_bracket(char, opening, closing, state)
        return adjust_depth(state, 1) if char == opening
        return adjust_depth(state, -1) if char == closing

        nil
      end
      private_class_method :handle_bracket

      def self.adjust_depth(state, delta)
        state[:depth] += delta
        state[:depth].zero? ? :matched : nil
      end
      private_class_method :adjust_depth
    end
  end
end
