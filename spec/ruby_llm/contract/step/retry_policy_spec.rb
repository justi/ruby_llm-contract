# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Step::RetryPolicy do
  describe "configuration" do
    it "defaults to 1 attempt" do
      policy = described_class.new
      expect(policy.max_attempts).to eq(1)
    end

    it "sets max attempts" do
      policy = described_class.new { attempts 3 }
      expect(policy.max_attempts).to eq(3)
    end

    it "sets escalation models" do
      policy = described_class.new { escalate "nano", "mini", "full" }
      expect(policy.model_list).to eq(%w[nano mini full])
    end

    it "auto-sets max_attempts from escalation model count" do
      policy = described_class.new { escalate "nano", "mini", "full" }
      expect(policy.max_attempts).to eq(3)
    end

    it "keeps higher max_attempts if set explicitly" do
      policy = described_class.new do
        attempts 5
        escalate "nano", "mini"
      end
      expect(policy.max_attempts).to eq(5)
    end

    it "defaults retryable statuses" do
      policy = described_class.new
      expect(policy.retryable_statuses).to eq(%i[validation_failed parse_error adapter_error])
    end

    it "allows custom retryable statuses" do
      policy = described_class.new { retry_on :parse_error }
      expect(policy.retryable_statuses).to eq([:parse_error])
    end
  end

  describe "#retryable?" do
    let(:policy) { described_class.new }

    it "returns true for retryable statuses" do
      result = RubyLLM::Contract::Step::Result.new(status: :parse_error, raw_output: nil, parsed_output: nil)
      expect(policy.retryable?(result)).to be true
    end

    it "returns false for :ok" do
      result = RubyLLM::Contract::Step::Result.new(status: :ok, raw_output: nil, parsed_output: nil)
      expect(policy.retryable?(result)).to be false
    end

    it "returns false for :input_error (not retryable — bad input won't improve)" do
      result = RubyLLM::Contract::Step::Result.new(status: :input_error, raw_output: nil, parsed_output: nil)
      expect(policy.retryable?(result)).to be false
    end
  end

  describe "#model_for_attempt" do
    context "with escalation models" do
      let(:policy) { described_class.new { escalate "nano", "mini", "full" } }

      it "returns model for each attempt" do
        expect(policy.model_for_attempt(0, "default")).to eq("nano")
        expect(policy.model_for_attempt(1, "default")).to eq("mini")
        expect(policy.model_for_attempt(2, "default")).to eq("full")
      end

      it "returns last model for overflow attempts" do
        expect(policy.model_for_attempt(5, "default")).to eq("full")
      end
    end

    context "without escalation models" do
      let(:policy) { described_class.new { attempts 3 } }

      it "returns default model for all attempts" do
        expect(policy.model_for_attempt(0, "default")).to eq("default")
        expect(policy.model_for_attempt(2, "default")).to eq("default")
      end
    end
  end

  describe "validation" do
    it "raises ArgumentError when attempts is 0" do
      expect { described_class.new { attempts 0 } }.to raise_error(ArgumentError, /attempts must be at least 1/)
    end

    it "raises ArgumentError when attempts is negative" do
      expect { described_class.new { attempts(-1) } }.to raise_error(ArgumentError, /attempts must be at least 1/)
    end

    it "raises ArgumentError when attempts is not an integer" do
      expect { described_class.new { attempts "three" } }.to raise_error(ArgumentError, /attempts must be at least 1/)
    end

    it "raises ArgumentError for keyword attempts: 0" do
      expect {
        described_class.new(attempts: 0)
      }.to raise_error(ArgumentError, /attempts must be at least 1/)
    end

    it "raises ArgumentError for keyword attempts: -1" do
      expect {
        described_class.new(attempts: -1)
      }.to raise_error(ArgumentError, /attempts must be at least 1/)
    end
  end

  describe "keyword API" do
    it "accepts retry_on: keyword to override retryable statuses" do
      policy = described_class.new(retry_on: [:parse_error])
      expect(policy.retryable_statuses).to eq([:parse_error])
    end

    it "accepts models: keyword" do
      policy = described_class.new(models: %w[nano mini])
      expect(policy.model_list).to eq(%w[nano mini])
      expect(policy.max_attempts).to eq(2)
    end

    it "accepts attempts: keyword" do
      policy = described_class.new(attempts: 4)
      expect(policy.max_attempts).to eq(4)
    end
  end
end
