# frozen_string_literal: true

require_relative "lib/ruby_llm/contract/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_llm-contract"
  spec.version = RubyLLM::Contract::VERSION
  spec.authors = ["Justyna"]

  spec.summary = "Contract-first LLM step execution for RubyLLM"
  spec.description = "Turn RubyLLM calls into contracted, validated, testable steps with schema enforcement, " \
                     "retry with model escalation, and eval."
  spec.homepage = "https://github.com/justi/ruby_llm-contract"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?("spec/", "docs/", "doc/", ".ai/", ".claude/", ".git")
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "dry-types", "~> 1.7"
  spec.add_dependency "ruby_llm", "~> 1.0"
  spec.add_dependency "ruby_llm-schema"
end
