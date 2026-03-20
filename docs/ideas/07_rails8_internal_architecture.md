# Rails 8+ Internal Architecture — auditor feedback

## Current state (7/10 rails-way)

### Co jest już railsowe (API surface):
- top-level `validate` zamiast `contract do` wrappera — jak `validates` w modelach
- sensowne domyślności (infer parse z output_type, retry_on defaults)
- wygodne high-level API: `Pipeline.test`, `define_eval`, `run_eval`

### Co nie jest jeszcze railsowe (implementation):
1. **DSL oparte na instance_eval** — `retry_policy do...end` z własnym mini-językiem. Rails 8 preferuje keyword args, DSL tylko tam gdzie naprawdę daje wartość.
2. **Surowe @ivars bez class_attribute** — `@class_validates`, `@eval_definitions` trzymane w raw instance variables. Brak mechaniki dziedziczenia w stylu `class_attribute`. Potencjalnie nieprzewidywalne przy subclassingu.
3. **define_eval/verify** — ergonomiczne ale brzmi jak DSL gema, nie jak ActiveSupport/ActiveModel pattern.

## Proponowane poprawki (auditor)

### 1. class_attribute zamiast raw @ivars
```ruby
# Dziś
@class_validates ||= []
@eval_definitions ||= {}

# Rails-way
class_attribute :_validates, default: []
class_attribute :_eval_definitions, default: {}
```
Daje prawidłowe dziedziczenie — subclass dziedziczy parent validates ale może dodać swoje.

### 2. Keyword args domyślnie, DSL blok tylko dla power users
Już zaczęte w GH-12 (`retry_policy models: [...]`). Rozszerzyć na inne makra.

### 3. ActiveModel-compatible naming
`define_eval` → mogłoby być bardziej railsowe, np. `evaluates` jako makro rejestrujące.

## Status
Notatki z audytu. Do oceny czy warto implementować w v0.1 czy defer do v0.2.
