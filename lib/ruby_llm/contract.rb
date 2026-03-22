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

      # --- Eval host registry (P3 fix) ---

      def register_eval_host(klass)
        eval_hosts << klass unless eval_hosts.include?(klass)
      end

      def eval_hosts
        @eval_hosts ||= []
      end

      def run_all_evals(context: {})
        eval_hosts.select(&:eval_defined?).each_with_object({}) do |host, results|
          results[host] = host.run_eval(context: context)
        end
      end

      def reset_eval_hosts!
        @eval_hosts = []
      end

      def load_evals!(dir = nil)
        dirs = if dir
                 [dir]
               elsif defined?(::Rails)
                 %w[app/steps/eval app/contracts/eval].filter_map do |path|
                   full = ::Rails.root.join(path)
                   full.to_s if full.exist?
                 end
               else
                 []
               end

        dirs.each do |d|
          Dir[File.join(d, "**", "*_eval.rb")].sort.each { |f| load f }
        end
      end

      private

      def auto_create_adapter!
        require "ruby_llm"
        # If RubyLLM has any API key configured, auto-create the adapter
        configuration.default_adapter = Adapters::RubyLLM.new
      rescue LoadError
        # ruby_llm not available — user must set adapter manually
        nil
      end
    end
  end
end

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
require_relative "contract/railtie" if defined?(::Rails::Railtie)
