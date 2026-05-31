# frozen_string_literal: true

RSpec.describe "output_schema forwarding to adapter" do
  before { RubyLLM::Contract.reset_configuration! }

  it "forwards schema to adapter when using string prompt" do
    received_options = nil
    spy_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
      define_method(:call) do |messages:, **options|
        received_options = options
        RubyLLM::Contract::Adapters::Response.new(
          content: '{"intent": "billing"}',
          usage: { input_tokens: 10, output_tokens: 5 }
        )
      end
    end.new

    step = Class.new(RubyLLM::Contract::Step::Base) do
      output_schema do
        string :intent, enum: %w[sales support billing]
      end

      prompt "Classify: {input}"
    end

    step.run("test", context: { adapter: spy_adapter })

    # Previously asserted only `have_key(:schema)` + `not_to be_nil` (A2 / A4):
    # any truthy value would pass, including `true` or a stub. Now check the
    # schema is the structural shape the DSL ought to produce — a JSON Schema
    # carrying the declared `intent` property with the declared enum values.
    schema_class = received_options[:schema]
    expect(schema_class).to be < RubyLLM::Schema
    json = schema_class.new.to_json
    expect(json).to include("intent").and include("sales").and include("billing")
    # Drop sneaky placeholder so the test reflects the strengthening intent
    # documented above. (Block prompt test below mirrors this shape.)
  end

  it "forwards schema to adapter when using block prompt" do
    received_options = nil
    spy_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
      define_method(:call) do |messages:, **options|
        received_options = options
        RubyLLM::Contract::Adapters::Response.new(
          content: '{"intent": "billing"}',
          usage: { input_tokens: 10, output_tokens: 5 }
        )
      end
    end.new

    step = Class.new(RubyLLM::Contract::Step::Base) do
      output_schema do
        string :intent, enum: %w[sales support billing]
      end

      prompt do
        system "Classify intent."
        user "{input}"
      end
    end

    step.run("test", context: { adapter: spy_adapter })

    # Same strengthening as the string-prompt test above.
    schema_class = received_options[:schema]
    expect(schema_class).to be < RubyLLM::Schema
    json = schema_class.new.to_json
    expect(json).to include("intent").and include("sales").and include("billing")
  end

  it "both prompt styles forward the same schema object" do
    schemas = []
    spy_adapter = Class.new(RubyLLM::Contract::Adapters::Base) do
      define_method(:call) do |messages:, **options|
        schemas << options[:schema]
        RubyLLM::Contract::Adapters::Response.new(
          content: '{"intent": "billing"}',
          usage: { input_tokens: 10, output_tokens: 5 }
        )
      end
    end.new

    string_step = Class.new(RubyLLM::Contract::Step::Base) do
      output_schema do
        string :intent, enum: %w[sales support billing]
      end
      prompt "Classify: {input}"
    end

    block_step = Class.new(RubyLLM::Contract::Step::Base) do
      output_schema do
        string :intent, enum: %w[sales support billing]
      end
      prompt do
        system "Classify."
        user "{input}"
      end
    end

    string_step.run("test", context: { adapter: spy_adapter })
    block_step.run("test", context: { adapter: spy_adapter })

    # Previously asserted only `not_to be_nil` × 2 — the test title PROMISED
    # equivalence between styles but a divergence bug (different schema
    # objects per prompt style) would have passed silently. Compare their
    # JSON serialisations; structural equality is what matters, not object
    # identity (each step builds its own).
    expect(schemas[0]).to be < RubyLLM::Schema
    expect(schemas[1]).to be < RubyLLM::Schema
    expect(schemas[0].new.to_json).to eq(schemas[1].new.to_json)
  end
end
