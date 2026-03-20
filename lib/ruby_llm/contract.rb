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
