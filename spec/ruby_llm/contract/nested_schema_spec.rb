# frozen_string_literal: true

RSpec.describe "output_schema with nested objects in arrays" do
  before { RubyLLM::Contract.reset_configuration! }

  it "schema with array of objects generates correct JSON schema" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      output_schema do
        string :locale
        array :groups, min_items: 1, max_items: 3 do
          object do
            string :who
            array :use_cases do
              string
            end
          end
        end
      end

      prompt "Analyze: {input}"
    end

    schema = step.output_schema
    props = schema.properties
    groups = props[:groups]

    expect(groups[:type]).to eq("array")
    expect(groups[:items][:type]).to eq("object")
    expect(groups[:items][:properties]).to have_key(:who)
    expect(groups[:items][:properties][:who][:type]).to eq("string")
    expect(groups[:items][:properties]).to have_key(:use_cases)
  end

  it "parses nested response correctly and validates" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      output_schema do
        string :locale
        array :groups, min_items: 1 do
          object do
            string :who
            array :tags do
              string
            end
          end
        end
      end

      prompt "Analyze: {input}"
      validate("has groups") { |o| o[:groups].is_a?(Array) && o[:groups].size >= 1 }
      validate("groups have who") { |o| o[:groups].all? { |g| g[:who].to_s.size > 0 } }
      validate("groups have tags") { |o| o[:groups].all? { |g| g[:tags].is_a?(Array) } }
    end

    response = {
      locale: "en",
      groups: [
        { who: "I am a freelancer", tags: ["invoicing", "billing"] },
        { who: "I run a small shop", tags: ["retail", "pos"] }
      ]
    }.to_json

    adapter = RubyLLM::Contract::Adapters::Test.new(response: response)
    result = step.run("test", context: { adapter: adapter })

    expect(result.status).to eq(:ok)
    expect(result.parsed_output[:groups].size).to eq(2)
    expect(result.parsed_output[:groups][0][:who]).to eq("I am a freelancer")
    expect(result.parsed_output[:groups][0][:tags]).to eq(["invoicing", "billing"])
  end

  it "WRONG: array without object wrapper produces flat string items (documents the pitfall)" do
    step = Class.new(RubyLLM::Contract::Step::Base) do
      output_schema do
        array :groups do
          # BUG: this makes items: {type: "string"}, not nested object
          # Correct: array :groups do; object do; string :who; end; end
          string :who
        end
      end

      prompt "test {input}"
    end

    schema = step.output_schema
    groups = schema.properties[:groups]

    # This is the pitfall — items is string, not object
    expect(groups[:items][:type]).to eq("string")
  end
end
