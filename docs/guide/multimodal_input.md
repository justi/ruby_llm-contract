# Multimodal input

> Read this when your contract needs to send a PDF, image, or audio file to the LLM — not just text.

`ruby_llm-contract` 0.9.0+ routes attachments through the contract layer, so `max_cost`, `validate`, `retry_policy escalate(...)`, and trace observability still apply. The gem does **not** ship its own multimodal API — it forwards `with:` to `RubyLLM::Chat#ask`, which RubyLLM 1.15+ normalises per provider (Anthropic, OpenAI, Gemini).

## Minimal example

```ruby
# app/contracts/extract_invoice_data.rb
class ExtractInvoiceData < RubyLLM::Contract::Step::Base
  prompt "Extract invoice fields from the attached PDF. Return JSON."

  output_schema do
    string :vendor
    string :invoice_number
    number :total_amount
    string :currency, enum: %w[USD EUR PLN GBP]
  end

  validate("currency present") { |o, _| !o[:currency].nil? }

  # REQUIRED when max_cost is set and the contract receives an attachment.
  # Conservative estimate of attachment input tokens (provider/model-specific).
  attachment_token_estimate 15_000   # ~12 PDF pages at ~1250 tokens/page

  max_cost 0.10

  retry_policy do
    escalate "gpt-4.1-mini",
             { model: "gpt-5", reasoning_effort: "high" }
  end
end

result = ExtractInvoiceData.run(
  "Look for vendor, amount, currency.",
  context: { attachment: "tmp/invoice.pdf" }
)

result.status         # => :ok
result.parsed_output  # => { vendor: "...", invoice_number: "...", ... }
result.trace[:cost]   # => 0.0042  (total across attempts)
```

## How it works

1. **Input vs attachment.** The `input` argument to `Step.run` is the text prompt. The attachment travels via `context: { attachment: ... }` — opaque to the contract layer, forwarded to the adapter.
2. **Adapter forwards `with:`.** `RubyLLM::Contract::Adapters::RubyLLM` reads `options[:attachment]` and passes it to `chat.ask(content, with: attachment)`. RubyLLM picks the right wire format per provider.
3. **Multi-attachment supported.** `with: [pdf1, pdf2]` or `with: { images: [...], pdfs: [...] }` works natively (`RubyLLM::Content#process_attachments`).
4. **`with: nil` is a no-op.** Text-only contracts unaffected — the kwarg defaults to nil.

## Cost: `attachment_token_estimate` is required

The gem cannot count attachment input tokens precisely — vision/PDF token cost depends on model, image resolution, page count, and provider. To keep `max_cost` and `max_input` fail-closed, you declare a **conservative estimate** of attachment input tokens at the class level:

```ruby
class TranscribePDF < RubyLLM::Contract::Step::Base
  # ...
  attachment_token_estimate 15_000   # safe upper bound for ~12-page docs
  max_cost 0.05
end
```

The same estimate applies to:

- **Runtime** (`limit_checker`) — adds the estimate to `input_tokens` before checking `max_cost`/`max_input`. Refuses pre-flight if budget exceeded.
- **Pre-flight** (`estimate_cost`) — accepts `attachment:` kwarg; same accounting. No drift between estimate and runtime decisions.

### Fail-closed without estimate

If your contract has `max_cost` or `max_input` set, receives an attachment, and `attachment_token_estimate` is **not declared**, the call fails with `:limit_exceeded` — the gem refuses to spend money on cost it cannot bound.

```ruby
class MyContract < RubyLLM::Contract::Step::Base
  max_cost 0.05
  # no attachment_token_estimate declared
end

result = MyContract.run("text", context: { attachment: "doc.pdf" })
result.status # => :limit_exceeded
result.validation_errors # => ["attachment present but attachment_token_estimate not set; ..."]
```

### Opting out per-step

If you do not want fail-closed (e.g., experimental or development contracts), set:

```ruby
class FlexibleContract < RubyLLM::Contract::Step::Base
  on_unknown_attachment_size :warn   # log a warning instead of refusing
  max_cost 0.05
end
```

