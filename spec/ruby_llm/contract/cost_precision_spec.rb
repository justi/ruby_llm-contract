# frozen_string_literal: true

# OptimizeRakeTask's gate lives behind a rake-only require.
require "ruby_llm/contract/rake_task"

# Cost is rendered at two different precisions on purpose, and nothing pinned
# WHICH. The existing assertions match by substring, so "$0.000800" satisfies
# include("$0.0008") - the suite catches a COARSER format but not a finer one,
# which is the direction a unification would move. Measured: swapping every
# "%.4f" to "%.6f" leaves all 1431 examples green. These pin the decimal count,
# so changing a band becomes a visible decision.
#
#   6 decimals - per-call and trace accounting, where sub-cent amounts are the point
#   4 decimals - budget gates and comparison tables, where a human reads the number
RSpec.describe "cost rendering precision" do
  # Not hypothetical: audit_findings_spec uses this as a realistic per-attempt
  # cost (nano at $0.10/M over 100 input + 50 output tokens).
  sub_cent = 0.000015

  describe "per-call accounting keeps 6 decimals" do
    it "renders a sub-cent trace cost without collapsing it to zero" do
      trace = RubyLLM::Contract::Step::Trace.new(model: "m", cost: sub_cent)

      expect(trace.to_s).to include("$0.000015")
    end

    it "names the real ceiling when max_cost refuses a call" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "Analyze {input}"
        max_cost 0.0000001
      end

      result = step.run("hello", context: {
                          adapter: RubyLLM::Contract::Adapters::Test.new(response: '{"v":1}'),
                          model: "gpt-4.1-mini"
                        })

      expect(result.status).to eq(:limit_exceeded)
      # At 4 decimals this would read "max $0.0000", i.e. "your budget is zero"
      # rather than the limit actually configured.
      expect(result.validation_errors.first).to match(/max \$\d\.\d{6}\b/)
    end
  end

  describe "budget gates keep 4 decimals" do
    let(:gate) do
      RubyLLM::Contract::RakeTask::SuiteGate.allocate.tap do |g|
        g.instance_variable_set(:@maximum_cost, 0.05)
      end
    end

    it "renders the suite-gate message at 4 decimals, not 6" do
      msg = gate.send(:cost_abort_message, 1.5)

      expect(msg).to include("$1.5000")
      expect(msg).to include("$0.0500")
      expect(msg).not_to include("$1.500000")
    end

    # The known cost of this band: below 1e-4 it renders as zero. Pinned so the
    # limitation is recorded rather than discovered.
    it "collapses a sub-1e-4 spend to $0.0000" do
      expect(gate.send(:cost_abort_message, sub_cent)).to include("$0.0000")
    end
  end
end
