# frozen_string_literal: true

require_relative "contract/version"
require_relative "contract/errors"
require_relative "contract/types"

module RubyLLM
  module Contract
    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
        auto_create_adapter! if configuration.default_adapter.nil?
      end

      def reset_configuration!
        @configuration = Configuration.new
      end

      # --- Eval host registry ---

      def register_eval_host(klass)
        eval_hosts << klass unless eval_hosts.include?(klass)
      end

      def eval_hosts
        @eval_hosts ||= []
      end

      def run_all_evals(context: {})
        live_eval_hosts.to_h do |host|
          [host, host.run_eval(context: context)]
        end
      end

      def reset_eval_hosts!
        @eval_hosts = []
      end

      # Thread-local per-step adapter overrides used by test helpers (RSpec + Minitest).
      def step_adapter_overrides
        Thread.current[:ruby_llm_contract_step_overrides] ||= {}
      end

      def step_adapter_overrides=(map)
        Thread.current[:ruby_llm_contract_step_overrides] = map
      end

      def load_evals!(*dirs)
        dirs = dirs.flatten.compact
        if dirs.empty? && defined?(::Rails)
          dirs = %w[app/steps/eval app/contracts/eval].filter_map do |path|
            full = ::Rails.root.join(path)
            full.to_s if full.exist?
          end
        end

        return if dirs.empty?

        # In Rails, eager-load parent directories so contract classes
        # are available when eval files reference them.
        eager_load_contract_dirs! if defined?(::Rails)

        # Clear file-sourced evals ONCE, then load ALL dirs.
        Thread.current[:ruby_llm_contract_reloading] = true
        eval_hosts.each do |host|
          host.clear_file_sourced_evals! if host.respond_to?(:clear_file_sourced_evals!)
        end

        dirs.each do |d|
          Dir[File.join(d, "**", "*_eval.rb")].each { |f| load f }
        end
      ensure
        Thread.current[:ruby_llm_contract_reloading] = false
      end

      private

      # Filter stale hosts, deduplicate by name (last wins), prune registry in-place
      def live_eval_hosts
        # Remove hosts without evals
        @eval_hosts&.reject! { |h| !h.respond_to?(:eval_defined?) || !h.eval_defined? }

        # Deduplicate: if two classes share a name (reload), keep the latest
        seen = {}
        @eval_hosts&.each { |h| seen[h.name || h.object_id] = h }
        @eval_hosts = seen.values

        @eval_hosts || []
      end

      def eager_load_contract_dirs!
        %w[app/contracts app/steps].each do |path|
          full = ::Rails.root.join(path)
          next unless full.exist?

          # eval/ subdirs already ignored by Railtie initializer (before Zeitwerk setup)
          ::Rails.autoloaders.main.eager_load_dir(full.to_s)
        rescue StandardError
          nil
        end
      end

      def auto_create_adapter!
        require "ruby_llm"
        configuration.default_adapter = Adapters::RubyLLM.new
      rescue LoadError
        nil
      end
    end

    # One-time prepend on Step::Base that checks the override map before
    # falling through to the normal adapter resolution.
    # Used by both RSpec and Minitest test helpers.
    module StepAdapterOverride
      def run(input, context: {})
        context = context || {}
        overrides = RubyLLM::Contract.step_adapter_overrides
        unless overrides.empty? || context.key?(:adapter) || context.key?("adapter")
          override = overrides[self]
          context = context.merge(adapter: override) if override
        end
        super(input, context: context)
      end
    end
  end
end

require_relative "contract/concerns/context_helpers"
require_relative "contract/concerns/deep_freeze"
require_relative "contract/concerns/deep_symbolize"
require_relative "contract/concerns/eval_host"
require_relative "contract/concerns/trace_equality"
require_relative "contract/concerns/usage_aggregator"
require_relative "contract/configuration"
require_relative "contract/prompt/node"
require_relative "contract/prompt/nodes"
require_relative "contract/prompt/ast"
require_relative "contract/prompt/builder"
require_relative "contract/prompt/renderer"
require_relative "contract/contract"
require_relative "contract/cost_calculator"
require_relative "contract/token_estimator"
require_relative "contract/adapters"
require_relative "contract/step"
require_relative "contract/pipeline"
require_relative "contract/eval"
require_relative "contract/dsl"
require_relative "contract/railtie" if defined?(Rails::Railtie)

# Prepend after Step::Base is loaded
RubyLLM::Contract::Step::Base.singleton_class.prepend(RubyLLM::Contract::StepAdapterOverride)
