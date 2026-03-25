# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  primary_coverage :branch

  add_filter "/spec/"
  add_filter "/examples/"
  add_filter "/internal/"
  add_filter "/tmp/"

  track_files "lib/**/*.rb"

  if ENV["CI"] == "true" || ENV["SIMPLECOV_STRICT"] == "1"
    minimum_coverage line: 89
    minimum_coverage branch: 75
  end

  command_name "RSpec"
end
