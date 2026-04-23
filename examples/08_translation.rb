# frozen_string_literal: true

# =============================================================================
# EXAMPLE 8: Translation pipeline with quality checks
#
# Real-world case: translate product page segments preserving tone,
# length constraints, and key terms. Pipeline:
#
#   1. Extract — find translatable segments with context and max length
#   2. Translate — translate each segment respecting constraints
#   3. Review — quality-check translations (detect untranslated terms,
#      length violations, tone mismatches)
#
# Shows:
#   - Pipeline where each step has a fundamentally different LLM skill
#     (analysis → creative writing → evaluation)
#   - Cross-validation: all segment keys from step 1 must appear in step 2
#   - 2-arity invariant: max_length from extraction enforced on translations
#   - Content quality: detect untranslated source terms left in output
#   - Why 3 steps can't be 1: same model evaluating its own translation
#     has self-evaluation bias — step 3 should ideally use a different model
# =============================================================================

require_relative "../lib/ruby_llm/contract"

# =============================================================================
# STEP 1: Extract translatable segments
#
# Input: raw product page text
# Output: structured segments with context, importance, and max length
# =============================================================================

class ExtractSegments < RubyLLM::Contract::Step::Base
  input_type RubyLLM::Contract::Types::Hash.schema(
    page_text: RubyLLM::Contract::Types::String,
    target_lang: RubyLLM::Contract::Types::String
  )

  output_schema do
    string :source_lang
    string :target_lang
    array :segments, min_items: 1 do
      object do
        string :key, description: "Unique identifier like hero_headline, cta_button"
        string :text, description: "Original text to translate"
        string :context, enum: %w[headline subheadline description cta legal testimonial]
        integer :max_length, description: "Max character count for the translation"
        string :tone, enum: %w[punchy professional casual formal technical]
      end
    end
  end

  prompt do
    system "Extract translatable text segments from a product page."
    rule "Assign each segment a unique key based on its role (e.g., hero_headline, cta_primary)."
    rule "Determine context type and appropriate tone for translation."
    rule "Set max_length based on UI constraints — headlines short, descriptions longer."

    example input: "Ship faster. The deployment platform for modern teams. Try free →",
            output: '{"source_lang":"en","target_lang":"fr","segments":[' \
                    '{"key":"hero_headline","text":"Ship faster","context":"headline","max_length":20,"tone":"punchy"},' \
                    '{"key":"hero_sub","text":"The deployment platform for modern teams","context":"subheadline","max_length":60,"tone":"professional"},' \
                    '{"key":"cta_primary","text":"Try free →","context":"cta","max_length":15,"tone":"punchy"}]}'

    user "Target language: {target_lang}\n\nPage text:\n{page_text}"
  end

  validate("target_lang preserved") do |output, input|
    output[:target_lang] == input[:target_lang]
  end

  validate("unique segment keys") do |o|
    keys = o[:segments].map { |s| s[:key] }
    keys.uniq.length == keys.length
  end
end

# =============================================================================
# STEP 2: Translate segments
#
# Input: extracted segments with context and constraints
# Output: translated segments preserving keys and respecting max_length
# =============================================================================

class TranslateSegments < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    string :source_lang
    string :target_lang
    array :translations, min_items: 1 do
      object do
        string :key
        string :original
        string :translated
        string :context, enum: %w[headline subheadline description cta legal testimonial]
        integer :max_length, description: "Carried through from extraction for downstream validation"
        integer :original_length
        integer :translated_length
      end
    end
  end

  prompt do
    system "Translate product page segments to the target language."
    rule "Preserve tone: headlines punchy, CTAs action-oriented, descriptions natural."
    rule "Respect max_length — abbreviate naturally if needed, never truncate mid-word."
    rule "Keep brand names, product names, and URLs untranslated."
    rule "Carry through max_length from the input segments."
    rule "Include original and translated length for quality tracking."
    user "Source: {source_lang} → Target: {target_lang}\n\nSegments:\n{segments}"
  end

  validate("all segments translated") do |output, input|
    output[:translations].map { |t| t[:key] }.sort ==
      (input[:segments] || []).map { |s| s[:key] }.sort
  end

  validate("translations within max_length") do |output, input|
    segments_by_key = (input[:segments] || []).to_h { |s| [s[:key], s] }
    output[:translations].all? do |t|
      max = segments_by_key.dig(t[:key], :max_length)
      max.nil? || t[:translated].to_s.length <= max
    end
  end

  validate("translations differ from originals") do |o|
    o[:translations].all? { |t| t[:translated] != t[:original] }
  end

  retry_policy models: %w[gpt-4.1-nano gpt-4.1-mini]
end

# =============================================================================
# STEP 3: Review translation quality
#
# Input: original segments + translations
# Output: quality report with per-segment scores and issues
#
# This step uses a DIFFERENT LLM skill (evaluation, not generation).
# A model reviewing its own translations has bias — in production,
# you'd use a different model or temperature for this step.
# =============================================================================

