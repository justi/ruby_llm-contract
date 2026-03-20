# Real Case: reddit_promo_planner — jak ruby_llm-contract rozwiązuje konkretne problemy

## Stan obecny pipeline'u

7-stopniowy pipeline LLM:
1. **TargetAudience** (gpt-5-mini) → product_context, audience groups
2. **PromotedPageContextBuilder** (gpt-5-nano) → per-page targeting
3. **SearchExpansion** (gpt-5-nano) → subreddit discovery keywords
4. **ThreadSearchContext** (gpt-5-nano) → problem-focused Reddit queries
5. **ThreadClassification** (gpt-5-mini) → PROMO/FILLER/SKIP per thread
6. **CommentPlanGeneration** (gpt-5-mini) → comment structure planning
7. **CommentGeneration** (gpt-5-mini/nano) → finalne komentarze z personą

Prompty: inline heredocy w concern modules (~6 plików).
Walidacja: `parse_llm_json` + ad-hoc checks + OpenAI strict schema.
Retry: custom concern z exponential backoff.
Trace: `AiCallLog` (truncated do 10k znaków).
Testy: VCR cassettes — mockowane, nie eval.

---

## PROBLEM 1: Zmiana promptu to ruletka ✅ WORKS NOW

### Gdzie boli
Prompt w `comment_prompts.rb` ma ~200 linii — persona, voice & tone, URL selection rules, format rules, length rules. Zmiana jednego zdania w personie może:
- popsuć ton w komentarzach po polsku
- zmienić sposób wstawiania linków
- złamać format (np. nagłówki markdown zamiast plain text)

### Jak to wygląda dziś
Zmieniasz prompt → deployujesz → patrzysz ręcznie na kilka wygenerowanych komentarzy → "chyba ok".

### Jak to wygląda z ruby_llm-contract
```ruby
class GeneratePromoComment < RubyLLM::Contract::Step::Base
  input_type Types::Hash.schema(
    thread_title: Types::String,
    thread_selftext: Types::String,
    subreddit: Types::String,
    target_length: Types::String,
    thread_language: Types::String
  )
  output_type Types::Hash.schema(comment: Types::String)

  prompt do
    system "You are a woman, 40+, a maker..."  # persona inline or from constant
    rule "Write in {thread_language}."
    rule "No markdown headers."
    rule "Include product link naturally."
    user "Thread: {thread_title}\n\n{thread_selftext}\n\nWrite a helpful comment."
  end

  contract do
    parse :json
    invariant("comment not empty") { |o| o[:comment].to_s.strip.size > 10 }
    invariant("no markdown headers") { |o| !o[:comment].match?(/^#{2,}/) }
    invariant("correct language") do |output, input|
      LanguageDetector.detect(output[:comment]) == input[:thread_language]
    end
  end
end
```

**Co działa teraz:**
- Hash.schema input z automatyczną interpolacją kluczy (`{thread_language}`, `{thread_title}`)
- Hash.schema output z symbol keys
- Invarianty z 2-arity `|output, input|` do cross-walidacji
- Prompt AST zamiast string concatenation
- StepResult z trace (messages, model, latency_ms, usage)

**🗓 ROADMAP:** `ruby_llm-contract eval` do sprawdzenia regresji przed deployem (wymaga Eval::Dataset).

---

## PROBLEM 2: Silent failures w klasyfikacji threadów ✅ WORKS NOW

### Gdzie boli
`ThreadClassification` batchuje 15 threadów na raz i klasyfikuje PROMO/FILLER/SKIP. Ale:
- Jeśli model zwróci złą klasyfikację → thread ląduje w złym bucketcie
- Jeśli `relevance_score` jest niespójny z klasyfikacją → nikt tego nie złapie
- `LlmResultMapper` ma fallback pozycyjny gdy model przepisze ID — to maskuje błędy

### Jak to wygląda dziś
Thread o crochecie dostaje PROMO i relevance 8 dla SaaS produktu. Nikt tego nie widzi aż do code review wygenerowanego planu.

### Jak to wygląda z ruby_llm-contract
```ruby
class ClassifyThreadBatch < RubyLLM::Contract::Step::Base
  input_type  Types::Array.of(Types::Hash)
  output_type Types::Array.of(Types::Hash)

  prompt do
    system "Classify each thread as PROMO, FILLER, or SKIP."
    rule "Return a JSON array with id, classification, and relevance_score for each thread."
    user "{input}"
  end

  contract do
    parse :json

    invariant("all IDs must match input") do |output, input|
      output.map { |r| r[:id] }.sort == input.map { |t| t[:id] }.sort
    end

    invariant("PROMO must have relevance >= 5") do |output|
      output.select { |r| r[:classification] == "PROMO" }
            .all? { |r| r[:relevance_score] >= 5 }
    end

    invariant("classification must be valid enum") do |output|
      output.all? { |r| %w[PROMO FILLER SKIP].include?(r[:classification]) }
    end
  end
end
```

