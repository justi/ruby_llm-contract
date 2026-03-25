# frozen_string_literal: true

module RubyLLM
  module Contract
    module Step
      class PromptCompiler
        def initialize(prompt_block:)
          @prompt_block = prompt_block
        end

        def call(input)
          dynamic_prompt = @prompt_block.arity >= 1
          builder_input = dynamic_prompt ? input : nil
          ast = Prompt::Builder.build(input: builder_input, &@prompt_block)

          Prompt::Renderer.render(ast, variables: template_variables_for(input, dynamic_prompt))
        rescue StandardError => error
          raise RubyLLM::Contract::Error, "Prompt build failed: #{error.class}: #{error.message}"
        end

        private

        def template_variables_for(input, dynamic_prompt)
          return {} if dynamic_prompt

          { input: input }.tap do |variables|
            variables.merge!(input.transform_keys(&:to_sym)) if input.is_a?(Hash)
          end
        end
      end
    end
  end
end