class ReviewTranslations < RubyLLM::Contract::Step::Base
  input_type Hash

  output_schema do
    string :target_lang
    integer :total_segments
    integer :passed_segments
    array :reviews, min_items: 1 do
      object do
        string :key
        string :verdict, enum: %w[pass warning fail]
        string :issue, description: "Empty if pass, description if warning/fail"
      end
    end
  end

  prompt do
    system "Review translations for quality. You are a professional translator and editor."
    rule "Check each translation for: accuracy, natural phrasing, tone match, length vs max_length."
    rule "Pass: translation is accurate, natural, and within max_length."
    rule "Warning: minor issue (slightly awkward phrasing, could be improved)."
    rule "Fail: wrong meaning, untranslated text left in, or translated_length exceeds max_length."
    user "Target language: {target_lang}\n\nTranslations:\n{translations}"
  end

  validate("all translations reviewed") do |output, input|
    output[:reviews].map { |r| r[:key] }.sort ==
      (input[:translations] || []).map { |t| t[:key] }.sort
  end

  validate("counts are consistent") do |o|
    o[:passed_segments] == o[:reviews].count { |r| r[:verdict] == "pass" }
  end

  validate("failed reviews have issues") do |o|
    o[:reviews].reject { |r| r[:verdict] == "pass" }.all? do |r|
      !r[:issue].to_s.strip.empty?
    end
  end

  validate("fail verdict for over-limit translations") do |output, input|
    translations_by_key = (input[:translations] || []).to_h { |t| [t[:key], t] }
    output[:reviews].all? do |r|
      t = translations_by_key[r[:key]]
      next true unless t && t[:max_length] && t[:translated_length]
      next true if t[:translated_length] <= t[:max_length]

      %w[warning fail].include?(r[:verdict])
    end
  end
end

# =============================================================================
# PIPELINE
# =============================================================================

class TranslationPipeline < RubyLLM::Contract::Pipeline::Base
  step ExtractSegments,    as: :extract
  step TranslateSegments,  as: :translate
  step ReviewTranslations, as: :review
end

# =============================================================================
# TEST WITH CANNED RESPONSES
# =============================================================================

page_text = <<~PAGE
  Ship faster with Acme Deploy

  The deployment platform built for modern engineering teams.
  Push to production in seconds, not hours. Zero-downtime deploys,
  instant rollbacks, and real-time logs.

  Start free — no credit card required.

  "Acme Deploy cut our deployment time from 45 minutes to 30 seconds."
  — Sarah Chen, CTO at Widgets Inc.
PAGE

input = { page_text: page_text, target_lang: "fr" }

extract_response = {
  source_lang: "en", target_lang: "fr",
  segments: [
    { key: "hero_headline", text: "Ship faster with Acme Deploy", context: "headline", max_length: 40, tone: "punchy" },
    { key: "hero_sub", text: "The deployment platform built for modern engineering teams", context: "subheadline",
      max_length: 80, tone: "professional" },
    { key: "feature_1", text: "Push to production in seconds, not hours", context: "description", max_length: 60,
      tone: "punchy" },
    { key: "feature_2", text: "Zero-downtime deploys, instant rollbacks, and real-time logs", context: "description",
      max_length: 80, tone: "technical" },
    { key: "cta_primary", text: "Start free — no credit card required", context: "cta", max_length: 50,
      tone: "punchy" },
    { key: "testimonial", text: "Acme Deploy cut our deployment time from 45 minutes to 30 seconds.",
      context: "testimonial", max_length: 100, tone: "formal" }
  ]
}.to_json

translate_response = {
  source_lang: "en", target_lang: "fr",
  translations: [
    { key: "hero_headline", original: "Ship faster with Acme Deploy",
      translated: "Déployez plus vite avec Acme Deploy", context: "headline", max_length: 40, original_length: 29, translated_length: 36 },
    { key: "hero_sub", original: "The deployment platform built for modern engineering teams",
      translated: "La plateforme de déploiement pour les équipes d'ingénierie modernes", context: "subheadline", max_length: 80, original_length: 57, translated_length: 67 },
    { key: "feature_1", original: "Push to production in seconds, not hours",
      translated: "En production en secondes, pas en heures", context: "description", max_length: 60, original_length: 41, translated_length: 41 },
    { key: "feature_2", original: "Zero-downtime deploys, instant rollbacks, and real-time logs",
      translated: "Déploiements sans interruption, rollbacks instantanés et logs en temps réel", context: "description", max_length: 80, original_length: 60, translated_length: 75 },
    { key: "cta_primary", original: "Start free — no credit card required",
      translated: "Essai gratuit — sans carte bancaire", context: "cta", max_length: 50, original_length: 36, translated_length: 36 },
    { key: "testimonial", original: "Acme Deploy cut our deployment time from 45 minutes to 30 seconds.",
      translated: "Acme Deploy a réduit notre temps de déploiement de 45 minutes à 30 secondes.", context: "testimonial", max_length: 100, original_length: 66, translated_length: 76 }
  ]
}.to_json

