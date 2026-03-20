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

    expect(received_options).to have_key(:schema)
    expect(received_options[:schema]).not_to be_nil
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

    expect(received_options).to have_key(:schema)
    expect(received_options[:schema]).not_to be_nil
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

    # Both should forward a schema (not nil)
    expect(schemas[0]).not_to be_nil
    expect(schemas[1]).not_to be_nil
  end
end