**Co działa teraz:**
- 2-arity invariant do sprawdzenia ID match między input a output
- Enum validation na klasyfikacji
- Score/classification consistency check
- Wszystkie invarianty zbierane (no short-circuit) — widzisz WSZYSTKIE problemy na raz

---

## PROBLEM 3: Language mismatch wykrywany za późno ✅ WORKS NOW

### Gdzie boli
`CommentLlmCaller#language_mismatch_ids` — dopiero PO wygenerowaniu komentarza sprawdza czy jest w dobrym języku. Marnuje tokeny, czas, retry.

### Jak to wygląda z ruby_llm-contract
Invariant na outputcie stepu z dostępem do inputu:
```ruby
invariant("language matches thread") do |output, input|
  LanguageDetector.detect(output[:comment]) == input[:thread_language]
end
```
Fail → status `:validation_failed` → caller decyduje o retry.

**Co działa teraz:**
- 2-arity invariant z dostępem do inputu
- Fail fast z czytelnym błędem w `validation_errors`
- Trace zachowany nawet przy failure

**🗓 ROADMAP:** Retry policy (max 3 próby, fallback prompt).

---

## PROBLEM 4: Brak regression safety przy zmianie persona/voice 🗓 ROADMAP

### Gdzie boli
`PERSONA_TEXT` i `VOICE_LINES` w `comment_prompts.rb` definiują osobowość bota. Zmiana np. "typo-prone" na "clean writing" zmienia CAŁY output — ton, styl, długość. Dziś nie ma sposobu zmierzyć wpływ.

### Jak to będzie wyglądać z ruby_llm-contract (planowane)
```ruby
# Dataset ze złotymi przykładami
dataset "promo_comments" do
  case input: { thread_title: "Best tool for invoicing?", ... },
       expected_traits: { tone: :casual, has_link: true, length: 80..300 }
  case input: { thread_title: "Jak wybrać program do faktur?", ... },
       expected_traits: { language: "pl", tone: :casual }
end

# Regression check
regression do
  compare old: "persona_v3", new: "persona_v4"
  reject_if score_drop > 0.05
end
```

CLI:
```bash
ruby_llm-contract eval spec/datasets/promo_comments.rb
# => 2 cases regressed: case_3 language mismatch, case_7 tone shift
```

**Co działa teraz:** Nic z powyższego — wymaga `Eval::Dataset`, `Regression::Baseline`, CLI.

**Co MOŻNA zrobić dziś:** Ręczne dataset testy z Test Adapterem + RSpec — definiujesz cases, odpalasz step z canned responses, sprawdzasz invarianty. Brak automatycznego scoringu.

---

## PROBLEM 5: AiCallLog to za mało na debug ⚠️ PARTIAL

### Gdzie boli
`AiCallLog` loguje prompt i response, ale:
- truncated do 10k znaków (wielkie prompty się ucinają)
- brak structured trace (który step, jaki input, jaki parsed output)
- brak replay capability
- brak porównania dwóch runów

### Jak to wygląda z ruby_llm-contract
Każdy step automatycznie generuje trace w `StepResult`:
```ruby
result = ClassifyThreadBatch.run(threads, context: { adapter: adapter, model: "gpt-5-mini" })

result.trace
# => {
#   messages: [{role: :system, content: "..."}, {role: :user, content: "..."}],
#   model: "gpt-5-mini",
#   latency_ms: 2340,
#   usage: {input_tokens: 3200, output_tokens: 890}
# }

result.raw_output      # pełny string, bez truncation
result.parsed_output   # sparsowany JSON z symbol keys
result.validation_errors # ["PROMO must have relevance >= 5"]
```

**Co działa teraz:**
- Structured trace per step (messages, model, latency, usage)
- Pełny raw output bez truncation
- Parsed output + validation errors

**🗓 ROADMAP:** `trace_id`, persisted trace store, `trace.replay(run_id)`, `trace.compare(run_a, run_b)`.

---

## PROBLEM 6: Prompt composition jest kruche ✅ WORKS NOW

