# frozen_string_literal: true

module RubyLLM
  module Contract
    class Railtie < ::Rails::Railtie
      # Eval files (e.g. classify_threads_eval.rb) don't define Zeitwerk-compatible
      # constants — they call define_eval on an existing Step class. We use `load`
      # after initialization instead of adding to autoload_paths.
      config.after_initialize do
        RubyLLM::Contract.load_evals!
      end
    end
  end
end
