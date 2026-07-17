# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/type" unless defined?(Type)
require_relative "../ruby/mir/mir" unless defined?(MIR::StdlibDefFsCoercion)
require_relative "../ruby/ast/std_lib" unless defined?(StdLibTypeBinding)
require_relative "../ruby/annotator/helpers/intrinsic_registry" unless defined?(IntrinsicRegistry)

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
    expect(fs.required_intrinsic_template(IntrinsicTemplateKind::Zig)).to eq("try {0}.append({alloc}, {1})")
    expect(fs.emits_allocating?).to be(true)
    expect(fs.intrinsic_alloc(IntrinsicAllocationKind::Alloc)).to eq(:receiver_storage)
    expect(fs.mutates_receiver?).to be(true)
    expect(fs.takes_ownership?).to be(true)
    expect(T.must(contract).ownership.takes_indices).to include(1)
    expect(fs.intrinsic_argument_takes_indices).to be_empty
    expect(fs.intrinsic_bc?).to be(true)
  end

  it "constructs each signature's intrinsic contract once and invalidates it on replacement" do
    fs = IntrinsicRegistry.send(:convert_entry, "append", STD_LIB["append"], REGISTRIES)
    original = fs.intrinsic_contract

    expect(fs.intrinsic_contract).to equal(original)

    fs.replace_intrinsic_emit!(IntrinsicEmit.new(allocates: false))
    replacement = fs.intrinsic_contract
    expect(replacement).not_to equal(original)
    expect(replacement.allocation.allocates).to be(false)
    expect(fs.intrinsic_contract).to equal(replacement)
  end

  it "uses registry identity before structural compatibility matching" do
    allow(IntrinsicRegistry).to receive(:registry_matches?).and_call_original

    expect(IntrinsicRegistry.send(:registry_name_for, REGISTRIES, MAP_METHODS)).to eq(:MAP_METHODS)
    expect(IntrinsicRegistry).not_to have_received(:registry_matches?)

    equivalent = MAP_METHODS.dup
    expect(IntrinsicRegistry.send(:registry_name_for, REGISTRIES, equivalent)).to eq(:MAP_METHODS)
    expect(IntrinsicRegistry).to have_received(:registry_matches?).at_least(:once)
  end

  it "exposes typed intrinsic argument specs for consumers" do
    fs = IntrinsicRegistry.send(:convert_entry, "append", STD_LIB["append"], REGISTRIES)
    arg_specs = fs.intrinsic_arg_specs

    expect(arg_specs.map(&:type)).to eq([:"Any[]", :Any])
    expect(arg_specs[1].takes).to be(true)
    expect(fs.params.map(&:type)).to eq([:"Any[]", :Any])
    expect(fs.params[1].takes).to be(true)
    expect(fs.intrinsic_fixed_arg_list?).to be(true)
    expect(fs.intrinsic_args_label).to eq("(Any[], Any)")
  end

  it "normalizes string capability metadata while preserving simple registry input" do
    spec = IntrinsicArgSpec.from_registry(
      name: :payload,
      type: "String",
      sync: "locked",
      ownership: "borrowed",
      mutable: true,
      takes: true,
    )

    expect(spec.name).to eq("payload")
    expect(spec.type).to eq(:String)
    expect(spec.sync).to eq(:locked)
    expect(spec.ownership).to eq(:borrowed)
    expect(spec.mutable).to be(true)
    expect(spec.takes).to be(true)
    expect(spec.capability_constrained?).to be(true)
  end

  it "preserves receiver mutation in the call-validation contract" do
    fs = IntrinsicRegistry.send(:convert_entry, "append", STD_LIB["append"], REGISTRIES)
    validation = fs.intrinsic_call_validation_signature

    expect(fs.params.first.mutable).to be(true)
    expect(validation.params.first.mutable).to be(true)
    expect(validation.params[1].takes).to be(true)
  end

  it "returns typed overload sets instead of raw registry hashes" do
    overloads = IntrinsicRegistry.overloads(STD_LIB, "length")

    expect(overloads).not_to be_empty
    expect(overloads).to all(be_a(FunctionSignature))
    expect(overloads.map(&:intrinsic_args_label)).to eq(["(String)", "(Any[])"])
    expect(IntrinsicRegistry.overloads(STD_LIB, "timestampMs"))
      .to eq([IntrinsicRegistry.lookup(STD_LIB, "timestampMs")])
    expect(IntrinsicRegistry.overloads(STD_LIB, "missingIntrinsic")).to eq([])
  end

  it "marks varargs signatures without leaking the raw sentinel to callers" do
    fs = T.must(IntrinsicRegistry.lookup(STD_LIB, "map"))

    expect(fs.intrinsic_varargs?).to be(true)
    expect(fs.intrinsic_fixed_arg_list?).to be(false)
    expect(fs.intrinsic_arg_specs).to eq([])
    expect(fs.intrinsic_args_label).to eq("(varargs)")
  end

  it "distinguishes declared empty args from arity-only method registry entries" do
    declared_empty = T.must(IntrinsicRegistry.lookup(STD_LIB, "timestampMs"))
    arity_only_method = T.must(IntrinsicRegistry.lookup(MAP_METHODS, "count"))

    expect(declared_empty.intrinsic_fixed_arg_list?).to be(true)
    expect(declared_empty.intrinsic_arg_specs).to eq([])
    expect(arity_only_method.intrinsic_fixed_arg_list?).to be(false)
    expect(arity_only_method.intrinsic_arg_specs).to eq([])
  end

  it "keeps method argument takes separate from canonical signature params" do
    fs = IntrinsicRegistry.send(:convert_entry, "insert", POOL_METHODS["insert"], REGISTRIES)
    contract = T.must(fs.intrinsic_contract)

    expect(contract.ownership.argument_takes_indices).to include(0)
    expect(contract.ownership.takes_indices).to include(1)
    expect(fs.takes_ownership?).to be(true)
  end

  it "applies intrinsic overrides through FunctionSignature without mutating the registry entry" do
    original = T.must(IntrinsicRegistry.lookup(MAP_METHODS, "put"))
    overridden = original.with_intrinsic_override(
      pattern: "custom({0})",
      alloc: :sharded_receiver_storage,
    )

    expect(original.intrinsic_pattern).not_to eq("custom({0})")
    expect(overridden.intrinsic_pattern).to eq("custom({0})")
    expect(overridden.intrinsic_alloc(IntrinsicAllocationKind::Alloc)).to eq(:sharded_receiver_storage)
  end

  it "applies intrinsic overrides to empty signatures and rejects missing required templates" do
    signature = FunctionSignature.new(params: [], return_type: Type.new(:Void), intrinsic: true)

    expect(signature.intrinsic_pattern).to be_nil
    expect { signature.required_intrinsic_template(IntrinsicTemplateKind::Zig) }
      .to raise_error(/registry template missing :zig/)

    overridden = signature.with_intrinsic_override(pattern: :identity)

    expect(signature.emit).to be_nil
    expect(overridden.intrinsic_pattern).to eq(:identity)
    expect(overridden.intrinsic_alloc(IntrinsicAllocationKind::Alloc)).to be_nil
  end

  it "classifies registry-backed collection ownership predicates from typed contracts" do
    expect(IntrinsicRegistry.collection_element_evidence_method?("append", 1)).to be(true)
    expect(IntrinsicRegistry.collection_element_evidence_method?(:push, 1)).to be(true)
    expect(IntrinsicRegistry.collection_element_evidence_method?("insert", 1)).to be(true)
    expect(IntrinsicRegistry.collection_element_evidence_method?("append", 2)).to be(false)
    expect(IntrinsicRegistry.collection_element_evidence_method?("contains?", 1)).to be(false)
    expect(IntrinsicRegistry.collection_element_evidence_method?("missing", 1)).to be(false)

    expect(IntrinsicRegistry.map_pair_evidence_method?("put", 2)).to be(true)
    expect(IntrinsicRegistry.map_pair_evidence_method?(:put, 2)).to be(true)
    expect(IntrinsicRegistry.map_pair_evidence_method?("contains?", 2)).to be(false)
    expect(IntrinsicRegistry.map_pair_evidence_method?("missing", 2)).to be(false)
    expect(IntrinsicRegistry.map_pair_evidence_method?("put", 1)).to be(false)

    expect(IntrinsicRegistry.collection_value_store_method?("append", 1)).to be(true)
    expect(IntrinsicRegistry.collection_value_store_method?(:append, 1)).to be(true)
    expect(IntrinsicRegistry.collection_value_store_method?("insert", 1)).to be(true)
    expect(IntrinsicRegistry.collection_value_store_method?("put", 2)).to be(true)
    expect(IntrinsicRegistry.collection_value_store_method?("contains?", 1)).to be(false)
    expect(IntrinsicRegistry.collection_value_store_method?("pop", 0)).to be(false)
    expect(IntrinsicRegistry.collection_value_store_method?("missing", 1)).to be(false)
  end

  it "requires each collection value-store predicate, not just matching method names" do
    true_store = {
      args: [:List, :Int64],
      is_method: true,
      mutates_receiver: true,
      takes_args: [0],
      return: :Void,
    }
    not_mutating = true_store.merge(mutates_receiver: false)
    not_taking = true_store.merge(takes_args: [])
    not_method = true_store.merge(is_method: false)

    stub_const("STD_LIB", { "store" => true_store, "read" => not_mutating })
    stub_const("POOL_METHODS", { "poolStore" => true_store, "borrow" => not_taking })
    stub_const("SET_METHODS", { "setStore" => true_store, "free" => not_method })
    stub_const("MAP_METHODS", { "mapStore" => true_store.merge(arity: 2) })

    expect(IntrinsicRegistry.collection_value_store_method?("store", 1)).to be(true)
    expect(IntrinsicRegistry.collection_value_store_method?("poolStore", 1)).to be(true)
    expect(IntrinsicRegistry.collection_value_store_method?("setStore", 1)).to be(true)
    expect(IntrinsicRegistry.collection_value_store_method?("mapStore", 2)).to be(true)
    expect(IntrinsicRegistry.collection_value_store_method?("mapStore", 1)).to be(false)
    expect(IntrinsicRegistry.collection_value_store_method?("read", 1)).to be(false)
    expect(IntrinsicRegistry.collection_value_store_method?("borrow", 1)).to be(false)
    expect(IntrinsicRegistry.collection_value_store_method?("free", 1)).to be(false)
  end

  it "resolves typed map aliases only through the map-method registry" do
    put = IntrinsicRegistry.lookup(MAP_METHODS, "put")
    aliased_insert = IntrinsicRegistry.lookup(MAP_METHODS, "insert")

    expect(aliased_insert).to be_a(FunctionSignature)
    expect(aliased_insert).to equal(put)
    expect(IntrinsicRegistry.lookup(POOL_METHODS, "insert")).not_to equal(put)
    expect(IntrinsicRegistry.lookup(MAP_METHODS, "unknownAlias")).to be_nil
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

    expect(template.pattern_for(IntrinsicTemplateKind::Zig)).to eq("zig")
    expect(template.pattern_for(IntrinsicTemplateKind::NumericZig)).to eq("num")
    expect(template.pattern_for(IntrinsicTemplateKind::ShardedZig)).to eq("sharded")
    expect(template.pattern_for(IntrinsicTemplateKind::ShardDirectZig)).to eq("direct")
    expect(IntrinsicTemplateContract.new.pattern_for(IntrinsicTemplateKind::Zig)).to be_nil
    expect(template.bc_op_or(:fallback)).to eq(:custom_bc)
    expect(IntrinsicTemplateContract.new.bc_op_or(:fallback)).to eq(:fallback)

    expect(allocation.placeholder(IntrinsicAllocationKind::Alloc)).to eq(:heap)
    expect(allocation.placeholder(IntrinsicAllocationKind::ReturnAlloc)).to eq(:frame)
    expect(allocation.placeholder(IntrinsicAllocationKind::ValAlloc)).to eq(:value_heap)
    expect(allocation.placeholder(IntrinsicAllocationKind::KeyAlloc)).to eq(:key_heap)
    expect(allocation.placeholder(IntrinsicAllocationKind::ShardAlloc)).to eq(:shard_heap)
    expect(allocation.placeholder(IntrinsicAllocationKind::ShardedAlloc)).to eq(:sharded_heap)
    expect(IntrinsicAllocationContract.new.placeholder(IntrinsicAllocationKind::Alloc)).to be_nil
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
      fsm_setup_present: true,
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

  it "covers raw emit conversion branches on synthetic entries" do
    child_registry = { "child" => { return: :Void, args: [] } }
    registries = { CHILD: child_registry }

    emit = IntrinsicRegistry.send(:build_emit, {
      bc: 1,
      zig: :identity,
      reject_error: :bad,
      tag: "custom",
      takes_args: "2",
      lifetime: :current_scope,
      fsm_setup: [:prepare],
      fsm_state_decls: [:state_decl],
      fsm_finish_block: [:finish_block],
      fsm_state_finalize: [:state_finalize],
      cleanup: { registry: child_registry },
      eql: { zig: "eq({0}, {1})", return: :Bool },
    }, registries)

    expect(emit.bc).to be(true)
    expect(emit.zig).to eq(:identity)
    expect(emit.reject_error).to eq("bad")
    expect(emit.tag).to eq(:custom)
    expect(emit.takes_args).to eq([2])
    expect(emit.lifetime).to eq(["current_scope"])
    expect(emit.fsm_setup).to eq([:prepare])
    expect(emit.fsm_setup_present).to be(true)
    expect(emit.fsm_state_decls).to eq([:state_decl])
    expect(emit.fsm_state_decls_present).to be(true)
    expect(emit.fsm_finish_block).to eq([:finish_block])
    expect(emit.fsm_finish_block_present).to be(true)
    expect(emit.fsm_state_finalize).to eq([:state_finalize])
    expect(emit.fsm_state_finalize_present).to be(true)
    expect(emit.cleanup.registry).to eq(:CHILD)
    expect(emit.eql.zig).to eq("eq({0}, {1})")

    expect(IntrinsicRegistry.send(:build_emit, nil, registries)).to be_nil
    expect(IntrinsicRegistry.send(:build_emit, :not_hash, registries)).to be_nil
    expect {
      IntrinsicRegistry.send(:build_emit, { unknown_key: true }, registries)
    }.to raise_error(RuntimeError, /unmapped registry key/)
  end

  it "covers nested emit registry pointer and fallback branches" do
    registry = { "x" => { return: :Void, args: [] } }
    registries = { KNOWN: registry }

    expect(IntrinsicRegistry.send(:nested_emit, nil, registries)).to be_nil
    expect(IntrinsicRegistry.send(:nested_emit, { registry: registry }, registries).registry).to eq(:KNOWN)
    expect(IntrinsicRegistry.send(:nested_emit, { registry: {} }, registries).registry).to eq(:unknown)
    expect(IntrinsicRegistry.send(:nested_emit, { zig: "nested({0})" }, registries).zig).to eq("nested({0})")
  end

  it "covers declarative return descriptor conversion branches" do
    type = Type.new(:String)

    expect(IntrinsicRegistry.send(:to_return_def, nil).fixed).to eq(Type.new(:Void))
    expect(IntrinsicRegistry.send(:to_return_def, type).fixed).to equal(type)
    expect(IntrinsicRegistry.send(:to_return_def, { type: :Int64, sync: :locked }).fixed.sync).to eq(:locked)
    expect(IntrinsicRegistry.send(:to_return_def, { type: :Int64, ownership: :borrowed }).fixed.ownership).to eq(:borrowed)
    expect(IntrinsicRegistry.send(:to_return_def, {}).fixed).to eq(Type.new(:Any))
    expect(IntrinsicRegistry.send(:to_return_def, :r_key_list).kind).to eq(FunctionReturn::Kind::KeyList)
    expect(IntrinsicRegistry.send(:to_return_def, :infer_return).kind).to eq(FunctionReturn::Kind::Infer)
    expect(IntrinsicRegistry.send(:to_return_def, :macro_result).kind).to eq(FunctionReturn::Kind::Infer)
    expect(IntrinsicRegistry.send(:to_return_def, "infer_return").infer).to eq(:infer_return)
    expect(IntrinsicRegistry.send(:to_return_def, :Bool).fixed).to eq(Type.new(:Bool))
    expect {
      IntrinsicRegistry.send(:to_return_def, proc { :Int64 })
    }.to raise_error(RuntimeError, /Proc return descriptor/)
  end

  it "returns concrete static Types from typed return descriptors" do
    fixed = FunctionReturn.fixed(Type.new(:String))
    variant = FunctionReturn.variant(:ElementOf)

    expect(IntrinsicRegistry.send(:to_return_type, fixed)).to eq(Type.new(:String))
    expect(IntrinsicRegistry.send(:to_return_type, variant)).to eq(Type.new(:Any))
    expect(IntrinsicRegistry.send(:to_return_type, variant)).to be_a(Type)
    expect {
      IntrinsicRegistry.send(:to_return_type, FunctionReturn.new(kind: FunctionReturn::Kind::Fixed))
    }.to raise_error(RuntimeError, /fixed return descriptor missing Type/)
  end

  it "covers lifetime, params, fs, and lookup fallback branches" do
    expect(IntrinsicRegistry.send(:normalize_lifetime, nil)).to eq([])
    expect(IntrinsicRegistry.send(:normalize_lifetime, [:a, :b])).to eq([:a, :b])
    expect(IntrinsicRegistry.send(:normalize_lifetime, :a)).to eq([:a])
    expect(IntrinsicRegistry.send(:lifetime_source_string, "value")).to eq("value")
    expect(IntrinsicRegistry.send(:lifetime_source_string, :value)).to eq("value")
    expect(IntrinsicRegistry.send(:coerce_symbol, "value")).to eq(:value)
    expect(IntrinsicRegistry.send(:coerce_symbol, :value)).to eq(:value)
    expect { IntrinsicRegistry.send(:coerce_symbol, 1) }.to raise_error(RuntimeError, /symbol-compatible/)
    expect(IntrinsicRegistry.send(:coerce_integer, "2")).to eq(2)
    expect(IntrinsicRegistry.send(:coerce_integer, 2)).to eq(2)
    expect { IntrinsicRegistry.send(:coerce_integer, :two) }.to raise_error(RuntimeError, /integer-compatible/)

    method_sig = IntrinsicRegistry.send(:convert_entry, "method", {
      args: [{ name: "receiver", type: :List }, { name: "value", type: :Int64 }],
      is_method: true,
      mutates_receiver: true,
      takes_args: [0],
      return: :Void,
    }, REGISTRIES)
    expect(method_sig.params.map(&:name)).to eq(%w[receiver value])
    expect(method_sig.params[0].mutable).to be(true)
    expect(method_sig.params[1].takes).to be(true)

    method_takes_sig = IntrinsicRegistry.send(:convert_entry, "method_takes", {
      args: [:List, :Int64],
      is_method: true,
      mutates_receiver: false,
      takes_args: [0],
      return: :Void,
    }, REGISTRIES)
    expect(method_takes_sig.params.map(&:name)).to eq(%w[arg0 arg1])
    expect(method_takes_sig.params[0].takes).to be(false)
    expect(method_takes_sig.params[1].takes).to be(true)

    function_takes_sig = IntrinsicRegistry.send(:convert_entry, "function_takes", {
      args: [:List, :Int64],
      is_method: false,
      mutates_receiver: :truthy_is_not_true,
      takes_args: [0],
      return: :Void,
    }, REGISTRIES)
    expect(function_takes_sig.params[0].mutable).to be(false)
    expect(function_takes_sig.params[0].takes).to be(true)
    expect(function_takes_sig.params[1].takes).to be(false)

    second_arg_takes_sig = IntrinsicRegistry.send(:convert_entry, "second_arg_takes", {
      args: [:List, :Int64],
      takes_args: [1],
      return: :Void,
    }, REGISTRIES)
    expect(second_arg_takes_sig.params[0].takes).to be(false)
    expect(second_arg_takes_sig.params[1].takes).to be(true)

    mutable_arg_sig = IntrinsicRegistry.send(:convert_entry, "mutable_arg", {
      args: [{ type: :List }, { type: :Int64, mutable: true }],
      mutates_receiver: true,
      return: :Void,
    }, REGISTRIES)
    expect(mutable_arg_sig.params.map(&:required)).to eq([true, true])
    expect(mutable_arg_sig.params.map(&:mutable)).to eq([true, true])

    receiver_only_mutation_sig = IntrinsicRegistry.send(:convert_entry, "receiver_only_mutation", {
      args: [{ type: :List }, { type: :Int64 }],
      mutates_receiver: true,
      return: :Void,
    }, REGISTRIES)
    expect(receiver_only_mutation_sig.params.map(&:mutable)).to eq([true, false])

    fs = FunctionSignature.new(params: [], return_type: Type.new(:Void))
    expect(IntrinsicRegistry.fs(nil)).to be_nil
    expect(IntrinsicRegistry.fs(fs)).to equal(fs)
    expect(IntrinsicRegistry.fs(:not_hash)).to be_nil
    expect(IntrinsicRegistry.fs({ return: :Bool, args: [] }).return_type).to eq(Type.new(:Bool))

    expect(IntrinsicRegistry.lookup({}, "missing")).to be_nil
  end

  it "builds the loaded registry map directly from stdlib constants" do
    registries = IntrinsicRegistry.send(:registries)

    expect(registries.keys).to include(:STD_LIB, :POOL_METHODS, :SET_METHODS, :MAP_METHODS, :INDEX_OPS, :BUILTIN_OPS)
    expect(registries[:STD_LIB]).to equal(STD_LIB)
    expect(registries[:POOL_METHODS]).to equal(POOL_METHODS)
    expect(registries[:SET_METHODS]).to equal(SET_METHODS)
    expect(registries[:MAP_METHODS]).to equal(MAP_METHODS)
    expect(registries[:INDEX_OPS]).to equal(INDEX_OPS)
    expect(registries[:BUILTIN_OPS]).to equal(BUILTIN_OPS)
  end

  it "uses closed registry snapshots instead of runtime constant reflection" do
    snapshot = IntrinsicRegistry.send(:registries)
    map_methods = MAP_METHODS

    hide_const("BUILTIN_OPS")
    expect(snapshot).to have_key(:BUILTIN_OPS)
    expect(IntrinsicRegistry.send(:registries)).to have_key(:BUILTIN_OPS)

    hide_const("MAP_METHOD_ALIASES")
    expect(IntrinsicRegistry.lookup(map_methods, "insert")).not_to be_nil

    hide_const("MAP_METHODS")
    expect(IntrinsicRegistry.lookup({}, "insert")).to be_nil
  end

  it "carries all FunctionSignature fields from synthetic registry entries" do
    validator = proc { true }
    signature = IntrinsicRegistry.send(:convert_entry, "synthetic", {
      args: [{ name: "value", type: :Int64 }],
      return_type: { type: :String, sync: :locked, ownership: :borrowed },
      lifetime: :call_scope,
      validate: validator,
      arity: 1,
      can_fail: true,
      needs_rt: false,
      allocates: true,
      return_alloc: :caller,
    }, REGISTRIES)

    expect(signature.params.map(&:name)).to eq(["value"])
    expect(signature.return_type).to eq(Type.new(:String, sync: :locked, ownership: :borrowed))
    expect(signature.return_lifetime).to eq(["call_scope"])
    expect(signature.arg_validator).to equal(validator)
    expect(signature.arity).to eq(1)
    expect(signature.can_fail).to be(true)
    expect(signature.needs_rt).to be(false)
    expect(signature.emit.allocates).to be(true)
    expect(signature.emit.return_alloc).to eq(:caller)
  end

  it "ignores nil emit fields and accepts Hash subclasses" do
    hash_class = Class.new(Hash)
    raw = hash_class[
      reject_error: nil,
      tag: nil,
      fsm_setup: nil,
      zig: "emit({0})",
    ]

    emit = IntrinsicRegistry.send(:build_emit, raw, REGISTRIES)

    expect(emit.zig).to eq("emit({0})")
    expect(emit.reject_error).to be_nil
    expect(emit.tag).to be_nil
    expect(emit.fsm_setup).to eq([])
    expect(emit.fsm_setup_present).to be(false)
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
        emit = IntrinsicRegistry.lookup(registry, name).emit
        expect(emit).to be_a(IntrinsicEmit)
        expect(emit.zig).to be_a(String).or be_a(Symbol)
      end
    end
  end
end
