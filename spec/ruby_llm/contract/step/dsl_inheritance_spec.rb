# frozen_string_literal: true

require "spec_helper"

# Characterization tests for the DSL inheritance walk in step/dsl.rb.
# Pin the existing behaviour BEFORE refactoring 5 `_explicitly_unset`
# shadow-ivar accessors (model, temperature, max_cost,
# attachment_token_estimate, thinking) onto a single `inherited_attr` /
# `inherited_resettable_attr` macro family backed by an `UNSET` sentinel.
#
# If any of these tests change after the refactor, the new implementation
# has subtly different semantics from what the rest of the gem assumes.
RSpec.describe "Step::Dsl inheritance walk" do
  describe "3-level chain (grandparent -> parent -> grandchild)" do
    it "model: grandchild reads grandparent's value when intermediate parents do not set it" do
      grandparent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        model "gpt-4.1-mini"
      end
      parent = Class.new(grandparent)
      grandchild = Class.new(parent)

      expect(grandchild.model).to eq("gpt-4.1-mini")
    end

    it "max_cost: grandchild inherits from grandparent through silent parent" do
      grandparent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        max_cost 0.05
      end
      grandchild = Class.new(Class.new(grandparent))

      expect(grandchild.max_cost).to eq(0.05)
    end

    it "temperature: grandchild inherits from grandparent through silent parent" do
      grandparent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        temperature 0.7
      end
      grandchild = Class.new(Class.new(grandparent))

      expect(grandchild.temperature).to eq(0.7)
    end
  end

  describe ":default reset semantics" do
    it "model :default on child shadows grandparent's value AND grandchild sees nil (not grandparent's)" do
      grandparent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        model "gpt-4.1"
      end
      parent = Class.new(grandparent) do
        model :default # explicit reset
      end
      grandchild = Class.new(parent)

      expect(parent.model).to be_nil
      expect(grandchild.model).to be_nil
    end

    it "max_cost :default on child resets to nil and superclass lookup stops" do
      grandparent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        max_cost 0.10
      end
      child = Class.new(grandparent) do
        max_cost :default
      end

      expect(child.max_cost).to be_nil
    end

    it "temperature :default reset is sticky across re-reads" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        temperature 0.9
      end
      child = Class.new(parent) do
        temperature :default
      end

      3.times { expect(child.temperature).to be_nil }
    end

    it "attachment_token_estimate :default reset is honoured by child" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        attachment_token_estimate 5_000
      end
      child = Class.new(parent) do
        attachment_token_estimate :default
      end

      expect(child.attachment_token_estimate).to be_nil
    end
  end

  describe "falsy / boundary value edge cases" do
    it "temperature 0 is preserved as 0 (not treated as unset)" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        temperature 0
      end

      expect(step.temperature).to eq(0)
    end

    it "temperature 0 set on parent: child without override reads 0 (not nil)" do
      parent = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        temperature 0
      end
      child = Class.new(parent)

      expect(child.temperature).to eq(0)
    end

    it "max_cost is not settable to 0 (positive-amount validation)" do
      expect do
        Class.new(RubyLLM::Contract::Step::Base) { max_cost 0 }
      end.to raise_error(ArgumentError, /must be positive/)
    end
  end

  describe "re-set after :default reset" do
    it "model: :default then a fresh value sticks (not the reset)" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        model "gpt-4.1"
        model :default
        model "gpt-5-mini"
      end

      expect(step.model).to eq("gpt-5-mini")
    end

    it "attachment_token_estimate: :default then a fresh value sticks" do
      step = Class.new(RubyLLM::Contract::Step::Base) do
        prompt "p"
        attachment_token_estimate 5_000
        attachment_token_estimate :default
        attachment_token_estimate 12_000
      end

      expect(step.attachment_token_estimate).to eq(12_000)
    end
  end

  describe "consistency across the five resettable attributes" do
    %i[model temperature max_cost attachment_token_estimate].each do |attr|
      it "#{attr}: :default returns nil and shadows superclass on read" do
        parent = Class.new(RubyLLM::Contract::Step::Base) do
          prompt "p"
        end
        # Set a sensible-ish value per attribute on parent.
        case attr
        when :model                     then parent.model "gpt-4.1"
        when :temperature               then parent.temperature 0.5
        when :max_cost                  then parent.max_cost 0.10
        when :attachment_token_estimate then parent.attachment_token_estimate 5_000
        end

        child = Class.new(parent)
        child.public_send(attr, :default)

        expect(child.public_send(attr)).to be_nil
      end
    end
  end
end