### Gdzie boli
Prompt assembly w `comment_prompts.rb`:
```ruby
[
  product_section,
  pages_section,
  section("URL SELECTION", promo_url_selection_rules),
  section("FORMAT", format_lines),
  audience_section,
  items_section
].compact.join("\n\n")
```

To jest string concatenation. Dodanie sekcji, zmiana kolejności, usunięcie fragmentu — nie ma żadnej ochrony. Zapomniałeś `compact`? Masz podwójne `\n\n`. Źle nazwałeś sekcję? Nikt nie złapie.

### Jak to wygląda z ruby_llm-contract
```ruby
prompt do
  system "You are a helpful community member with expertise in #{product_domain}."
  rule "Write in {thread_language}."
  rule "No markdown headers."
  rule "Include link naturally, max once."
  section "PRODUCT", "Domain: acme.com\nDescription: Invoicing tool for freelancers"
  section "PAGES", "#{promoted_pages_text}"
  section "URL SELECTION", "Only link to pages relevant to the thread topic."
  example input: "Best invoicing tool?", output: '{"comment":"I use Acme for my freelance invoicing..."}'
  user "Thread: {thread_title}\n\n{thread_selftext}"
end
```

**Co działa teraz:**
- Prompt AST: 5 typów node'ów (system, rule, section, example, user)
- Immutable — po zbudowaniu nie da się zmodyfikować
- Deterministyczny rendering do messages array
- Section nodes jako osobne system messages
- Example nodes jako user/assistant pairs
- Hash interpolation we wszystkich node'ach

---

## PROBLEM 7: Brak izolacji — cascade failure ✅ WORKS NOW

### Gdzie boli
Jeśli `TargetAudience` (stage 1) zwróci słaby `product_context`:
- `SearchExpansion` generuje złe keywords
- `ThreadSearchContext` szuka nie tam
- `Classification` klasyfikuje nierelewantne thready jako PROMO
- Komentarze są off-topic

Cały pipeline się sypie, ale error widać dopiero na końcu.

### Jak to wygląda z ruby_llm-contract
Każdy step ma kontrakt. Stage 1 pada → wiadomo natychmiast:
```ruby
class GenerateTargetAudience < RubyLLM::Contract::Step::Base
  input_type  Types::String
  output_type Types::Hash

  prompt do
    system "Analyze the product at this URL and generate a target audience profile."
    rule "Return JSON with locale, product_description, and audience_groups."
    user "{input}"
  end

  contract do
    parse :json

    invariant("has at least 1 audience group") do |o|
      o[:audience_groups].is_a?(Array) && o[:audience_groups].size >= 1
    end

    invariant("locale is valid ISO 639-1") do |o|
      o[:locale].is_a?(String) && o[:locale].match?(/\A[a-z]{2}\z/)
    end

    invariant("product description present") do |o|
      o[:product_description].is_a?(String) && o[:product_description].strip.size > 10
    end
  end
end

result = GenerateTargetAudience.run(url, context: { adapter: adapter })
if result.failed?
  # Fail fast — nie puszczaj dalej do SearchExpansion
  raise "Audience generation failed: #{result.validation_errors.join(', ')}"
end
```

**Co działa teraz:**
- Kontrakt na każdym stepie — fail fast z czytelnym statusem
- `result.failed?` / `result.ok?` do decyzji o kontynuacji
- Validation errors z opisami invariantów
- Trace zachowany nawet przy failure

**🗓 ROADMAP:** `Pipeline::Base` z automatycznym `depends_on` i propagacją failure:
```ruby
class RedditPromoPipeline < RubyLLM::Contract::Pipeline::Base
  step GenerateTargetAudience, as: :audience
  step BuildPageContexts, as: :pages, depends_on: :audience
  step DiscoverSubreddits, as: :discovery, depends_on: [:audience, :pages]
  step ClassifyThreadBatch, as: :classify, depends_on: :discovery
  step GenerateComment, as: :comment, depends_on: :classify
end
```

---

## PROBLEM 8: Testowanie promptów jest fake ⚠️ PARTIAL

### Gdzie boli
VCR cassettes nagrywają response i go odtwarzają. To testuje:
- ✅ parsing
- ✅ error handling
- ❌ jakość promptu
- ❌ regresję po zmianie
- ❌ coverage edge cases

