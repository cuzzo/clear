require "rspec"
require_relative "../src/ast/type"

RSpec.describe Type, "provenance" do
  it "defaults to nil" do
    t = Type.new(:String)
    expect(t.provenance).to be_nil
  end

  it "can be marked as rodata" do
    t = Type.new(:String)
    t.send(:mark_rodata!)
    expect(t.rodata?).to be true
    expect(t.heap?).to be false
    expect(t.frame?).to be false
  end

  it "can be marked as frame allocated" do
    t = Type.new(:String)
    t.mark_frame_allocated!
    expect(t.frame?).to be true
    expect(t.provenance_alloc).to eq(:frame)
  end

  it "can be marked as heap allocated" do
    t = Type.new(:String)
    t.mark_heap_allocated!
    expect(t.heap?).to be true
    expect(t.provenance_alloc).to eq(:heap)
  end

  it "provenance_alloc returns nil for rodata" do
    t = Type.new(:String)
    t.send(:mark_rodata!)
    expect(t.provenance_alloc).to be_nil
  end

  it "is preserved through copy constructor" do
    t = Type.new(:String)
    t.mark_heap_allocated!
    copy = Type.new(t)
    expect(copy.provenance).to eq(:heap)
    expect(copy.heap?).to be true
  end
end
