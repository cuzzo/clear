require "rspec"
require_relative "../ruby/semantic/ownership_edge_planner" unless defined?(OwnershipEdgePlanner)

# V5-3a: the carrier-preserving ownership-edge planner. One writer selects
# exactly one of 7 ops from (source carrier + fan-out operation + UNIQUE
# boundary), per the design Operation table. No carrier normalization:
# a plain payload NEVER becomes an Rc.
RSpec.describe OwnershipEdgePlanner do
  def op(carrier:, fan_out:, unique_boundary: false)
    OwnershipEdgePlanner.select(source_carrier: carrier, fan_out: fan_out, at_unique_boundary: unique_boundary).op
  end

  describe "final consuming use (move)" do
    it "moves the payload for a plain carrier (NO Rc wrap)" do
      expect(op(carrier: :plain, fan_out: :move)).to eq(:payload_move)
    end
    it "moves the Rc handle for @multiowned" do
      expect(op(carrier: :multiowned, fan_out: :move)).to eq(:rc_handle_move)
    end
    it "moves the Arc handle for @shared" do
      expect(op(carrier: :shared, fan_out: :move)).to eq(:arc_handle_move)
    end
  end

  describe "KEEP (carrier-preserving fan-out)" do
    it "copies the payload for a plain carrier" do
      expect(op(carrier: :plain, fan_out: :keep)).to eq(:payload_copy)
    end
    it "non-atomic-retains for @multiowned" do
      expect(op(carrier: :multiowned, fan_out: :keep)).to eq(:rc_retain)
    end
    it "atomic-retains for @shared" do
      expect(op(carrier: :shared, fan_out: :keep)).to eq(:arc_retain)
    end
  end

  describe "COPY" do
    it "copies the payload for a plain carrier" do
      expect(op(carrier: :plain, fan_out: :copy)).to eq(:payload_copy)
    end
    it "is a shared->unique copy for @multiowned at a UNIQUE boundary" do
      expect(op(carrier: :multiowned, fan_out: :copy, unique_boundary: true)).to eq(:shared_to_unique_copy)
    end
    it "is a shared->unique copy for @shared at a UNIQUE boundary" do
      expect(op(carrier: :shared, fan_out: :copy, unique_boundary: true)).to eq(:shared_to_unique_copy)
    end
    it "rejects COPY of a retained carrier without a UNIQUE boundary" do
      result = OwnershipEdgePlanner.select(source_carrier: :multiowned, fan_out: :copy, at_unique_boundary: false)
      expect(result.op).to be_nil
      expect(result.error_kind).to eq(:copy_needs_unique_boundary)
    end
  end
end
