# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "railties", ">= 7.1" # boots a throwaway app in spec/integration/railtie_boot_spec.rb
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.92.0" # pinned: CI has no lockfile, so a floating version drifts from local
  gem "rubycritic", "~> 4.9"
  gem "simplecov", "~> 0.22"
  gem "webmock", "~> 3.25"
end