review_response = {
  target_lang: "fr", total_segments: 6, passed_segments: 5,
  reviews: [
    { key: "hero_headline", verdict: "pass", issue: "" },
    { key: "hero_sub", verdict: "pass", issue: "" },
    { key: "feature_1", verdict: "pass", issue: "" },
    { key: "feature_2", verdict: "warning", issue: "Slightly long — consider shorter phrasing for mobile" },
    { key: "cta_primary", verdict: "pass", issue: "" },
    { key: "testimonial", verdict: "pass", issue: "" }
  ]
}.to_json

puts "=" * 60
puts "TRANSLATION PIPELINE: en → fr"
puts "=" * 60

# Run each step with its own adapter
puts "\n--- Step 1: Extract segments ---"
r1 = ExtractSegments.run(input, context: { adapter: RubyLLM::Contract::Adapters::Test.new(response: extract_response) })
puts "Status: #{r1.status} | Segments: #{r1.parsed_output[:segments].length}"
r1.parsed_output[:segments].each do |s|
  puts "  #{s[:key].ljust(16)} [#{s[:context].ljust(12)}] #{s[:text][0..50]}... (max: #{s[:max_length]})"
end

puts "\n--- Step 2: Translate ---"
r2 = TranslateSegments.run(r1.parsed_output,
                           context: { adapter: RubyLLM::Contract::Adapters::Test.new(response: translate_response) })
puts "Status: #{r2.status}"
r2.parsed_output[:translations].each do |t|
  len_ok = t[:translated_length] <= 80 ? "✓" : "⚠"
  puts "  #{len_ok} #{t[:key].ljust(16)} #{t[:translated][0..60]}"
end

puts "\n--- Step 3: Review ---"
r3 = ReviewTranslations.run(r2.parsed_output,
                            context: { adapter: RubyLLM::Contract::Adapters::Test.new(response: review_response) })
puts "Status: #{r3.status} | Passed: #{r3.parsed_output[:passed_segments]}/#{r3.parsed_output[:total_segments]}"
r3.parsed_output[:reviews].each do |r|
  icon = { "pass" => "✓", "warning" => "⚠", "fail" => "✗" }[r[:verdict]]
  line = "  #{icon} #{r[:key]}"
  line += " — #{r[:issue]}" unless r[:issue].to_s.empty?
  puts line
end

# =============================================================================
# INVARIANT CATCHES
# =============================================================================

puts "\n\n--- Invariant catches: missing translation ---"
incomplete = {
  source_lang: "en", target_lang: "fr",
  translations: [
    { key: "hero_headline", original: "Ship faster", translated: "Déployez vite", context: "headline", original_length: 11, translated_length: 13 }
    # Missing 5 other segments!
  ]
}.to_json

r_bad = TranslateSegments.run(r1.parsed_output,
                              context: { adapter: RubyLLM::Contract::Adapters::Test.new(response: incomplete) })
puts "Status: #{r_bad.status}"
puts "Errors: #{r_bad.validation_errors}"

puts "\n--- Invariant catches: translation too long ---"
too_long = translate_response.gsub(
  "Déployez plus vite avec Acme Deploy",
  "Déployez beaucoup plus rapidement et efficacement avec la plateforme Acme Deploy"
)
r_long = TranslateSegments.run(r1.parsed_output,
                               context: { adapter: RubyLLM::Contract::Adapters::Test.new(response: too_long) })
puts "Status: #{r_long.status}"
puts "Errors: #{r_long.validation_errors}"

puts "\n--- Invariant catches: untranslated (echoed back) ---"
echoed = translate_response.gsub("Essai gratuit — sans carte bancaire", "Start free — no credit card required")
r_echo = TranslateSegments.run(r1.parsed_output,
                               context: { adapter: RubyLLM::Contract::Adapters::Test.new(response: echoed) })
puts "Status: #{r_echo.status}"
puts "Errors: #{r_echo.validation_errors}"

# =============================================================================
# SUMMARY
#
# 3 steps, 3 different LLM skills:
#   1. Extract (analysis) — find segments, assign context and constraints
#   2. Translate (creative) — translate respecting tone and length
#   3. Review (evaluation) — quality-check each translation
#
# Why 3 steps, not 1:
#   - Each step has focused attention and its own schema
#   - Step 3 evaluates step 2's work (shouldn't self-evaluate)
#   - If extraction fails, no tokens wasted on translation
#   - Each step independently testable and retryable
#
# Invariants catch:
#   - Missing translations (not all segments covered)
#   - Translation too long (exceeds max_length from step 1)
#   - Untranslated text (model echoed back original)
#   - Review inconsistency (counts don't match verdicts)
# =============================================================================
