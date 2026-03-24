# frozen_string_literal: true

module RubyLLM
  module Contract
    class Railtie < ::Rails::Railtie
      # Ignore eval/ subdirs BEFORE Zeitwerk setup — eval files don't define
      # constants, they call define_eval on existing Step classes.
      initializer "ruby_llm_contract.ignore_eval_dirs", before: :set_autoload_paths do |app|
        %w[app/contracts/eval app/steps/eval].each do |path|
          full = app.root.join(path)
          next unless full.exist?

          Rails.autoloaders.each { |loader| loader.ignore(full.to_s) }
        end
      end

      config.after_initialize do
        RubyLLM::Contract.load_evals!
      end

      config.to_prepare do
        RubyLLM::Contract.load_evals!
      end
    end
  end
end
