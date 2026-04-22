# Prompt AST

Prompts are structured data, not strings. That matters the moment `SummarizeArticle` has to ship in more than one shape — a different audience per tenant, a different language per region, a different tone template for a B2B vs consumer card. Building those variants by string-concatenating a monolithic prompt leads to silent drift across environments. The AST gives you typed nodes (`system`, `rule`, `section`, `example`, `user`) that compose, diff, and snapshot-test cleanly.

Available node types:

```ruby
prompt do
  system  "You summarize articles for a UI card."     # system message
  rule    "Return valid JSON only."                   # appended as separate system message
  section "AUDIENCE", "Rails developers"              # labeled system message: [AUDIENCE]\n...
  example input:  "Ruby 3.4 ships frozen strings...", # user/assistant few-shot pair
          output: '{"tldr":"...","takeaways":[...],"tone":"analytical"}'
  user    "{input}"                                   # user message with interpolation
end
```

Or just a plain string (wraps as a single user message):

```ruby
prompt "Summarize this article for a UI card. {input}"
```

The AST is immutable, diffable, and hashable. Useful for snapshot testing and auditing prompt changes.

## Hash inputs with variable interpolation

When input is a Hash, each key becomes a template variable. Concrete scenario: a multi-language newsletter product where the same article has to be summarised in Polish for EU subscribers, English for US, with different audiences per tier (Rails developers vs engineering managers). Hash inputs let one step cover all of these without forking the class:

```ruby
class SummarizeArticle < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    article:  RubyLLM::Contract::Types::String,
    audience: RubyLLM::Contract::Types::String,
    language: RubyLLM::Contract::Types::String
  )

  prompt do
    system  "You summarize articles for a UI card."
    rule    "Write the TL;DR and takeaways in {language}."
    section "AUDIENCE", "{audience}"
    user    "{article}"
  end

  output_schema do
    string :tldr
    array  :takeaways, of: :string, min_items: 3, max_items: 5
    string :tone, enum: %w[neutral positive negative analytical]
  end
end
```

Every `{key}` in a prompt node is pulled from the input hash at run time. Missing keys raise — making wire-up bugs loud, not silent.

## Cross-validating output against input

Validate blocks support 2-arity `|output, input|` so you can check that the model's answer stays faithful to the request:

```ruby
validate("tldr is not just the article reprinted") do |output, input|
  # Guard against lazy models that return the input verbatim.
  output[:tldr].length < input[:article].length / 2
end

validate("no takeaway repeats the TL;DR") do |output, _input|
  output[:takeaways].none? { |t| t == output[:tldr] }
end
```

The first example uses `input`; the second ignores it. Both are legal 2-arity signatures — Ruby accepts the unused `_input` parameter naming convention.
