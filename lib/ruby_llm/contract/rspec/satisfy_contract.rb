# frozen_string_literal: true

RSpec::Matchers.define :satisfy_contract do
  match do |result|
    @result = result
    result.respond_to?(:ok?) && result.ok?
  end

  failure_message do
    lines = ["expected step result to satisfy contract, but got status: #{@result.status}"]

    if @result.respond_to?(:validation_errors) && @result.validation_errors.any?
      lines << ""
      lines << "Validation errors:"
      @result.validation_errors.each { |e| lines << "  - #{e}" }
    end

    if @result.respond_to?(:raw_output) && @result.raw_output
      output = @result.raw_output.to_s
      output = "#{output[0, 200]}..." if output.size > 200
      lines << ""
      lines << "Raw output: #{output}"
    end

    lines.join("\n")
  end

  failure_message_when_negated do
    "expected step result NOT to satisfy contract, but it passed with status: :ok"
  end
end
