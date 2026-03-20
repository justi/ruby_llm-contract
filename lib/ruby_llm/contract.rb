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
        return unless configuration.api_key_set? && configuration.default_adapter.nil?

        configuration.default_adapter = Adapters::RubyLLM.new
      end

      def reset_configuration!
        @configuration = Configuration.new
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
