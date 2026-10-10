# frozen_string_literal: true

# Pricing goes through RubyLLM's own Model#cost_for, so cache, long-context and
# per-provider prices count, and a used category without a price is unknown
# rather than free. Models are fixtures, not catalog entries, so the expected
# figures do not move when RubyLLM ships a new models.json.
RSpec.describe RubyLLM::Contract::CostCalculator, "pricing" do
  after { described_class.reset_custom_models! }

  def model(id, provider, standard, long_context: nil, threshold: nil)
    text = { standard: standard }
    text.merge!(long_context: long_context, long_context_threshold: threshold) if long_context
    RubyLLM::Model.new(id: id, provider: provider, pricing: { text_tokens: text })
  end

  def calculate(usage, model_name: "fx-model", provider: nil)
    described_class.calculate(model_name: model_name, usage: usage, provider: provider)
  end

  let(:priced) do
    model("fx-model", "fx", { input_per_million: 0.4, output_per_million: 1.6, cache_read_input_per_million: 0.1 })
  end

  before { allow(RubyLLM.models).to receive(:find).with("fx-model").and_return(priced) }

  describe "prompt cache" do
    # 10_000 prompt tokens, 9_000 of them read from the cache, 200 output:
    # 1_000 x 0.4 + 9_000 x 0.1 + 200 x 1.6 = 1_620 per million = $0.00162.
    it "prices cache reads at the cache price, out of a prompt that includes them" do
      usage = { input_tokens: 10_000, output_tokens: 200, cache_read_tokens: 9_000 }

      expect(calculate(usage)).to eq(0.00162)
    end

    it "prices a prompt without a cache breakdown as uncached input" do
      expect(calculate({ input_tokens: 10_000, output_tokens: 200 })).to eq(0.00432)
    end

    it "has no price for a cache write the model has no write price for" do
      usage = { input_tokens: 10_000, output_tokens: 200, cache_write_tokens: 9_000 }

      expect(calculate(usage)).to be_nil
    end
  end

  describe "missing prices" do
    let(:input_only) { model("fx-half", "fx", { input_per_million: 125.0 }) }

    before { allow(RubyLLM.models).to receive(:find).with("fx-half").and_return(input_only) }

    it "has no price when used output has none, instead of counting it free" do
      expect(calculate({ input_tokens: 1_000, output_tokens: 1_000 }, model_name: "fx-half")).to be_nil
    end

    it "needs no output price when no output was used" do
      expect(calculate({ input_tokens: 1_000, output_tokens: 0 }, model_name: "fx-half")).to eq(0.125)
    end
  end

  describe "provider" do
    let(:pricier) { model("fx-model", "other", { input_per_million: 1.74, output_per_million: 3.48 }) }

    before { allow(RubyLLM.models).to receive(:find).with("fx-model", provider: :other).and_return(pricier) }

    it "uses the named provider's price for an id several providers list" do
      usage = { input_tokens: 1_000_000, output_tokens: 0 }

      expect(calculate(usage)).to eq(0.4)
      expect(calculate(usage, provider: :other)).to eq(1.74)
    end
  end

  describe "pre-flight with a provider" do
    let(:pricier) { model("fx-model", "other", { input_per_million: 1.74, output_per_million: 3.48 }) }
    let(:step) do
      Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Summarize: {input}"
        max_output 100
      end
    end
    let(:input) { "word " * 400 }

    before { allow(RubyLLM.models).to receive(:find).with("fx-model", provider: :other).and_return(pricier) }

    it "estimates with the provider's price, per call and per eval" do
      cheap = step.estimate_cost(input: input, model: "fx-model")[:estimated_cost]
      dear = step.estimate_cost(input: input, model: "fx-model", provider: :other)[:estimated_cost]
      expect(dear).to be > cheap * 2

      step.define_eval("smoke") { add_case "a", input: "word " * 400, expected: { a: 1 } }
      expect(step.estimate_eval_cost("smoke", models: ["fx-model"], provider: :other)).to eq("fx-model" => dear)
    end

    it "finds a model only the provider knows, such as a deployment name" do
      deployment = model("fx-deploy", "other", { input_per_million: 1.0, output_per_million: 1.0 })
      allow(RubyLLM.models).to receive(:find).with("fx-deploy").and_return(nil)
      allow(RubyLLM.models).to receive(:find).with("fx-deploy", provider: :other).and_return(deployment)

      expect(step.estimate_cost(input: input, model: "fx-deploy", provider: :other)).to include(:estimated_cost)
    end

    it "refuses under max_cost when the provider the call goes to is the pricier one" do
      cheap = step.estimate_cost(input: input, model: "fx-model")[:estimated_cost]
      dear = step.estimate_cost(input: input, model: "fx-model", provider: :other)[:estimated_cost]
      limited = Class.new(step) { max_cost((cheap + dear) / 2) }
      adapter = RubyLLM::Contract::Adapters::Test.new(response: '{"a":1}')

      expect(limited.run(input, context: { adapter: adapter, model: "fx-model" }).status).to eq(:ok)
      expect(limited.run(input, context: { adapter: adapter, model: "fx-model", provider: :other }).status)
        .to eq(:limit_exceeded)
    end
  end

  describe "long context" do
    let(:tiered) do
      model("fx-long", "fx", { input_per_million: 5.0, output_per_million: 25.0 },
            long_context: { input_per_million: 10.0, output_per_million: 37.5 }, threshold: 200_000)
    end

    before { allow(RubyLLM.models).to receive(:find).with("fx-long").and_return(tiered) }

    it "charges the long-context tier past the model's threshold" do
      usage = { input_tokens: 300_000, output_tokens: 0 }

      expect(calculate(usage, model_name: "fx-long")).to eq(3.0)
    end
  end

  describe "register_model" do
    before { described_class.register_model("fx-custom", input_per_1m: 2.0, output_per_1m: 8.0) }

    it "charges cache reads at the input price" do
      usage = { input_tokens: 1_000_000, output_tokens: 0, cache_read_tokens: 900_000 }

      expect(calculate(usage, model_name: "fx-custom")).to eq(2.0)
    end

    it "has no price for a cache write, which can cost more than input" do
      usage = { input_tokens: 1_000_000, output_tokens: 0, cache_write_tokens: 900_000 }

      expect(calculate(usage, model_name: "fx-custom")).to be_nil
    end

    describe "with cache prices" do
      before do
        described_class.register_model("fx-cached", input_per_1m: 2.0, output_per_1m: 8.0,
                                                    cache_read_per_1m: 0.5, cache_write_per_1m: 2.5)
      end

      # 100_000 uncached x 2.0 + 600_000 read x 0.5 + 300_000 write x 2.5 + 10_000 out x 8.0
      # = 200_000 + 300_000 + 750_000 + 80_000 = 1_330_000 per million.
      it "charges each part of the prompt once, at its own price" do
        usage = { input_tokens: 1_000_000, output_tokens: 10_000, cache_read_tokens: 600_000,
                  cache_write_tokens: 300_000 }

        expect(calculate(usage, model_name: "fx-cached")).to eq(1.33)
      end

      it "accepts a free cache" do
        described_class.register_model("fx-free", input_per_1m: 0, output_per_1m: 0,
                                                  cache_read_per_1m: 0, cache_write_per_1m: 0)
        usage = { input_tokens: 1_000, output_tokens: 10, cache_write_tokens: 500 }

        expect(calculate(usage, model_name: "fx-free")).to eq(0.0)
      end

      it "rejects a negative cache price" do
        expect { described_class.register_model("fx-bad", input_per_1m: 1, output_per_1m: 1, cache_write_per_1m: -1) }
          .to raise_error(ArgumentError, /cache_write_per_1m/)
      end
    end

    it "still overrides RubyLLM's price for the same id" do
      described_class.register_model("fx-model", input_per_1m: 99.0, output_per_1m: 99.0)

      expect(calculate({ input_tokens: 1_000_000, output_tokens: 0 })).to eq(99.0)
    end
  end

  it "passes reasoning tokens on, for a model that prices them apart from output" do
    reasoning = model("fx-reason", "fx", { input_per_million: 1.0, output_per_million: 2.0,
                                           reasoning_output_per_million: 10.0 })
    allow(RubyLLM.models).to receive(:find).with("fx-reason").and_return(reasoning)

    # 100 x 1 + 50 x 2 + 40 x 10 = 600 per million.
    usage = { input_tokens: 100, output_tokens: 50, thinking_tokens: 40 }
    expect(calculate(usage, model_name: "fx-reason")).to eq(0.0006)
  end

  it "costs zero tokens 0.0 whatever the pricing" do
    expect(calculate({ input_tokens: 0, output_tokens: 0 })).to eq(0.0)
  end
end
