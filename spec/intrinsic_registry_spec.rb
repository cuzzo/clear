# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../src/ast/ast"
require_relative "../src/ast/type"
require_relative "../src/mir/mir"
require_relative "../src/ast/std_lib"
require_relative "../src/annotator/helpers/intrinsic_registry"

# Totality + fidelity: every real registry entry must convert without
# error (T::Struct raises on any mistyped IntrinsicEmit prop, so this
# proves the typed model fits the real authoring data), and key
# semantics must round-trip.
RSpec.describe IntrinsicRegistry do
  REGISTRIES = {
    STD_LIB: STD_LIB, POOL_METHODS: POOL_METHODS, SET_METHODS: SET_METHODS,
    MAP_METHODS: MAP_METHODS, INDEX_OPS: INDEX_OPS, BUILTIN_OPS: BUILTIN_OPS
  }.freeze

  it "converts every entry in every registry without error (totality)" do
    REGISTRIES.each do |rname, reg|
      reg.each do |mname, entry|
        next unless entry.is_a?(Hash)

        expect { IntrinsicRegistry.send(:convert_entry, mname, entry, REGISTRIES) }
          .not_to(raise_error, "#{rname}[#{mname.inspect}] failed to convert")
      end
    end
  end

  it "yields a pure Type return_type and a typed FunctionReturn (no Proc/Hash)" do
    REGISTRIES.each_value do |reg|
      reg.each do |mname, entry|
        next unless entry.is_a?(Hash)

        fs = IntrinsicRegistry.send(:convert_entry, mname, entry, REGISTRIES)
        expect(fs.return_type).to be_a(Type)
        expect(fs.return_def).to be_a(FunctionReturn)
        expect(fs.intrinsic_contract).to be_a(IntrinsicContract)
        src = entry.key?(:return_type) ? entry[:return_type] : entry[:return]
        # No Proc/Hash leakage: every descriptor maps to a closed
        # FunctionReturn variant, and the static return_type matches
        # the FunctionReturn for the Fixed case.
        expect(src).not_to be_a(Proc)
        if fs.return_def.kind == FunctionReturn::Kind::Fixed
          expect(fs.return_type).to eq(fs.return_def.fixed)
        else
          expect(fs.return_type.resolved).to eq(:Any)
        end
        case src
        when :r_element_of
          expect(fs.return_def.kind).to eq(FunctionReturn::Kind::ElementOf)
        when :r_id_element
          expect(fs.return_def.kind).to eq(FunctionReturn::Kind::IdOfElement)
        when :r_optional_value
          expect(fs.return_def.kind).to eq(FunctionReturn::Kind::OptionalOfValue)
        end
        expect(fs.emit).to be_a(IntrinsicEmit).or be_nil
        expect(fs.intrinsic).to be(true)
      end
    end
  end

  it "normalizes allocation, ownership, and template facts into a contract" do
    fs = IntrinsicRegistry.send(:convert_entry, "append", STD_LIB["append"], REGISTRIES)
    contract = fs.intrinsic_contract

    expect(contract).to be_a(IntrinsicContract)
    expect(fs.intrinsic_pattern).to eq("try {0}.append({alloc}, {1})")
    expect(fs.required_intrinsic_template(:zig)).to eq("try {0}.append({alloc}, {1})")
    expect(fs.emits_allocating?).to be(true)
    expect(fs.intrinsic_alloc(:alloc)).to eq(:receiver_storage)
    expect(fs.mutates_receiver?).to be(true)
    expect(fs.takes_ownership?).to be(true)
    expect(T.must(contract).ownership.takes_indices).to include(1)
    expect(fs.intrinsic_argument_takes_indices).to be_empty
    expect(fs.intrinsic_bc?).to be(true)
  end

  it "keeps method argument takes separate from canonical signature params" do
    fs = IntrinsicRegistry.send(:convert_entry, "insert", POOL_METHODS["insert"], REGISTRIES)
    contract = T.must(fs.intrinsic_contract)

    expect(contract.ownership.argument_takes_indices).to include(0)
    expect(contract.ownership.takes_indices).to include(1)
    expect(fs.takes_ownership?).to be(true)
  end

  it "applies intrinsic overrides through FunctionSignature without mutating the registry entry" do
    original = T.must(IntrinsicRegistry.sig(MAP_METHODS, "put"))
    overridden = original.with_intrinsic_override(
      pattern: "custom({0})",
      alloc: :sharded_receiver_storage,
    )

    expect(original.intrinsic_pattern).not_to eq("custom({0})")
    expect(overridden.intrinsic_pattern).to eq("custom({0})")
    expect(overridden.intrinsic_alloc(:alloc)).to eq(:sharded_receiver_storage)
  end

  it "applies intrinsic overrides to empty signatures and rejects missing required templates" do
    signature = FunctionSignature.new(params: [], return_type: Type.new(:Void), intrinsic: true)

    expect(signature.intrinsic_pattern).to be_nil
    expect { signature.required_intrinsic_template(:zig) }
      .to raise_error(/registry template missing :zig/)

    overridden = signature.with_intrinsic_override(pattern: :identity)

    expect(signature.emit).to be_nil
    expect(overridden.intrinsic_pattern).to eq(:identity)
    expect(overridden.intrinsic_alloc(:alloc)).to be_nil
  end

  it "classifies registry-backed collection ownership predicates from typed contracts" do
    expect(IntrinsicRegistry.map_pair_evidence_method?("put", 2)).to be(true)
    expect(IntrinsicRegistry.map_pair_evidence_method?("contains?", 2)).to be(false)
    expect(IntrinsicRegistry.map_pair_evidence_method?("missing", 2)).to be(false)
    expect(IntrinsicRegistry.map_pair_evidence_method?("put", 1)).to be(false)

    expect(IntrinsicRegistry.collection_value_store_method?("append", 1)).to be(true)
    expect(IntrinsicRegistry.collection_value_store_method?("insert", 1)).to be(true)
    expect(IntrinsicRegistry.collection_value_store_method?("contains?", 1)).to be(false)
    expect(IntrinsicRegistry.collection_value_store_method?("pop", 0)).to be(false)
    expect(IntrinsicRegistry.collection_value_store_method?("missing", 1)).to be(false)
  end

  it "keeps indexed assignment set intrinsics value-consuming" do
    INDEX_OPS.each do |kind, ops|
      set_op = ops[:set]
      next unless set_op

      signature = IntrinsicRegistry.fs(set_op, "#{kind}_set")

      expect(signature.intrinsic_takes_value?).to be(true)
      expect(signature.takes_ownership?).to be(true)
    end
  end

  it "covers intrinsic template and allocation contract branch lookups" do
    template = IntrinsicTemplateContract.new(
      zig: "zig",
      numeric_zig: "num",
      sharded_zig: "sharded",
      shard_direct_zig: "direct",
      bc_op: :custom_bc,
    )
    allocation = IntrinsicAllocationContract.new(
      alloc: :heap,
      return_alloc: :frame,
      val_alloc: :value_heap,
      key_alloc: :key_heap,
      shard_alloc: :shard_heap,
      sharded_alloc: :sharded_heap,
    )

    expect(template.pattern_for(:zig)).to eq("zig")
    expect(template.pattern_for(:numeric_zig)).to eq("num")
    expect(template.pattern_for(:sharded_zig)).to eq("sharded")
    expect(template.pattern_for(:shard_direct_zig)).to eq("direct")
    expect(template.pattern_for(:missing)).to be_nil
    expect(template.bc_op_or(:fallback)).to eq(:custom_bc)
    expect(IntrinsicTemplateContract.new.bc_op_or(:fallback)).to eq(:fallback)

    expect(allocation.placeholder(:alloc)).to eq(:heap)
    expect(allocation.placeholder(:return_alloc)).to eq(:frame)
    expect(allocation.placeholder(:val_alloc)).to eq(:value_heap)
    expect(allocation.placeholder(:key_alloc)).to eq(:key_heap)
    expect(allocation.placeholder(:shard_alloc)).to eq(:shard_heap)
    expect(allocation.placeholder(:sharded_alloc)).to eq(:sharded_heap)
    expect(allocation.placeholder(:missing)).to be_nil
  end

  it "covers intrinsic empty defaults and ownership normalization branches" do
    empty = IntrinsicContract.empty
    expect(empty.ownership.takes_any?).to be(false)
    expect(empty.behavior.narrows_collection_type?).to be(false)

    receiver_param = AST::Param.new(name: "self", type: :List, takes: false)
    value_param = AST::Param.new(name: "value", type: :Int64, takes: true)
    emit = IntrinsicEmit.new(
      takes_args: [0],
      narrows_receiver_collection: true,
      fsm_setup: [],
    )
    contract = IntrinsicContract.from_emit(emit, [receiver_param, value_param])

    expect(contract.ownership.takes_indices).to include(0, 1)
    expect(contract.ownership.argument_takes_indices).to include(0)
    expect(contract.ownership.takes_any?).to be(true)
    expect(contract.behavior.narrows_collection_type?).to be(true)
    expect(contract.behavior.fsm_setup_present).to be(true)

    no_takes = IntrinsicEmit.new
    expect(IntrinsicContract.normalized_takes_indices(no_takes, [receiver_param])).to be_empty
    expect(IntrinsicContract.normalized_argument_takes_indices(no_takes)).to be_empty
    expect(IntrinsicContract.from_emit(no_takes, []).behavior.fsm_setup_present).to be(false)
  end

  it "round-trips representative emit fields incl. recursion" do
    fs = IntrinsicRegistry.send(:convert_entry,
      "insert", POOL_METHODS["insert"], REGISTRIES
    )
    expect(fs.emit.tag).to eq(:pool_method)
    expect(fs.emit.is_method).to be(true)
    expect(fs.emit.zig).to be_a(String)
    # POOL_METHODS["insert"] returns `Id<element>` -> IdOfElement variant.
    expect(fs.return_def).to be_a(FunctionReturn)
    expect(fs.return_def.kind).to eq(FunctionReturn::Kind::IdOfElement)

    # Nested recursive sub-descriptor (eql/cleanup/... -> IntrinsicEmit)
    nested = REGISTRIES.each_value.flat_map(&:values)
                       .select { |e| e.is_a?(Hash) }
                       .find { |e| e[:eql].is_a?(Hash) || e[:cleanup].is_a?(Hash) }
    if nested
      fe = IntrinsicRegistry.send(:convert_entry, "x", nested, REGISTRIES)
      sub = fe.emit.eql || fe.emit.cleanup
      expect(sub).to be_a(IntrinsicEmit)
    end
  end

  it "keeps collection method entries fully emittable" do
    [POOL_METHODS, SET_METHODS, MAP_METHODS].each do |registry|
      registry.each_key do |name|
        emit = IntrinsicRegistry.sig(registry, name).emit
        expect(emit).to be_a(IntrinsicEmit)
        expect(emit.zig).to be_a(String).or be_a(Symbol)
      end
    end
  end
end
