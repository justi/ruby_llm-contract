# Prompt AST

Prompts are structured data, not strings. Available node types:

```ruby
prompt do
  system "Main system instruction."          # system message
  rule   "Return JSON only."                 # appended as separate system message
  section "CONTEXT", "Product: Acme Inc."    # labeled system message: [CONTEXT]\n...
  example input: "hello", output: "hi"       # user/assistant message pair
  user   "Process this: {input}"             # user message with interpolation
end
```

Or just a plain string (wraps as user message):

```ruby
prompt "Classify the intent of this text: {input}"
```

The AST is immutable, diffable, and hashable. Useful for snapshot testing and auditing prompt changes.

## Hash inputs with variable interpolation

When input is a Hash, each key becomes a template variable:

```ruby
class GenerateComment < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    thread_title: RubyLLM::Contract::Types::String,
    subreddit: RubyLLM::Contract::Types::String,
    language: RubyLLM::Contract::Types::String
  )

  prompt do
    system "You are a helpful community member."
    rule   "Write in {language}."
    rule   "Stay on topic for r/{subreddit}."
    user   "Thread: {thread_title}\n\nWrite a helpful comment."
  end
end
```

## Cross-validating output against input

Validate blocks support 2-arity to compare output against input:

```ruby
validate("all IDs must match input") do |output, input|
  output.map { |r| r[:id] }.sort == input.map { |t| t[:id] }.sort
end
```