`:warn` is per-step. There is no global opt-out — the same invariant as `on_unknown_pricing`.

## Pre-flight cost estimation

`estimate_cost` accepts an optional `attachment:` kwarg for budget planning:

```ruby
ExtractInvoiceData.estimate_cost(
  input: "Look for vendor, amount...",
  attachment: "tmp/invoice.pdf"
)
# => { model: "gpt-4.1-mini",
#      input_tokens: 15_320,
#      output_tokens_estimate: 256,
#      estimated_cost: 0.0123 }
```

The `input_tokens` figure includes both the text estimate (chars/4 heuristic) AND the declared `attachment_token_estimate`. Pre-flight refusal mirrors runtime: if `attachment` is passed and `attachment_token_estimate` is not declared, `estimate_cost` returns nil and emits the same fail-closed reason.

**Note on output tokens.** `attachment_token_estimate` adds to `input_tokens` only — not to `output_tokens_estimate`. Vision-heavy responses (long image descriptions, transcribed paragraphs) may exceed the conservative `output_tokens_estimate` default. Treat `estimated_cost` as a floor for budget planning, not a precise predictor; inflate `max_output` or `max_cost` accordingly if your prompt routinely produces verbose descriptions.

## Calibrating `attachment_token_estimate`

The number depends on provider, model, and content shape. Some baselines:

| Content                       | Provider | Approx tokens |
|-------------------------------|----------|---------------|
| 1 PDF page (text-heavy)       | OpenAI   | ~1000-1500    |
| 1 PDF page (text-heavy)       | Anthropic | ~1000-1500   |
| 1 image (1024x1024, low res)  | OpenAI   | ~85           |
| 1 image (1024x1024, high res) | OpenAI   | ~765          |
| 1 image                       | Anthropic | ~1500 max    |
| 1 image                       | Gemini   | ~258 (fixed)  |

Pick a value at or above the provider's worst-case. The estimate is a **floor for safety**, not a precise count — use it to gate budget refusal, not to predict exact cost.

## Multi-turn caveat

If your contract uses history (`add_history`), attachments from prior turns are **not** replayed in 0.9.0. Single-turn multimodal works; follow-up questions on the same document require additional work that is deferred to a later release. See [ADR-0022](../decisions/ADR-0022-v09-multimodal-input.md) (internal) for the rationale.

## Provider notes

- **OpenAI** — PDFs sent as `type: 'file'` with `file_data` (base64). Images as `image_url`. Audio as `input_audio`. Vision pricing varies by image detail; check the model card.
- **Anthropic** — PDFs sent as `type: 'document'` with `source.type: 'base64'` or `'url'` (auto-selected). Images same. Page limit ~100 per call.
- **Gemini** — Everything via `inline_data` with `mime_type`. Multimodal token counting is unified.

RubyLLM dispatches on `attachment.type` (`:image`, `:pdf`, `:audio`, `:text`, `:unknown`). Tempfiles must have the right extension (`.pdf`, `.png`, etc.) — RubyLLM detects MIME from the filename; an unsuffixed tempfile becomes `:unknown` and is rejected by the provider.

## Testing contracts with attachments

The Test adapter ignores the `attachment` context key (deterministic responses by step). To verify your adapter call shape, stub `RubyLLM::Chat` directly:

```ruby
RSpec.describe ExtractInvoiceData do
  it "forwards attachment to chat.ask" do
    expect_any_instance_of(RubyLLM::Chat).to receive(:ask)
      .with(anything, with: "fixtures/invoice.pdf")
      .and_return(double(content: '{"vendor":"X",...}', input_tokens: 200, output_tokens: 50))

    result = described_class.run("extract", context: { attachment: "fixtures/invoice.pdf" })
    expect(result.status).to eq(:ok)
  end
end
```

For pre-flight estimate tests, just call `.estimate_cost(input: ..., attachment: ...)` — no adapter stub needed.
