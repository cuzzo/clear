require "rspec"
require_relative "../src/ast/type"

RSpec.describe Type, "provenance" do
  it "defaults to nil" do
    t = Type.new(:String)
    expect(t.provenance).to be_nil
  end

  it "can be set to :rodata" do
    t = Type.new(:String)
    t.provenance = :rodata
    expect(t.rodata_provenance?).to be true
    expect(t.heap_provenance?).to be false
    expect(t.frame_provenance?).to be false
  end

  it "can be set to :frame" do
    t = Type.new(:String)
    t.provenance = :frame
    expect(t.frame_provenance?).to be true
    expect(t.provenance_alloc).to eq(:frame)
  end

  it "can be set to :heap" do
    t = Type.new(:String)
    t.provenance = :heap
    expect(t.heap_provenance?).to be true
    expect(t.provenance_alloc).to eq(:heap)
  end

  it "cleanup_alloc= sets provenance and provenance_alloc returns it" do
    t = Type.new(:String)
    t.cleanup_alloc = :heap
    expect(t.provenance).to eq(:heap)
    expect(t.provenance_alloc).to eq(:heap)
  end

  it "provenance_alloc returns nil for rodata" do
    t = Type.new(:String)
    t.provenance = :rodata
    expect(t.provenance_alloc).to be_nil
  end

  it "is preserved through copy constructor" do
    t = Type.new(:String)
    t.provenance = :heap
    copy = Type.new(t)
    expect(copy.provenance).to eq(:heap)
    expect(copy.heap_provenance?).to be true
  end
end