### Jak to wygląda z ruby_llm-contract
```ruby
RSpec.describe ClassifyThreadBatch do
  let(:adapter) { RubyLLM::Contract::Adapters::Test.new(response: valid_json) }

  it "satisfies contract on valid output" do
    result = described_class.run(sample_threads, context: { adapter: adapter })
    expect(result.status).to eq(:ok)
    expect(result.validation_errors).to be_empty
  end

  it "catches invalid classification enum" do
    bad_adapter = RubyLLM::Contract::Adapters::Test.new(response: invalid_enum_json)
    result = described_class.run(sample_threads, context: { adapter: bad_adapter })
    expect(result.status).to eq(:validation_failed)
    expect(result.validation_errors).to include("classification must be valid enum")
  end

  it "catches ID mismatch between output and input" do
    mismatched_adapter = RubyLLM::Contract::Adapters::Test.new(response: wrong_ids_json)
    result = described_class.run(sample_threads, context: { adapter: mismatched_adapter })
    expect(result.validation_errors).to include("all IDs must match input")
  end
end
```

**Co działa teraz:**
- Test Adapter z canned responses — zero API calls, w pełni deterministyczne
- Contract validation na każdym teście — testuje parsing + invarianty
- Pokrycie edge cases (złe JSON, złe enum, mismatched IDs, puste output)
- StepResult z pełnym trace do debug

**🗓 ROADMAP:**
- `described_class.eval("golden_set")` — dataset-based eval z real LLM
- `satisfy_contract` RSpec matcher
- `match_baseline("v2")` — snapshot regression
- `aggregate_score` — scoring across dataset

---

## Jak wyglądałby refactor pipeline'u

### Przed (obecny flow)
```
RedditPlannerJob
  → TargetAudience concern (inline prompt, parse_llm_json, ad-hoc check)
  → SearchExpansion concern (inline prompt, parse_llm_json, ad-hoc check)
  → ThreadClassification concern (inline prompt, batch, fallback mapper)
  → CommentGeneration concern (inline prompt, concurrent threads, language retry)
```

### Po (z ruby_llm-contract) — działa teraz ✅
```
RedditPlannerJob
  → GenerateTargetAudience.run(url_data, context:)     # typed, contracted, traced
  → BuildPageContexts.run(pages, context:)              # typed, contracted, traced
  → DiscoverSubreddits.run(product_context, context:)   # typed, contracted, traced
  → BuildSearchQueries.run(page_contexts, context:)     # typed, contracted, traced
  → ClassifyThreadBatch.run(threads, context:)           # typed, contracted, traced
  → PlanComment.run(thread, context:)                    # typed, contracted, traced
  → GenerateComment.run(plan, context:)                  # typed, contracted, traced
```

Każdy step: osobna klasa, kontrakt, trace. Caller decyduje o kontynuacji na podstawie `result.ok?`.

### Pipeline composition — 🗓 ROADMAP
```ruby
class RedditPromoPipeline < RubyLLM::Contract::Pipeline::Base
  step GenerateTargetAudience, as: :audience
  step BuildPageContexts, as: :pages, depends_on: :audience
  step DiscoverSubreddits, as: :discovery, depends_on: [:audience, :pages]
  step ClassifyThreadBatch, as: :classify, depends_on: :discovery
  step GenerateComment, as: :comment, depends_on: :classify
end
```

---

## Co NIE trzeba zmieniać

- Reddit API integration — zostaje jak jest
- Solid Queue / job orchestration — zostaje
- AiCallLog — może zostać jako backup, trace z gema go uzupełni
- VCR testy — zostawiasz dla unit testów, dodajesz contract testy obok
- Concurrent thread pool w comment generation — to jest warstwa executora, nie promptu

---

## TL;DR — realne zyski

| Problem | Dziś | Z ruby_llm-contract | Status |
|---------|------|-------------------|--------|
| Zmiana promptu | Ręczny spot-check | Prompt AST + contract enforcement | ✅ NOW |
| Zły output | Odkryty w UI/review | Contract fail fast + validation_errors | ✅ NOW |
| Language mismatch | Retry po fakcie | 2-arity invariant (output, input) | ✅ NOW |
| Cascade failure | Widać na końcu | Fail fast na wadliwym stepie | ✅ NOW |
| Debug | Truncated log + guessing | Structured trace per step | ✅ NOW |
| Prompt composition | String concat | AST z immutability | ✅ NOW |
| Testy | VCR mockuje response | Test Adapter + contract specs | ✅ NOW |
| Regression safety | Yolo deploy | Dataset eval + regression gate | 🗓 ROADMAP |
| Pipeline orchestration | Manual caller logic | Pipeline::Base z depends_on | 🗓 ROADMAP |
| Trace replay/compare | Nie istnieje | trace.replay / trace.compare | 🗓 ROADMAP |
