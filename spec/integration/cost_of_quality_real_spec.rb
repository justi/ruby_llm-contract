# frozen_string_literal: true

# =============================================================================
# THE GAME CHANGER TEST
#
# This test proves that compare_models works with a real LLM.
# It calls the API, tracks real costs, and produces a real comparison table.
#
# Run:  OPENAI_API_KEY=sk-... bundle exec rspec spec/integration/cost_of_quality_real_spec.rb
#   or: ANTHROPIC_API_KEY=sk-... bundle exec rspec spec/integration/cost_of_quality_real_spec.rb
# =============================================================================

require "ruby_llm/contract/rspec"

RSpec.describe "Cost of Quality — real LLM", :online do
  before(:all) do
    has_openai = ENV["OPENAI_API_KEY"] && !ENV["OPENAI_API_KEY"].empty?
    has_anthropic = ENV["ANTHROPIC_API_KEY"] && !ENV["ANTHROPIC_API_KEY"].empty?

    skip "Set OPENAI_API_KEY or ANTHROPIC_API_KEY to run online tests" unless has_openai || has_anthropic

    RubyLLM.configure do |c|
      c.openai_api_key = ENV["OPENAI_API_KEY"] if has_openai
      c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] if has_anthropic
    end

    @provider = has_openai ? :openai : :anthropic
    @models = if has_openai
                %w[gpt-4.1-nano gpt-4.1-mini]
              else
                %w[claude-haiku-4-5-20251001 claude-sonnet-4-5-20250514]
              end
  end

  before do
    RubyLLM::Contract.reset_configuration!
    RubyLLM::Contract.configure {} # triggers auto_create_adapter! with configured RubyLLM
  end

  let(:classify_step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt do
        system "You are a support ticket classifier."
        rule "Return ONLY valid JSON, no markdown."
        rule "Use exactly one priority: low, medium, high, urgent."
        user "Classify this ticket: {input}"
      end

      validate("valid priority") { |o| %w[low medium high urgent].include?(o[:priority]) }
    end
  end

  # ===========================================================================
  # Test 1: Single eval with real LLM produces cost > 0
  # ===========================================================================

  describe "single eval with real cost" do
    it "run_eval returns report with real cost and latency" do
      classify_step.define_eval("smoke") do
        add_case "billing",
          input: "I was charged twice on my credit card",
          expected: { priority: "high" }

        add_case "feature",
          input: "Can you add dark mode to the app?",
          expected: { priority: "low" }
      end

      report = classify_step.run_eval("smoke", context: { model: @models.first })

      puts "\n--- Single Eval (#{@models.first}) ---"
      report.print_summary

      expect(report.results.length).to eq(2)
      expect(report.total_cost).to be > 0, "Expected real cost but got #{report.total_cost}"
      expect(report.avg_latency_ms).to be > 0, "Expected real latency but got #{report.avg_latency_ms}"
      expect(report.score).to be > 0, "Expected some cases to pass"

      report.results.each do |result|
        expect(result.cost).to be > 0, "Case '#{result.name}' has no cost"
        expect(result.duration_ms).to be > 0, "Case '#{result.name}' has no latency"
        expect(result.output).to be_a(Hash), "Case '#{result.name}' output is not a Hash"
      end
    end
  end

  # ===========================================================================
  # Test 2: THE GAME CHANGER — compare_models with real LLM
  # ===========================================================================

  describe "compare_models — the game changer" do
    it "compares two models with real costs and real scores" do
      classify_step.define_eval("regression") do
        add_case "billing",
          input: "I was charged twice on my credit card",
          expected: { priority: "high" }

        add_case "feature",
          input: "Can you add dark mode to the app?",
          expected: { priority: "low" }

        add_case "outage",
          input: "The entire website is down and customers can't access anything",
          expected: { priority: "urgent" }
      end

      comparison = classify_step.compare_models("regression", models: @models)

      puts "\n--- Model Comparison ---"
      comparison.print_summary

      # Both models should have real data
      @models.each do |model|
        score = comparison.score_for(model)
        cost = comparison.cost_for(model)

        expect(score).to be_between(0.0, 1.0), "#{model} score out of range: #{score}"
        expect(cost).to be > 0, "#{model} cost is #{cost} — expected > 0"

        puts "  #{model}: score=#{score.round(2)}, cost=$#{format("%.6f", cost)}"
      end

      # best_for should return a model
      best = comparison.best_for(min_score: 0.5)
      expect(best).not_to be_nil, "No model meets min_score 0.5"
      puts "\n  Best for >= 50%: #{best}"

      # Table should contain model names and real numbers
      table = comparison.table
      @models.each { |m| expect(table).to include(m) }
    end
  end

  # ===========================================================================
  # Test 3: CI gate with real cost budget
  # ===========================================================================

  describe "CI gate with cost" do
    it "pass_eval with_minimum_score works with real LLM" do
      classify_step.define_eval("ci_gate") do
        add_case "billing",
          input: "I was double-charged",
          expected: { priority: "high" }
      end

      expect(classify_step).to pass_eval("ci_gate")
        .with_context(model: @models.first)
        .with_minimum_score(0.5)
        .with_maximum_cost(1.0) # generous budget for test
    end
  end
end
