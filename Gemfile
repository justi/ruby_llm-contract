# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  # faraday-net_http 3.5.0 (2026-10-11) declares no faraday dependency, so a fresh
  # resolve pairs it with faraday 2.0.0, which cannot load it (:net_http is not
  # registered). CI has no lockfile; this floor keeps it on a working pair.
  gem "faraday", ">= 2.14"
  gem "railties", ">= 7.1" # boots a throwaway app in spec/integration/railtie_boot_spec.rb
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.92.0" # pinned: CI has no lockfile, so a floating version drifts from local
  gem "rubycritic", "~> 4.9"
  gem "simplecov", "~> 0.22"
  gem "webmock", "~> 3.25"
end
