require "rspec"
require "set"

require_relative "../src/semantic/escape_analysis" unless defined?(EscapeAnalysis::EscapeSink)

RSpec.describe EscapeAnalysis do
  let(:tok) { Lexer::Token.new(:VAR_ID, "x", 1, 1) }

  def fn(body, name: "main", params: [], return_type: :Void)
    AST::FunctionDef.new(tok, name, params, [], return_type, nil, body, [], nil, :private, [], false)
  end

  def id(name, type: :String, storage: :frame)
    node = AST::Identifier.new(tok, name)
    node.full_type = type
    node.symbol = SymbolEntry.new(reg: name, type: type, mutable: false, storage: storage)
    node
  end

  def lit(value = "x", type: :String)
    node = AST::Literal.new(tok, type == :String ? :STRING : :NUMBER, value, nil)
    node.full_type = type
    node
  end

  def param(name, type: :String, takes: false)
    p = AST::Param.new(name: name, type: type, default: nil, mutable: false, takes: takes, comptime: false,
      name_token: tok, required: nil, sync: nil)
    p.takes = takes
    p.symbol = SymbolEntry.new(reg: name, type: type, mutable: false, storage: :heap)
    p.symbol.is_param = true
    p.symbol.takes = takes
    p
  end

  def allocating_mutating_signature(receiver_type)
    FunctionSignature.new(
      params: [param("self", type: receiver_type)],
      return_type: Type.new(:Void),
      intrinsic: true,
      emit: IntrinsicEmit.new(allocates: true, mutates_receiver: true),
    )
  end

  def call_site_fact(call, id: 1, fn_var_call: false)
    Semantic::CallSiteFact.new(
      id: Semantic::CallSiteId.new(value: id),
      node: call,
      callee_name: call.name,
      args: call.args,
      fn_var_call: fn_var_call || call.fn_var_call == true,
      propagates_failure: true,
    )
  end

  def body_summary(name:, return_nodes: [], binding_nodes: [], assignment_nodes: [], escape_nodes: [], call_site_facts: [])
    Annotator::Phases::FunctionBodySummary.new(
      name: name,
      callees: Set.new,
      propagating_callees: Set.new,
      has_fnptr_call: false,
      raises_directly: false,
      return_nodes: return_nodes,
      binding_nodes: binding_nodes,
      assignment_nodes: assignment_nodes,
      escape_nodes: escape_nodes,
      call_site_facts: call_site_facts,
    )
  end

  it "records heap symbols from params and local symbol facts" do
    heap_param = param("input", type: :String)
    local_entry = SymbolEntry.new(reg: "local", type: Type.new(:String), mutable: false, storage: :heap)
    stack_entry = SymbolEntry.new(reg: "stack", type: Type.new(:String), mutable: false, storage: :frame)
    facts = EscapeAnalysis::FunctionFacts.new(
      fn: fn([], params: [heap_param]),
      symbols: { "local" => local_entry, "stack" => stack_entry },
      binding_values: {},
      return_values: [],
      assignment_nodes: [],
      escape_nodes: [],
    )

    expect(facts.heap_symbol_count).to eq(2)
    expect(facts.heap_symbols.keys).to contain_exactly("input", "local")
    expect(facts.heap_symbol_ids).to eq(Set[heap_param.symbol.binding_id, local_entry.binding_id])
  end

  it "records placement facts for symbols newly promoted to heap" do
    entry = SymbolEntry.new(reg: "owned", type: Type.new(:String), mutable: false, storage: :frame)
    facts = EscapeAnalysis::FunctionFacts.new(
      fn: fn([], name: "make"),
      symbols: { "owned" => entry },
      binding_values: {},
      return_values: [],
      assignment_nodes: [],
      escape_nodes: [],
    )
    placements = EscapeAnalysis::EscapePlacementFacts.new

    entry.storage = :heap
    placements.record_new_heap_symbols!(facts, Set.new, :escape_sink)

    expect(placements.heap_function_names).to eq(Set["make"])
    expect(placements.placements.first).to have_attributes(
      fn_name: "make",
      symbol_name: "owned",
      binding_id: entry.binding_id,
      reason: :escape_sink,
    )
  end

  it "matches escape sinks by configured node classes" do
    sink = EscapeAnalysis::EscapeSink.new(
      name: :binding_result,
      node_classes: [AST::VarDecl],
      handler: :apply_binding_escape_sink!,
    )

    decl = AST::VarDecl.new(tok, "value", Type.new(:String), lit, false)
    expect(sink.matches?(decl)).to eq(true)
    expect(sink.matches?(id("value"))).to eq(false)

    locatable_sink = EscapeAnalysis::EscapeSink.new(
      name: :any_ast_node,
      node_classes: [AST::Locatable],
      handler: :apply_binding_escape_sink!,
    )
    expect(locatable_sink.matches?(decl)).to eq(true)
  end

  it "validates handler registries and executable escape sinks" do
    expect { EscapeAnalysis.send(:validate_escape_sink_handlers!) }.not_to raise_error
    expect { EscapeAnalysis.send(:validate_derived_placement_handlers!) }.not_to raise_error
    expect { EscapeAnalysis.send(:validate_escape_sinks!) }.not_to raise_error
    expect {
      EscapeAnalysis.send(:validate_handler_registry!, "bad", missing: [:nope])
    }.to raise_error(RuntimeError, /bad is incomplete: missing=nope/)
  end

  it "rejects missing escape sink handler registry entries" do
    stub_const(
      "EscapeAnalysis::ESCAPE_SINK_HANDLERS",
      { missing_sink: [:missing_handler].freeze }.freeze,
    )

    expect {
      EscapeAnalysis.send(:validate_escape_sink_handlers!)
    }.to raise_error(RuntimeError, /EscapeAnalysis sink registry is incomplete: missing_sink=missing_handler/)
  end

  it "rejects missing derived placement handler registry entries" do
    stub_const(
      "EscapeAnalysis::DERIVED_PLACEMENT_HANDLERS",
      { missing_phase: [:missing_derived_handler].freeze }.freeze,
    )

    expect {
      EscapeAnalysis.send(:validate_derived_placement_handlers!)
    }.to raise_error(RuntimeError, /EscapeAnalysis derived placement registry is incomplete: missing_phase=missing_derived_handler/)
  end

  it "rejects executable escape sinks with unknown names or handlers" do
    stub_const(
      "EscapeAnalysis::ESCAPE_SINKS",
      [
        EscapeAnalysis::EscapeSink.new(
          name: :unknown_sink,
          node_classes: [AST::ReturnNode],
          handler: :apply_return_escape_sink!,
        ),
        EscapeAnalysis::EscapeSink.new(
          name: :owning_return,
          node_classes: [AST::ReturnNode],
          handler: :missing_escape_handler!,
        ),
      ].freeze,
    )

    expect {
      EscapeAnalysis.send(:validate_escape_sinks!)
    }.to raise_error(RuntimeError, /missing_escape_handler!, unknown_sink/)
  end

  it "apply! forwards inputs and returns the legacy heap tuple" do
    fn_nodes = { "main" => fn([]) }
    schema_lookup = proc { nil }
    heap_fns = Set["main"]
    bg_heap = Set["captured"]
    result = EscapeAnalysis::Result.new(
      heap_fns: heap_fns,
      bg_heap: bg_heap,
      placements: EscapeAnalysis::EscapePlacementFacts.new,
    )

    expect(EscapeAnalysis).to receive(:apply_with_facts!)
      .with(fn_nodes, schema_lookup)
      .and_return(result)

    expect(EscapeAnalysis.apply!(fn_nodes, schema_lookup)).to eq([heap_fns, bg_heap])
  end

  it "apply! accepts omitted schema lookup" do
    expect(EscapeAnalysis.apply!({})).to eq([Set.new, Set.new])
  end

  it "apply_with_facts! walks function bodies when summaries are omitted" do
    local_type = Type.new(:String)
    decl = AST::VarDecl.new(tok, "local", local_type, lit("owned", type: :String), false)
    entry = SymbolEntry.new(reg: decl, type: local_type, mutable: false, storage: :frame)
    decl.symbol = entry
    decl.full_type = local_type

    returned = id("local", type: local_type, storage: :frame)
    returned.symbol = entry
    ret = AST::ReturnNode.new(tok, returned)
    analyzed_fn = fn([decl, ret], return_type: local_type)

    result = EscapeAnalysis.apply_with_facts!({ "main" => analyzed_fn })

    expect(entry.storage).to eq(:heap)
    expect(result.heap_fns).to eq(Set["main"])
  end

  it "apply_with_facts! ignores function declarations without bodies" do
    external = fn(nil, name: "external", return_type: Type.new(:String))

    result = EscapeAnalysis.apply_with_facts!({ "external" => external })

    expect(result.heap_fns).to eq(Set.new)
    expect(result.bg_heap).to eq(Set.new)
    expect(result.placements.placements).to eq([])
  end

  it "apply_with_facts! honors explicit summaries instead of walking full bodies" do
    receiver_type = Type.new(:"Int64[]", collection: :list)
    receiver = id("items", type: receiver_type, storage: :frame)
    receiver.symbol.is_param = true
    call = AST::MethodCall.new(tok, receiver, "append", [])
    call.full_type = Type.new(:Void)
    call.matched_signature = allocating_mutating_signature(receiver_type)
    analyzed_fn = fn([call], params: [param("items", type: receiver_type)])
    analyzed_fn.params.first.symbol = receiver.symbol

    result = EscapeAnalysis.apply_with_facts!({
      "main" => analyzed_fn,
    }, nil, {
      "main" => body_summary(name: "main"),
    })

    expect(receiver.symbol.storage).to eq(:frame)
    expect(result.placements.placements).to eq([])
  end

  it "handles caller sync propagation empty inputs and function-pointer call sites" do
    expect { EscapeAnalysis.propagate_caller_sync!({}, {}) }.not_to raise_error

    callee_param = param("value", type: :String)
    callee = fn([], name: "callee", params: [callee_param])
    arg = id("arg", type: Type.new(:String, sync: :locked), storage: :heap)
    call = AST::FuncCall.new(tok, "callee", [arg])
    fact = call_site_fact(call, fn_var_call: true)

    EscapeAnalysis.propagate_caller_sync!({ "callee" => callee }, {
      "main" => body_summary(name: "main", call_site_facts: [fact]),
    })

    expect(callee_param.symbol.sync).to be_nil
  end

  it "propagates caller storage from shared and multiowned values" do
    shared_param = param("value", type: Type.new(:Counter))
    shared_param.symbol.storage = :frame
    shared_callee = fn([], name: "sharedCallee", params: [shared_param])
    shared_arg = id("arg", type: Type.new(:Counter, ownership: :shared), storage: :frame)
    shared_call = AST::FuncCall.new(tok, "sharedCallee", [shared_arg])

    multi_param = param("value", type: Type.new(:Counter))
    multi_param.symbol.storage = :frame
    multi_callee = fn([], name: "multiCallee", params: [multi_param])
    multi_arg = id("arg", type: Type.new(:Counter), storage: :multiowned)
    multi_call = AST::FuncCall.new(tok, "multiCallee", [multi_arg])

    EscapeAnalysis.propagate_caller_sync!({
      "sharedCallee" => shared_callee,
      "multiCallee" => multi_callee,
    }, {
      "main" => body_summary(
        name: "main",
        call_site_facts: [call_site_fact(shared_call, id: 1), call_site_fact(multi_call, id: 2)],
      ),
    })

    expect(shared_param.symbol.storage).to eq(:shared)
    expect(multi_param.symbol.storage).to eq(:multiowned)
  end

  it "propagates sync and ownership from type facts when symbol fields are bare" do
    sync_param = param("value", type: Type.new(:Counter))
    sync_param.symbol.storage = :frame
    sync_callee = fn([], name: "syncCallee", params: [sync_param])
    sync_arg = id("arg", type: Type.new(:Counter, sync: :locked), storage: :frame)
    sync_arg.symbol.sync = nil
    sync_call = AST::FuncCall.new(tok, "syncCallee", [sync_arg])

    owned_param = param("value", type: Type.new(:Counter))
    owned_param.symbol.storage = :frame
    owned_callee = fn([], name: "ownedCallee", params: [owned_param])
    owned_arg = id("arg", type: Type.new(:Counter, ownership: :multiowned), storage: :frame)
    owned_call = AST::FuncCall.new(tok, "ownedCallee", [owned_arg])

    EscapeAnalysis.propagate_caller_sync!({
      "syncCallee" => sync_callee,
      "ownedCallee" => owned_callee,
    }, {
      "main" => body_summary(
        name: "main",
        call_site_facts: [call_site_fact(sync_call, id: 1), call_site_fact(owned_call, id: 2)],
      ),
    })

    expect(sync_param.symbol.sync).to eq(:locked)
    expect(owned_param.symbol.storage).to eq(:multiowned)
  end

  it "leaves caller storage unchanged when callers disagree" do
    callee_param = param("value", type: Type.new(:Counter))
    callee_param.symbol.storage = :frame
    callee = fn([], name: "callee", params: [callee_param])
    shared_arg = id("shared", type: Type.new(:Counter, ownership: :shared), storage: :frame)
    multi_arg = id("multi", type: Type.new(:Counter), storage: :multiowned)
    shared_call = AST::FuncCall.new(tok, "callee", [shared_arg])
    multi_call = AST::FuncCall.new(tok, "callee", [multi_arg])

    EscapeAnalysis.propagate_caller_sync!({ "callee" => callee }, {
      "main" => body_summary(
        name: "main",
        call_site_facts: [call_site_fact(shared_call, id: 1), call_site_fact(multi_call, id: 2)],
      ),
    })

    expect(callee_param.symbol.storage).to eq(:frame)
  end

  it "skips params without symbols without skipping later params" do
    missing_symbol_param = param("missing", type: Type.new(:Counter))
    missing_symbol_param.symbol = nil
    synced_param = param("value", type: Type.new(:Counter))
    callee = fn([], name: "callee", params: [missing_symbol_param, synced_param])
    missing_arg = id("missing_arg", type: Type.new(:Counter, sync: :always_mutable), storage: :frame)
    synced_arg = id("synced_arg", type: Type.new(:Counter, sync: :locked), storage: :frame)
    call = AST::FuncCall.new(tok, "callee", [missing_arg, synced_arg])

    EscapeAnalysis.propagate_caller_sync!({ "callee" => callee }, {
      "main" => body_summary(name: "main", call_site_facts: [call_site_fact(call)]),
    })

    expect(synced_param.symbol.sync).to eq(:locked)
  end

  it "can replace a propagated sync value when the param did not declare sync" do
    callee_param = param("value", type: Type.new(:Counter))
    callee_param.symbol.sync = :always_mutable
    callee = fn([], name: "callee", params: [callee_param])
    locked_arg = id("locked", type: Type.new(:Counter, sync: :locked), storage: :frame)
    call = AST::FuncCall.new(tok, "callee", [locked_arg])

    EscapeAnalysis.propagate_caller_sync!({ "callee" => callee }, {
      "main" => body_summary(name: "main", call_site_facts: [call_site_fact(call)]),
    })

    expect(callee_param.symbol.sync).to eq(:locked)
  end

  it "does not infer RC storage from bare caller values" do
    callee_param = param("value", type: Type.new(:Counter))
    callee_param.symbol.storage = :frame
    callee = fn([], name: "callee", params: [callee_param])
    bare_arg = id("bare", type: Type.new(:Counter), storage: :frame)
    call = AST::FuncCall.new(tok, "callee", [bare_arg])

    EscapeAnalysis.propagate_caller_sync!({ "callee" => callee }, {
      "main" => body_summary(name: "main", call_site_facts: [call_site_fact(call)]),
    })

    expect(callee_param.symbol.storage).to eq(:frame)
  end

  it "propagates caller storage to a fixed point through reversed call chains" do
    leaf_param = param("value", type: Type.new(:Counter))
    leaf_param.symbol.storage = :frame
    leaf = fn([], name: "leaf", params: [leaf_param])
    middle_param = param("value", type: Type.new(:Counter))
    middle_param.symbol.storage = :frame
    middle = fn([], name: "middle", params: [middle_param])
    root_param = param("value", type: Type.new(:Counter))
    root_param.symbol.storage = :frame
    root = fn([], name: "root", params: [root_param])

    root_arg = id("root_arg", type: Type.new(:Counter, ownership: :shared), storage: :frame)
    root_call = AST::FuncCall.new(tok, "root", [root_arg])
    middle_arg = id("middle_arg", type: Type.new(:Counter), storage: :frame)
    middle_arg.symbol = root_param.symbol
    middle_call = AST::FuncCall.new(tok, "middle", [middle_arg])
    leaf_arg = id("leaf_arg", type: Type.new(:Counter), storage: :frame)
    leaf_arg.symbol = middle_param.symbol
    leaf_call = AST::FuncCall.new(tok, "leaf", [leaf_arg])

    EscapeAnalysis.propagate_caller_sync!({
      "leaf" => leaf,
      "middle" => middle,
      "root" => root,
    }, {
      "main" => body_summary(
        name: "main",
        call_site_facts: [
          call_site_fact(root_call, id: 1),
          call_site_fact(middle_call, id: 2),
          call_site_fact(leaf_call, id: 3),
        ],
      ),
    })

    expect(root_param.symbol.storage).to eq(:shared)
    expect(middle_param.symbol.storage).to eq(:shared)
    expect(leaf_param.symbol.storage).to eq(:shared)
  end

  it "does not override a declared param sync or admit atomic sync without a requires contract" do
    declared_param = param("value", type: Type.new(:Counter, sync: :locked))
    declared_param.symbol.sync = :locked
    declared = fn([], name: "declared", params: [declared_param])
    mutable_arg = id("mutable", type: Type.new(:Counter, sync: :always_mutable), storage: :heap)
    declared_call = AST::FuncCall.new(tok, "declared", [mutable_arg])

    atomic_param = param("value", type: Type.new(:Counter))
    atomic_param.symbol.sync = nil
    atomic = fn([], name: "atomic", params: [atomic_param])
    atomic_arg = id("atomic_arg", type: Type.new(:Counter, sync: :atomic), storage: :heap)
    atomic_call = AST::FuncCall.new(tok, "atomic", [atomic_arg])

    declared_bare_param = param("value", type: Type.new(:Counter, sync: :locked))
    declared_bare_param.symbol.sync = nil
    declared_bare = fn([], name: "declaredBare", params: [declared_bare_param])
    declared_bare_call = AST::FuncCall.new(tok, "declaredBare", [mutable_arg])

    EscapeAnalysis.propagate_caller_sync!({
      "declared" => declared,
      "atomic" => atomic,
      "declaredBare" => declared_bare,
    }, {
      "main" => body_summary(
        name: "main",
        call_site_facts: [
          call_site_fact(declared_call, id: 1),
          call_site_fact(atomic_call, id: 2),
          call_site_fact(declared_bare_call, id: 3),
        ],
      ),
    })

    expect(declared_param.symbol.sync).to eq(:locked)
    expect(atomic_param.symbol.sync).to be_nil
    expect(declared_bare_param.symbol.sync).to be_nil
  end

  it "skips function-variable call sites without skipping later direct calls" do
    callee_param = param("value", type: Type.new(:Counter))
    callee_param.symbol.storage = :frame
    callee = fn([], name: "callee", params: [callee_param])
    ignored_arg = id("ignored", type: Type.new(:Counter, sync: :always_mutable), storage: :frame)
    ignored_call = AST::FuncCall.new(tok, "callee", [ignored_arg])
    ignored_call.fn_var_call = true
    direct_arg = id("direct", type: Type.new(:Counter, sync: :locked), storage: :frame)
    direct_call = AST::FuncCall.new(tok, "callee", [direct_arg])

    EscapeAnalysis.propagate_caller_sync!({ "callee" => callee }, {
      "main" => body_summary(
        name: "main",
        call_site_facts: [call_site_fact(ignored_call, id: 1, fn_var_call: true), call_site_fact(direct_call, id: 2)],
      ),
    })

    expect(callee_param.symbol.sync).to eq(:locked)
  end

  it "propagates caller facts to a fixed point through reversed call chains" do
    leaf_param = param("value", type: Type.new(:Counter))
    leaf_param.symbol.storage = :frame
    leaf = fn([], name: "leaf", params: [leaf_param])
    middle_param = param("value", type: Type.new(:Counter))
    middle_param.symbol.storage = :frame
    middle = fn([], name: "middle", params: [middle_param])
    root_param = param("value", type: Type.new(:Counter))
    root_param.symbol.storage = :frame
    root = fn([], name: "root", params: [root_param])

    root_arg = id("root_arg", type: Type.new(:Counter, sync: :locked), storage: :frame)
    root_call = AST::FuncCall.new(tok, "root", [root_arg])
    middle_arg = id("middle_arg", type: Type.new(:Counter), storage: :frame)
    middle_arg.symbol = root_param.symbol
    middle_call = AST::FuncCall.new(tok, "middle", [middle_arg])
    leaf_arg = id("leaf_arg", type: Type.new(:Counter), storage: :frame)
    leaf_arg.symbol = middle_param.symbol
    leaf_call = AST::FuncCall.new(tok, "leaf", [leaf_arg])

    EscapeAnalysis.propagate_caller_sync!({
      "leaf" => leaf,
      "middle" => middle,
      "root" => root,
    }, {
      "main" => body_summary(
        name: "main",
        call_site_facts: [
          call_site_fact(root_call, id: 1),
          call_site_fact(middle_call, id: 2),
          call_site_fact(leaf_call, id: 3),
        ],
      ),
    })

    expect(root_param.symbol.sync).to eq(:locked)
    expect(middle_param.symbol.sync).to eq(:locked)
    expect(leaf_param.symbol.sync).to eq(:locked)
  end

  it "marks parameter receiver allocations as heap only for allocating mutating calls" do
    receiver_type = Type.new(:"Int64[]", collection: :list)
    param_receiver = id("param_items", type: receiver_type, storage: :frame)
    param_receiver.symbol.is_param = true
    mutating_sig = allocating_mutating_signature(receiver_type)
    pure_sig = FunctionSignature.new(
      params: [param("self", type: receiver_type)],
      return_type: Type.new(:Void),
      intrinsic: true,
      emit: IntrinsicEmit.new,
    )
    pure_call = AST::MethodCall.new(tok, param_receiver, "length", [])
    pure_call.full_type = Type.new(:Void)
    pure_call.matched_signature = pure_sig
    mutating_call = AST::MethodCall.new(tok, param_receiver, "append", [])
    mutating_call.full_type = Type.new(:Void)
    mutating_call.matched_signature = mutating_sig

    EscapeAnalysis.send(:mark_param_receiver_allocations_heap!, [pure_call])
    expect(param_receiver.symbol.heap_storage?).to eq(false)

    EscapeAnalysis.send(:mark_param_receiver_allocations_heap!, [mutating_call])
    expect(param_receiver.symbol.heap_storage?).to eq(true)
  end

  it "marks owning TAKES arguments as heap and leaves non-owning args alone" do
    owned_arg = id("owned", type: :String, storage: :frame)
    move = AST::MoveNode.new(tok, owned_arg)
    move.full_type = Type.new(:String)
    primitive_arg = id("count", type: :Int64, storage: :frame)
    takes_string = param("value", type: :String, takes: true)
    takes_string.symbol.storage = :frame
    takes_int = param("count", type: :Int64, takes: true)
    takes_int.symbol.storage = :frame

    EscapeAnalysis.send(
      :mark_takes_args_heap!,
      [move, primitive_arg],
      [takes_string, takes_int],
      nil,
    )

    expect(owned_arg.symbol.storage).to eq(:heap)
    expect(primitive_arg.symbol.storage).to eq(:frame)
  end

  it "marks args for heap-backed mutable params and skips missing args" do
    heap_param = param("slot", type: :String)
    heap_param.symbol.storage = :heap
    missing_param = param("missing", type: :String, takes: true)
    arg = id("arg", type: :String, storage: :frame)

    expect {
      EscapeAnalysis.send(:mark_takes_args_heap!, [arg], [heap_param, missing_param], nil)
    }.not_to raise_error

    expect(arg.symbol.storage).to eq(:heap)
  end

  it "does not promote ordinary non-TAKES params" do
    ordinary_param = param("value", type: :String)
    ordinary_param.symbol.storage = :frame
    arg = id("arg", type: :String, storage: :frame)

    EscapeAnalysis.send(:mark_takes_args_heap!, [arg], [ordinary_param], nil)

    expect(arg.symbol.storage).to eq(:frame)
  end

  it "promotes heap-owned transfer sources even when the value type is primitive" do
    takes_int = param("value", type: :Int64, takes: true)
    takes_int.symbol.storage = :frame
    arg = id("arg", type: :Int64, storage: :heap)

    EscapeAnalysis.send(:mark_takes_args_heap!, [arg], [takes_int], nil)

    expect(arg.symbol.storage).to eq(:heap)
  end

  it "uses schema lookup when deciding whether TAKES aggregate args need owned storage" do
    takes_box = param("value", type: :Box, takes: true)
    takes_box.symbol.storage = :frame
    arg = id("arg", type: :Box, storage: :frame)
    schema_lookup = proc do |name|
      name == :Box ? Schemas::StructSchema.new(fields: { "field" => Type.new(:String) }) : nil
    end

    EscapeAnalysis.send(:mark_takes_args_heap!, [arg], [takes_box], schema_lookup)

    expect(arg.symbol.storage).to eq(:heap)
  end

  it "records receiver backing storage placement through apply_with_facts!" do
    receiver_type = Type.new(:"Int64[]", collection: :list)
    receiver = id("items", type: receiver_type, storage: :frame)
    receiver.symbol.is_param = true
    call = AST::MethodCall.new(tok, receiver, "append", [])
    call.full_type = Type.new(:Void)
    call.matched_signature = allocating_mutating_signature(receiver_type)
    analyzed_fn = fn([call], params: [param("items", type: receiver_type)])
    analyzed_fn.params.first.symbol = receiver.symbol

    result = EscapeAnalysis.apply_with_facts!({
      "main" => analyzed_fn,
    }, nil, {
      "main" => body_summary(name: "main", escape_nodes: [call]),
    })

    expect(receiver.symbol.storage).to eq(:heap)
    expect(result.placements.placements.map(&:reason)).to include(:receiver_backing_storage)
  end

  it "records recursive aggregate owner placement through apply_with_facts!" do
    schema_lookup = proc do |name|
      name == :Box ? Schemas::StructSchema.new(fields: { "field" => Type.new(:String) }) : nil
    end
    owner = param("box", type: Type.new(:Box))
    owner.symbol.storage = :frame
    analyzed_fn = fn([], params: [owner])

    result = EscapeAnalysis.apply_with_facts!({ "main" => analyzed_fn }, schema_lookup)

    expect(owner.symbol.storage).to eq(:heap)
    expect(result.placements.placements.map(&:reason)).to include(:recursive_aggregate_owner)
  end

  it "uses schema lookup when deciding owning return placement" do
    schema_lookup = proc do |name|
      name == :Box ? Schemas::StructSchema.new(fields: { "field" => Type.new(:String) }) : nil
    end
    box_type = Type.new(:Box)
    decl = AST::VarDecl.new(tok, "box", box_type, AST::StructLit.new(tok, "Box", {}, :stack, nil), false)
    entry = SymbolEntry.new(reg: decl, type: box_type, mutable: false, storage: :frame)
    decl.symbol = entry
    decl.full_type = box_type
    returned = id("box", type: box_type, storage: :frame)
    returned.symbol = entry
    ret = AST::ReturnNode.new(tok, returned)
    analyzed_fn = fn([decl, ret], return_type: box_type)

    result = EscapeAnalysis.apply_with_facts!({
      "main" => analyzed_fn,
    }, schema_lookup, {
      "main" => body_summary(name: "main", return_nodes: [ret], binding_nodes: [decl]),
    })

    expect(entry.storage).to eq(:heap)
    expect(result.placements.placements.map(&:reason)).to include(:owning_return)
  end

  it "uses schema lookup to avoid heap placement for copyable owning returns" do
    schema_lookup = proc do |name|
      name == :Point ? Schemas::StructSchema.new(fields: { "x" => Type.new(:Int64) }) : nil
    end
    point_type = Type.new(:Point)
    decl = AST::VarDecl.new(tok, "point", point_type, AST::StructLit.new(tok, "Point", {}, :stack, nil), false)
    entry = SymbolEntry.new(reg: decl, type: point_type, mutable: false, storage: :frame)
    decl.symbol = entry
    decl.full_type = point_type
    returned = id("point", type: point_type, storage: :frame)
    returned.symbol = entry
    ret = AST::ReturnNode.new(tok, returned)
    analyzed_fn = fn([decl, ret], return_type: point_type)

    result = EscapeAnalysis.apply_with_facts!({
      "main" => analyzed_fn,
    }, schema_lookup, {
      "main" => body_summary(name: "main", return_nodes: [ret], binding_nodes: [decl]),
    })

    expect(entry.storage).to eq(:frame)
    expect(analyzed_fn.heap_carry_return).to be_nil
    expect(result.placements.placements.map(&:reason)).not_to include(:owning_return)
  end

  it "uses schema lookup when promoting FSM context locals" do
    schema_lookup = proc do |name|
      name == :Box ? Schemas::StructSchema.new(fields: { "field" => Type.new(:String) }) : nil
    end
    box_type = Type.new(:Box)
    decl = AST::VarDecl.new(tok, "box", box_type, AST::StructLit.new(tok, "Box", {}, :stack, nil), false)
    entry = SymbolEntry.new(reg: decl, type: box_type, mutable: false, storage: :frame)
    decl.symbol = entry
    decl.full_type = box_type
    bg = AST::BgBlock.new(tok, [decl], nil, nil, false, false, nil, false)
    bg.spawn_form = :fsm
    analyzed_fn = fn([bg])

    result = EscapeAnalysis.apply_with_facts!({
      "main" => analyzed_fn,
    }, schema_lookup, {
      "main" => body_summary(name: "main", escape_nodes: [bg]),
    })

    expect(entry.storage).to eq(:heap)
    expect(result.placements.placements).to eq([])
  end

  it "records loop receiver backing storage placement through apply_with_facts!" do
    receiver_type = Type.new(:"Int64[]", collection: :list)
    receiver = id("items", type: receiver_type, storage: :frame)
    receiver.symbol.is_param = true
    local_value = AST::StringConcat.new(tok, [lit("x", type: :String)])
    local_value.full_type = Type.new(:String)
    local_decl = AST::VarDecl.new(tok, "scratch", Type.new(:String), local_value, false)
    local_decl.symbol = SymbolEntry.new(reg: local_decl, type: Type.new(:String), mutable: false, storage: :frame)
    local_decl.full_type = Type.new(:String)
    call = AST::MethodCall.new(tok, receiver, "append", [])
    call.full_type = Type.new(:Void)
    call.matched_signature = allocating_mutating_signature(receiver_type)
    loop = AST::WhileLoop.new(tok, lit(true, type: :Bool), [local_decl, call], [])
    analyzed_fn = fn([loop], params: [param("items", type: receiver_type)])
    analyzed_fn.params.first.symbol = receiver.symbol

    result = EscapeAnalysis.apply_with_facts!({
      "main" => analyzed_fn,
    }, nil, {
      "main" => body_summary(name: "main"),
    })

    expect(receiver.symbol.storage).to eq(:heap)
    expect(result.placements.placements.map(&:reason)).to include(:loop_receiver_backing_storage)
  end

  it "records assignment ownership placement through apply_with_facts!" do
    target_type = Type.new(:String)
    target_decl = AST::VarDecl.new(tok, "target", target_type, lit("old", type: :String), false)
    target_entry = SymbolEntry.new(reg: target_decl, type: target_type, mutable: true, storage: :frame)
    target_decl.symbol = target_entry
    target_decl.full_type = target_type
    source = id("source", type: target_type, storage: :heap)
    assignment = AST::Assignment.new(tok, "target", source)
    analyzed_fn = fn([target_decl, assignment])

    result = EscapeAnalysis.apply_with_facts!({
      "main" => analyzed_fn,
    }, nil, {
      "main" => body_summary(name: "main", binding_nodes: [target_decl], assignment_nodes: [assignment]),
    })

    expect(target_entry.storage).to eq(:heap)
    expect(result.placements.placements.map(&:reason)).to include(:assignment_ownership)
  end

  it "uses schema lookup when propagating assignment ownership from call results" do
    schema_lookup = proc do |name|
      name == :Box ? Schemas::StructSchema.new(fields: { "field" => Type.new(:String) }) : nil
    end
    box_type = Type.new(:Box)
    target_type = Type.new(:Counter)
    target_decl = AST::VarDecl.new(tok, "target", target_type, AST::StructLit.new(tok, "Counter", {}, :stack, nil), false)
    target_entry = SymbolEntry.new(reg: target_decl, type: target_type, mutable: true, storage: :frame)
    target_decl.symbol = target_entry
    target_decl.full_type = target_type
    source_decl = AST::VarDecl.new(tok, "source", box_type, AST::StructLit.new(tok, "Box", {}, :stack, nil), false)
    source_entry = SymbolEntry.new(reg: source_decl, type: box_type, mutable: false, storage: :frame)
    source_decl.symbol = source_entry
    source_decl.full_type = box_type
    returned = id("source", type: box_type, storage: :frame)
    returned.symbol = source_entry
    ret = AST::ReturnNode.new(tok, returned)
    callee = fn([source_decl, ret], name: "makeBox", return_type: box_type)
    call = AST::FuncCall.new(tok, "makeBox", [])
    assignment = AST::Assignment.new(tok, "target", call)
    caller = fn([target_decl, assignment], name: "main")

    result = EscapeAnalysis.apply_with_facts!({
      "main" => caller,
      "makeBox" => callee,
    }, schema_lookup, {
      "main" => body_summary(name: "main", binding_nodes: [target_decl], assignment_nodes: [assignment]),
      "makeBox" => body_summary(name: "makeBox", binding_nodes: [source_decl], return_nodes: [ret]),
    })

    expect(target_entry.storage).to eq(:heap)
    expect(result.placements.placements.map(&:reason)).to include(:assignment_ownership)
  end

  it "uses schema lookup to avoid assignment ownership from copyable call results" do
    schema_lookup = proc do |name|
      name == :Point ? Schemas::StructSchema.new(fields: { "x" => Type.new(:Int64) }) : nil
    end
    point_type = Type.new(:Point)
    target_decl = AST::VarDecl.new(tok, "target", point_type, AST::StructLit.new(tok, "Point", {}, :stack, nil), false)
    target_entry = SymbolEntry.new(reg: target_decl, type: point_type, mutable: true, storage: :frame)
    target_decl.symbol = target_entry
    target_decl.full_type = point_type
    source_decl = AST::VarDecl.new(tok, "source", point_type, AST::StructLit.new(tok, "Point", {}, :stack, nil), false)
    source_entry = SymbolEntry.new(reg: source_decl, type: point_type, mutable: false, storage: :frame)
    source_decl.symbol = source_entry
    source_decl.full_type = point_type
    returned = id("source", type: point_type, storage: :frame)
    returned.symbol = source_entry
    ret = AST::ReturnNode.new(tok, returned)
    callee = fn([source_decl, ret], name: "makePoint", return_type: point_type)
    call = AST::FuncCall.new(tok, "makePoint", [])
    assignment = AST::Assignment.new(tok, "target", call)
    caller = fn([target_decl, assignment], name: "main")

    result = EscapeAnalysis.apply_with_facts!({
      "main" => caller,
      "makePoint" => callee,
    }, schema_lookup, {
      "main" => body_summary(name: "main", binding_nodes: [target_decl], assignment_nodes: [assignment]),
      "makePoint" => body_summary(name: "makePoint", binding_nodes: [source_decl], return_nodes: [ret]),
    })

    expect(target_entry.storage).to eq(:frame)
    expect(callee.heap_carry_return).to be_nil
    expect(result.placements.placements.map(&:reason)).not_to include(:assignment_ownership)
  end

  it "marks owning returned identifiers and records heap-carry return facts" do
    local_type = Type.new(:String)
    decl = AST::VarDecl.new(tok, "local", local_type, lit("owned", type: :String), false)
    entry = SymbolEntry.new(reg: decl, type: local_type, mutable: false, storage: :frame)
    decl.symbol = entry
    decl.full_type = local_type

    returned = id("local", type: local_type, storage: :frame)
    returned.symbol = entry
    ret = AST::ReturnNode.new(tok, returned)
    analyzed_fn = fn([decl, ret], return_type: local_type)

    result = EscapeAnalysis.apply_with_facts!({
      "main" => analyzed_fn,
    }, nil, {
      "main" => body_summary(name: "main", return_nodes: [ret], binding_nodes: [decl]),
    })

    expect(entry.storage).to eq(:heap)
    expect(analyzed_fn.heap_carry_return).to eq(true)
    expect(analyzed_fn.heap_carry_return_vars).to include("local")
    expect(result.heap_fns).to include("main")
    fact = result.placements.placements.find { |placement| placement.symbol_name == "local" }
    expect(fact).to have_attributes(fn_name: "main", binding_id: entry.binding_id, reason: :owning_return)
  end

  it "uses hoist bindings to propagate returned aggregate ownership to sources" do
    local_type = Type.new(:String)
    source_decl = AST::VarDecl.new(tok, "source", local_type, lit("owned", type: :String), false)
    source_entry = SymbolEntry.new(reg: source_decl, type: local_type, mutable: false, storage: :frame)
    source_decl.symbol = source_entry
    source_decl.full_type = local_type

    source_ref = id("source", type: local_type, storage: :frame)
    source_ref.symbol = source_entry
    aggregate = AST::StructLit.new(tok, "Box", { "field" => source_ref }, :stack, nil)
    aggregate.full_type = local_type

    hoist_decl = AST::VarDecl.new(tok, "__hoist_1", local_type, aggregate, false)
    hoist_entry = SymbolEntry.new(reg: hoist_decl, type: local_type, mutable: false, storage: :frame)
    hoist_decl.symbol = hoist_entry
    hoist_decl.full_type = local_type

    returned = id("__hoist_1", type: local_type, storage: :frame)
    returned.symbol = hoist_entry
    ret = AST::ReturnNode.new(tok, returned)
    analyzed_fn = fn([source_decl, hoist_decl, ret], return_type: local_type)

    result = EscapeAnalysis.apply_with_facts!({
      "main" => analyzed_fn,
    }, nil, {
      "main" => body_summary(name: "main", return_nodes: [ret], binding_nodes: [source_decl]),
    }, {
      "main" => [hoist_decl],
    })

    expect(hoist_entry.storage).to eq(:heap)
    expect(source_entry.storage).to eq(:heap)
    source_fact = result.placements.placements.find { |placement| placement.symbol_name == "source" }
    expect(source_fact).to have_attributes(fn_name: "main", reason: :hoist_dependency)
  end

  it "uses recorded body escape nodes for binding-result heap placement" do
    local_type = Type.new(:String)
    callee = fn([], name: "callee", return_type: local_type)
    callee.heap_carry_return = true
    call = AST::FuncCall.new(tok, "callee", [])
    decl = AST::VarDecl.new(tok, "made", local_type, call, false)
    entry = SymbolEntry.new(reg: decl, type: local_type, mutable: false, storage: :frame)
    decl.symbol = entry
    decl.full_type = local_type
    main = fn([decl], return_type: :Void)

    result = EscapeAnalysis.apply_with_facts!({
      "main" => main,
      "callee" => callee,
    }, nil, {
      "main" => body_summary(
        name: "main",
        binding_nodes: [decl],
        escape_nodes: [decl, call],
        call_site_facts: [call_site_fact(call)],
      ),
      "callee" => body_summary(name: "callee"),
    })

    expect(entry.storage).to eq(:heap)
    fact = result.placements.placements.find { |placement| placement.symbol_name == "made" }
    expect(fact).to have_attributes(fn_name: "main", reason: :escape_sink)
  end

  it "classifies heap-return dependencies through returned params" do
    p = param("value", type: :String)
    heap_arg = id("arg", type: :String, storage: :heap)
    heap_arg.full_type.mark_heap_allocated!

    expect(EscapeAnalysis.send(:heap_return_from_args?, [heap_arg], [p], Set["value"], Type.new(:String), nil)).to eq(true)
    expect(EscapeAnalysis.send(:heap_return_from_args?, [lit("x", type: :String)], [p], Set["missing"], Type.new(:String), nil)).to eq(true)
    expect(EscapeAnalysis.send(:heap_return_from_args?, [lit(1, type: :Int64)], [param("n", type: :Int64)], Set["n"], Type.new(:Int64), nil)).to eq(false)
    expect(EscapeAnalysis.send(:heap_return_from_args?, [], [], nil, Type.new(:String), nil)).to be_nil
  end

  it "distinguishes borrowed returns from owning returns" do
    p = param("source", type: :String)
    borrowed = fn([], params: [p], return_type: :String)
    borrowed.return_lifetime = [p]
    expect(EscapeAnalysis.send(:borrowed_return?, borrowed, id("source", type: :String))).to eq(true)

    owned = fn([], params: [p], return_type: :String)
    expect(EscapeAnalysis.send(:owning_return_needs_heap_placement?, owned, id("local", type: :String, storage: :heap), nil)).to eq(true)
  end
end
