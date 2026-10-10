# frozen_string_literal: true

require "tmpdir"
require "webmock"

# The multimodal path is otherwise only covered with the Test adapter, which
# never builds a request. This drives a real attachment through the real
# RubyLLM 2.x adapter and inspects what would go over the wire, with HTTP
# intercepted - so no key, no spend, and no dependency on the network.
RSpec.describe "Attachment through the RubyLLM adapter (HTTP intercepted)" do
  include WebMock::API

  # 1x1 transparent PNG.
  let(:png_base64) do
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  end

  let(:step) do
    Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Describe the attached image. {input}"
      output_schema { string :label }
      attachment_token_estimate 1_000
      max_cost 1.0
    end
  end

  let(:completion) do
    {
      id: "resp_1", object: "response", model: "gpt-4.1-mini", status: "completed",
      output: [{ type: "message", role: "assistant",
                 content: [{ type: "output_text", text: '{"label":"pixel"}' }] }],
      usage: { input_tokens: 120, output_tokens: 8 }
    }.to_json
  end

  around do |example|
    previous_key = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = "test-key-not-real"
    WebMock.enable!
    WebMock.disable_net_connect!
    example.run
  ensure
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
    RubyLLM.config.openai_api_key = previous_key
  end

  it "sends the image as an input_image part next to the prompt and reads usage back" do
    request_body = nil
    stub_request(:post, %r{\Ahttps://api\.openai\.com/v1/responses\z}).to_return do |request|
      request_body = JSON.parse(request.body)
      { status: 200, body: completion, headers: { "Content-Type" => "application/json" } }
    end

    result = Dir.mktmpdir do |dir|
      path = File.join(dir, "pixel.png")
      File.binwrite(path, png_base64.unpack1("m0"))
      step.run("Be brief.", context: { adapter: RubyLLM::Contract::Adapters::RubyLLM.new,
                                       model: "gpt-4.1-mini", attachment: path })
    end

    parts = request_body["input"].flat_map { |message| Array(message["content"]) }.grep(Hash)
    image = parts.find { |part| part["type"] == "input_image" }
    text = parts.find { |part| part["type"] == "input_text" }

    expect(image["image_url"]).to eq("data:image/png;base64,#{png_base64}")
    expect(text["text"]).to include("Describe the attached image. Be brief.")
    expect(result.status).to eq(:ok)
    expect(result.parsed_output).to eq(label: "pixel")
    expect(result.trace[:usage]).to eq(input_tokens: 120, output_tokens: 8)
    expect(result.trace[:cost]).to be_positive
  end
end
