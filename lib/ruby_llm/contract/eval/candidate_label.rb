# frozen_string_literal: true

module RubyLLM
  module Contract
    module Eval
      # The `model (effort: x)` notation, rendered into optimizer tables and parsed
      # back to rebuild candidate configs. Render and parse live together because a
      # format change on one side silently mis-parses on the other: the pattern is
      # built from the same literal the renderer emits.
      module CandidateLabel
        OPEN = " (effort: "
        CLOSE = ")"
        PATTERN = /\s*#{Regexp.escape(OPEN.lstrip)}(\w+)#{Regexp.escape(CLOSE)}/

        def self.render(config)
          effort = config[:reasoning_effort]
          return config[:model] unless effort

          "#{config[:model]}#{OPEN}#{effort}#{CLOSE}"
        end

        def self.parse(label)
          match = PATTERN.match(label)
          return { model: label } unless match

          { model: match.pre_match.strip, reasoning_effort: RubyLLM::Contract.normalize_effort(match[1]) }
        end
      end
    end
  end
end
