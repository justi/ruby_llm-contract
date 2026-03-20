# frozen_string_literal: true

module RubyLLM
  module Contract
    class Definition
      attr_reader :parse_strategy, :invariants

      def initialize(&block)
        @parse_strategy = :text
        @invariants = []
        instance_eval(&block) if block
        @invariants = @invariants.freeze
        freeze
      end

      def parse(strategy)
        @parse_strategy = strategy
      end

      def invariant(description, &block)
        @invariants << Invariant.new(description, block)
      end
      alias validate invariant

      def self.build(&)
        new(&)
      end

      def self.merge(base, extra_invariants: [], parse_override: nil)
        new do
          parse(parse_override || base.parse_strategy)
          (base.invariants + extra_invariants).each do |inv|
            @invariants << inv
          end
        end
      end
    end
  end
end
