---
id: ADR-0012
decision_type: adr
status: Proposed
created: 2026-03-23
summary: "Migrate all 5 persona_tool LLM services to ruby_llm-contract"
owners:
  - justi
---

# ADR-0012: persona_tool Full Migration

## Context

persona_tool has 5 LLM services using raw HTTP calls (LlmClient). One (gate_question_generator) was migrated to ruby_llm-contract. Migration revealed 16 DX issues, all fixed in 0.2.0-0.2.2.

Goal: migrate remaining 4 services. This validates the gem on the hardest real-world cases and eliminates ~400 lines of boilerplate (LlmClient, retry, JSON parsing, error handling).

## Services by migration difficulty

### 1. EvaluatePersonaJob — MEDIUM (178 lines → ~40 lines)

**What it does:** Evaluates a persona against a product proposition. Returns 12 structured fields (first_reaction, gate_answer, pain_level, barrier, trigger, etc.).

**Current flow:**
- Builds prompt from EvaluationSchema + persona profile + proposition
- Calls LLM with JSON schema
- Retries 3x on failure
- Saves evaluation fields to DB
- Broadcasts Turbo Stream

**Contract design:**
```ruby
class EvaluatePersona < RubyLLM::Contract::Step::Base
  model "gpt-4.1-mini"
  temperature 0.8

  prompt do |input|
    system "You are roleplaying as #{input[:persona_name]}."
    section "PERSONA", input[:persona_profile]
    section "PRODUCT", input[:proposition_description]
    rule "Answer as this persona would. Be authentic."
    user EvaluationSchema.prompt_instructions
  end

  output_schema do
    string :first_reaction
    string :gate_answer, enum: %w[yes no]
    string :current_solution
    integer :pain_level, minimum: 1, maximum: 10
    string :trigger
    string :would_replace, enum: %w[yes no maybe]
    string :what_do_instead
    string :what_works
    string :what_doesnt
    string :barrier
    string :suggestion
    string :minority_view
  end

  validate("gate_answer is definitive") { |o| %w[yes no].include?(o[:gate_answer]) }
  validate("pain_level realistic") { |o| o[:pain_level].between?(1, 10) }
  validate("first_reaction substantive") { |o| o[:first_reaction].to_s.split.length >= 5 }

  retry_policy models: %w[gpt-4.1-mini gpt-4.1]
end
```

**around_call for AiCallLog:**
```ruby
EvaluatePersona.around_call do |step, input, result|
  AiCallLog.create!(
    model: result.trace.model,
    latency_ms: result.trace.latency_ms,
    input_tokens: result.trace.usage[:input_tokens],
    output_tokens: result.trace.usage[:output_tokens],
    cost: result.trace.cost,
    status: result.status
  )
end
```

**Eval:**
```ruby
EvaluatePersona.define_eval("smoke") do
  add_case "tech-savvy user",
    input: { persona_name: "Alex", persona_profile: "Senior dev, 35, uses 10 SaaS tools",
             proposition_description: "AI code review tool" },
    expected: { gate_answer: /yes|no/ }

  add_case "non-target user",
    input: { persona_name: "Maria", persona_profile: "Retired teacher, 68, uses email only",
             proposition_description: "AI code review tool" },
    expected: { gate_answer: "no", pain_level: 1..3 }
end
```

### 2. ContrastiveAnalyzer — MEDIUM (107 lines → ~35 lines)

**What it does:** Compares YES/NO evaluation groups, finds behavioral patterns, generates refined generation_config.

**Contract design:**
```ruby
class AnalyzeContrastive < RubyLLM::Contract::Step::Base
  model "gpt-4.1"
  input_type Hash

  prompt do |input|
    system "You analyze persona evaluation results."
    section "YES GROUP (passed gate)", input[:yes_evaluations].to_json
    section "NO GROUP (rejected)", input[:no_evaluations].to_json
    rule "Identify behavioral patterns distinguishing converters from non-converters."
    user "Analyze and produce archetype + generation_config."
  end

  output_schema do
    string :archetype
    string :yes_patterns
    string :no_patterns
    string :key_differentiators
    object :generation_config do
      array :ages do; integer; end
      array :professions do; string; end
      array :seniority_levels do
        string :value, enum: %w[junior mid senior lead executive]
      end
    end
  end

  validate("archetype is 3-5 sentences") { |o| o[:archetype].to_s.split(". ").length.between?(2, 6) }
  validate("has differentiators") { |o| o[:key_differentiators].to_s.split.length >= 10 }
end
```

### 3. PersonaDistiller — EASY (73 lines → ~25 lines)

**What it does:** Analyzes top personas, generates config for producing more like them.

