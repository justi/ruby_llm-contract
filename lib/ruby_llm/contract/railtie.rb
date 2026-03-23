# frozen_string_literal: true

module RubyLLM
  module Contract
    class Railtie < ::Rails::Railtie
      # Eval files (e.g. classify_threads_eval.rb) don't define Zeitwerk-compatible
      # constants — they call define_eval on an existing Step class. We use `load`
      # after initialization, and hook into the reloader for development.

      config.after_initialize do
        RubyLLM::Contract.load_evals!
      end

      # Re-load eval files on code reload in development (Spring, zeitwerk:check, etc.)
      config.to_prepare do
        RubyLLM::Contract.load_evals!
      end
    end
  end
end
