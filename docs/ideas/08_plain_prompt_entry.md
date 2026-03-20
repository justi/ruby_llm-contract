# Plain Prompt Entry — najłatwiejszy on-ramp

## Problem

Największy próg wejścia to nie `validate`, tylko `prompt { user "{input}" }` — to już wygląda jak framework, nie jak zwykły prompt. Developer startuje od surowego tekstu prompta i nie rozumie po co mu AST.

## Propozycja audytora: `prompt <<~TEXT` + `returns`

### Najprostszy tryb wejścia:

```ruby
class GenerateComment < RubyLLM::Contract::Step::Base
  prompt <<~TEXT
    Write a short Reddit comment for this product:
    {input}

    Return JSON with:
    - comment
    - tone
  TEXT

  returns :json

  validate("has comment") { |o| o[:comment].to_s.size > 0 }
end
```

### Jeszcze prostszy:

```ruby
class GenerateComment < RubyLLM::Contract::Step::Base
  prompt <<~TEXT
    Write a short Reddit comment for this product:
    {input}
  TEXT

  returns comment: String, tone: String
end
```

## Dlaczego to jest ważne

1. Użytkownik startuje od tego co już ma — surowy tekst prompta
2. Dopiero potem dokładamy kontrakt: `returns` i `validate`
3. Tłumaczy sens gemu: "to nie jest nowy sposób pisania promptów, tylko prompt + gwarancje"
4. Ścieżka nauki: plain text → returns → validate → prompt DSL (system/rule/section) → output_schema

## Progression path

```ruby
# Level 0: mam prompt, chcę go ogarnąć
class MyStep < RubyLLM::Contract::Step::Base
  prompt "Classify this: {input}"
  returns :json
end

# Level 1: dodaję walidację
class MyStep < RubyLLM::Contract::Step::Base
  prompt "Classify this: {input}"
  returns :json
  validate("has intent") { |o| o[:intent].to_s.size > 0 }
end

# Level 2: rozbudowuję prompt
class MyStep < RubyLLM::Contract::Step::Base
  prompt do
    system "You are a classifier."
    rule "Return JSON with intent."
    user "{input}"
  end
  returns :json
  validate("has intent") { |o| o[:intent].to_s.size > 0 }
end

# Level 3: pełny kontrakt ze schema
class MyStep < RubyLLM::Contract::Step::Base
  input_type String
  output_schema do
    string :intent, enum: %w[sales support billing]
    number :confidence, minimum: 0.0, maximum: 1.0
  end
  prompt do
    system "You are a classifier."
    rule "Return JSON."
    user "{input}"
  end
  validate("high confidence") { |o| o[:confidence] > 0.5 }
end
```

## Implementacja

### `prompt` akceptuje String ALBO blok:
```ruby
def prompt(text = nil, &block)
  if text
    # String → wrap w single user message z {input} interpolacją
    @prompt_block = -> { user text }
  elsif block
    @prompt_block = block
  else
    @prompt_block
  end
end
```

### `returns` jako alias/shortcut:
```ruby
def returns(type_or_schema = nil, **fields)
  if type_or_schema == :json
    @output_type = Hash
  elsif type_or_schema == :text
    @output_type = String
  elsif fields.any?
    # returns comment: String, tone: String → inline output_schema
    output_schema do
      fields.each { |name, type| string name } # simplified
    end
  end
end
```

## Open questions
- Czy `returns` zastępuje `output_type` / `output_schema` czy jest dodatkowym shortcutem?
- Czy `prompt "text"` implikuje `input_type String`?
- Jak `returns comment: String, tone: String` mapuje się na output_schema vs output_type?

## Status
Propozycja audytora. Wymaga ADR i implementacji.
