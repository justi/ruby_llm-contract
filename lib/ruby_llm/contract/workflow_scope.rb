# frozen_string_literal: true

module RubyLLM
  module Contract
    # Groups a step's or pipeline's RubyLLM calls under `RubyLLM.workflow`, so
    # OpenTelemetry spans and instrumentation events carry the step's name.
    # Off unless `RubyLLM::Contract.configure { |c| c.workflow_instrumentation = true }`.
    #
    # A pipeline opens one workflow and runs each step as `workflow.step(alias)`;
    # a step run inside it does not open another. A step run on its own opens a
    # workflow named after its class. A workflow the application opened itself
    # becomes the parent, as RubyLLM links nested workflows.
    module WorkflowScope
      CURRENT_KEY = :ruby_llm_contract_workflow

      def self.workflow(name, &block)
        return yield unless enabled? && current.nil?

        ::RubyLLM.workflow(name.to_s) { |workflow| within(workflow, &block) }
      end

      def self.step(name, &)
        workflow = current
        return yield unless enabled? && workflow

        workflow.step(name.to_s, &)
      end

      def self.enabled?
        Contract.configuration.workflow_instrumentation
      end

      # Fiber-local, so concurrent eval threads each get their own.
      def self.current
        Thread.current[CURRENT_KEY]
      end

      def self.within(workflow)
        previous = Thread.current[CURRENT_KEY]
        Thread.current[CURRENT_KEY] = workflow
        yield
      ensure
        Thread.current[CURRENT_KEY] = previous
      end
      private_class_method :within
    end
  end
end
