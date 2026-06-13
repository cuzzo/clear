require "rspec"

require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../src/ast/source_error" unless defined?(CompilerError)
require_relative "../src/ast/type" unless defined?(Type)
require_relative "../src/annotator/helpers/function_signature" unless defined?(FunctionSignature::AnalysisFacts)

RSpec.describe "Type#zig_type gap coverage" do
  it "renders generic and stream-style surface names without string re-parsing" do
    expect(Type.surface_name(Type.generic_instance_of(:Box, [Type.new(:Int64)]))).to eq("Box<Int64>")
    expect(Type.array_capacity_suffix(:STREAM_OPEN)).to eq("[?]")
    expect(Type.array_capacity_suffix(:INF)).to eq("[INF]")
  end

  it "keeps fallible function return types fallible" do
    sig = FunctionSignature.new(params: [], return_type: Type.new("!Int64"))

    expect(Type.new(sig).zig_type).to eq("*const fn(*Runtime) !i64")
  end

  it "wraps shared fixed SOA arrays around the SoaList shape" do
    type = Type.new(:"Int64[4]", ownership: :shared)
    type.soa = true

    expect(type.zig_type).to eq("CheatLib.Arc(CheatLib.SoaList(i64))")
  end

  it "uses a pointer for sync-wrapped affine structs" do
    expect(Type.new("Counter", sync: :locked).zig_type).to eq("*CheatLib.Locked(Counter)")
  end

  it "maps striped numeric hash maps through the numeric striped wrapper" do
    type = Type.new(:"HashMap<Int64, Float64>", sync: :locked, shard_count: 4)

    expect(type.zig_type).to eq("CheatLib.StripedNumericMap(i64, f64, 4)")
  end

  it "wraps shared striped maps around the striped inner map shape" do
    type = Type.new(:"HashMap<Int64, Float64>", ownership: :shared, sync: :locked, shard_count: 4)

    expect(type.zig_type).to eq("CheatLib.Arc(CheatLib.StripedNumericMap(i64, f64, 4))")
  end

  it "stores capability dimensions in a typed capabilities object" do
    type = Type.new(:"Int64[]")
    type.ownership = :shared
    type.sync = :locked
    type.layout = :indirect
    type.lock_rank = 7
    type.collection = :list
    type.shard_count = 3
    type.soa = true
    type.elem_ownership = :multiowned
    type.elem_sync = :atomic
    type.link_source = :shared
    type.is_observable = true
    type.observable_terminal = :sum
    token = Object.new
    type.observable_token = token
    type.polymorphic_shared = true

    caps = type.capabilities
    expect(caps.ownership).to eq(:shared)
    expect(caps.sync).to eq(:locked)
    expect(caps.layout).to eq(:indirect)
    expect(caps.lock_rank).to eq(7)
    expect(caps.collection).to eq(:list)
    expect(caps.shard_count).to eq(3)
    expect(caps.soa).to be true
    expect(caps.elem_ownership).to eq(:multiowned)
    expect(caps.elem_sync).to eq(:atomic)
    expect(caps.link_source).to eq(:shared)
    expect(caps.observable).to be true
    expect(caps.observable_terminal).to eq(:sum)
    expect(caps.observable_token).to equal(token)
    expect(caps.polymorphic_shared).to be true
    expect(type.lock_rank).to eq(7)
    expect(type.link_source).to eq(:shared)
    expect(type.observable_token).to equal(token)
    expect(type.polymorphic_shared).to be true
  end

  it "copies capabilities without sharing mutable capability state" do
    type = Type.new(:"Int64[]", ownership: :shared, sync: :locked, shard_count: 4)
    type.collection = :list
    copy = Type.new(type)

    copy.ownership = :affine
    copy.sync = nil
    copy.collection = nil
    copy.shard_count = nil

    expect(type.ownership).to eq(:shared)
    expect(type.sync).to eq(:locked)
    expect(type.collection).to eq(:list)
    expect(type.shard_count).to eq(4)
    expect(copy.ownership).to eq(:affine)
    expect(copy.sync).to be_nil
    expect(copy.collection).to be_nil
    expect(copy.shard_count).to be_nil
  end

  it "invalidates cached zig rendering when capabilities change" do
    type = Type.new(:Counter)

    expect(type.zig_type).to eq("Counter")
    type.sync = :locked

    expect(type.zig_type).to eq("*CheatLib.Locked(Counter)")
  end

  it "parses tense types with neutral capability defaults" do
    type = Type.new(:"~Int64")

    expect(type.tense?).to be true
    expect(type.ownership).to eq(:affine)
    expect(type.sync).to be_nil
    expect(type.collection).to be_nil
  end

  it "keeps plain type construction affine without extra capability metadata" do
    type = Type.new(:Int64)

    expect(type.resolved).to eq(:Int64)
    expect(type.ownership).to eq(:affine)
    expect(type.sync).to be_nil
    expect(type.collection).to be_nil
    expect(type.provenance).to be_nil
  end

  it "normalizes Number aliases on bare and nested type names" do
    expect(Type.new(:Number).resolved).to eq(:Float64)
    expect(T.must(Type.new(:"HashMap<Number>").value_type).resolved).to eq(:Float64)
  end

  it "keeps suffix and constructor capability overrides after parsing defaults" do
    suffixed = Type.new(:"String@shared:locked")
    constructed = Type.new(:Counter, sync: :locked)

    expect(suffixed.ownership).to eq(:shared)
    expect(suffixed.sync).to eq(:locked)
    expect(constructed.ownership).to eq(:affine)
    expect(constructed.sync).to eq(:locked)
  end

  it "keeps function-signature type wrappers affine" do
    sig = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
    type = Type.new(sig)

    expect(type.fn_type?).to be true
    expect(type.ownership).to eq(:affine)
    expect(type.sync).to be_nil
  end

  it "applies observable terminal constructor metadata and surface names" do
    plain = Type.new(:Int64)
    observable = Type.new(:"~Int64", observable: true, observable_terminal: :sum)

    expect(plain.ownership_surface_name).to be_nil
    expect(plain.sync_surface_name).to be_nil
    expect(plain.sync_family_name).to be_nil
    expect(observable.observable_terminal).to eq(:sum)
    expect(observable.send(:observable_wrapper_zig, Type.new(:Int64))).to eq("ObservableSum(i64)")
  end

  it "renders every observable terminal wrapper through typed terminal metadata" do
    wrappers = {
      count: "ObservableCount()",
      avg: "ObservableAvg(f64)",
      min: "ObservableMin(i64)",
      any: "ObservableAny()",
      all: "ObservableAll()",
      find: "ObservableFind(i64)",
      reduce: "ObservableReduce(i64)",
    }

    wrappers.each do |terminal, expected|
      observable = Type.new(:"~Int64", observable: true, observable_terminal: terminal)
      tense_type = terminal == :find ? Type.new(:"?Int64") : Type.new(:Int64)
      expect(observable.send(:observable_wrapper_zig, tense_type)).to eq(expected)
    end

    distinct = Type.new(:"~Int64[4]", observable: true, observable_terminal: :distinct)
    expect(distinct.send(:observable_wrapper_zig, Type.new(:"Int64[4]", collection: :set))).to eq("ObservableStreamSetBounded(i64, 4)")
  end

  it "exposes placement location aliases and dynamic field-array intent through composition" do
    heap = Type.new(:String, location: :heap)
    fallback = Type.new(:String)

    expect(heap.placement.location).to eq(:heap)
    expect(heap.location).to eq(:heap)
    expect(fallback.apply_cleanup_placement!(value_type: nil, alloc: nil)).to equal(fallback.placement)
    expect(Type.new(:"Int64[]").dynamic_field_array?).to be true
    expect(Type.new(:"Int64[2]", collection: :list).dynamic_field_array?).to be true
  end

  it "applies element-level capabilities to array element types" do
    type = Type.new(:"Counter[]")
    type.elem_ownership = :shared
    type.elem_sync = :locked

    elem = T.must(type.element_type)
    expect(elem.ownership).to eq(:shared)
    expect(elem.sync).to eq(:locked)
  end

  it "answers raw sync and link wrapper helpers through capabilities" do
    raw = Type.new(:Int64, sync: :raw)
    weak = Type.new(:Counter, ownership: :link)
    weak.link_source = :shared
    local = Type.new(:Counter, ownership: :link)

    expect(raw.raw?).to be true
    expect(weak.zig_type).to eq("CheatLib.WeakArc(Counter)")
    expect(local.zig_type).to eq("CheatLib.WeakRc(Counter)")
  end

  it "wraps always mutable sync capabilities through RefCell" do
    expect(Type.new(:Counter, sync: :always_mutable).zig_type).to eq("*CheatLib.RefCell(Counter)")
  end

  it "copies outer capabilities onto error-union payloads" do
    type = Type.new(:"!Int64[]", ownership: :shared, sync: :locked, layout: :indirect, collection: :list, shard_count: 2)
    type.soa = true
    payload = type.success_type

    expect(payload.collection).to eq(:list)
    expect(payload.shard_count).to eq(2)
    expect(payload.soa?).to be true
    expect(payload.layout).to eq(:indirect)
    expect(payload.ownership).to eq(:shared)
    expect(payload.sync).to eq(:locked)
  end

  it "exposes wrapper payloads and generic type parameters without string parsing" do
    fallible_optional = Type.new(:"!?Mode")

    expect(fallible_optional.success_type).to be_optional
    expect(fallible_optional.value_payload_type.resolved).to eq(:Mode)
    expect(Type.new(:T)).to be_generic_type_parameter
    expect(Type.new(:Result)).not_to be_generic_type_parameter
  end

  it "raises a compiler error for observable wrappers without terminal stamps" do
    type = Type.new(:"~Int64", observable: true)

    expect {
      type.send(:observable_wrapper_zig, Type.new(:Int64))
    }.to raise_error(CompilerError, /without an observable_terminal stamp/)
  end
end
