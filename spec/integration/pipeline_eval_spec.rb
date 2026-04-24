# frozen_string_literal: true

# Pipeline eval contract — prevents the regression where pipeline-level
# `run_eval` silently stopped working because of strict additional-property
# handling. The bug that prompted this spec was in example code (extra keys
# in a Test response), but the gem-level behaviour we rely on (define_eval
# on a Pipeline, run_eval matching the FINAL step's output) has no integration
# coverage outside this file.

require "spec_helper"

RSpec.describe "Pipeline eval end-to-end" do
  before do
    stub_const("SummarizeArticle", Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Summarize: {input}"
      output_schema do
        string :tldr, max_length: 200
        array  :takeaways, of: :string, min_items: 3, max_items: 5
        string :tone, enum: %w[neutral positive negative analytical]
      end
    end)

    stub_const("TranslateSummary", Class.new(RubyLLM::Contract::Step::Base) do
      input_type Hash
      prompt "Translate: {tldr}"
      output_schema do
        string :tldr, max_length: 200
        array  :takeaways, of: :string, min_items: 3, max_items: 5
        string :tone, enum: %w[neutral positive negative analytical]
      end
    end)

    stub_const("ReviewTranslation", Class.new(RubyLLM::Contract::Step::Base) do
      input_type Hash
      prompt "Review: {tldr}"
      output_schema do
        string :overall_verdict, enum: %w[pass warning fail]
      end
    end)

    stub_const("TranslatedPipeline", Class.new(RubyLLM::Contract::Pipeline::Base) do
      step SummarizeArticle,  as: :summarise
      step TranslateSummary,  as: :translate
      step ReviewTranslation, as: :review
    end)

    TranslatedPipeline.define_eval("smoke") do
      add_case "release post",
               input: "Ruby 3.4 ships frozen string literals.",
               expected: { overall_verdict: "pass" }
    end
  end

  let(:adapter) do
    RubyLLM::Contract::Adapters::Test.new(responses: [
      { tldr: "EN summary", takeaways: %w[a b c], tone: "analytical" },
      { tldr: "FR summary", takeaways: %w[a b c], tone: "analytical" },
      { overall_verdict: "pass" }
    ])
  end

  it "runs run_eval end-to-end on a pipeline and scores against the final step's output" do
    report = TranslatedPipeline.run_eval("smoke", context: { adapter: adapter })

    expect(report.score).to eq(1.0)
    expect(report.pass_rate).to eq("1/1")
    expect(report.passed?).to be true

    case_result = report.results.first
    expect(case_result).to be_passed
    expect(case_result.name).to eq("release post")
  end

  it "fails the eval when the final step's output does not match expected" do
    failing_adapter = RubyLLM::Contract::Adapters::Test.new(responses: [
      { tldr: "EN summary", takeaways: %w[a b c], tone: "analytical" },
      { tldr: "FR summary", takeaways: %w[a b c], tone: "analytical" },
      { overall_verdict: "fail" }
    ])

    report = TranslatedPipeline.run_eval("smoke", context: { adapter: failing_adapter })

    expect(report.score).to eq(0.0)
    expect(report.passed?).to be false
    expect(report.results.first.details).to include("overall_verdict")
  end

  it "fails the eval when an intermediate step's validate rejects (fail-fast propagates to report)" do
    # Schema has NO max_length on tldr, so the short response passes the
    # schema and reaches the `validate("tldr fits card")` block. That
    # validate rejects anything over 10 chars — exercises the intended
    # invariant-rejection path (schema max_length + validate together
    # would short-circuit on schema before validate ever sees the output).
    stub_const("SummarizeArticleStrict", Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Summarize: {input}"
      output_schema do
        string :tldr
        array  :takeaways, of: :string, min_items: 3, max_items: 5
        string :tone, enum: %w[neutral positive negative analytical]
      end
      validate("tldr fits card") { |o, _| o[:tldr].length <= 10 }
    end)

    stub_const("StrictPipeline", Class.new(RubyLLM::Contract::Pipeline::Base) do
      step SummarizeArticleStrict, as: :summarise
      step TranslateSummary,       as: :translate
      step ReviewTranslation,      as: :review
    end)

    StrictPipeline.define_eval("fail_case") do
      add_case "too long",
               input: "anything",
               expected: { overall_verdict: "pass" }
    end

    # 50-char tldr: passes schema (no max_length), fails the validate.
    long_tldr_adapter = RubyLLM::Contract::Adapters::Test.new(responses: [
      { tldr: "x" * 50, takeaways: %w[a b c], tone: "analytical" },
      { overall_verdict: "pass" }
    ])

    report = StrictPipeline.run_eval("fail_case", context: { adapter: long_tldr_adapter })

    expect(report.passed?).to be false
    case_result = report.results.first
    # Proves the validate path was exercised (not the schema):
    # - step_status records why the intermediate step failed.
    # - details references the validate label we defined.
    expect(case_result.step_status).to eq(:validation_failed)
    expect(case_result.details).to include("tldr fits card")
  end
end
