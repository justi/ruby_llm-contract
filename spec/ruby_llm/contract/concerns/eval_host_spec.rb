# frozen_string_literal: true

require "spec_helper"

# Characterization test pinning the register_subclasses path before the
# dead `ObjectSpace.each_object` else branch was dropped (Batch 1 / TODO).
RSpec.describe RubyLLM::Contract::Concerns::EvalHost do
  before { RubyLLM::Contract.instance_variable_get(:@eval_hosts)&.clear }

  it "registers direct subclass as an eval host on define_eval" do
    parent = Class.new(RubyLLM::Contract::Step::Base) { prompt "p" }
    child  = Class.new(parent)

    parent.define_eval("smoke") { default_input("x"); sample_response({}) }

    expect(RubyLLM::Contract.eval_hosts).to include(child)
  end

  it "registers grandchild subclasses recursively" do
    parent     = Class.new(RubyLLM::Contract::Step::Base) { prompt "p" }
    child      = Class.new(parent)
    grandchild = Class.new(child)

    parent.define_eval("smoke") { default_input("x"); sample_response({}) }

    expect(RubyLLM::Contract.eval_hosts).to include(child, grandchild)
  end

  it "does not invoke ObjectSpace.each_object (Ruby >= 3.1 path only)" do
    parent = Class.new(RubyLLM::Contract::Step::Base) { prompt "p" }
    Class.new(parent)

    expect(ObjectSpace).not_to receive(:each_object)

    parent.define_eval("smoke") { default_input("x"); sample_response({}) }
  end
end
