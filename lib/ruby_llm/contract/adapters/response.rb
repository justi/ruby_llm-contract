# frozen_string_literal: true

module RubyLLM
  module Contract
    module Adapters
      # `content` and `usage` are the whole interface an adapter has to fill.
      # The rest is optional accounting: an adapter that leaves `cost` out gets
      # its usage priced from the registry, as before; one that passes `cost`
      # (nil included) owns the figure, and `cost_complete` / `usage_complete`
      # say whether it and the token counts cover the whole call.
      class Response
        include Concerns::DeepFreeze

        attr_reader :content, :usage, :usage_complete, :cost_complete, :finish_reason

        def initialize(content:, usage: {}, cost: Step::Trace::COST_UNSET, usage_complete: nil,
                       cost_complete: nil, finish_reason: nil)
          @content = deep_dup_freeze(content)
          @usage = deep_dup_freeze(usage)
          @cost = cost
          @usage_complete = usage_complete
          @cost_complete = cost_complete
          @finish_reason = finish_reason
          freeze
        end

        def cost
          cost_provided? ? @cost : nil
        end

        def cost_provided?
          !@cost.equal?(Step::Trace::COST_UNSET)
        end

        # Keyword arguments for Step::Trace.new. Omits what the adapter did not
        # report, so a plain Response keeps the registry pricing path.
        def trace_accounting
          fields = { usage_complete: @usage_complete, cost_complete: @cost_complete,
                     finish_reason: @finish_reason }.compact
          cost_provided? ? fields.merge(cost: @cost) : fields
        end
      end
    end
  end
end
