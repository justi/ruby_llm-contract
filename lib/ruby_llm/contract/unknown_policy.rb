# frozen_string_literal: true

module RubyLLM
  module Contract
    # What a limit does when the number it needs is unknown: model pricing for
    # max_cost/maximum_cost, attachment size for max_input. One vocabulary for
    # every such option, step-level and eval-level, so a new mode or a changed
    # default reaches all of them. Standalone: the rake task loads it before the
    # rest of the gem to validate its settings at definition time.
    module UnknownPolicy
      MODES = %i[refuse warn].freeze
      DEFAULT = :refuse

      def self.validate!(option, mode)
        return mode if MODES.include?(mode)

        raise ArgumentError, "#{option} must be #{MODES.map(&:inspect).join(" or ")}, got #{mode.inspect}"
      end
    end
  end
end