**Contract design:**
```ruby
class DistillPersonas < RubyLLM::Contract::Step::Base
  model "gpt-4.1-mini"
  input_type Hash

  prompt do |input|
    system "Analyze high-scoring personas and extract generation patterns."
    section "TOP PERSONAS", input[:persona_profiles].to_json
    user "Generate a config to produce more personas like these."
  end

  output_schema do
    array :ages do; integer; end
    array :professions do; string; end
    array :seniority_levels do; string; end
    array :company_size do; string; end
    array :job_roles do; string; end
    array :skills do; string; end
    array :years_of_experience do; integer; end
  end

  validate("ages are realistic") { |o| o[:ages].all? { |a| a.between?(18, 80) } }
  validate("at least 3 professions") { |o| o[:professions].length >= 3 }
end
```

### 4. PersonaGenerator — HARD (299 lines → ~80 lines)

**What it does:** Generates N synthetic personas in parallel batches.

**Challenges for contract:**
- **Parallel batch generation** — runs N threads, each calling LLM
- **Fill remaining** — retries failed batches
- **Verbalized Sampling** — separate LLM call to expand seed lists
- **Post-processing** — saves to DB, deduplicates

**Contract design — two steps + orchestrator:**

```ruby
# Step 1: Expand seed lists (verbalized sampling)
class ExpandSeedLists < RubyLLM::Contract::Step::Base
  model "gpt-4.1-nano"
  temperature 1.0

  prompt do |input|
    system "Generate low-probability variations."
    user "Base list: #{input[:base_list].join(", ")}. Generate #{input[:count]} variations."
  end

  output_schema do
    array :responses do
      object do
        string :value
        number :probability, minimum: 0.0, maximum: 1.0
      end
    end
  end

  validate("probability below max") do |o, input|
    max_p = input[:max_probability] || 0.1
    o[:responses].all? { |r| r[:probability] <= max_p }
  end
end

# Step 2: Generate persona batch
class GeneratePersonaBatch < RubyLLM::Contract::Step::Base
  model "gpt-4.1-mini"
  temperature 0.9

  prompt do |input|
    system "Generate synthetic personas matching constraints."
    section "CONSTRAINTS", input[:constraints]
    section "EXISTING NAMES", input[:existing_names].join(", ")
    user "Generate #{input[:batch_size]} unique personas."
  end

  output_schema do
    array :personas do
      object do
        string :name
        integer :age
        string :nationality
        string :profession
        string :job_title
        string :family_status
        string :education
        string :income
        string :location
        string :tech_level, enum: %w[minimal basic intermediate advanced expert]
        string :skills
        string :company_context
        string :employment_status
        integer :years_of_experience
      end
    end
  end

  validate("unique names") { |o| o[:personas].map { |p| p[:name] }.uniq.length == o[:personas].length }
  validate("all have age") { |o| o[:personas].all? { |p| p[:age].between?(18, 80) } }

  retry_policy models: %w[gpt-4.1-mini gpt-4.1]
end
```

**Orchestrator stays in Rails service** — parallel threading, DB saves, fill-remaining logic is application concern, not contract concern:

```ruby
class PersonaGenerator
  def call
    expand_seed_lists!
    generate_in_parallel
    fill_remaining!
  end

  private

  def generate_batch(batch_num)
    GeneratePersonaBatch.run(
      { batch_size: BATCH_SIZE, constraints: constraints, existing_names: names },
      context: { model: "gpt-4.1-mini" }
    )
  end
end
```

### 5. ReportGenerator — SKIP for now

**Reason:** Output is Markdown, not JSON. The gem is optimized for structured JSON output. ReportGenerator's value is in caching, fallback, and formatting — not in contract validation. Migration would add complexity without clear benefit.

## Migration order

1. **PersonaDistiller** (easiest, ~25 lines) — warm up
2. **EvaluatePersonaJob** (medium, ~40 lines) — highest call volume, biggest AiCallLog impact
3. **ContrastiveAnalyzer** (medium, ~35 lines) — needs generation_config validation
4. **PersonaGenerator** (hardest, ~80 lines) — parallel batches, two steps
5. **ReportGenerator** — skip (Markdown output, not JSON)

## Success criteria

- All 4 migrated services pass existing test suite
- AiCallLog populated via around_call (no manual logging)
- LlmClient removed from all migrated services
- Each service has define_eval with ≥3 test cases
- compare_models run on each to identify cheapest viable model

## What this proves

If persona_tool runs on ruby_llm-contract with:
- 12-field structured evaluation (EvaluatePersona)
- Parallel batch generation with retry (PersonaGenerator)
- Nested config generation with enum validation (ContrastiveAnalyzer)
- Pattern extraction from data (PersonaDistiller)

...then the gem handles the hardest real-world Ruby/Rails LLM patterns. That's the proof point for adoption.
