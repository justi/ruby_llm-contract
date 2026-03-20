# frozen_string_literal: true

RSpec.describe RubyLLM::Contract::Pipeline::Result do
  describe "successful result" do
    let(:result) do
      described_class.new(
        status: :ok,
        step_results: [{ alias: :a, result: "r1" }, { alias: :b, result: "r2" }],
        outputs_by_step: { a: { value: 1 }, b: { value: 2 } }
      )
    end

    it "has :ok status" do
      expect(result.status).to eq(:ok)
    end

    it "is ok" do
      expect(result.ok?).to be true
    end

    it "is not failed" do
      expect(result.failed?).to be false
    end

    it "has no failed_step" do
      expect(result.failed_step).to be_nil
    end

    it "provides outputs_by_step" do
      expect(result.outputs_by_step[:a]).to eq({ value: 1 })
      expect(result.outputs_by_step[:b]).to eq({ value: 2 })
    end

    it "provides step_results" do
      expect(result.step_results.length).to eq(2)
    end

    it "is frozen" do
      expect(result).to be_frozen
    end
  end

  describe "failed result" do
    let(:result) do
      described_class.new(
        status: :validation_failed,
        step_results: [{ alias: :a, result: "r1" }],
        outputs_by_step: {},
        failed_step: :a
      )
    end

    it "has failed status" do
      expect(result.status).to eq(:validation_failed)
    end

    it "is not ok" do
      expect(result.ok?).to be false
    end

    it "is failed" do
      expect(result.failed?).to be true
    end

    it "reports failed_step" do
      expect(result.failed_step).to eq(:a)
    end
  end
end
