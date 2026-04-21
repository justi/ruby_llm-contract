# frozen_string_literal: true

require "stringio"
require "timeout"

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

  describe "deprecation: :adapter_error in default retry_on" do
    before { described_class.reset_deprecation_warnings! }

    it "warns only once per process even across many policy constructions" do
      expect do
        5.times { described_class.new { attempts 3 } }
      end.to output(/\A\[ruby_llm-contract\] DEPRECATION.*\n\z/m).to_stderr
    end

    it "warns when attempts > 1 without escalation and default retry_on" do
      expect { described_class.new { attempts 3 } }
        .to output(/DEPRECATION.*adapter_error.*0\.7\.0/m).to_stderr
    end

    it "does not warn when user explicitly passes retry_on via DSL" do
      expect do
        described_class.new do
          attempts 3
          retry_on :validation_failed, :parse_error, :adapter_error
        end
      end.not_to output(/DEPRECATION/).to_stderr
    end

    it "does not warn when user explicitly passes retry_on keyword" do
      expect { described_class.new(attempts: 3, retry_on: %i[adapter_error parse_error]) }
        .not_to output(/DEPRECATION/).to_stderr
    end

    it "does not warn with escalation chain of 2+ models (:adapter_error is meaningful there)" do
      expect { described_class.new { escalate "nano", "mini" } }
        .not_to output(/DEPRECATION/).to_stderr
    end

    it "warns when escalate has only one model (no real fallback — same model every attempt)" do
      expect do
        described_class.new do
          attempts 3
          escalate "nano"
        end
      end.to output(/DEPRECATION.*adapter_error/m).to_stderr
    end

    it "does not warn when max_attempts is 1 (no retry happens anyway)" do
      expect { described_class.new }.not_to output(/DEPRECATION/).to_stderr
    end

    describe "thread safety (Mutex) — GH PR #12 review" do
      # Captures Warning.warn output into a StringIO across threads.
      # Warning.warn defaults to writing to $stderr in MRI, and $stderr is
      # a shared global, so swapping it for the duration of the block
      # captures output from all threads.
      def capture_concurrent_stderr
        buffer = StringIO.new
        original = $stderr
        $stderr = buffer
        yield
        buffer.string
      ensure
        $stderr = original
      end

      it "emits exactly once under stress (50 concurrent constructions)" do
        output = capture_concurrent_stderr do
          threads = Array.new(50) do
            Thread.new { described_class.new { attempts 3 } }
          end
          threads.each(&:join)
        end

        expect(output.scan(/DEPRECATION/).size).to eq(1)
      end

      it "stays correct even when the check-then-set window is forced open" do
        # Adversarial scheduler: every time a thread reads the flag and sees
        # `false`, it yields the scheduler before the caller gets a chance to
        # set the flag. Without the Mutex'd re-check in
        # warn_adapter_error_default_deprecated!, multiple threads would
        # observe `false`, both enter the critical region, and both emit.
        # The double-checked lock inside synchronize catches this.
        allow(described_class).to receive(:adapter_error_default_warned).and_wrap_original do |original|
          value = original.call
          Thread.pass unless value
          value
        end

        output = capture_concurrent_stderr do
          threads = Array.new(20) do
            Thread.new { described_class.new { attempts 3 } }
          end
          threads.each(&:join)
        end

        expect(output.scan(/DEPRECATION/).size).to eq(1)
      end

      it "re-emits after reset even under concurrent pressure" do
        # First burst: all threads contend; exactly one warning.
        first_output = capture_concurrent_stderr do
          Array.new(10) { Thread.new { described_class.new { attempts 3 } } }.each(&:join)
        end
        expect(first_output.scan(/DEPRECATION/).size).to eq(1)

        described_class.reset_deprecation_warnings!

        # After reset a second burst must emit exactly one more warning
        # (not zero — flag was cleared; not two — mutex still dedupes).
        second_output = capture_concurrent_stderr do
          Array.new(10) { Thread.new { described_class.new { attempts 3 } } }.each(&:join)
        end
        expect(second_output.scan(/DEPRECATION/).size).to eq(1)
      end

      it "does not deadlock when reset is called between constructions" do
        expect do
          Timeout.timeout(2) do
            3.times do
              described_class.new { attempts 3 }
              described_class.reset_deprecation_warnings!
            end
          end
        end.not_to raise_error
      end

      it "exposes the mutex as a Mutex instance (SOLID: depend on abstraction, not duck-typing)" do
        expect(described_class.deprecation_mutex).to be_a(Mutex)
      end
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
      expect do
        described_class.new(attempts: 0)
      end.to raise_error(ArgumentError, /attempts must be at least 1/)
    end

    it "raises ArgumentError for keyword attempts: -1" do
      expect do
        described_class.new(attempts: -1)
      end.to raise_error(ArgumentError, /attempts must be at least 1/)
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

    it "keyword models: works with config_list" do
      policy = described_class.new(models: %w[gpt-4.1-nano gpt-4.1-mini])
      expect(policy.config_list).to eq([{ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini" }])
    end
  end

  describe "config-based features (v0.6)" do
    describe "#config_list with string args" do
      it "returns normalized configs for string escalation" do
        policy = described_class.new { escalate "gpt-4.1-nano", "gpt-4.1-mini" }
        expect(policy.config_list).to eq([{ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini" }])
      end
    end

    describe "#config_list with hash args" do
      it "preserves reasoning_effort in config" do
        policy = described_class.new do
          escalate({ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini", reasoning_effort: "high" })
        end

        expect(policy.config_list).to eq([
                                           { model: "gpt-4.1-nano" },
                                           { model: "gpt-4.1-mini", reasoning_effort: "high" }
                                         ])
      end
    end

    describe "#config_list with mixed args" do
      it "normalizes strings and hashes correctly" do
        policy = described_class.new do
          escalate "gpt-4.1-nano", { model: "gpt-4.1-mini", reasoning_effort: "high" }
        end

        expect(policy.config_list).to eq([
                                           { model: "gpt-4.1-nano" },
                                           { model: "gpt-4.1-mini", reasoning_effort: "high" }
                                         ])
      end
    end

    describe "#config_for_attempt" do
      let(:policy) do
        described_class.new do
          escalate(
            { model: "gpt-4.1-nano" },
            { model: "gpt-4.1-mini", reasoning_effort: "high" }
          )
        end
      end

      it "returns correct config per attempt" do
        expect(policy.config_for_attempt(0, {})).to eq({ model: "gpt-4.1-nano" })
        expect(policy.config_for_attempt(1, {})).to eq({ model: "gpt-4.1-mini", reasoning_effort: "high" })
      end

      it "returns last config for overflow index" do
        expect(policy.config_for_attempt(5, {})).to eq({ model: "gpt-4.1-mini", reasoning_effort: "high" })
      end

      it "returns default_config when no configs" do
        empty_policy = described_class.new { attempts 3 }
        default = { model: "gpt-5-mini" }
        expect(empty_policy.config_for_attempt(0, default)).to eq(default)
        expect(empty_policy.config_for_attempt(2, default)).to eq(default)
      end
    end

    describe "#model_for_attempt backward compatibility" do
      it "returns string model name even with hash configs" do
        policy = described_class.new do
          escalate({ model: "gpt-4.1-nano", reasoning_effort: "low" }, { model: "gpt-4.1-mini" })
        end

        expect(policy.model_for_attempt(0, "default")).to eq("gpt-4.1-nano")
        expect(policy.model_for_attempt(1, "default")).to eq("gpt-4.1-mini")
      end
    end

    describe "#model_list" do
      it "returns frozen array of model name strings" do
        policy = described_class.new do
          escalate({ model: "gpt-4.1-nano" }, { model: "gpt-4.1-mini", reasoning_effort: "high" })
        end

        list = policy.model_list
        expect(list).to eq(%w[gpt-4.1-nano gpt-4.1-mini])
        expect(list).to be_frozen
      end
    end

    describe "normalize_config raises on invalid type" do
      it "raises ArgumentError for non-String/Hash via escalate" do
        expect do
          described_class.new { escalate 42 }
        end.to raise_error(ArgumentError, /Expected String or Hash, got Integer/)
      end

      it "raises ArgumentError for Symbol via escalate" do
        expect do
          described_class.new { escalate :some_model }
        end.to raise_error(ArgumentError, /Expected String or Hash, got Symbol/)
      end
    end
  end
end
