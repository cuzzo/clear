require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

RSpec.describe "annotator branch gap burndown" do
  def annotate_source(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  def expect_compile(source)
    expect { annotate_source(source) }.not_to raise_error
  end

  def expect_reject(source)
    expect { annotate_source(source) }.to raise_error(CompilerError)
  end

  def token(type = :VAR_ID, value = "x")
    Lexer::Token.new(type, value, 1, 1)
  end

  def quiet_annotator
    ann = SemanticAnnotator.new(source_code: "")
    errors = []
    ann.define_singleton_method(:error!) do |node, code, *args, **kwargs|
      errors << [node, code, args, kwargs]
      nil
    end
    ann.define_singleton_method(:fixable!) do |node, **kwargs|
      errors << [node, :fixable, [], kwargs]
      nil
    end
    ann.define_singleton_method(:og_declare) { |_name, _node, _type_info| nil }
    ann.instance_variable_set(:@direct_errors, errors)
    ann
  end

  def parse_source(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  def function_from(source, name)
    parse_source(source).statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  def auto_type
    t = Type.new(:Auto, auto: true)
    t.auto_token = token(:TYPE_ID, "Auto")
    t
  end

  def function_def(name, return_type: Type.new(:Void), params: [])
    AST::FunctionDef.new(token(:VAR_ID, name), name, params, [], return_type, nil, [], [], nil, :pub, [], false)
  end

  def symbol_entry(type: Type.new(:Int64), storage: :stack)
    SymbolEntry.new(reg: nil, type: type, mutable: false, storage: storage)
  end

  def call_site_fact(call, id: 1)
    Semantic::CallSiteFact.new(
      id: Semantic::CallSiteId.new(value: id),
      node: call,
      callee_name: call.name,
      args: call.args,
      fn_var_call: call.fn_var_call == true,
      propagates_failure: true
    )
  end

  def with_function_context(ann, return_type: Type.new(:Void))
    ctx = FunctionContext.new(name: "gap", return_type: return_type)
    ann.send(:push_function_context!, ctx)
    yield ctx
  ensure
    ann.send(:pop_function_context!)
  end

  def direct_errors(ann)
    ann.instance_variable_get(:@direct_errors)
  end

  def typed_identifier(name, type, storage: :stack, symbol: nil)
    node = AST::Identifier.new(token(:IDENTIFIER, name), name)
    node.full_type = type
    node.storage = storage
    node.symbol = symbol if symbol
    node
  end

  def with_capability_fact(cap, var_name: nil, type: Type.new(:Counter), sync: :locked, storage: :stack)
    cap[:resolved_type] = type
    if cap[:var_node].respond_to?(:symbol) && cap[:var_node].symbol.nil?
      cap[:var_node].symbol = SymbolEntry.new(reg: nil, type: type, mutable: true, storage: storage, sync: sync)
    end
    capability_transition(cap)
  end

  def transition_for_sync(name, sync: nil, sync_families: nil)
    ident = AST::Identifier.new(token(:IDENTIFIER, name), name)
    ident.full_type = Type.new(:Counter)
    ident.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :heap, sync: sync)
    ident.symbol.sync_families = sync_families
    capability_transition(AST::Capability.new(capability: :EXCLUSIVE, var_node: ident))
  end

  it "covers capability-plan request helpers and atomic admission facts" do
    inferred_cap = AST::Capability.new(
      capability: :infer,
      var_node: AST::Identifier.new(token(:IDENTIFIER, "cell"), "cell"),
    )
    inferred_request = CapabilityPlan::CapabilityRequest.from_ast(inferred_cap)

    expect(inferred_request.inferred?).to be(true)
    expect(inferred_request.effective_alias_name).to eq("cell")

    view_cap = AST::Capability.new(
      capability: :VIEW,
      var_node: AST::Identifier.new(token(:IDENTIFIER, "row"), "row"),
      alias: "view_alias",
    )
    view_request = CapabilityPlan::CapabilityRequest.from_ast(view_cap)
    view_transition = capability_transition(view_cap)

    expect(view_request.effective_alias_name).to eq("view_alias")
    expect(view_transition.view?).to be(true)
    expect(transition_for_sync("plain").view?).to be(false)

    missing_symbol = capability_transition(AST::Capability.new(
      capability: :EXCLUSIVE,
      var_node: AST::Identifier.new(token(:IDENTIFIER, "missing"), "missing"),
    ))

    expect(missing_symbol.admits_atomic?).to be(false)
    expect(transition_for_sync("direct_locked", sync: :locked).send(:exclusive_sync?)).to be(true)
    expect(transition_for_sync("direct_write_locked", sync: :write_locked).send(:exclusive_sync?)).to be(true)
    expect(transition_for_sync("direct_write_locked", sync: :write_locked).write_locked_sync?).to be(true)
    expect(transition_for_sync("direct_locked", sync: :locked).write_locked_sync?).to be(false)
    expect(transition_for_sync("direct_atomic", sync: :atomic).send(:exclusive_sync?)).to be(false)
    expect(transition_for_sync("direct_locked", sync: :locked).exclusive_validation_action).to eq(:valid)
    expect(transition_for_sync("direct_atomic", sync: :atomic).exclusive_validation_action).to eq(:mismatch)
    expect(transition_for_sync("direct_atomic", sync: :atomic).admits_atomic?).to be(true)
    expect(transition_for_sync("bad_family_shape", sync_families: :ATOMIC).admits_atomic?).to be(false)
    expect(transition_for_sync("atomic_family", sync_families: Set[:ATOMIC]).admits_atomic?).to be(true)
    expect(transition_for_sync("snapshotted_family", sync_families: Set[:SNAPSHOTTED]).admits_atomic?).to be(true)
    expect(transition_for_sync("locked_family", sync_families: Set[:LOCKED]).admits_atomic?).to be(false)

    param_ident = AST::Identifier.new(token(:IDENTIFIER, "param_lock"), "param_lock")
    param_ident.full_type = Type.new(:Counter)
    param_ident.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :heap, sync: nil)
    param_ident.symbol.is_param = true
    expect(param_ident.symbol.declared_sync_contract?).to be(false)
    param_transition = capability_transition(AST::Capability.new(capability: :EXCLUSIVE, var_node: param_ident))
    expect(param_transition.send(:parameter_target?)).to be(true)
    expect(param_transition.declared_sync_contract?).to be(false)
    expect(param_transition.deferred_sync_param?).to be(true)
    expect(param_transition.send(:deferred_lock_param?)).to be(true)
    expect(param_transition.exclusive_validation_action).to eq(:defer)

    declared_family_param = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :heap, sync: nil)
    declared_family_param.sync_families = Set[:LOCKED]
    expect(declared_family_param.declared_sync_contract?).to be(true)

    versioned_param = AST::Identifier.new(token(:IDENTIFIER, "versioned_param"), "versioned_param")
    versioned_param.full_type = Type.new(:Counter)
    versioned_param.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :stack, sync: :versioned)
    versioned_param.symbol.is_param = true
    versioned_param.symbol.sync_families = Set[:VERSIONED]
    expect(versioned_param.symbol.declared_sync_contract?).to be(true)
    versioned_transition = capability_transition(AST::Capability.new(capability: :EXCLUSIVE, var_node: versioned_param))
    expect(versioned_transition.send(:parameter_target?)).to be(true)
    expect(versioned_transition.send(:exclusive_sync?)).to be(false)
    expect(versioned_transition.declared_sync_contract?).to be(true)
    expect(versioned_transition.deferred_sync_param?).to be(false)
    expect(versioned_transition.exclusive_validation_action).to eq(:declared_contract)
    versioned_param.symbol.sync = nil
    versioned_param.symbol.sync_families = :VERSIONED
    expect(versioned_param.symbol.declared_sync_contract?).to be(false)

    literal_target = AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack)
    literal_field = AST::GetField.new(token(:DOT, "."), literal_target, "fallback")
    expect(CapabilityPlan.var_name_for(literal_field)).to eq("fallback")

    with_without_plan = AST::WithBlock.new(token(:WITH, "WITH"), [], [])
    expect {
      CapabilityPlan.require_for(with_without_plan)
    }.to raise_error(/without a CapabilityPlan/)

    param = AST::Param.new(name: "cell", type: Type.new(:Counter), mutable: true)
    param.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :heap)
    fn = function_def("refresh_without_plan", params: [param])
    fn.body = [with_without_plan]

    expect { CapabilityPlan.refresh_function_plans!(fn, []) }.not_to raise_error
  end

  it "annotates default fixed-array literals with their target type" do
    ann = quiet_annotator
    lit = AST::DefaultArrayLit.new(token(:KEYWORD, "DEFAULT"), Type.array_of(:Bool, capacity: 3), :heap)

    result = ann.send(:visit_DefaultArrayLit, lit)

    expect(result).to eq(Type.array_of(:Bool, capacity: 3))
    expect(lit.full_type).to eq(Type.array_of(:Bool, capacity: 3))
    expect(lit.storage).to eq(:stack)
  end

  it "marks sync field WITH aliases as non-escaping" do
    expect_compile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      STRUCT Env { cell: Counter @locked }
      FN main() RETURNS Void ->
        env = Env{ cell: Counter{ value: 0 } @locked };
        WITH EXCLUSIVE env.cell AS inner {
          inner.value = inner.value + 1;
        }
        RETURN;
      END
    CLEAR
  end

  it "raises a clear invariant error when a type stamp is missing" do
    ann = quiet_annotator
    ident = AST::Identifier.new(token(:IDENTIFIER, "x"), "x")

    expect {
      ann.send(:stamp_type!, ident, nil)
    }.to raise_error(RuntimeError, /annotation stamp missing type for AST::Identifier/)
  end

  it "dispatches extern declarations through the generic visitor" do
    ann = SemanticAnnotator.new(source_code: "")
    extern_fn = AST::ExternFnDecl.new(
      token(:VAR_ID, "native_len"),
      "native_len",
      [AST::Param.new(name: "s", type: Type.new(:String), default: nil, mutable: false, takes: false)],
      Type.new(:Int64),
      "native",
      nil
    )

    result = ann.send(:visit, extern_fn)

    signature = FunctionSignature.unwrap(ann.send(:current_scope).resolve_entry!("native_len").type)
    expect(result).to be_nil
    expect(signature.extern).to eq(true)
    expect(signature.return_type.resolved).to eq(:Int64)
    expect(extern_fn.full_type!.resolved).to eq(:Void)
  end

  def record_body_summaries(ann, graph, propagating: {}, raises: Set.new, fnptr: Set.new)
    graph.each do |name, callees|
      callee_set = callees.to_set
      prop_set = (propagating.key?(name) ? propagating.fetch(name) : callee_set).to_set
      ann.send(:record_function_body_summary!, Annotator::Phases::FunctionBodySummary.new(
        name: name,
        callees: callee_set,
        propagating_callees: prop_set,
        has_fnptr_call: fnptr.include?(name),
        raises_directly: raises.include?(name)
      ))
    end
  end

  def empty_body_summary
    Annotator::Phases::BodyScanSummary.new(
      callees: Set.new,
      propagating_callees: Set.new,
      has_fnptr_call: false,
      raises_directly: false
    )
  end

  def body_fact_summary(ann, nodes = nil, &block)
    ann.send(:with_body_fact_frame, Semantic::BodyIdentity.unassigned) do
      if block
        block.call
      else
        Array(nodes).each { |node| ann.send(:record_body_fact_node!, node) }
      end
    end
  end

  it "marks non-stack list literal backing storage as frame-allocated" do
    ann = quiet_annotator
    item = AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack)
    list = AST::ListLit.new(token, [item], :heap)

    ann.send(:visit_ListLit, list)

    expect(list.full_type).to be_frame
    expect(list.full_type.location).to eq(:frame)
  end

  it "covers collection return inference across stream and list receiver shapes" do
    ann = quiet_annotator

    receiver = AST::Identifier.new(token, "xs")
    [
      [Type.new(:"~Int64[]"), :Int64],
      [Type.new(:"~Int64[3]"), :Int64],
      [Type.new(:"~Int64[INF]"), :Int64],
      [Type.new(:"~?Int64[]"), :Int64],
      [Type.new(:"String[]"), :String],
    ].each do |receiver_type, expected_elem|
      receiver.full_type = receiver_type
      inferred = ann.send(:infer_to_list, [receiver], nil)
      expect(inferred.element_type.resolved).to eq(expected_elem)
      expect(inferred.list_collection?).to be(true)
      expect(inferred.location).to eq(:heap)
    end
  end

  it "covers moved annotator domain defensive branches directly" do
    ann = quiet_annotator

    with_node = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(
        capability: :EXCLUSIVE,
        var_node: AST::Identifier.new(token, "cell"),
        alias_mutable: true,
      ),
      AST::Capability.new(
        capability: :EXCLUSIVE,
        var_node: AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack),
      ),
    ], [])
    with_node.arms = [AST::WithMatchArm.new(family: :VERSIONED)]
    with_node.snapshot_mode = nil

    fact_builder = method(:with_capability_fact)
    ann.define_singleton_method(:acquire_capability!) { |_node, cap, expanded| expanded.add(fact_builder.call(cap)) }
    ann.define_singleton_method(:check_nested_lock_reacquire!) { |_node, _caps| nil }
    ann.define_singleton_method(:check_lock_rank_ordering!) { |_node, _caps| nil }
    ann.define_singleton_method(:record_with_acquire!) { |_fn, _cap, _held, _escape| nil }
    ann.define_singleton_method(:cap_var_name) { |node| node.respond_to?(:name) ? node.name : "cap" }
    ann.define_singleton_method(:lock_identity_of) { |_cap| :Counter }
    ann.define_singleton_method(:with_new_scope) { |_scope, &blk| blk.call }
    ann.define_singleton_method(:current_scope) { nil }
    ann.define_singleton_method(:declare_capability_scope!) { |_cap| nil }
    ann.define_singleton_method(:validate_and_visit_with_guards!) { |_node| nil }
    ann.define_singleton_method(:validate_with_guard_no_body_mutation!) { |_node| nil }
    ann.define_singleton_method(:retryable_with_fallible_sources) { |_body| [] }
    ann.define_singleton_method(:retryable_with_universal_poly_candidate?) { |_node| false }
    ann.define_singleton_method(:finalize_scope) { |_node| nil }
    ann.define_singleton_method(:validate_no_multi_object_atomic!) { |_node| nil }
    ann.define_singleton_method(:validate_lock_error_clause!) { |_node, _caps| nil }
    ann.define_singleton_method(:validate_snapshot_match_arms!) { |_node| nil }
    ann.define_singleton_method(:visit_stmts) do |_body|
      send(:ownership_graph).mark_moved("captured", action: :capture)
    end

    ann.send(:visit_WithBlock, with_node)

    infer_without_symbol = AST::Capability.new(
      capability: :infer,
      var_node: AST::Identifier.new(token, "missing"),
    )
    infer_with_sync = AST::Capability.new(
      capability: :infer,
      var_node: AST::Identifier.new(token, "syncy"),
    )
    infer_with_sync[:var_node].symbol = SymbolEntry.new(
      reg: nil,
      type: Type.new(:Int64),
      mutable: true,
      storage: :heap,
      sync: :atomic,
    )

    expect(capability_transition(infer_without_symbol).sync_constrained?).to be(false)
    expect(capability_transition(infer_with_sync).sync_constrained?).to be(true)
    expect(ann.send(:field_name_for_msg, AST::GetField.new(token, AST::Identifier.new(token, "x"), nil))).to eq("<field>")
    expect(ann.send(:match_variant_name, AST::MethodCall.new(token, AST::Identifier.new(token, "Result"), "Ok", []))).to eq("Ok")

    codes = direct_errors(ann).map { |e| e[1] }
    expect(codes).to include(:WITH_MATCH_VERSIONED_AS_MUTABLE, :WITH_MATCH_MULTI_CELL)
  end

  it "reports tokenless struct-pattern field diagnostics" do
    ann = quiet_annotator
    ann.send(:current_scope).declare_type(:Point, Schemas::StructSchema.new(
      fields: { "x" => AST::StructField.new(type: Type.new(:Int64)) }
    ))

    subject = AST::Identifier.new(token, "point")
    subject.full_type = Type.new(:Point)
    match = AST::MatchStatement.new(token(:MATCH, "MATCH"), subject, [], nil, nil, nil, false, false)
    field = AST::PatternField.new(name: "missing", value: :bind, name_token: nil)
    pattern = AST::StructPattern.new(token, [field], false)

    ann.send(:annotate_struct_pattern!, match, pattern)

    expect(direct_errors(ann).map { |err| err[1] }).to include(:MATCH_FIELD_UNKNOWN)
    expect(pattern.full_type!.resolved).to eq(:Point)
  end

  it "annotates struct extra-patterns in match arms" do
    ann = quiet_annotator
    ann.send(:current_scope).declare_type(:Point, Schemas::StructSchema.new(
      fields: { "x" => AST::StructField.new(type: Type.new(:Int64)) }
    ))
    ann.define_singleton_method(:visit) do |node|
      node.full_type = Type.new(:Point) if node.respond_to?(:full_type=)
      nil
    end

    subject = AST::Identifier.new(token, "point")
    pattern = AST::Identifier.new(token, "Point")
    extra = AST::StructPattern.new(token, [], false)
    match = AST::MatchStatement.new(
      token(:MATCH, "MATCH"),
      subject,
      [AST::MatchCase.new(kind: :eq, value: pattern, extra_values: [extra], body: [])],
      nil,
      nil,
      nil,
      false,
      false
    )

    ann.send(:visit_MatchStatement, match)

    expect(extra.full_type!.resolved).to eq(:Point)
  end

  it "stops union destructure binding after an unknown tokenless field" do
    ann = quiet_annotator
    ann.send(:current_scope).declare_type(:Result, Schemas::UnionSchema.new(
      variants: {
        "Ok" => Schemas::InlineStructVariant.new(fields: { "value" => Type.new(:Int64) })
      }
    ))
    ann.define_singleton_method(:visit) do |node|
      node.full_type = Type.new(:Result) if node.respond_to?(:full_type=)
      nil
    end

    subject = AST::Identifier.new(token, "result")
    variant = AST::GetField.new(token, AST::Identifier.new(token, "Result"), "Ok")
    missing = AST::PatternField.new(name: "missing", value: :bind, name_token: nil)
    destructure = AST::StructPattern.new(token, [missing], false)
    match = AST::MatchStatement.new(
      token(:MATCH, "MATCH"),
      subject,
      [AST::MatchCase.new(kind: :eq, value: variant, destructure: destructure, body: [])],
      nil,
      nil,
      nil,
      false,
      false
    )

    ann.send(:visit_MatchStatement, match)

    expect(direct_errors(ann).map { |err| err[1] }).to include(:MATCH_DESTRUCTURE_FIELD_UNKNOWN)
    expect(ann.send(:current_scope).entry?("missing")).to be(false)
  end

  it "records TRUE identifier while loops and visits scalar loop bodies" do
    ann = quiet_annotator
    seen = []
    effects = []
    ann.define_singleton_method(:visit) do |node|
      seen << node
      node.full_type = Type.new(:Bool) if node.respond_to?(:full_type=)
      nil
    end
    ann.define_singleton_method(:record_effect) { |effect| effects << effect }

    condition = AST::Identifier.new(token(:IDENTIFIER, "TRUE"), "TRUE")
    body = AST::PassStmt.new(token(:PASS, "PASS"))
    loop = AST::WhileLoop.new(token(:WHILE, "WHILE"), condition, body, nil)

    ann.send(:visit_WhileLoop, loop)

    expect(seen).to include(condition, body)
    expect(effects).to include(EffectTracker::LOOP_UNBOUND)
  end

  it "skips captured moved values while validating WHILE EXISTS AS loops" do
    ann = quiet_annotator
    condition = AST::Identifier.new(token, "next_value")
    condition.full_type = Type.optional_of(:String)
    ann.define_singleton_method(:visit) { |_node| nil }
    ann.define_singleton_method(:visit_stmts) { |_body| nil }
    ann.define_singleton_method(:finalize_scope) { |_node| nil }
    ann.define_singleton_method(:record_capture_local!) { |_name| nil }
    ann.define_singleton_method(:classify_ownership!) { |_entry| nil }
    ann.define_singleton_method(:og_declare) { |_name, _node, _type_info| nil }
    ann.define_singleton_method(:collect_body_identifier_names) { |_body| Set["captured"] }
    ann.define_singleton_method(:analyze_control_flow_branches) do |branches, merge_to_parent: true|
      branches.map(&:call)
    end
    capture_context = Struct.new(:analysis).new(Struct.new(:captures).new({ "captured" => true }))
    ann.define_singleton_method(:current_capture_context) { capture_context }
    ann.send(:ownership_graph).declare("captured", kind: :affine, type_info: Type.new(:String), scope_depth: 0)

    loop = AST::WhileBindLoop.new(
      token(:WHILE, "WHILE"),
      condition,
      "item",
      token(:VAR_ID, "item"),
      [AST::Identifier.new(token, "captured")],
      nil
    )

    ann.send(:visit_WhileBindLoop, loop)

    expect(direct_errors(ann).map { |err| err[1] }).not_to include(:USE_OF_MOVED_IN_LOOP_SHORT)
  end

  it "resolves CATCH types after body traversal registers error types" do
    ann = quiet_annotator
    exit_node = AST::OrElseExit.new(token(:OR_ELSE, "OR_ELSE"), :Input, "GapSeededError", nil)
    fn = function_def("seeded")
    fn.body = [exit_node]
    clause = AST::CatchClause.new(
      items: [AST::CatchItem.new(form: :type, name: "GapSeededError", token: token(:TYPE_ID, "GapSeededError"))],
      body: []
    )
    fn.catch_clauses = [clause]
    program = AST::Program.new(token(:PROGRAM, "PROGRAM"), [fn])

    declarations = Annotator::Phases::DeclarationIndexer.index(program)
    ann.send(:visit, exit_node)
    ann.send(:resolve_catch_clauses_from_declarations!, declarations)

    expect(AST.error_type?(:GapSeededError)).to be(true)
    expect(AST.kind_of_type(:GapSeededError)).to eq(:Input)
    expect(clause.types).to eq(["GapSeededError"])
  end

  it "visits sync-policy exit messages and block bodies" do
    ann = quiet_annotator
    visited = []
    bodies = []
    ann.define_singleton_method(:visit) { |node| visited << node }
    ann.define_singleton_method(:visit_stmts) { |body| bodies << body }

    message = AST::Literal.new(token(:STRING, "timeout"), :STRING, "timeout", :heap)
    body_stmt = AST::PassStmt.new(token(:PASS, "PASS"))
    policy = AST::SyncPolicyDecl.new(token(:SYNC, "SYNC"), [
      AST::ErrorClause.new(selectors: [], action: AST::ErrorActionKind::Exit, retries: nil, token: token, message: message),
      AST::ErrorClause.new(selectors: [], action: AST::ErrorActionKind::Block, retries: nil, token: token, body: [body_stmt]),
    ])

    ann.send(:visit_SyncPolicyDecl, policy)

    expect(visited).to eq([message])
    expect(bodies).to eq([[body_stmt]])
  end

  it "visits DIE status expressions and stamps NoReturn" do
    ann = quiet_annotator
    visited = []
    ann.define_singleton_method(:visit) { |node| visited << node }

    status = AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack)
    die = AST::DieNode.new(token(:DIE, "DIE"), status)

    ann.send(:visit_DieNode, die)

    expect(visited).to eq([status])
    expect(die.full_type!.resolved).to eq(:NoReturn)
  end

  it "reports unregistered type-only error exits" do
    ann = quiet_annotator
    exit_node = AST::OrElseExit.new(token(:OR_ELSE, "OR_ELSE"), nil, "NeverRegisteredGapError", nil)

    ann.send(:resolve_error_registration!, exit_node, nil, "NeverRegisteredGapError", exit_node.token)

    expect(direct_errors(ann).map { |err| err[1] }).to include(:ERROR_TYPE_NOT_REGISTERED)
    expect(exit_node.kind).to be_nil
  end

  it "reports inline BG captures on returns" do
    ann = quiet_annotator
    value = AST::Identifier.new(token, "handle")
    value.full_type = Type.new(:Int64)
    ann.define_singleton_method(:visit) { |_node| nil }
    ann.define_singleton_method(:collect_bg_sources_in_expr) { |_node| [value] }
    ann.define_singleton_method(:lookup_source_name) { |_node| "handle" }
    ann.define_singleton_method(:verify_return) { |_node| nil }
    ann.define_singleton_method(:verify_tied_return!) { |_node| nil }
    ann.define_singleton_method(:return_value_type) { |_node| Type.new(:Int64) }
    ann.define_singleton_method(:return_type_compatible?) { |_actual, _expected| true }

    with_function_context(ann, return_type: Type.new(:Int64)) do
      ann.send(:visit_ReturnNode, AST::ReturnNode.new(token(:RETURN, "RETURN"), value))
    end

    expect(direct_errors(ann).map { |err| err[1] }).to include(:RETURN_BORROWED_NO_COPY_OR_LIFETIME)
  end

  it "reports returning indexed WITH-scoped borrows" do
    ann = quiet_annotator
    entry = symbol_entry(type: Type.array_of(:Int64), storage: :borrow)
    entry.mark_non_escaping!
    target = AST::Identifier.new(token, "items")
    target.symbol = entry
    value = AST::GetIndex.new(token, target, AST::Literal.new(token(:INT64, "0"), :INT64, 0, :stack))
    value.full_type = Type.new(:Int64)
    ann.send(:phase_receiver_state).with_block_depth = 1
    ann.define_singleton_method(:visit) { |_node| nil }
    ann.define_singleton_method(:collect_bg_sources_in_expr) { |_node| [] }
    ann.define_singleton_method(:verify_return) { |_node| nil }
    ann.define_singleton_method(:verify_tied_return!) { |_node| nil }
    ann.define_singleton_method(:return_value_type) { |_node| Type.new(:Int64) }
    ann.define_singleton_method(:return_type_compatible?) { |_actual, _expected| true }

    with_function_context(ann, return_type: Type.new(:Int64)) do
      ann.send(:visit_ReturnNode, AST::ReturnNode.new(token(:RETURN, "RETURN"), value))
    end

    expect(direct_errors(ann).map { |err| err[1] }).to include(:RETURN_INDEX_FROM_WITH_SCOPED)
  end

  it "covers OR_ELSE EXIT, OR_ELSE BREAK, and optional OR_ELSE fallback branches" do
    ann = quiet_annotator
    ann.define_singleton_method(:visit) { |_node| nil }

    left = AST::Identifier.new(token, "value")
    left.full_type = Type.new(:Int64)
    exit_right = AST::OrElseExit.new(token(:OR_ELSE, "OR_ELSE"), nil, nil, nil)
    exit_right.full_type = Type.new(:NoReturn)
    exit_expr = AST::BinaryOp.new(token(:OR_ELSE, "OR_ELSE"), left, :OR_ELSE, exit_right)
    ann.send(:visit_OrElse, exit_expr)
    expect(exit_expr.full_type!.resolved).to eq(:Int64)

    break_right = AST::OrElseBreak.new(token(:OR_ELSE, "OR_ELSE"))
    break_right.full_type = Type.new(:NoReturn)
    break_expr = AST::BinaryOp.new(token(:OR_ELSE, "OR_ELSE"), left, :OR_ELSE, break_right)
    ann.send(:with_loop_context) { ann.send(:visit_OrElse, break_expr) }
    expect(break_expr.full_type!.resolved).to eq(:Int64)

    optional_left = AST::Identifier.new(token, "maybe")
    optional_left.full_type = Type.optional_of(:Int64)
    fallback = AST::Identifier.new(token, "fallback")
    fallback.full_type = Type.new(:String)
    optional_expr = AST::BinaryOp.new(token(:OR_ELSE, "OR_ELSE"), optional_left, :OR_ELSE, fallback)
    ann.send(:visit_OrElse, optional_expr)

    expect(optional_expr.full_type!.resolved).to eq(:Int64)
    expect(direct_errors(ann).map { |err| err[1] }).to include(:TYPE_MISMATCH_IN_OR)

    map_type = Type.new(:"HashMap<String, Any>")
    optional_map = AST::Identifier.new(token, "maybe_map")
    optional_map.full_type = Type.optional_of(map_type)
    map_fallback = AST::Identifier.new(token, "map_fallback")
    map_fallback.full_type = map_type
    map_expr = AST::BinaryOp.new(token(:OR_ELSE, "OR_ELSE"), optional_map, :OR_ELSE, map_fallback)
    ann.send(:visit_OrElse, map_expr)

    expect(map_expr.full_type!).to be_map
    expect(map_expr.full_type!.value_type.resolved).to eq(:Any)
  end

  it "covers expression visitor fallback and scalar binding branches" do
    ann = quiet_annotator
    ann.define_singleton_method(:visit) { |_node| nil }

    right = AST::Identifier.new(token, "n")
    right.full_type = Type.new(:Int64)
    unary = AST::UnaryOp.new(token(:OPERATOR, "~"), :BIT_NOT, right)
    ann.send(:visit_UnaryOp, unary)
    expect(unary.full_type!.resolved).to eq(:Int64)

    unknown = AST::Literal.new(token(:UNKNOWN, "?"), :UNKNOWN, "?", :stack)
    ann.send(:visit_Literal, unknown)
    expect(unknown.full_type!.resolved).to eq(:Any)

    default = AST::DefaultLit.new(token(:DEFAULT, "DEFAULT"))
    ann.send(:visit_DefaultLit, default)
    expect(default.full_type!.resolved).to eq(:Any)

    placeholder = AST::Placeholder.new(token(:UNDERSCORE, "_"))
    seen_placeholder = []
    ann.define_singleton_method(:visit_Identifier) { |node| seen_placeholder << node.name }
    ann.send(:visit_Placeholder, placeholder)
    expect(seen_placeholder).to eq(["_"])

    scalar = AST::Identifier.new(token, "scalar")
    scalar.full_type = Type.new(:Int64)
    binding = AST::Identifier.new(token, "item")
    bind = AST::BinaryOp.new(token(:AS, "AS"), scalar, :BIND_VAR, binding)
    ann.send(:visit_BindVar, bind)
    expect(ann.send(:current_scope).resolve_entry!("item").type.resolved).to eq(:Int64)
    expect(bind.full_type!.resolved).to eq(:Int64)
  end

  it "reports invalid indirect atomic capability combinations" do
    ann = quiet_annotator
    ann.define_singleton_method(:visit) { |_node| nil }
    value = AST::Identifier.new(token, "box")
    value.full_type = Type.new(:Box)
    cap = AST::CapabilityWrap.new(token(:ATOMIC, "@atomic"), value, :local, :atomic, :indirect)

    ann.send(:visit_CapabilityWrap, cap)

    expect(direct_errors(ann).map { |err| err[1] }).to include(:LOCAL_INDIRECT_ATOMIC)
    expect(cap.full_type!.atomic_ptr?).to be(true)
  end

  it "recovers from missing expression match cases and flags non-copyable expression results" do
    ann = quiet_annotator
    box_type = Type.new(:Box)

    if_node = AST::IfStatement.new(token(:IF, "IF"), AST::Literal.new(token(:TRUE, "TRUE"), :BOOLEAN, true, :stack), [], [], nil, nil)
    if_node.then_result_type = box_type
    if_node.else_result_type = box_type
    ann.send(:promote_to_expr_if!, if_node, if_node)
    expect(if_node.full_type!.resolved).to eq(:Box)

    missing_value_if = AST::IfStatement.new(token(:IF, "IF"), AST::Literal.new(token(:TRUE, "TRUE"), :BOOLEAN, true, :stack), [], [], nil, nil)
    ann.send(:promote_to_expr_if!, missing_value_if, missing_value_if)
    expect(missing_value_if.full_type!.resolved).to eq(:Any)

    empty_match = AST::MatchStatement.new(token(:MATCH, "MATCH"), AST::Identifier.new(token, "tag"), [], nil, nil, nil, true, false)
    empty_match.case_result_types = []
    empty_match.default_result_type = nil
    ann.send(:promote_to_expr_match!, empty_match, empty_match)
    expect(empty_match.full_type!.resolved).to eq(:Any)

    boxed_match = AST::MatchStatement.new(token(:MATCH, "MATCH"), AST::Identifier.new(token, "tag"), [], nil, nil, nil, true, false)
    boxed_match.case_result_types = [box_type]
    boxed_match.default_result_type = nil
    ann.send(:promote_to_expr_match!, boxed_match, boxed_match)
    expect(boxed_match.full_type!.resolved).to eq(:Box)

    codes = direct_errors(ann).map { |err| err[1] }
    expect(codes).to include(:IF_EXPR_RESULT_NOT_COPYABLE, :MATCH_EXPR_NEEDS_CASE, :MATCH_EXPR_RESULT_NOT_COPYABLE)
  end

  it "covers scoped lifetime storage and root traversal branches" do
    ann = quiet_annotator
    scoped = symbol_entry(type: Type.new(:Int64), storage: :borrow)
    scoped.mark_non_escaping!
    value = AST::Identifier.new(token, "alias")
    value.symbol = scoped
    value.full_type = Type.new(:Int64)

    expect(ann.send(:ensure_owned_value!, value, Type.new(:Int64), "Box")).to be_nil

    managed_scoped = symbol_entry(type: Type.new(:String), storage: :borrow)
    managed_scoped.mark_non_escaping!
    managed_value = AST::Identifier.new(token, "managed_alias")
    managed_value.symbol = managed_scoped
    managed_value.full_type = Type.new(:String)
    ann.send(:ensure_owned_value!, managed_value, Type.new(:String), "Box")

    field = AST::GetField.new(token(:DOT, "."), AST::Identifier.new(token, "root"), "child")
    index = AST::GetIndex.new(token(:LBRACKET, "["), field, AST::Literal.new(token(:INT64, "0"), :INT64, 0, :stack))
    expect(ann.send(:get_root_object, index).name).to eq("root")

    bad_value = AST::Identifier.new(token, "borrowed")
    bad_value.symbol = scoped
    bad_value.define_singleton_method(:full_type!) { |context: nil| :"??Int64" }
    decl = AST::VarDecl.new(token(:VAR_ID, "dest"), "dest", Type.new(:Box), bad_value, false)
    ann.send(:reject_scoped_assignment_move!, decl)

    codes = direct_errors(ann).map { |err| err[1] }
    expect(codes).to include(:STORE_WITH_SCOPED_INTO_CONTAINER, :MOVE_WITH_SCOPED)
  end

  it "collects resource drops and reports unconsumed future drops" do
    ann = quiet_annotator
    resource = symbol_entry(type: Type.new(:File), storage: :stack)
    resource.ownership_kind = :resource
    promise = symbol_entry(type: Type.new(:"~String"), storage: :stack)
    promise.ownership_kind = :affine
    ann.send(:current_scope).install_entry("file_handle", resource)
    ann.send(:current_scope).install_entry("promise", promise)
    ann.send(:ownership_graph).declare("file_handle", kind: :resource, type_info: Type.new(:File), scope_depth: 0, line: 1)
    ann.send(:ownership_graph).declare("promise", kind: :affine, type_info: Type.new(:"~String"), scope_depth: 0, line: 1)
    match = AST::MatchStatement.new(token(:MATCH, "MATCH"), AST::Identifier.new(token, "tag"), [], nil, nil, nil, true, false)

    drops = ann.send(:collect_scope_drops, node: match)

    expect(drops.map(&:name)).to include("file_handle", "promise")
    expect(drops.find { |drop| drop.name == "file_handle" }.resource).to be(true)
    expect(direct_errors(ann).map { |err| err[1] }).to include(:PROMISE_NOT_CONSUMED)
  end

  it "uses atomic escape fixes for tied assignment lifetime violations" do
    ann = quiet_annotator
    source = symbol_entry(type: Type.new(:Cell), storage: :heap)
    source.scope_depth = 2
    carried = symbol_entry(type: Type.new(:Cell), storage: :heap)
    carried.lifetime = [source]
    dest = symbol_entry(type: Type.new(:Cell), storage: :heap)
    dest.scope_depth = 0
    target = AST::Identifier.new(token, "dest")
    target.symbol = dest
    value = AST::Identifier.new(token, "carried")
    value.symbol = carried
    value.full_type = Type.new(:Cell)
    ann.define_singleton_method(:build_atomic_escape_migration_fix) { |_source, _name| :atomic_fix }
    assign = AST::Assignment.new(token(:EQUAL, "="), target, value)

    ann.send(:verify_tied_assignment!, assign)

    fix = direct_errors(ann).find { |err| err[1] == :fixable }
    expect(fix).not_to be_nil
    expect(fix[3][:fixes]).to eq([:atomic_fix])
  end

  it "falls back to function parameters when looking up lifetime source names" do
    ann = quiet_annotator
    source = symbol_entry(type: Type.new(:String), storage: :stack)
    param = AST::Param.new(name: "arg", type: Type.new(:String), default: nil, mutable: false, takes: false, symbol: source)
    fn = function_def("source_name", params: [param])
    ann.semantic_function_nodes.replace({ "source_name" => fn })

    expect(ann.send(:lookup_source_name, source)).to eq("arg")
  end

  it "walks object receivers and non-target values for root variable names" do
    ann = quiet_annotator
    receiver = AST::Identifier.new(token, "receiver")
    call = AST::MethodCall.new(token(:DOT, "."), receiver, "next", [])
    field = AST::GetField.new(token(:DOT, "."), receiver, "value")

    expect(ann.send(:root_variable_name, field)).to eq("receiver")
    expect(ann.send(:root_variable_name, call)).to eq("receiver")
    expect(ann.send(:root_variable_name, AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack))).to be_nil
  end

  it "preserves specific ownership move actions while backfilling consumer types" do
    ann = quiet_annotator
    ident = AST::Identifier.new(token, "owned")
    ident.full_type = Type.new(:Box)
    og = ann.send(:ownership_graph)
    og.declare("owned", kind: :owned, type_info: Type.new(:Box), scope_depth: 0, line: 1)
    og.mark_moved("owned", action: :give)
    existing = T.must(og.nodes["owned"])
    consumer = Type.new(:Box)

    ann.send(:move_if_not_copyable!, ident, action: :takes, consumer_param_type: consumer)

    expect(existing.move_action).to eq(:give)
    expect(existing.move_consumer_param_type).to eq(consumer)
    expect(ident.was_moved).to be(true)
  end

  it "covers member access index, moved path, slice, and empty heap-list branches" do
    ann = quiet_annotator
    ann.define_singleton_method(:visit) { |_node| nil }

    unwrapped = AST::OptionalUnwrap.new(token(:QUESTION, "?"), AST::Identifier.new(token, "items"))
    unwrapped.full_type = Type.array_of(:Int64)
    index = AST::Literal.new(token(:INT64, "0"), :INT64, 0, :stack)
    get_index = AST::GetIndex.new(token(:LBRACKET, "["), unwrapped, index)
    ann.send(:visit_GetIndex, get_index)
    expect(get_index.full_type!.optional?).to be(true)
    expect(get_index.full_type!.wrapped_type.resolved).to eq(:Int64)

    root = AST::Identifier.new(token, "root")
    root.full_type = Type.new(:Box)
    ann.send(:ownership_graph).declare("root", kind: :affine, type_info: Type.new(:Box), scope_depth: 0, line: 1)
    T.must(ann.send(:ownership_graph).nodes["root"]).state = :moved
    moved_field = AST::GetField.new(token(:DOT, "."), root, "*")
    ann.send(:visit_GetField, moved_field)
    expect(moved_field.full_type!.resolved).to eq(:Void)

    scalar = AST::Identifier.new(token, "scalar")
    scalar.full_type = Type.new(:Int64)
    slice = AST::Slice.new(token(:LBRACKET, "["), scalar, nil, nil)
    ann.send(:visit_Slice, slice)
    expect(slice.full_type!.resolved).to eq(:Any)

    list = AST::ListLit.new(token(:LBRACKET, "["), [], :heap)
    ann.send(:visit_ListLit, list)
    expect(list.full_type!.location).to eq(:heap)
  end

  it "covers field-access schema rejection branches" do
    ann = quiet_annotator
    ann.define_singleton_method(:visit) { |_node| nil }
    schemas = {
      Color: Schemas::EnumSchema.new(variants: [:Red]),
      Choice: Schemas::UnionSchema.new(variants: { Some: Type.new(:Int64), None: nil }),
      Box: Schemas::StructSchema.new(fields: {
        "value" => AST::StructField.new(type: Type.new(:Int64)),
      }),
    }
    ann.define_singleton_method(:lookup_type_schema) do |type_name|
      schemas[type_name.to_sym]
    end

    ann.send(:visit_GetField, AST::GetField.new(token(:DOT, "."), typed_identifier("color", Type.new(:Color)), "Red"))
    ann.send(:visit_GetField, AST::GetField.new(token(:DOT, "."), typed_identifier("choice", Type.new(:Choice)), "Some"))
    ann.send(:visit_GetField, AST::GetField.new(token(:DOT, "."), typed_identifier("n", Type.new(:Int64)), "field"))
    ann.send(:visit_GetField, AST::GetField.new(nil, typed_identifier("box", Type.new(:Box)), "missing"))

    codes = direct_errors(ann).map { |err| err[1] }
    expect(codes).to include(:ENUM_FIELD_ACCESS, :UNION_FIELD_ACCESS)
    expect(codes.count(:ILLEGAL_FIELD_LOOKUP)).to eq(2)
  end

  it "raises on observable terminal declaration mismatches" do
    ann = quiet_annotator
    left = AST::Identifier.new(token, "stream")
    right = AST::Placeholder.new(token(:UNDERSCORE, "_"))
    pipe = AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, right)
    pipe.observable_terminal = :sum
    pipe.full_type = Type.new(:Int64, observable: true, observable_terminal: :sum)
    decl = AST::VarDecl.new(
      token(:VAR_ID, "running"),
      "running",
      Type.new(:"~Int64", observable: true, observable_terminal: :count),
      pipe,
      false
    )

    ann.send(:promote_pipe_to_observable_dest!, decl)
    error = direct_errors(ann).find { |err| err[1] == :OBSERVABLE_TERMINAL_MISMATCH }
    expect(error).not_to be_nil
    expect(error[3]).to include(lhs: ":count", pipe: ":sum")
  end

  it "notes bare affine versioned declarations without a token-local fix" do
    ann = quiet_annotator
    notes = []
    ann.define_singleton_method(:note!) { |node, message| notes << [node, message] }
    ann.define_singleton_method(:verify_unrestricted!) { |_node| nil }
    ann.define_singleton_method(:handle_assign_move) { |_node| nil }
    ann.define_singleton_method(:handle_assign_borrow) { |_node| nil }
    ann.define_singleton_method(:validate_type_annotation!) { |_node, _type| nil }
    ann.define_singleton_method(:validate_stream_type!) { |_node| nil }
    ann.define_singleton_method(:promote_pipe_to_observable_dest!) { |_node| nil }
    ann.define_singleton_method(:check_prefixed_int_range!) { |_node, _type| nil }
    ann.define_singleton_method(:propagate_declared_type_to_value!) { |_node, _type| nil }
    ann.define_singleton_method(:finalize_decl_storage!) { |_node, _type| :stack }
    ann.define_singleton_method(:propagate_collection_metadata!) { |_node, _type| nil }
    ann.define_singleton_method(:propagate_call_flags!) { |_node| nil }
    ann.define_singleton_method(:set_cleanup_alloc!) { |_node| nil }
    ann.define_singleton_method(:resolve_resource_close) do |_node|
      Type::ResourceCloseResult.new(is_resource: false, close_plan: nil)
    end
    ann.define_singleton_method(:record_capture_local!) { |_name| nil }
    ann.define_singleton_method(:classify_ownership!) { |_sym| nil }
    ann.define_singleton_method(:og_declare) { |_name, _node, _type| nil }
    ann.define_singleton_method(:register_container_borrow!) { |_node| nil }
    ann.define_singleton_method(:accumulate_stack_bytes) { |_storage, _node| nil }
    ann.define_singleton_method(:track_union_alias) { |_name, _value| nil }
    ann.define_singleton_method(:record_capability_binding) { |_name, _node, _type, _storage| nil }

    value = AST::Identifier.new(token, "source")
    versioned = Type.new(:Cell, sync: :versioned)
    value.full_type = Type.new(:Cell)
    value.define_singleton_method(:coerce!) { |_type| [versioned, nil] }
    decl = AST::VarDecl.new(token(:VAR_ID, "cell"), "cell", versioned, value, false)
    decl.full_type = versioned

    ann.send(:finalize_decl_node!, decl, false)

    expect(notes.map(&:last).join("\n")).to include("Bare `@versioned`")
  end

  it "returns after undefined identifier suggestions" do
    ann = quiet_annotator
    missing = AST::Identifier.new(token(:IDENTIFIER, "missing"), "missing")

    ann.send(:visit_Identifier, missing)

    expect(direct_errors(ann)).not_to be_empty
  end

  it "dispatches assignment targets and rejects invalid targets" do
    ann = quiet_annotator
    ann.send(:current_scope).declare("x", nil, Type.new(:Int64), true, false, nil, :stack)
    ann.define_singleton_method(:visit) { |_node| nil }
    ann.define_singleton_method(:verify_unrestricted!) { |_node| nil }
    ann.define_singleton_method(:verify_tied_assignment!) { |_node| nil }
    ann.define_singleton_method(:handle_assign_move) { |_node| nil }
    ann.define_singleton_method(:handle_assign_borrow) { |_node| nil }
    ann.define_singleton_method(:og_set_live) { |_name| nil }
    ann.define_singleton_method(:validate_assignment_type) { |_node, _expected, _actual| nil }

    value = AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack)
    assign = AST::Assignment.new(token(:EQUAL, "="), AST::Identifier.new(token, "x"), value)
    ann.send(:visit_Assignment, assign)
    expect(assign.full_type!.resolved).to eq(:Int64)

    invalid = AST::Assignment.new(token(:EQUAL, "="), AST::Literal.new(token(:INT64, "2"), :INT64, 2, :stack), value)
    ann.send(:visit_Assignment, invalid)
    expect(direct_errors(ann).map { |err| err[1] }).to include(:INVALID_ASSIGNMENT_TARGET)
  end

  it "covers assignment variable undefined and immutable fix branches" do
    ann = quiet_annotator
    ann.define_singleton_method(:validate_assignment_type) { |_node, _expected, _actual| nil }
    value = AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack)

    missing = AST::Identifier.new(token, "missing")
    ann.send(:visit_assignment_variable, missing, AST::Assignment.new(token(:EQUAL, "="), missing, value))

    ann.send(:current_scope).declare("fixed", nil, Type.new(:Int64), false, false, nil, :stack)
    ann.define_singleton_method(:build_declare_mutable_fix) { |_name, _scope| :make_mutable }
    fixed = AST::Identifier.new(token, "fixed")
    ann.send(:visit_assignment_variable, fixed, AST::Assignment.new(token(:EQUAL, "="), fixed, value))

    ann.send(:current_scope).declare("plain", nil, Type.new(:Int64), false, false, nil, :stack)
    ann.define_singleton_method(:build_declare_mutable_fix) { |_name, _scope| nil }
    plain = AST::Identifier.new(token, "plain")
    ann.send(:visit_assignment_variable, plain, AST::Assignment.new(token(:EQUAL, "="), plain, value))

    codes = direct_errors(ann).map { |err| err[1] }
    expect(codes).to include(:ASSIGN_UNDEFINED_VAR, :fixable, :ASSIGN_VAR_IMMUTABLE)
  end

  it "covers representable capability conflict validation directly" do
    type = Type.new(:Counter)
    type.ownership = :shared
    type.soa = true

    expect(Capabilities.errors_for(type)).to eq(["SOA layout is incompatible with reference-counted ownership"])

    seen = []
    Capabilities.validate!(:decl, type) { |node, msg| seen << [node, msg] }
    expect(seen).to eq([[:decl, "SOA layout is incompatible with reference-counted ownership"]])
  end

  it "covers high-rank access, call, loop, match, and capability source shapes" do
    positive = [
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @locked;
          c.value = c.value + 1_i64;
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @locked;
          WITH EXCLUSIVE c {
            c.value = c.value + 1_i64;
          }
          RETURN;
        END
      CHT
      <<~CHT,
        UNION Box { Empty, Item: String @boxed }
        FN main() RETURNS Void ->
          b = Box{ Item: COPY "abc" };
          RETURN;
        END
      CHT
      <<~CHT,
        UNION Box { Empty, Item: String @boxed }
        top = Box{ Item: COPY "abc" };
      CHT
      <<~CHT,
        UNION Value { Nil, Lambda { body: Value @boxed } }
        top = Value.Lambda{ body: Value.Nil };
      CHT
      <<~CHT,
        STRUCT Box { label: String }
        UNION Shape { Empty, Named { label: String }, Boxed: Box @boxed }
        FN main() RETURNS Void ->
          s = Shape.Named{ label: COPY "abc" };
          PARTIAL MATCH TAKES s START
            Shape.Named AS n -> n.label.length();,
            Shape.Empty -> 0_i64;
          END
          RETURN;
        END
      CHT
      <<~CHT,
        FN make(flag: Bool) RETURNS !String ->
          IF flag THEN RETURN COPY "ok"; END
          RAISE Input;
        END
        FN main() RETURNS !Void ->
          s: String = make(TRUE) OR_ELSE RAISE;
          ASSERT s.length() == 2_i64, "fallible return";
          RETURN;
        END
      CHT
      <<~CHT,
        FN by_name(x: String) RETURNS x:String -> RETURN x; END
        FN main() RETURNS Void ->
          s: String = COPY "abc";
          out: String = by_name(s);
          ASSERT out.length() == 3_i64, "named lifetime";
          RETURN;
        END
      CHT
      <<~CHT,
        FN by_any(x: String) RETURNS *:String -> RETURN x; END
        FN main() RETURNS Void ->
          s: String = COPY "abc";
          out: String = by_any(s);
          ASSERT out.length() == 3_i64, "wildcard lifetime";
          RETURN;
        END
      CHT
      <<~CHT,
        FN inc(x: Int64) RETURNS Int64 -> RETURN x + 1_i64; END
        FN main() RETURNS !Void ->
          a = 1_i64 |> inc;
          b = 2_i64 |> inc();
          RETURN;
        CATCH Input
          RETURN;
        END
      CHT
      <<~CHT,
        FN risky(x: Int64) RETURNS !Int64 ->
          IF x > 0_i64 THEN RETURN x; END
          RAISE Input;
        END
        FN main() RETURNS !Void ->
          y = 1_i64 |> risky();
          ASSERT y == 1_i64, "pipe unwrap";
          RETURN;
        CATCH Input
          RETURN;
        END
      CHT
      <<~CHT,
        FN main() RETURNS Void ->
          1_i64 |> print;
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @boxed:atomic;
          WITH SNAPSHOT c AS MUTABLE x {
            x.value = x.value + 1_i64;
          } ON AtomicConflict RAISE
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN bump!(MUTABLE c: Counter) RETURNS Void -> c.value = c.value + 1_i64; RETURN; END
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 };
          bump!(c);
          RETURN;
        END
      CHT
      <<~CHT,
        FN main() RETURNS Void ->
          src: ~?Int64[] = BG STREAM {
            YIELD 1_i64;
            YIELD 2_i64;
          };
          running: ~Int64@observable = src |> SUM _;
          ASSERT (NEXT running) == 3_i64, "observable dest";
          RETURN;
        END
      CHT
      <<~CHT,
        FN main() RETURNS Void ->
          MUTABLE items: {String}Int64 = {};
          items["a"] = 1_i64;
          items["b"] = 2_i64;
          FOR k IN items DO
            v = items[k] OR_ELSE 0_i64;
            IF v == 1_i64 THEN CONTINUE; END
          END
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Box { values: []Int64 }
        FN main() RETURNS Void ->
          MUTABLE xs: []Int64 = [];
          xs.append(1_i64);
          b = Box{ values: xs };
          MUTABLE out: []Int64 = [];
          out.append(b.values[0_i64]);
          RETURN;
        END
      CHT
      <<~CHT,
        FN make() RETURNS ~String -> RETURN BG { COPY "abc"; }; END
        FN main() RETURNS Void ->
          h = make();
          s: String = NEXT h;
          ASSERT s.length() == 3_i64, "shared promise next";
          RETURN;
        END
      CHT
    ]

    negative = [
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 } @locked;
          x = c.value;
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 } @boxed:atomic;
          x = c.value;
          RETURN;
        END
      CHT
      <<~CHT,
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 };
          WITH SNAPSHOT c AS x { x.value; }
          RETURN;
        END
      CHT
      <<~CHT,
        FN main() RETURNS Void ->
          xs: Int64[] = [1_i64, 2_i64];
          WHILE xs.pop() EXISTS AS v DO
            s: String = COPY "owned";
            GIVE s;
          END
          RETURN;
        END
      CHT
      <<~CHT,
        FN bad(x: Int64) RETURNS x.missing:Int64 -> RETURN x; END
      CHT
      <<~CHT,
        FN hold(MUTABLE x: String) RETURNS *:String -> RETURN x; END
        FN main() RETURNS Void ->
          MUTABLE s: String = COPY "abc";
          out: String = hold(s);
          RETURN;
        END
      CHT
    ]

    positive.each { |source| expect_compile(source) }
    negative.each { |source| expect_reject(source) }
  end

  it "covers literal source span recovery branches directly" do
    ann = SemanticAnnotator.new(source_code: "missing\nplain = \"abc\"\nesc = \"a\\\\\"b\"\ntriple = \"\"\"abc\"\"\"\nopen = \"\"\"abc\nnum = 123_456_i64\n")
    tok_missing = Lexer::Token.new(:STRING, "x", 99, 1)
    tok_plain = Lexer::Token.new(:STRING, "abc", 2, 9)
    tok_escape = Lexer::Token.new(:STRING, "a\"b", 3, 7)
    tok_triple = Lexer::Token.new(:STRING, "abc", 4, 10)
    tok_open = Lexer::Token.new(:STRING, "abc", 5, 8)
    tok_number = Lexer::Token.new(:NUMBER, "123_456_i64", 6, 7)

    expect(ann.send(:literal_source_length, tok_missing)).to eq(1)
    expect(ann.send(:literal_source_length, tok_plain)).to eq(5)
    expect(ann.send(:literal_source_length, tok_escape)).to eq(5)
    expect(ann.send(:literal_source_length, tok_triple)).to eq(9)
    expect(ann.send(:literal_source_length, tok_open)).to eq(3)
    expect(ann.send(:literal_source_length, tok_number)).to eq(11)
  end

  it "covers collection narrowing helper branches directly" do
    ann = SemanticAnnotator.new(source_code: "")
    sig = FunctionSignature.new(
      params: [],
      return_type: Type.new(:Void),
      emit: IntrinsicEmit.new(narrows_collection: true)
    )

    list_type = Type.new(:"Any[]", collection: :list)
    list_type.shard_count = 2
    list_type.mark_heap_allocated!
    list_type.elem_ownership = :shared
    list_type.elem_sync = :locked
    sym = SymbolEntry.new(reg: "xs", type: list_type, mutable: true, storage: :heap)

    list = AST::Identifier.new(token, "xs")
    list.symbol = sym
    value = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    value.full_type = Type.new(:Int64)

    ann.send(:narrow_collection_type!, sig, [list, value])

    expect(sym.type.element_type.resolved).to eq(:Int64)
    expect(sym.type.collection).to eq(:list)
    expect(sym.type.shard_count).to eq(2)
    expect(sym.type.provenance).to eq(:heap)
    expect(sym.type.elem_ownership).to eq(:shared)
    expect(sym.type.elem_sync).to eq(:locked)
    expect(list.full_type.element_type.resolved).to eq(:Int64)
  end

  it "narrows receiver collections from mutating method calls" do
    ann = SemanticAnnotator.new(source_code: "")
    sig = FunctionSignature.new(
      params: [],
      return_type: Type.new(:Void),
      emit: IntrinsicEmit.new(narrows_receiver_collection: true)
    )

    list_type = Type.new(:"Any[]", collection: :list)
    list_type.mark_heap_allocated!
    list_type.elem_ownership = :shared
    list_type.elem_sync = :locked
    sym = SymbolEntry.new(reg: "items", type: list_type, mutable: true, storage: :heap)

    receiver = AST::Identifier.new(token, "items")
    receiver.symbol = sym
    value = AST::Literal.new(token(:INT64, 1), :INT64, 1, :stack)
    value.full_type = Type.new(:Int64)
    call = AST::MethodCall.new(token, receiver, "append", [value])

    ann.send(:narrow_receiver_collection!, call, list_type, sig)

    expect(sym.type.element_type.resolved).to eq(:Int64)
    expect(sym.type.collection).to eq(:list)
    expect(sym.type.provenance).to eq(:heap)
    expect(sym.type.elem_ownership).to eq(:shared)
    expect(sym.type.elem_sync).to eq(:locked)
    expect(receiver.full_type.element_type.resolved).to eq(:Int64)
  end

  it "returns an invalid source fact when no pipeline item type is known" do
    ann = SemanticAnnotator.new(source_code: "")
    source = AST::Identifier.new(token, "mystery")
    source.full_type = Type.new(:Mystery)
    fact = ann.send(:pipeline_source_fact, source, Type.new(:Mystery))

    expect(fact.valid?).to be(false)
    expect(fact.item_type).to eq(:Any)
  end

  it "returns a typed source fact with the item type and source kind" do
    ann = SemanticAnnotator.new(source_code: "")
    list = AST::Identifier.new(token, "items")
    list_type = Type.new(:"String[]")
    list.full_type = list_type
    stream = AST::Identifier.new(token, "finite")
    stream_type = Type.new(:"~Bool[]")
    stream.full_type = stream_type
    inf = AST::Identifier.new(token, "stream")
    inf_type = Type.new(:"~Int64[INF]")
    inf.full_type = inf_type
    scalar = AST::Identifier.new(token, "scalar")
    scalar_type = Type.new(:Int64)
    scalar.full_type = scalar_type

    list_fact = ann.send(:pipeline_source_fact, list, list_type)
    stream_fact = ann.send(:pipeline_source_fact, stream, stream_type)
    inf_fact = ann.send(:pipeline_source_fact, inf, inf_type, include_inf_stream: true)

    expect(list_fact.item_type).to eq(:String)
    expect(list_fact.kind).to eq(:collection)
    expect(stream_fact.item_type).to eq(:Bool)
    expect(stream_fact.finite_stream?).to be(true)
    expect(inf_fact.item_type).to eq(:Int64)
    expect(inf_fact.inf_stream?).to be(true)
    expect(ann.send(:pipeline_source_fact, scalar, scalar_type).valid?).to be(false)
  end

  it "uses one compact predicate for all annotator pipeline operators" do
    ann = SemanticAnnotator.new(source_code: "")
    expect(ann.send(:pipe_complex_op?, AST::CollectOp.new(token(:COLLECT, "COLLECT")))).to be(true)
    expect(ann.send(:pipe_complex_op?, AST::RecoverOp.new(token(:RECOVER, "RECOVER"), AST::DefaultLit.new(token(:DEFAULT, "DEFAULT"))))).to be(true)
    expect(ann.send(:pipe_complex_op?, AST::Identifier.new(token, "not_pipeline"))).to be(false)
  end

  it "uses Any after reporting non-iterable auto-shard inputs" do
    ann = quiet_annotator
    scope = double
    allow(scope).to receive(:declare)
    ann.define_singleton_method(:current_scope) { scope }
    ann.define_singleton_method(:with_new_scope) { |&block| block.call }

    left = AST::Identifier.new(token, "n")
    left.full_type = Type.new(:Int64)
    smooth = AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, AST::EachOp.new(token(:KEYWORD, "EACH"), []))
    conc = AST::ConcurrentOp.new(
      token(:CONCURRENT, "CONCURRENT"),
      AST::EachOp.new(token(:EACH, "EACH"), []),
      {}
    )

    ann.send(:analyze_auto_shard_each_op, smooth, conc, smooth)

    expect(direct_errors(ann).map { |e| e[1] }).to include(:CONCURRENT_EACH_BAD_INPUT)
    expect(scope).to have_received(:declare).with("_", nil, :Any, true, false, nil, :stack)
  end

  it "covers borrow source resolver branches directly" do
    ann = SemanticAnnotator.new(source_code: "")
    source = AST::Identifier.new(token, "source")

    intrinsic = FunctionSignature.new(
      params: [],
      return_type: Type.new(:String),
      arg_spec: [{ name: "value" }],
      emit: IntrinsicEmit.new(lifetime: ["value"])
    )
    intrinsic_call = AST::FuncCall.new(token, "borrow_intrinsic", [source])
    intrinsic_call.matched_stdlib_def = intrinsic
    expect(ann.send(:resolve_borrow_source, intrinsic_call)).to equal(source)

    missing_named_arg = FunctionSignature.new(
      params: [],
      return_type: Type.new(:String),
      arg_spec: [{ name: "other" }],
      emit: IntrinsicEmit.new(lifetime: ["value"])
    )
    missing_named_call = AST::FuncCall.new(token, "missing_borrow_intrinsic", [source])
    missing_named_call.matched_stdlib_def = missing_named_arg
    expect(ann.send(:resolve_borrow_source, missing_named_call)).to be_nil

    self_lifetime = FunctionSignature.new(
      params: [],
      return_type: Type.new(:String),
      emit: IntrinsicEmit.new(lifetime: ["self"])
    )
    method_call = AST::MethodCall.new(token, source, "trim", [])
    method_call.matched_stdlib_def = self_lifetime
    expect(ann.send(:resolve_borrow_source, method_call)).to equal(source)

    user_sig = FunctionSignature.new(
      params: [AST::Param.new(name: "x", type: Type.new(:String))],
      return_type: Type.new(:String),
      return_lifetime: ["x"]
    )
    wildcard_sig = FunctionSignature.new(
      params: [AST::Param.new(name: "x", type: Type.new(:String))],
      return_type: Type.new(:String),
      return_lifetime: :wildcard
    )
    scope = Struct.new(:entries) do
      def resolve_type(name) = entries[name]
    end.new({ "borrow_user" => user_sig, "borrow_any" => wildcard_sig })
    ann.define_singleton_method(:lookup_scope_for) { |name| scope if scope.entries.key?(name) }

    expect(ann.send(:resolve_borrow_source, AST::MethodCall.new(token, source, "borrow_user", []))).to equal(source)
    expect(ann.send(:resolve_borrow_source, AST::FuncCall.new(token, "borrow_any", [source]))).to be_nil
    expect(ann.send(:resolve_borrow_source, AST::FuncCall.new(token, "missing", [source]))).to be_nil
  end

  it "matches intrinsic overloads through typed capability argument specs" do
    ann = SemanticAnnotator.new(source_code: "")
    matching_arg = typed_identifier("matching", Type.new(:String, sync: :locked, ownership: :borrowed))
    wrong_sync_arg = typed_identifier("wrong_sync", Type.new(:String, sync: :raw, ownership: :borrowed))
    wrong_owner_arg = typed_identifier("wrong_owner", Type.new(:String, sync: :locked, ownership: :owned))

    capability_sig = FunctionSignature.new(
      params: [],
      return_type: Type.new(:Void),
      intrinsic: true,
      arg_spec: [{ type: :String, sync: :locked, ownership: :borrowed }],
    )
    two_arg_sig = FunctionSignature.new(
      params: [],
      return_type: Type.new(:Void),
      intrinsic: true,
      arg_spec: [:String, :String],
    )

    expect(ann.send(:find_matching_intrinsic, [two_arg_sig], [matching_arg])).to be_nil
    expect(ann.send(:find_matching_intrinsic, [capability_sig], [wrong_sync_arg])).to be_nil
    expect(ann.send(:find_matching_intrinsic, [capability_sig], [wrong_owner_arg])).to be_nil
    expect(ann.send(:find_matching_intrinsic, [capability_sig], [matching_arg])).to equal(capability_sig)
  end


  it "covers direct annotator diagnostic branch clusters without a corpus template" do
    expect { annotate_source("FN main() RETURNS Void -> x: Missing<Int64> = 1_i64; RETURN; END") }.to raise_error(CompilerError)

    unknown = AST::StructLit.new(nil, "Missing", {}, :stack, nil)
    expect { SemanticAnnotator.new(source_code: "").send(:visit_StructLit, unknown) }.to raise_error(CompilerError)

    lit = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    lit.full_type = Type.new(:Int64)

    union_ann = SemanticAnnotator.new(source_code: "")
    union_ann.define_singleton_method(:lookup_type_schema) do |name|
      Schemas::UnionSchema.new(variants: { Good: Type.new(:Int64) }) if name == :Choice
    end
    union_ann.define_singleton_method(:literal_type_substitution!) { |_node, _schema| {} }
    bad_variant = AST::StructLit.new(nil, "Choice", { "Bad" => lit }, :stack, nil)
    expect { union_ann.send(:visit_StructLit, bad_variant) }.to raise_error(CompilerError)

    struct_ann = SemanticAnnotator.new(source_code: "")
    struct_ann.define_singleton_method(:lookup_type_schema) do |name|
      if name == :Box
        Schemas::StructSchema.new(fields: {
          "value" => AST::StructField.new(type: Type.new(:Int64))
        })
      end
    end
    struct_ann.define_singleton_method(:literal_type_substitution!) { |_node, _schema| {} }
    bad_field = AST::StructLit.new(nil, "Box", { "missing" => lit }, :stack, nil)
    expect { struct_ann.send(:visit_StructLit, bad_field) }.to raise_error(CompilerError)

    pipe_ann = quiet_annotator
    pipe_ann.define_singleton_method(:has_catch_blocks?) { true }
    left = AST::Literal.new(token(:STRING, "abc"), :STRING, "abc", :rodata)
    left.full_type = Type.new(:String)
    pipe = AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, AST::Identifier.new(token, "f"))
    range_mismatch_sig = FunctionSignature.new(
      params: [
        AST::Param.new(name: "x", type: Type.new(:Int64), required: true),
        AST::Param.new(name: "y", type: Type.new(:Int64), required: true),
        AST::Param.new(name: "z", type: Type.new(:Int64), required: false),
      ],
      return_type: Type.new(:"!String")
    )
    pipe_ann.send(:analyze_pipe_to_named_function, pipe, range_mismatch_sig, "f")
    no_arg_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
    pipe_ann.send(:analyze_pipe_to_named_function, pipe, no_arg_sig, "zero")
    expect(direct_errors(pipe_ann).map { |e| e[1] }).to include(:ARITY_MISMATCH_RANGE, :ARITY_MISMATCH, :ARGUMENT_TYPE_ERROR)
    expect(pipe.full_type.resolved).to eq(:Void)

    cap_ann = quiet_annotator
    cap_graph = cap_ann.send(:ownership_graph)
    %w[locked plain borrowed cell borrowed_lock].each do |name|
      cap_graph.declare(name, kind: :affine, type_info: Type.new(:Counter), scope_depth: 0)
    end

    locked_var = AST::Identifier.new(token, "locked")
    locked_var.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :heap, sync: :locked)
    locked_var.full_type = Type.new(:Counter, sync: :locked)
    cap_ann.send(:declare_capability_scope!, cap_ann.send(:with_capability_fact, AST::Capability.new(
      capability: :EXCLUSIVE, var_node: locked_var, alias: "inner",
      old_scope: Scope.new, resolved_type: Type.new(:Counter)
    )))

    plain_var = AST::Identifier.new(token, "plain")
    plain_var.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :stack)
    plain_var.full_type = Type.new(:Counter)
    cap_ann.send(:declare_capability_scope!, cap_ann.send(:with_capability_fact, AST::Capability.new(
      capability: :EXCLUSIVE, var_node: plain_var, old_scope: Scope.new,
      resolved_type: Type.new(:Counter)
    )))

    borrowed_var = AST::Identifier.new(token, "borrowed")
    borrowed_var.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :stack)
    borrowed_var.full_type = Type.new(:Counter)
    cap_ann.send(:declare_capability_scope!, cap_ann.send(:with_capability_fact, AST::Capability.new(
      capability: :BORROWED, var_node: borrowed_var, old_scope: Scope.new,
      resolved_type: Type.new(:Counter)
    )))

    sync_field = AST::GetField.new(token, AST::Identifier.new(token, "env"), "cell")
    sync_field.full_type = Type.new(:Counter, sync: :locked)
    cap_ann.send(:declare_capability_scope!, cap_ann.send(:with_capability_fact, AST::Capability.new(
      capability: :EXCLUSIVE, var_node: sync_field, alias: "cell",
      old_scope: Scope.new, resolved_type: sync_field.full_type
    )))

    borrowed_scope = Scope.new
    borrowed_entry = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :stack, sync: :write_locked)
    borrowed_scope.install_entry("borrowed_lock", borrowed_entry)
    borrowed_lock = AST::Identifier.new(token, "borrowed_lock")
    borrowed_lock.symbol = borrowed_entry
    borrowed_lock.full_type = Type.new(:Counter, sync: :write_locked)
    cap_ann.send(:declare_capability_scope!, cap_ann.send(:with_capability_fact, AST::Capability.new(
      capability: :BORROWED, var_node: borrowed_lock,
      old_scope: borrowed_scope, resolved_type: Type.new(:Counter)
    )))

    expect(direct_errors(cap_ann).map { |e| e[1] }).to include(:WITH_CAP_BINDING_LOST)
    borrowed_error = direct_errors(cap_ann).find { |e| e[1] == :WITH_BORROWED_ON_QUALIFIED_VAR }
    expect(borrowed_error[3][:qualifier]).to eq("@writeLocked")
    expect(cap_graph.edges.map(&:kind)).to include(:borrows)
  end


  it "covers direct capability and parameter validation branch clusters" do
    cap_ann = quiet_annotator
    with_node = AST::WithBlock.new(token(:WITH, "WITH"), [], [], [])

    mk_var = lambda do |name, type, storage: nil, sync: nil, layout: nil, is_param: false|
      ident = AST::Identifier.new(token, name)
      ident.full_type = type
      ident.symbol = SymbolEntry.new(reg: nil, type: type, mutable: true, storage: storage || :stack, sync: sync, layout: layout)
      ident.symbol.is_param = is_param
      ident
    end

    validate = lambda do |capability, var_node|
      cap = AST::Capability.new(capability: capability, var_node: var_node)
      cap_ann.send(:validate_capability_transition!, with_node, capability_transition(cap))
    end

    validate.call(:write_locked_read, mk_var.call("read_param", Type.new(:Counter), is_param: true))
    validate.call(:write_locked_read, mk_var.call("plain_read", Type.new(:Counter)))
    view_target = AST::Identifier.new(token, "source")
    view_target.full_type = Type.new(:Row)
    view_field = AST::GetField.new(token, view_target, "count")
    view_field.full_type = Type.new(:Int64)
    validate.call(:VIEW, view_field)
    validate.call(:SNAPSHOT, mk_var.call("atomic_cell", Type.new(:Counter, ownership: :shared, sync: :atomic, layout: :indirect), sync: :atomic, layout: :indirect))
    validate.call(:SNAPSHOT, mk_var.call("indirect_locked", Type.new(:Counter, sync: :locked, layout: :indirect), sync: :locked, layout: :indirect))
    validate.call(:SNAPSHOT, mk_var.call("locked", Type.new(:Counter, sync: :locked), sync: :locked))
    validate.call(:SNAPSHOT, mk_var.call("shared", Type.new(:Counter, ownership: :shared), storage: :shared))
    plain = AST::Identifier.new(token, "plain")
    plain.full_type = Type.new(:Counter)
    validate.call(:SNAPSHOT, plain)
    validate.call(:multiowned, mk_var.call("not_multi", Type.new(:Counter), storage: :stack))
    validate.call(:shared, mk_var.call("not_shared", Type.new(:Counter), storage: :stack))
    validate.call(:ATOMIC, mk_var.call("param_atomic", Type.new(:Counter), is_param: true))
    validate.call(:ATOMIC, mk_var.call("locked_atomic", Type.new(:Counter, sync: :locked), sync: :locked))
    validate.call(:ATOMIC, mk_var.call("wrong_atomic", Type.new(:Counter), storage: :shared))
    validate.call(:ATOMIC, plain)
    validate.call(:RESTRICT, AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack))
    validate.call(:UNKNOWN, mk_var.call("unknown", Type.new(:Counter)))

    guard_expr = AST::Literal.new(token(:TRUE, "TRUE"), :BOOL, true, :stack)
    guard_expr.full_type = Type.new(:Bool)
    guarded = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(
        capability: :BORROWED,
        var_node: mk_var.call("guarded", Type.new(:Counter)),
        alias: "g",
        guard_expr: guard_expr,
      )
    ], [])
    guarded.snapshot_mode = :transaction
    attach_capability_plan!(guarded)
    cap_ann.define_singleton_method(:visit) { |_node| nil }
    cap_ann.send(:validate_and_visit_with_guards!, guarded)

    expanded = CapabilityHelper::WithCapabilityExpansion.new
    atomic_var = mk_var.call("atomic_var", Type.new(:Int64, sync: :atomic), sync: :atomic)
    atomic_cap = AST::Capability.new(capability: :infer, var_node: atomic_var)
    cap_ann.send(:acquire_capability!, with_node, atomic_cap, expanded)
    unknown_var = AST::Identifier.new(token, "unknown_cap")
    unknown_var.full_type = Type.new(:Counter)
    unknown_cap = AST::Capability.new(capability: :infer, var_node: unknown_var)
    cap_ann.send(:acquire_capability!, with_node, unknown_cap, expanded)

    codes = direct_errors(cap_ann).map { |e| e[1] }
    expect(codes).to include(
      :WITH_CAP_BAD_TARGET,
      :WITH_READ_NEEDS_WRITE_LOCK,
      :WITH_VIEW_NEEDS_OBSERVABLE,
      :WITH_GUARD_NOT_ON_SNAPSHOT,
      :WITH_CANNOT_INFER_CAP,
      :UNKNOWN_WITH_CAP_TYPE
    )
    expect(atomic_cap[:capability]).to eq(:ATOMIC)
    expect(unknown_cap[:capability]).to eq(:unknown)
    expect(cap_ann.pending_deferred_validation_count).to be > 0

    bad_param_ann = SemanticAnnotator.new(source_code: "")
    bad_fn = AST::FunctionDef.new(token, "bad_default", [
      AST::Param.new(name: "plain", type: Type.new(:Int64), default: AST::DefaultLit.new(token(:DEFAULT, "DEFAULT")))
    ], Type.new(:Void), [], :package)
    expect { bad_param_ann.send(:declare_and_verify_params, bad_fn) }.to raise_error(CompilerError)

    param_ann = quiet_annotator
    default_number = token(:NUMBER, "1_i64")
    param_ann.define_singleton_method(:lookup_type_schema) do |name|
      case name
      when :AllDefault
        Schemas::StructSchema.new(fields: {
          "a" => AST::StructField.new(type: Type.new(:Int64), default: AST::Literal.new(default_number, :INT64, 1, :stack))
        })
      when :MissingDefault
        Schemas::StructSchema.new(fields: { "a" => AST::StructField.new(type: Type.new(:Int64)) })
      when :EmptyDefault
        Schemas::StructSchema.new(fields: {})
      end
    end
    param_ann.define_singleton_method(:visit) { |node| node.full_type = Type.new(:String) if node.respond_to?(:full_type=) }
    fn = AST::FunctionDef.new(token, "defaults", [
      AST::Param.new(name: "ok", type: Type.new(:AllDefault), default: AST::DefaultLit.new(token(:DEFAULT, "DEFAULT"))),
      AST::Param.new(name: "missing", type: Type.new(:MissingDefault), default: AST::DefaultLit.new(token(:DEFAULT, "DEFAULT"))),
      AST::Param.new(name: "empty", type: Type.new(:EmptyDefault), default: AST::DefaultLit.new(token(:DEFAULT, "DEFAULT"))),
      AST::Param.new(name: "wrong", type: Type.new(:Int64), default: AST::Literal.new(token(:STRING, "x"), :STRING, "x", :rodata))
    ], Type.new(:Void), [], :package)
    param_ann.send(:declare_and_verify_params, fn)
    expect(direct_errors(param_ann).map { |e| e[1] }).to include(:DEFAULT_STRUCT_MISSING_DEFAULTS, :DEFAULT_VALUE_TYPE_MISMATCH)

    pipe_ann = SemanticAnnotator.new(source_code: "")
    void_lit = AST::Literal.new(token(:NIL, "nil"), :NIL, nil, :stack)
    void_lit.full_type = Type.new(:Void)
    err_lit = AST::Literal.new(token(:STRING, "x"), :STRING, "x", :rodata)
    err_lit.full_type = Type.new(:"!String")
    int_lit = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    int_lit.full_type = Type.new(:Int64)
    pipe_summary = body_fact_summary(pipe_ann) do
      [void_lit, err_lit, int_lit].each do |source|
        source_type = source.full_type!(context: "test pipe source")
        pipe_ann.send(:record_body_fact_pipe_input_type!, source_type.resolved.to_s) if source_type.catch_snapshot_payload?
      end
    end
    snapshot_summary = body_fact_summary(pipe_ann, [AST::Identifier.new(token(:IDENTIFIER, "snapshot"), "snapshot")])
    expect(void_lit.full_type.catch_snapshot_payload?).to be(false)
    expect(err_lit.full_type.catch_snapshot_payload?).to be(false)
    expect(int_lit.full_type.catch_snapshot_payload?).to be(true)
    expect(pipe_summary.pipe_input_types).to eq(Set["Int64"])
    expect(snapshot_summary.references_snapshot).to be(true)
  end

  it "covers function analysis call, capture, TAKES, and return lifetime branches directly" do
    missing_call_ann = quiet_annotator
    missing_call_ann.semantic_function_nodes.replace({})
    missing_call = AST::FuncCall.new(token(:VAR_ID, "missing_fn"), "missing_fn", [])
    missing_call_ann.send(:resolve_call, missing_call, missing_call.args)

    symbol_call_ann = quiet_annotator
    symbol_scope = Struct.new(:value) do
      def resolve_type(_name) = value
      def resolve_entry(_name) = nil
      def mark_read(_name) = nil
    end.new(:Int64)
    symbol_call_ann.define_singleton_method(:lookup_scope_for) { |_name| symbol_scope }
    symbol_call = AST::FuncCall.new(token(:VAR_ID, "symbol_fn"), "symbol_fn", [])
    symbol_call_ann.send(:resolve_call, symbol_call, symbol_call.args)
    expect(symbol_call.full_type!.resolved).to eq(:Int64)

    not_fn_ann = quiet_annotator
    not_fn_ann.send(:current_scope).declare("not_fn", nil, Type.new(:Int64), false, false, nil, :stack)
    not_fn_call = AST::FuncCall.new(token(:VAR_ID, "not_fn"), "not_fn", [])
    not_fn_ann.send(:resolve_call, not_fn_call, not_fn_call.args)

    alloc_ann = quiet_annotator
    receiver = AST::Identifier.new(token, "items")
    receiver.symbol = symbol_entry(type: Type.new(:"String[]"), storage: :frame)
    method = AST::MethodCall.new(token, receiver, "push", [])
    expect(alloc_ann.send(:receiver_container_alloc, method)).to eq(:frame)
    receiver.symbol.storage = :heap
    expect(alloc_ann.send(:receiver_container_alloc, method)).to eq(:heap)

    takes_ann = quiet_annotator
    takes_ann.define_singleton_method(:ensure_owned_value!) { |_node, _expected, _desc, container_alloc: :heap| nil }
    takes_ann.define_singleton_method(:move_if_takes_ownership!) { |_node, action: :takes, consumer_param_type: nil| nil }
    root = AST::Identifier.new(token, "source")
    root.symbol = symbol_entry(type: Type.new(:Widget), storage: :stack)
    root.symbol.is_param = true
    borrowed_field = AST::GetField.new(token(:DOT, "."), root, "item")
    borrowed_field.full_type = Type.new(:Widget)
    copy_arg = AST::CopyNode.new(token(:COPY, "COPY"), AST::Identifier.new(token, "value"))
    copy_arg.full_type = Type.new(:String)
    frame_receiver = AST::Identifier.new(token, "list")
    frame_receiver.symbol = symbol_entry(type: Type.new(:"String[]"), storage: :frame)
    takes_call = AST::MethodCall.new(token, frame_receiver, "append", [borrowed_field, copy_arg])
    signature = FunctionSignature.new(params: [
      AST::Param.new(name: "owned", type: Type.new(:Widget), takes: true),
      AST::Param.new(name: "copied", type: Type.new(:String), takes: true),
    ], return_type: Type.new(:Void))
    takes_ann.send(:verify_function_signature!, takes_call, signature)
    expect(copy_arg.alloc).to eq(:frame)
    site = takes_ann.send(:call_signature_site, takes_call)
    arity = takes_ann.send(:call_arity_plan, site, signature)
    expect(site.name).to eq("append")
    expect(arity.mismatch?).to be(false)
    expect(arity.injectable_defaults).to eq([])
    facts = takes_ann.send(:call_argument_facts, site, signature.params[1], copy_arg, 1)
    expect(facts.expected_type.resolved).to eq(:String)
    expect(facts.is_give).to be(false)
    expect(takes_ann.send(:param_mutable?, AST::Param.new(name: "m", type: Type.new(:Int64), mutable: "MUTABLE"))).to be(true)
    default_param = AST::Param.new(
      name: "fallback",
      type: Type.new(:Widget),
      required: false,
      default: AST::DefaultLit.new(token(:DEFAULT, "DEFAULT"))
    )
    default_arg = takes_ann.send(:default_argument_for, default_param)
    expect(default_arg).to be_a(AST::StructLit)
    expect(default_arg.name).to eq("Widget")

    capture_ann = quiet_annotator
    capture_fn = function_def("captures")
    capture_fn.captures = [AST::Param.new(name: "missing", type: Type.new(:Int64))]
    capture_ann.send(:verify_captures!, capture_fn)

    return_ann = quiet_annotator
    return_ctx = FunctionContext.new(name: "ret", return_type: Type.new(:Widget), lifetime: [:source], type_params: [])
    return_ann.send(:push_function_context!, return_ctx)
    begin
      orphan_field = AST::GetField.new(token(:DOT, "."), AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack), "value")
      orphan_field.full_type = Type.new(:Widget)
      return_ann.send(:verify_return, orphan_field)
    ensure
      return_ann.send(:pop_function_context!)
    end

    expect(direct_errors(missing_call_ann).map { |err| err[1] }).to include(:TYPO_SUGGESTION_REJECTED)
    expect(direct_errors(not_fn_ann).map { |err| err[1] }).to include(:NOT_A_FUNCTION)
    expect(direct_errors(takes_ann).map { |err| err[1] }).to include(:TAKES_NEEDS_OWNED_BORROW)
    expect(direct_errors(capture_ann).map { |err| err[1] }).to include(:CAPTURE_UNDEFINED_VAR)
    expect(direct_errors(return_ann).map { |err| err[1] }).to include(:RETURN_LIFETIME_NOT_ASSOCIATED)
  end

  it "raises on impossible FunctionReturn kind values" do
    invalid_return = Class.new(FunctionReturn) do
      def kind = :bogus
    end.new(kind: FunctionReturn::Kind::Fixed, fixed: Type.new(:Int64))

    expect {
      invalid_return.resolve(nil)
    }.to raise_error(RuntimeError, /unknown FunctionReturn kind/)
  end

  it "preserves split fallibility metadata when duplicating function signatures" do
    source_requires = { "x" => Set[:LOCKED] }
    sig = FunctionSignature.new(
      params: [],
      return_type: Type.new(:Void),
      can_fail: true,
      alloc_fault: true,
      error_fallible: false,
      needs_rt: true,
      effects: Set[:HEAP],
      return_strategy: :value,
      stack_tier: :large,
      requires: source_requires,
      heap_carry_return: true,
      heap_carry_return_vars: Set["x"],
      arg_validator: ->(_args) { true },
      arg_spec: [{ name: "x" }],
      arity: 1,
      emit: IntrinsicEmit.new(allocates: true),
      return_def: FunctionReturn.infer(:infer_element_type)
    )

    copy = sig.dup

    expect(copy.can_fail).to eq(true)
    expect(copy.alloc_fault).to eq(true)
    expect(copy.error_fallible).to eq(false)
    expect(copy.needs_rt).to eq(true)
    expect(copy.effects).to eq(Set[:HEAP])
    expect(copy.return_strategy).to eq(:value)
    expect(copy.stack_tier).to eq(:large)
    expect(copy.requires).to eq("x" => Set[:LOCKED])
    expect(copy.heap_carry_return).to eq(true)
    expect(copy.heap_carry_return_vars).to eq(Set["x"])
    expect(copy.arg_validator&.call([])).to eq(true)
    expect(copy.intrinsic_arg_specs.map(&:name)).to eq(["x"])
    expect(copy.arity).to eq(1)
    expect(copy.emit&.allocates).to eq(true)
    expect(copy.return_def.kind).to eq(FunctionReturn::Kind::Infer)

    copy.requires["x"] << :VERSIONED
    expect(source_requires).to eq("x" => Set[:LOCKED])
    expect(sig.requires).to eq("x" => Set[:LOCKED])
  end

  it "covers FunctionSignature constructor seams over split storage" do
    sig = FunctionSignature.new(
      params: [],
      return_type: nil,
      return_lifetime: [:self],
      extern: true,
      module_alias: "native",
      extern_effects: { alloc: :heap },
      fn_type_params: [:T],
      owner_type: "Box",
      owner_type_params: [:T],
      intrinsic: true,
      emit: IntrinsicEmit.new(zig: :call_box)
    )

    expect(sig.return_type.raw).to eq(:Void)
    expect(sig.return_lifetime).to eq(["self"])
    expect(sig.extern).to eq(true)
    expect(sig.module_alias).to eq("native")
    expect(sig.extern_effects).to eq(alloc: :heap)
    expect(sig.fn_type_params).to eq([:T])
    expect(sig.owner_type).to eq("Box")
    expect(sig.owner_type_params).to eq([:T])
    expect(sig.intrinsic).to eq(true)
    expect(sig.intrinsic_pattern).to eq(:call_box)

    expect(FunctionSignature.allocating_intrinsic.emit&.allocates).to eq(true)
    expect(FunctionSignature.intrinsic_signature(borrows: []).emit&.borrows).to eq([])

    fn = Struct.new(
      :needs_rt,
      :can_fail,
      :alloc_fault,
      :error_fallible,
      :effects,
      :requires,
      :return_strategy,
      :return_type,
      :stack_tier,
      :heap_carry_return,
      :heap_carry_return_vars,
      keyword_init: true,
    ).new(
      needs_rt: true,
      can_fail: true,
      alloc_fault: false,
      error_fallible: true,
      effects: Set[:IO],
      requires: { "lock" => Set[:LOCKED] },
      return_strategy: :by_value,
      return_type: Type.new(:String),
      stack_tier: :small,
      heap_carry_return: false,
      heap_carry_return_vars: Set["tmp"],
    )

    source_fn_requires = T.must(fn.requires)
    FunctionSignature.sync_signature_from_function_def!(sig, fn)
    expect(source_fn_requires).to eq("lock" => Set[:LOCKED])
    expect(sig.needs_rt).to eq(true)
    expect(sig.can_fail).to eq(true)
    expect(sig.alloc_fault).to eq(false)
    expect(sig.error_fallible).to eq(true)
    expect(sig.effects).to eq(Set[:IO])
    expect(sig.requires).to eq("lock" => Set[:LOCKED])
    expect(sig.return_strategy).to eq(:by_value)
    expect(sig.return_type.raw).to eq(:String)
    expect(sig.stack_tier).to eq(:small)
    expect(sig.heap_carry_return).to eq(false)
    expect(sig.heap_carry_return_vars).to eq(Set["tmp"])

    unchanged = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
    FunctionSignature.sync_signature_from_function_def!(unchanged, Struct.new(:unused).new(nil))
    expect(unchanged.return_type.raw).to eq(:Int64)
    expect(unchanged.needs_rt).to be_nil
  end

  it "covers intrinsic registry converter edge contracts directly" do
    registry = { "known" => { args: [], return: :Int64, zig: "known()" } }
    registries = { KNOWN: registry }
    label = ->(_t) { "label" }

    emit = IntrinsicRegistry.send(:build_emit, { label: label, cleanup: { registry: registry } }, registries)
    expect(emit.label).to eq(label)
    expect(emit.cleanup.registry).to eq(:KNOWN)
    expect(IntrinsicRegistry.send(:nested_emit, { registry: {} }, registries).registry).to eq(:unknown)

    converted = IntrinsicRegistry.sigs({ "ok" => { args: [], return: :Int64 }, "skip" => :not_hash })
    expect(converted["ok"]).to be_a(FunctionSignature)
    expect(converted["skip"]).to be_nil

    expect {
      IntrinsicRegistry.send(:build_emit, { unmapped_key: true }, registries)
    }.to raise_error(RuntimeError, /unmapped registry key/)
    expect {
      IntrinsicRegistry.to_return_def(-> { Type.new(:Int64) })
    }.to raise_error(RuntimeError, /Proc return descriptor is not allowed/)
  end

  it "covers direct struct-pattern, literal-span, and atomic bind branch clusters" do
    ann = quiet_annotator
    ann.define_singleton_method(:lookup_type_schema) do |_name|
      Schemas::StructSchema.new(fields: {
        "a" => AST::StructField.new(type: Type.new(:Int64)),
        "b" => AST::StructField.new(type: Type.new(:Int64)),
        "_private" => AST::StructField.new(type: Type.new(:String))
      })
    end
    ann.define_singleton_method(:emit_typo_suggestion!) do |node, *_args, **_kwargs|
      error!(node, :typo)
    end
    ann.define_singleton_method(:visit) { |node| node.full_type = Type.new(:String) if node.respond_to?(:full_type=) }

    subject = AST::Identifier.new(token, "thing")
    subject.full_type = Type.new(:Thing)
    match_node = AST::MatchStatement.new(token(:MATCH, "MATCH"), subject, [], nil, [], nil, false, nil)
    expr = AST::Literal.new(token(:STRING, "bad"), :STRING, "bad", :rodata)
    expr.full_type = Type.new(:String)
    pat = AST::StructPattern.new(token(:LBRACE, "{"), [
      AST::PatternField.new(name: "missing_tok", value: expr, name_token: token(:VAR_ID, "missing_tok")),
      AST::PatternField.new(name: "missing_plain", value: expr, name_token: token(:VAR_ID, "missing_plain")),
      AST::PatternField.new(name: "a", value: :bind, name_token: token(:VAR_ID, "a")),
      AST::PatternField.new(name: "b", value: expr, name_token: token(:VAR_ID, "b")),
      AST::PatternField.new(name: "_private", value: :wildcard, name_token: token(:VAR_ID, "_private"))
    ], false)
    ann.send(:annotate_struct_pattern!, match_node, pat)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:typo, :MATCH_FIELD_TYPE_MISMATCH)

    nil_schema_ann = quiet_annotator
    nil_schema_ann.define_singleton_method(:lookup_type_schema) { |_name| nil }
    nil_schema_ann.define_singleton_method(:visit) { |_node| nil }
    nil_schema_subject = AST::Identifier.new(token, "unknown_struct")
    nil_schema_subject.full_type = Type.new(:UnknownStruct)
    nil_schema_match = AST::MatchStatement.new(token(:MATCH, "MATCH"), nil_schema_subject, [], nil, [], nil, false, nil)
    nil_schema_pat = AST::StructPattern.new(token(:LBRACE, "{"), [
      AST::PatternField.new(name: "a", value: :bind, name_token: token(:VAR_ID, "a"))
    ], false)
    nil_schema_ann.send(:annotate_struct_pattern!, nil_schema_match, nil_schema_pat)

    span_ann = SemanticAnnotator.new(source_code: "x = \"a\\\"b\";\ny = \"\"\"multi\"\"\";\nz = ;\n")
    expect(span_ann.send(:literal_source_length, Lexer::Token.new(:STRING, "a\"b", 1, 5))).to eq(6)
    expect(span_ann.send(:literal_source_length, Lexer::Token.new(:STRING, "multi", 2, 5))).to eq(11)
    expect(span_ann.send(:literal_source_length, Lexer::Token.new(:NUMBER, "1", 3, 5))).to eq(1)
    expect(SemanticAnnotator.new(source_code: nil).send(:literal_source_length, Lexer::Token.new(:STRING, "abc", 1, 1))).to eq(3)

    bind_ann = quiet_annotator
    bind_ann.send(:current_scope).declare("a", nil, Type.new(:Int64), true, false, nil, :stack, Set.new, [], sync: :atomic)
    bind_ann.define_singleton_method(:visit) { |_node| nil }
    bind_ann.define_singleton_method(:verify_unrestricted!) { |_node| nil }
    bind_ann.define_singleton_method(:validate_assignment_type) { |_node, _expected, _actual| nil }
    bind_ann.define_singleton_method(:handle_assign_move) { |_node| nil }
    bind_ann.define_singleton_method(:handle_assign_borrow) { |_node| nil }
    bind_ann.define_singleton_method(:mark_var_mutated) { |_name| nil }
    bind_ann.define_singleton_method(:og_set_live) { |_name| nil }
    bind_ann.define_singleton_method(:record_effect) { |_effect| nil }
    value = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    value.full_type = Type.new(:Int64)
    [:ADD, :SUB, :MUL, :DIV, :MOD].each do |op|
      node = AST::BindExpr.new(token(:VAR_ID, "a"), "a", Type.new(:Int64), value)
      node.compound_op = op
      bind_ann.send(:visit_BindExpr, node)
    end
    expect(direct_errors(bind_ann).map { |e| e[1] }).to include(:ATOMIC_NO_MUL_DIV_COMPOUND, :ATOMIC_UNSUPPORTED_COMPOUND)
  end

  it "covers direct generic, precondition, index, next, and concurrent branch clusters" do
    generic_node = Struct.new(:token).new(nil)
    expect {
      SemanticAnnotator.new(source_code: "").send(:validate_type_annotation!, generic_node, Type.new(:"Missing<Int64>"))
    }.to raise_error(CompilerError)

    pre_ann = quiet_annotator
    bool_expr = AST::Literal.new(token(:TRUE, "TRUE"), :BOOLEAN, true, :stack)
    bool_expr.full_type = Type.new(:Bool)
    fn = AST::FunctionDef.new(token, "guarded", [], Type.new(:Void), [], :package)
    fn.pre_clauses = [{ expr: bool_expr, source: "TRUE" }]
    fn.explicit_return_type = false
    fn.arrow_token = nil
    pre_ann.define_singleton_method(:visit) { |_node| nil }
    pre_ann.send(:visit_pre_clauses!, fn)
    expect(direct_errors(pre_ann).map { |e| e[1] }).to include(:PRE_CLAUSES_NEED_EXPLICIT_FALLIBLE_RETURN)

    index_ann = quiet_annotator
    index_ann.define_singleton_method(:visit) { |_node| nil }
    index_ann.define_singleton_method(:resolve_index_op) do |type_info, _op|
      case type_info.resolved
      when :Indexed
        { return_type: Type.new(:Int64), container_borrow: true }
      when :ValueIndexed
        { return_type: Type.new(:Int64), container_borrow: false }
      end
    end
    target = AST::Identifier.new(token, "items")
    target.full_type = Type.new(:Indexed)
    idx = AST::Literal.new(token(:NUMBER, "0_i64"), :INT64, 0, :stack)
    idx.full_type = Type.new(:Int64)
    get = AST::GetIndex.new(token(:LBRACKET, "["), target, idx)
    index_ann.send(:visit_GetIndex, get)
    expect(get.container_borrow).to eq(true)

    source_root = AST::Identifier.new(token, "source_items")
    source_root.full_type = Type.new(:"Int64[]")
    source_index = AST::GetIndex.new(token(:LBRACKET, "["), source_root, idx)
    expect(index_ann.send(:find_container_source, source_index)).to eq("source_items")
    expect(index_ann.send(:find_container_source, AST::OptionalUnwrap.new(token(:QUESTION, "?"), source_index))).to eq("source_items")

    value_target = AST::Identifier.new(token, "values")
    value_target.full_type = Type.new(:ValueIndexed)
    value_get = AST::GetIndex.new(token(:LBRACKET, "["), value_target, idx)
    index_ann.send(:visit_GetIndex, value_get)
    expect(value_get.container_borrow).to be_nil

    promise_list = AST::Identifier.new(token, "promises")
    promise_list.full_type = Type.new(:"~Int64[]", collection: :list)
    promise_get = AST::GetIndex.new(token(:LBRACKET, "["), promise_list, idx)
    index_ann.send(:visit_GetIndex, promise_get)
    expect(promise_get.resolved_type).to eq(:"?~Int64")

    struct_type = Type.new(:StructLike)
    struct_type.define_singleton_method(:metatype) { :struct }
    struct_type.define_singleton_method(:element_type) { Type.new(:String) }
    struct_target = AST::Identifier.new(token, "structish")
    struct_target.full_type = struct_type
    struct_get = AST::GetIndex.new(token(:LBRACKET, "["), struct_target, idx)
    index_ann.send(:visit_GetIndex, struct_get)
    expect(struct_get.resolved_type).to eq(:String)
    expect(struct_get.container_borrow).to eq(true)

    next_ann = quiet_annotator
    next_ann.define_singleton_method(:visit) { |_node| nil }
    next_ann.define_singleton_method(:record_effect) { |_effect| nil }
    next_ann.define_singleton_method(:og_set_moved) { |_name, **_kwargs| nil }
    {
      Type.new(:"~Int64[]") => :"?Int64",
      Type.new(:"~Int64[3]") => :Int64,
      Type.new(:"~Int64", ownership: :shared) => :Int64,
      Type.new(:"~?Int64[]") => :"?Int64"
    }.each do |promise_type, expected|
      expr = AST::Identifier.new(token, "future")
      expr.full_type = promise_type
      node = AST::NextExpr.new(token(:NEXT, "NEXT"), expr)
      next_ann.send(:visit_NextExpr, node)
      expect(node.resolved_type).to eq(expected)
    end

    pipe_ann = quiet_annotator
    left = AST::Identifier.new(token, "xs")
    left.full_type = Type.new(:"Int64[]")
    bad_op = AST::Placeholder.new(token(:UNDERSCORE, "_"))
    conc = AST::ConcurrentOp.new(token(:CONCURRENT, "CONCURRENT"), bad_op, {})
    pipe = AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, conc)
    pipe_ann.send(:analyze_concurrent_op, pipe)
    expect(direct_errors(pipe_ann).map { |e| e[1] }).to include(:CONCURRENT_BAD_FOLLOWING_OP)

    lifetime_ann = quiet_annotator
    lifetime_ann.send(:current_scope).declare("x", nil, Type.new(:String), true)
    arg = AST::Identifier.new(token, "x")
    sig = FunctionSignature.new(
      params: [AST::Param.new(name: "p", type: Type.new(:String))],
      return_type: Type.new(:String),
      return_lifetime: [:wildcard]
    )
    sig.instance_variable_set(:@return_lifetime, [:wildcard])
    lifetime_ann.send(:verify_param_lifetime!, arg, sig.params.first, sig)

    expect(SemanticAnnotator.new(source_code: "").send(:init_value_contents_heap?, nil)).to eq(false)
    init_ann = SemanticAnnotator.new(source_code: "")
    struct_lit = AST::StructLit.new(token, Type.new(:Thing), { "a" => nil })
    expect(init_ann.send(:init_value_contents_heap?, struct_lit)).to eq(true)

    post_ann = quiet_annotator
    post_expr = AST::Literal.new(token(:TRUE, "TRUE"), :BOOLEAN, true, :stack)
    post_expr.full_type = Type.new(:Bool)
    post_fn = AST::FunctionDef.new(token, "checked", [], [], nil, nil, [], [], nil, :package)
    post_fn.post_clauses = [{ expr: post_expr, source: "TRUE" }]
    post_ann.define_singleton_method(:visit) { |_node| nil }
    post_ann.send(:visit_post_clauses!, post_fn)

    effects_ann = SemanticAnnotator.new(source_code: "")
    caller = AST::FunctionDef.new(token, "caller", [], [], Type.new(:Void), nil, [], [], nil, :package)
    callee = AST::FunctionDef.new(token, "callee", [], [], Type.new(:"!Void"), nil, [], [], nil, :package)
    nil_return = AST::FunctionDef.new(token, "nil_return", [], [], nil, nil, [], [], nil, :package)
    bad_return = function_def("bad_return")
    bad_return.define_singleton_method(:return_type) { raise StandardError, "broken return type" }
    effects_ann.semantic_function_nodes.replace({
      "caller" => caller,
      "callee" => callee,
      "nil_return" => nil_return,
      "bad_return" => bad_return,
    })
    record_body_summaries(
      effects_ann,
      { "caller" => ["callee", "missing"], "callee" => [], "nil_return" => [], "bad_return" => [] },
      propagating: { "caller" => ["callee"] },
      raises: Set["callee"]
    )
    effects_ann.send(:compute_can_fail!)
    expect(caller.can_fail).to eq(true)
    expect(nil_return.alloc_fault).to eq(false)
    expect(bad_return.can_fail).to eq(false)

    tied_ann = quiet_annotator
    [
      nil,
      SymbolEntry.new(reg: nil, type: Type.new(:String), mutable: false, storage: :stack),
      SymbolEntry.new(reg: nil, type: Type.new(:String), mutable: false, storage: :stack)
    ].each_with_index do |sym, i|
      value = AST::Identifier.new(token, "ret#{i}")
      value.symbol = sym if sym
      sym.mark_non_escaping! if i == 2
      tied_ann.send(:verify_tied_return!, AST::ReturnNode.new(token(:RETURN, "RETURN"), value))
    end

    source_sym = SymbolEntry.new(reg: nil, type: Type.new(:String), mutable: false, storage: :stack)
    returned_sym = SymbolEntry.new(reg: nil, type: Type.new(:String), mutable: false, storage: :stack)
    returned_sym.instance_variable_set(:@lifetime, [source_sym])
    tied_ann.send(:current_scope).install_entry("source", source_sym)
    tied_ann.semantic_function_nodes.replace({
      "tied" => AST::FunctionDef.new(token, "tied", [], [], Type.new(:String), nil, [], [], nil, :package)
    })
    with_function_context(tied_ann, return_type: Type.new(:String)) do
      returned = AST::Identifier.new(token, "returned")
      returned.symbol = returned_sym
      tied_ann.send(:verify_tied_return!, AST::ReturnNode.new(token(:RETURN, "RETURN"), returned))
    end

    fix_ann = quiet_annotator
    moved_ident = AST::Identifier.new(token, "moved")
    fix_ann.send(:emit_use_of_moved_error!, moved_ident, OwnershipGraph::Node.new(path: "moved", kind: :owned, state: :moved))
    cap_ident = AST::Identifier.new(token, "cell")
    cap_field = AST::GetField.new(token(:DOT, "."), cap_ident, "value")
    fix_ann.send(:emit_cap_field_needs_with!, cap_field, :FIELD_NEEDS_WITH, name: "cell", field: "value", cap: "read", perm: "READ")
    expect(direct_errors(fix_ann).map { |e| e[1] }).to include(:USE_OF_MOVED_VALUE, :FIELD_NEEDS_WITH)
  end

  it "covers retryable WITH fallible source discovery branches directly" do
    ann = SemanticAnnotator.new(source_code: "")
    arg = AST::Literal.new(token(:STRING, "x"), :STRING, "x", :rodata)
    fn = AST::FuncCall.new(token, "fallible_fn", [arg])
    fn.error_union_type = Type.new(:"!String")
    method = AST::MethodCall.new(token, AST::Identifier.new(token, "s"), "fallible_method", [arg])
    method.define_singleton_method(:error_union_type) { Type.new(:"!String") }
    static = AST::StaticCall.new(token, AST::Identifier.new(token(:TYPE_ID, "Box"), "Box"), "fallible_static", [arg])
    static.define_singleton_method(:error_union_type) { Type.new(:"!String") }
    frozen = AST::FreezeNode.new(token(:FREEZE, "FREEZE"), fn)
    with_node = AST::WithBlock.new(token(:WITH, "WITH"), [], [])
    attach_capability_plan!(with_node)
    raise_node = AST::Raise.new(token(:RAISE, "RAISE"), nil, nil, nil)
    or_else_raise = AST::OrElseRaise.new(token(:OR_ELSE, "OR_ELSE"))

    body_fact_summary(ann) do
      ann.send(:record_body_fact_with_block!, with_node)
      ann.send(:with_body_fact_scope, with_node) do
        [raise_node, or_else_raise, method, static, frozen, fn].each { |node| ann.send(:record_body_fact_node!, node) }
      end
      sources = ann.send(:retryable_with_fallible_sources, with_node)
      expect(sources).to include("RAISE", "OR_ELSE RAISE", "fallible_fn", "fallible_method()", "fallible_static", "FREEZE")
    end

  end

  it "covers effect maybe-resolution branch matrix directly" do
    ann = SemanticAnnotator.new(source_code: "")
    families = ann.send(:effect_call_site_arg_families)
    families.clear

    plain = Set[EffectTracker::HEAP]
    expect(ann.send(:resolve_maybe_effects, plain, "caller", "plain")).to equal(plain)

    maybe = Set[EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE]
    expect(ann.send(:resolve_maybe_effects, maybe, "caller", "uncalled")).to equal(maybe)

    families["caller"]["locked"] << [Set[:LOCKED]]
    locked = ann.send(:resolve_maybe_effects, maybe, "caller", "locked")
    expect(locked).to include(EffectTracker::BLOCKING, EffectTracker::CONTENTION)
    expect(locked).not_to include(EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE)

    families["caller"]["atomic"] << [Set[:ATOMIC]]
    atomic = ann.send(:resolve_maybe_effects, maybe, "caller", "atomic")
    expect(atomic).to include(EffectTracker::CONTENTION)
    expect(atomic).not_to include(EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE)

    families["caller"]["none"] << [Set.new]
    none = ann.send(:resolve_maybe_effects, maybe, "caller", "none")
    expect(none).to include(EffectTracker::BLOCKING_MAYBE)
    expect(none).not_to include(EffectTracker::CONTENTION_MAYBE)

    families["caller"]["poly"] << [Set[:LOCKED, :ATOMIC]]
    poly = ann.send(:resolve_maybe_effects, maybe, "caller", "poly")
    expect(poly).to include(EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE)
    expect(poly).not_to include(EffectTracker::BLOCKING, EffectTracker::CONTENTION)
  end

  it "covers reentrance validation and mutual thunk fix branches directly" do
    ann = quiet_annotator
    direct = function_from(<<~CHT, "direct")
      FN direct(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:NOT_LOGICAL ->
        RETURN n;
      END
    CHT
    mutual = function_from(<<~CHT, "mutual")
      FN mutual(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:NOT_LOGICAL ->
        RETURN other(n);
      END
    CHT
    other = function_from(<<~CHT, "other")
      FN other(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT ->
        RETURN mutual(n);
      END
    CHT
    direct.reentrance_kind = :reentrant_not_logical
    mutual.reentrance_kind = :reentrant_not_logical
    other.reentrance_kind = :reentrant
    ann.semantic_function_nodes.replace({ "direct" => direct, "mutual" => mutual, "other" => other })
    ann.send(:effect_direct_effects).replace({ "direct" => Set[EffectTracker::REENTRANT], "mutual" => Set.new, "other" => Set.new })
    record_body_summaries(ann, { "direct" => Set.new, "mutual" => Set["other"], "other" => Set["mutual"] })

    ann.send(:validate_not_logical_recursion!)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:REENTRANT_NOT_LOGICAL_BUT_RECURSIVE)

    max_depth = function_from(<<~CHT, "bounded")
      FN bounded(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:MAX_DEPTH(8) ->
        RETURN partner(n);
      END
    CHT
    partner = function_from(<<~CHT, "partner")
      FN partner(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT ->
        RETURN bounded(n);
      END
    CHT
    max_depth.reentrance_kind = :reentrant_max_depth
    max_depth.max_depth_n = 8
    partner.reentrance_kind = :reentrant
    ann.semantic_function_nodes.replace({ "bounded" => max_depth, "partner" => partner })
    ann.send(:effect_direct_effects).replace({ "bounded" => Set.new, "partner" => Set.new })
    record_body_summaries(ann, { "bounded" => Set["partner"], "partner" => Set["bounded"] })
    ann.send(:validate_max_depth_mutual_cycle!)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:fixable)

    lonely = function_from(<<~CHT, "lonely")
      FN lonely(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN n;
      END
    CHT
    lonely.reentrance_kind = :reentrant_thunk
    ann.semantic_function_nodes.replace({ "lonely" => lonely })
    record_body_summaries(ann, { "lonely" => Set.new })
    expect(ann.send(:try_stamp_mutual_thunk_plan!, lonely)).to eq(false)

    a = function_from(<<~CHT, "a")
      FN a(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN b(n);
      END
    CHT
    b = function_from(<<~CHT, "b")
      FN b(n: Int64) RETURNS Bool
        EFFECTS REENTRANT:THUNK ->
        RETURN TRUE;
      END
    CHT
    a.reentrance_kind = :reentrant_thunk
    b.reentrance_kind = :reentrant_thunk
    ann.semantic_function_nodes.replace({ "a" => a, "b" => b })
    record_body_summaries(ann, { "a" => Set["b"], "b" => Set["a"] })
    expect(ann.send(:try_stamp_mutual_thunk_plan!, a)).to eq(false)

    c = function_from(<<~CHT, "c")
      FN c(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN d(n);
      END
    CHT
    d = function_from(<<~CHT, "d")
      FN d(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN c(n);
      END
    CHT
    c.reentrance_kind = :reentrant_thunk
    d.reentrance_kind = :reentrant_thunk
    ann.semantic_function_nodes.replace({ "c" => c, "d" => d })
    record_body_summaries(ann, { "c" => Set["d"], "d" => Set["c"] })
    ann.send(:emit_mutual_thunk_unsupported!, c)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:fixable)

    no_span = function_from(<<~CHT, "no_span")
      FN no_span(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN no_edit(n);
      END
    CHT
    no_edit = function_from(<<~CHT, "no_edit")
      FN no_edit(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN no_span(n);
      END
    CHT
    [no_span, no_edit].each do |fn|
      fn.reentrance_kind = :reentrant_thunk
      fn.effects_span = nil
      fn.return_type_token = nil
    end
    ann.semantic_function_nodes.replace({ "no_span" => no_span, "no_edit" => no_edit })
    record_body_summaries(ann, { "no_span" => Set["no_edit"], "no_edit" => Set["no_span"] })
    ann.send(:emit_mutual_thunk_unsupported!, no_span)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:REENTRANT_MUTUAL_THUNK_UNSUPPORTED)

    no_arrow = function_def("no_arrow")
    no_arrow.arrow_token = nil
    cycle_ann = quiet_annotator
    cycle_ann.semantic_function_nodes.replace({ "no_arrow" => no_arrow })
    cycle_ann.send(:effect_direct_effects).replace({ "no_arrow" => Set.new })
    record_body_summaries(cycle_ann, { "no_arrow" => Set["no_arrow"] })
    cycle_ann.send(:check_indirect_reentrancy!)
    expect(direct_errors(cycle_ann).map { |e| e[1] }).to include(:REENTRANCY_MUTUAL_CYCLE)
  end

  it "covers reentrance defensive edit fallback branches directly" do
    max_ann = quiet_annotator
    no_fix = function_def("no_fix")
    no_fix.reentrance_kind = :reentrant_max_depth
    no_fix.max_depth_n = 4
    no_fix_partner = function_def("no_fix_partner")
    no_fix_partner.reentrance_kind = :reentrant
    max_ann.semantic_function_nodes.replace({ "no_fix" => no_fix, "no_fix_partner" => no_fix_partner })
    max_ann.send(:effect_direct_effects).replace({ "no_fix" => Set.new, "no_fix_partner" => Set.new })
    record_body_summaries(max_ann, { "no_fix" => Set["no_fix_partner"], "no_fix_partner" => Set["no_fix"] })

    max_ann.send(:validate_max_depth_mutual_cycle!)

    max_depth_finding = direct_errors(max_ann).find { |err| err[1] == :fixable }
    expect(max_depth_finding).not_to be_nil
    expect(max_depth_finding[3][:fixes]).to eq([])

    direct_ann = quiet_annotator
    direct_thunk = function_from(<<~CHT, "direct_thunk")
      FN direct_thunk(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN direct_thunk(n);
      END
    CHT
    direct_thunk.reentrance_kind = :reentrant_thunk
    direct_ann.semantic_function_nodes.replace({ "direct_thunk" => direct_thunk })
    record_body_summaries(direct_ann, { "direct_thunk" => Set["direct_thunk"] })

    direct_ann.send(:validate_thunk_recursion!)

    expect(direct_errors(direct_ann)).to be_empty

    token_ann = quiet_annotator
    missing_rt_a = function_from(<<~CHT, "missing_rt_a")
      FN missing_rt_a(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN missing_rt_b(n);
      END
    CHT
    missing_rt_b = function_from(<<~CHT, "missing_rt_b")
      FN missing_rt_b(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN missing_rt_a(n);
      END
    CHT
    [missing_rt_a, missing_rt_b].each do |fn|
      fn.reentrance_kind = :reentrant_thunk
      fn.return_type_token = nil
    end
    token_ann.semantic_function_nodes.replace({ "missing_rt_a" => missing_rt_a, "missing_rt_b" => missing_rt_b })
    record_body_summaries(token_ann, { "missing_rt_a" => Set["missing_rt_b"], "missing_rt_b" => Set["missing_rt_a"] })

    token_ann.send(:emit_mutual_thunk_unsupported!, missing_rt_a)

    expect(direct_errors(token_ann).map { |err| err[1] }).to include(:fixable)
  end

  it "covers pipe window, distinct, shard, and fixable-helper branches directly" do
    ann = quiet_annotator
    ann.define_singleton_method(:visit) do |node|
      next unless node.respond_to?(:full_type=)
      inferred = case node
                 when AST::Literal
                   node.type == :STRING ? Type.new(:String) : Type.new(:Int64)
                 else
                   Type.new(:Int64)
                 end
      node.full_type = inferred
    end
    ann.send(:push_function_context!, FunctionContext.new(name: "pipe", return_type: Type.new(:Void), lifetime: [], type_params: []))

    left = AST::Identifier.new(token, "xs")
    left.full_type = Type.new(:"Int64[]")
    neg_size = AST::Literal.new(token(:NUMBER, "-1_i64"), :INT64, -1, :stack)
    bad_time = AST::Literal.new(token(:STRING, "0ms"), :STRING, "0ms", :rodata)
    expr = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    expr.full_type = Type.new(:Int64)
    batch = AST::BatchWindowOp.new(token(:WINDOW, "WINDOW"), {
      "bogus" => expr,
      "size" => neg_size,
      "time" => bad_time
    }, expr)
    ann.send(:analyze_batch_window_op, AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, batch))
    expect(direct_errors(ann).map { |e| e[1] }).to include(:WINDOW_BAD_OPTION, :WINDOW_SIZE_NEEDS_POSITIVE, :WINDOW_TIME_NEEDS_POSITIVE)

    no_opts = AST::BatchWindowOp.new(token(:WINDOW, "WINDOW"), {}, expr)
    ann.send(:analyze_batch_window_op, AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, no_opts))
    expect(direct_errors(ann).map { |e| e[1] }).to include(:WINDOW_NEEDS_SIZE_OR_TIME)

    distinct_ann = quiet_annotator
    observed_terminals = []
    distinct_ann.define_singleton_method(:visit) { |node| node.full_type = Type.new(:String) if node.respond_to?(:full_type=) }
    distinct_ann.define_singleton_method(:require_array_input!) { |_node, _op, **_kwargs| nil }
    distinct_ann.define_singleton_method(:mark_observable_terminal!) do |_node, **kwargs|
      observed_terminals << kwargs
      nil
    end
    distinct_ann.send(:push_function_context!, FunctionContext.new(name: "distinct", return_type: Type.new(:Void), lifetime: [], type_params: []))
    bounded_left = AST::Identifier.new(token, "stream")
    bounded_left.full_type = Type.new(:"~Int64[3]")
    key = AST::Literal.new(token(:STRING, "k"), :STRING, "k", :rodata)
    key.full_type = Type.new(:String)
    distinct_ann.send(:analyze_distinct_op, AST::BinaryOp.new(token(:PIPE, "|>"), bounded_left, :SMOOTH, AST::DistinctOp.new(token(:DISTINCT, "DISTINCT"), key)))

    array_left = AST::Identifier.new(token, "array")
    array_left.full_type = Type.new(:"Int64[]")
    distinct_ann.send(:analyze_distinct_op, AST::BinaryOp.new(token(:PIPE, "|>"), array_left, :SMOOTH, AST::DistinctOp.new(token(:DISTINCT, "DISTINCT"), key)))
    expect(observed_terminals.map { |t| t[:collection] }).to eq([:set, :set])

    shard_ann = quiet_annotator
    shard_ann.define_singleton_method(:visit) { |node| node.full_type ||= Type.new(:String) if node.respond_to?(:full_type=) }
    bad_left = AST::Identifier.new(token, "scalar")
    bad_left.full_type = Type.new(:Int64)
    bad_target = AST::Identifier.new(token, "plain_map")
    bad_target.full_type = Type.new(:HashMap)
    bad_key = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    bad_key.full_type = Type.new(:Int64)
    shard_ann.send(:analyze_shard_op, AST::BinaryOp.new(token(:PIPE, "|>"), bad_left, :SMOOTH, AST::ShardOp.new(token(:SHARD, "SHARD"), bad_target, bad_key)))

    map_type = Type.new(:HashMap)
    map_type.define_singleton_method(:sharded?) { true }
    map_type.define_singleton_method(:key_type) { Type.new(:String) }
    target = AST::Identifier.new(token, "sharded")
    target.full_type = map_type
    target.symbol = SymbolEntry.new(reg: nil, type: map_type, mutable: true, storage: :heap)
    shard_ann.send(:analyze_shard_op, AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, AST::ShardOp.new(token(:SHARD, "SHARD"), target, bad_key)))

    numeric_map = Type.new(:HashMap)
    numeric_map.define_singleton_method(:sharded?) { true }
    numeric_map.define_singleton_method(:key_type) { Type.new(:Int64) }
    numeric_target = AST::Identifier.new(token, "numeric")
    numeric_target.full_type = numeric_map
    numeric_target.symbol = SymbolEntry.new(reg: nil, type: numeric_map, mutable: true, storage: :heap)
    string_key = AST::Literal.new(token(:STRING, "k"), :STRING, "k", :rodata)
    string_key.full_type = Type.new(:String)
    shard_ann.send(:analyze_shard_op, AST::BinaryOp.new(token(:PIPE, "|>"), left, :SMOOTH, AST::ShardOp.new(token(:SHARD, "SHARD"), numeric_target, string_key)))
    expect(direct_errors(shard_ann).map { |e| e[1] }).to include(:SHARD_NEEDS_RANGE_OR_COLLECTION, :SHARD_TARGET_BAD, :SHARD_KEY_NEEDS_STRING)

    fix_ann = quiet_annotator
    fix_ann.instance_variable_set(:@source_code, "WITH SNAPSHOT cell AS MUTABLE guard {\n  guard.value;\n}\n")
    with_node = AST::WithBlock.new(token(:WITH, "WITH"), [], [], [])
    fix_ann.send(:emit_with_guard_mutable_mutated!, with_node, ["guard"], "is")
    expect(direct_errors(fix_ann).map { |e| e[1] }).to include(:fixable)

    auto_decl = AST::VarDecl.new(token(:VAR_ID, "item"), "item", Type.new(:"Int64[]"), expr, false)
    slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: auto_decl, sources: [], auto_token: token(:TYPE_ID, "Auto"))
    fix_ann.send(:emit_auto_shape_resolved_finding!, auto_decl, slot)
    expect(direct_errors(fix_ann).map { |e| e[1] }).to include(:fixable)
  end

  it "covers auto constraint collection branch matrix directly" do
    callee = AST::FunctionDef.new(token, "callee", [
      AST::Param.new(name: "x", type: auto_type),
      AST::Param.new(name: "y", type: Type.new(:Int64))
    ], [], auto_type, nil, [], [], nil, :package)
    collector = AutoConstraintCollector.new({ "callee" => callee })
    collector.send(:register_signature_slots)
    slots = collector.instance_variable_get(:@slots)

    arg = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    collector.send(:record_call_site, AST::FuncCall.new(token, "missing", [arg]))
    collector.send(:record_call_site, AST::FuncCall.new(token, "callee", []))
    collector.send(:record_call_site, AST::FuncCall.new(token, "callee", [arg]))
    expect(slots[AutoSlotId.param("callee", 0)].sources).to include(arg)

    ret = AST::ReturnNode.new(token(:RETURN, "RETURN"), arg)
    collector.send(:record_return, AST::ReturnNode.new(token(:RETURN, "RETURN"), nil), callee)
    collector.send(:record_return, ret, callee)
    expect(slots[AutoSlotId.return("callee")].sources).to include(arg)

    collector.instance_variable_set(:@local_decls, {})
    scalar_value = AST::Literal.new(token(:STRING, "s"), :STRING, "s", :rodata)
    scalar_decl = AST::VarDecl.new(token(:VAR_ID, "scalar"), "scalar", auto_type, scalar_value, true)
    collector.send(:record_local, scalar_decl)
    scalar_slot_id = AutoSlotId.local(scalar_decl)
    expect(slots[scalar_slot_id].sources).to include(scalar_value)

    reassigned = AST::Literal.new(token(:NUMBER, "2_i64"), :INT64, 2, :stack)
    collector.send(:record_local, AST::BindExpr.new(token(:VAR_ID, "scalar"), "scalar", nil, reassigned))
    expect(slots[scalar_slot_id].sources).to include(reassigned)
    collector.send(:record_local, AST::BindExpr.new(token(:VAR_ID, "unknown"), "unknown", nil, reassigned))

    list_decl = AST::VarDecl.new(token(:VAR_ID, "items"), "items", auto_type, AST::ListLit.new(token(:LBRACKET, "["), [], :stack), true)
    collector.send(:record_local, list_decl)
    list_slot = slots[AutoSlotId.list_element(list_decl)]
    list_items = [
      AST::Literal.new(token(:NUMBER, "3_i64"), :INT64, 3, :stack),
      AST::Literal.new(token(:NUMBER, "4_i64"), :INT64, 4, :stack)
    ]
    collector.send(:record_reassignment_sources, AutoSlotId.list_element(list_decl), AST::ListLit.new(token(:LBRACKET, "["), list_items, :stack))
    expect(list_slot.sources).to include(*list_items)

    map_decl = AST::VarDecl.new(token(:VAR_ID, "map"), "map", auto_type, AST::HashLit.new(token(:LBRACE, "{"), [], :stack), true)
    collector.send(:record_local, map_decl)
    key_slot = slots[AutoSlotId.map_key(map_decl)]
    val_slot = slots[AutoSlotId.map_value(map_decl)]
    key = AST::Literal.new(token(:STRING, "k"), :STRING, "k", :rodata)
    val = AST::Literal.new(token(:NUMBER, "5_i64"), :INT64, 5, :stack)
    collector.send(:record_reassignment_sources, AutoMapShapeEntry.new(key: AutoSlotId.map_key(map_decl), value: AutoSlotId.map_value(map_decl)), AST::HashLit.new(token(:LBRACE, "{"), [[key, val]], :stack))
    expect(key_slot.sources).to include(key)
    expect(val_slot.sources).to include(val)

    shape_collector = ShapeEvidenceCollector.new(slots, {})
    shape_slots = AutoShapeSlots.new(list: list_slot, key: key_slot, value: val_slot)
    target = AST::Identifier.new(token, "items")
    shape_collector.send(:record_method_call, AST::MethodCall.new(token, AST::Literal.new(token(:NUMBER, "0_i64"), :INT64, 0, :stack), "append", [arg]), {})
    shape_collector.send(:record_method_call, AST::MethodCall.new(token, target, "append", [arg]), {})
    shape_collector.send(:record_method_call, AST::MethodCall.new(token, target, "append", [arg]), { "items" => shape_slots })
    shape_collector.send(:record_method_call, AST::MethodCall.new(token, target, "insert", [key, val]), { "items" => shape_slots })
    shape_collector.send(:record_method_call, AST::MethodCall.new(token, target, "put", [key, val]), { "items" => shape_slots })
    expect(list_slot.sources).to include(arg)
    expect(key_slot.sources).to include(key)
    expect(val_slot.sources).to include(val)

    indexed = AST::GetIndex.new(token(:LBRACKET, "["), target, key)
    shape_collector.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), AST::Identifier.new(token, "plain"), val), { "items" => shape_slots })
    shape_collector.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), indexed, val), {})
    shape_collector.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), indexed, val), { "items" => AutoShapeSlots.new(list: list_slot, key: nil, value: nil) })
    shape_collector.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), indexed, val), { "items" => AutoShapeSlots.new(list: nil, key: key_slot, value: val_slot) })
    expect(list_slot.sources).to include(val)
    expect(key_slot.sources).to include(key)
    expect(val_slot.sources).to include(val)
  end

  it "covers fixable helper branch matrix directly" do
    ann = quiet_annotator
    ann.instance_variable_set(:@source_code, [
      "MUTABLE local: Int64 @local = 1_i64;",
      "other: Byte = 1000_i64;",
      "wide = 1000_i8;",
      "cell: Int64 @shared:atomic = 0_i64;"
    ].join("\n"))

    reg = AST::VarDecl.new(token(:MUTABLE, "MUTABLE"), "local", Type.new(:Int64), nil, true)
    reg.token.line = 1
    reg.token.column = 1
    ann.send(:emit_mutable_unused_finding!, reg, "local")
    ann.send(:emit_mutable_unused_finding!, AST::VarDecl.new(token(:VAR_ID, "plain"), "plain", Type.new(:Int64), nil, true), "plain")
    expect(ann.send(:levenshtein, "", "abc")).to eq(3)
    expect(ann.send(:levenshtein, "abc", "")).to eq(3)

    local_audit = CapabilityAudit::BindingAuditRecord.new(
      fn: "main", var: "local", line: 1, column: 1,
      sync: :local, ownership: nil, storage: :stack, sharded: false,
      mutated: false, captured_bg: false, captured_parallel: false
    )
    missing_audit = CapabilityAudit::BindingAuditRecord.new(
      fn: "main", var: "missing", line: 99, column: 1,
      sync: :local, ownership: nil, storage: :stack, sharded: false,
      mutated: false, captured_bg: false, captured_parallel: false
    )
    ann.send(:emit_local_never_shared_finding!, local_audit)
    ann.send(:emit_local_never_shared_finding!, missing_audit)

    overflow_suffix = AST::Literal.new(token(:NUMBER, "1000_i8"), :INT64, 1000, :stack)
    overflow_suffix.token.line = 3
    overflow_suffix.token.column = 8
    ann.send(:emit_int_overflow_error!, overflow_suffix, 1000, :Int8, -128, 127)
    overflow_annotation = AST::Literal.new(token(:NUMBER, "1000_i64"), :INT64, 1000, :stack)
    overflow_annotation.token.line = 2
    overflow_annotation.token.column = 15
    ann.send(:emit_int_overflow_error!, overflow_annotation, 1000, :Byte, 0, 255)

    close = token(:TYPE_ID, "Inpug")
    ann.send(:emit_registry_mismatch!, close, :Inpug, [:Input], "bad registry", "known type")
    ann.send(:emit_registry_mismatch!, token(:TYPE_ID, "zzzz"), :zzzz, [:Input], "bad registry", "known type")

    ann.send(:emit_variant_typo!, AnchorToken.new(1, 1), "Alpa", [:Alpha], "bad variant", "known variant")
    ann.send(:emit_variant_typo!, AnchorToken.new(1, 1), "zzzz", [:Alpha], "bad variant", "known variant")

    match = AST::MatchStatement.new(token(:MATCH, "MATCH"), AST::Identifier.new(token, "x"), [], nil, [], nil, false, nil)
    ann.send(:emit_match_partial_fix!, match, :MATCH_NON_EXHAUSTIVE, kind: "union", name: "Choice", missing: "Other")
    no_tok_match = AST::MatchStatement.new(nil, AST::Identifier.new(token, "x"), [], nil, [], nil, false, nil)
    ann.send(:emit_match_partial_fix!, no_tok_match, :MATCH_NON_EXHAUSTIVE, kind: "union", name: "Choice", missing: "Other")

    borrowed = AST::Identifier.new(token, "borrowed")
    borrowed.full_type = Type.new(:String)
    ann.send(:emit_return_borrowed_no_copy_error!, borrowed)
    borrowed_no_tok = AST::Identifier.new(nil, "borrowed")
    borrowed_no_tok.full_type = Type.new(:String)
    ann.send(:emit_return_borrowed_no_copy_error!, borrowed_no_tok)

    fn = AST::FunctionDef.new(token, "mutates", [], [], Type.new(:Void), nil, [], [], nil, :package)
    fn.name_token = token(:VAR_ID, "mutates")
    ann.send(:emit_style_mutable_param_needs_bang!, fn)
    fn.name_token = nil
    ann.send(:emit_style_mutable_param_needs_bang!, fn)

    scope = Scope.new
    decl_tok = token(:VAR_ID, "cell")
    decl_tok.line = 4
    decl_tok.column = 1
    cell_decl = AST::VarDecl.new(decl_tok, "cell", Type.new(:Int64), nil, true)
    cell_sym = SymbolEntry.new(reg: cell_decl, type: Type.new(:Int64), mutable: true, storage: :heap, sync: :atomic)
    scope.install_entry("cell", cell_sym)
    ann.define_singleton_method(:lookup_scope_for) { |name| name == "cell" ? scope : nil }
    ann.send(:emit_with_cannot_infer_cap!, AST::WithBlock.new(token(:WITH, "WITH"), [], []), "cell")
    expect(ann.send(:build_declare_mutable_fix, "missing", scope)).to be_nil
    expect(ann.send(:build_atomic_escape_migration_fix, cell_sym, "cell")).not_to be_nil

    codes = direct_errors(ann).map { |e| e[1] }
    expect(codes.count(:fixable)).to be >= 8
    expect(codes).to include(:REGISTRY_MISMATCH_REJECTED, :TYPO_SUGGESTION_REJECTED, :MATCH_NON_EXHAUSTIVE,
      :RETURN_BORROWED_NO_COPY_OR_LIFETIME, :STYLE_MUTABLE_PARAM_NEEDS_BANG)
  end

  it "covers error selector resolution branch matrix directly" do
    ann = quiet_annotator
    node = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(capability: :EXCLUSIVE, var_node: AST::Identifier.new(token, "lock"))
    ], [])
    attach_capability_plan!(node)
    clause = AST::ErrorClause.new(
      token: token(:ON, "ON"),
      retries: 1,
      action: AST::ErrorActionKind::Raise,
      selectors: [
        AST::ErrorSelector.new(form: :kind, name: :Transient, token: token(:TYPE_ID, "Transient")),
        AST::ErrorSelector.new(form: :kind, name: :Transint, token: token(:TYPE_ID, "Transint")),
        AST::ErrorSelector.new(form: :type, name: :LockTimeout, token: token(:TYPE_ID, "LockTimeout")),
        AST::ErrorSelector.new(form: :type, name: :MadeUpFailure, token: token(:TYPE_ID, "MadeUpFailure")),
        AST::ErrorSelector.new(form: :message, name: :ignored, token: token(:STRING, "\"x\"")),
      ],
    )

    ann.send(:resolve_error_selectors!, node, clause)

    expect(clause.matched_types).to include(:LockTimeout, :LockCycle)
    expect(clause.bubble_types).to include(:Deadlock)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:REGISTRY_MISMATCH_REJECTED)
  end

  it "covers union method and schema validation branch matrix directly" do
    ann = quiet_annotator
    scope = Scope.new
    ann.define_singleton_method(:lookup_scope_for) { |_name| scope }

    scope.install_entry("not_a_function", SymbolEntry.new(reg: nil, type: Type.new(:Int64), mutable: false, storage: :stack))
    short_sig = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
    scope.install_entry("short", SymbolEntry.new(reg: nil, type: short_sig, mutable: false, storage: :stack))
    no_return_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
    scope.install_entry("no_return", SymbolEntry.new(reg: nil, type: no_return_sig, mutable: false, storage: :stack))

    union = AST::UnionDef.new(token(:UNION, "UNION"), "Choice", {}, :package)
    union.methods = [
      AST::UnionMethodRequirement.new(token: token(:VAR_ID, "not_a_function"), name: "not_a_function", params: [], return_type: Type.new(:Int64)),
      AST::UnionMethodRequirement.new(token: token(:VAR_ID, "missing_no_body"), name: "missing_no_body", params: [], return_type: Type.new(:Int64)),
      AST::UnionMethodRequirement.new(
        token: token(:VAR_ID, "short"),
        name: "short",
        params: [AST::UnionMethodParamRequirement.new(name: "x", type: Type.new(:Int64))],
        return_type: Type.new(:Int64),
      ),
      AST::UnionMethodRequirement.new(token: token(:VAR_ID, "no_return"), name: "no_return", params: [], return_type: nil),
    ]

    ann.send(:validate_union_methods!, union)

    lit_token = token(:LBRACE, "{")
    lit_token.column = 20
    lit = AST::UnionVariantLit.new(lit_token, "Choice", "Missng", {}, :stack)
    schema = Schemas::UnionSchema.new(variants: { "Present" => Schemas::InlineStructVariant.new(fields: {}) })
    ann.send(:validate_union_schema!, lit, schema)

    codes = direct_errors(ann).map { |e| e[1] }
    expect(codes).to include(:UNION_METHOD_MISSING, :TYPO_SUGGESTION_REJECTED)
  end

  it "covers catch clause normalization branch matrix directly" do
    ann = quiet_annotator
    visited = []
    ann.define_singleton_method(:visit) do |node|
      visited << node
      node.full_type = Type.new(:String) if node.respond_to?(:full_type=)
    end

    msg = AST::Literal.new(token(:STRING, "\"retry\""), :STRING, "retry", :rodata)
    clause = AST::CatchClause.new(
      items: [
        AST::CatchItem.new(form: :kind, name: "Transient", token: token(:TYPE_ID, "Transient")),
        AST::CatchItem.new(form: :kind, name: "Transint", token: token(:TYPE_ID, "Transint")),
        AST::CatchItem.new(form: :type, name: "LockTimeout", token: token(:TYPE_ID, "LockTimeout")),
        AST::CatchItem.new(form: :type, name: "MadeUpFailure", token: token(:TYPE_ID, "MadeUpFailure")),
      ],
      filters: [
        AST::CatchFilter.new(form: :type, value: "MvccConflict", token: token(:TYPE_ID, "MvccConflict")),
        AST::CatchFilter.new(form: :type, value: "MadeUpFilter", token: token(:TYPE_ID, "MadeUpFilter")),
        AST::CatchFilter.new(form: :message, value: msg, token: token(:STRING, "\"retry\"")),
        AST::CatchFilter.new(form: :other, value: "ignored", token: token(:VAR_ID, "ignored")),
      ],
    )

    ann.send(:resolve_catch_clause!, clause)

    expect(clause.kinds).to eq([:Transient])
    expect(clause.types).to eq(["LockTimeout"])
    expect(clause.filter_types).to include("MvccConflict", "MadeUpFilter")
    expect(clause.filter_messages).to eq([msg])
    expect(visited).to eq([msg])
    expect(direct_errors(ann).map { |e| e[1] }).to include(:REGISTRY_MISMATCH_REJECTED, :CATCH_WITH_UNREGISTERED)
  end

  it "covers snapshot match handler validation branch matrix directly" do
    ann = quiet_annotator
    visited = []
    policy_msg = AST::Literal.new(token(:STRING, "\"policy\""), :STRING, "policy", :rodata)
    ann.define_singleton_method(:synthesize_clause_from_policy) do |name|
      name == :MvccConflict ? AST::ErrorClause.new(selectors: [], action: AST::ErrorActionKind::Exit, retries: nil, token: nil, message: policy_msg) : nil
    end
    ann.define_singleton_method(:visit) do |node|
      visited << node
      node.full_type = Type.new(:String) if node.respond_to?(:full_type=)
    end
    ann.define_singleton_method(:visit_stmts) { |body| visited.concat(body) }

    block_body = [AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)]
    node = AST::WithBlock.new(token(:WITH, "WITH"), [], [])
    node.arms = [
      AST::WithMatchArm.new(family: :VERSIONED),
      AST::WithMatchArm.new(family: :ATOMIC, lock_error_clauses: [AST::ErrorClause.new(selectors: [], action: AST::ErrorActionKind::Raise, retries: nil, token: nil)]),
      AST::WithMatchArm.new(family: :LOCKED, lock_error_clauses: [AST::ErrorClause.new(selectors: [], action: AST::ErrorActionKind::Block, retries: nil, token: nil, body: block_body)]),
      AST::WithMatchArm.new(family: :OTHER, lock_error_clauses: [AST::ErrorClause.new(selectors: [], action: AST::ErrorActionKind::Exit, retries: nil, token: nil, message: AST::Literal.new(token(:STRING, "\"x\""), :STRING, "x", :rodata))]),
    ]

    ann.send(:validate_snapshot_match_arms!, node)

    expect(node.arms.first.lock_error_clauses.first.action).to eq(AST::ErrorActionKind::Exit)
    expect(visited).to include(node.arms.first.lock_error_clauses.first.message, block_body.first, node.arms.last.lock_error_clauses.first.message)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:WITH_SNAPSHOT_MATCH_ATOMIC_FORBIDS_HANDLER)

    miss = AST::WithBlock.new(token(:WITH, "WITH"), [], [])
    miss.arms = [AST::WithMatchArm.new(family: :VERSIONED)]
    ann.define_singleton_method(:synthesize_clause_from_policy) { |_name| nil }
    ann.send(:validate_snapshot_match_arms!, miss)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:WITH_SNAPSHOT_MATCH_VERSIONED_NEEDS_HANDLER)
  end

  it "reports snapshot transactions with no inline or policy handler" do
    ann = quiet_annotator
    ann.define_singleton_method(:synthesize_clause_from_policy) { |_name| nil }
    node = AST::WithBlock.new(token(:WITH, "WITH"), [], [])
    node.snapshot_mode = :transaction
    attach_capability_plan!(node)

    ann.send(:validate_lock_error_clause!, node, [])

    expect(direct_errors(ann).map { |e| e[1] }).to include(:WITH_SNAPSHOT_NEEDS_HANDLER)
  end

  it "names multi-object atomic match fallback errors at the WITH level" do
    ann = quiet_annotator
    first = AST::Capability.new(capability: :EXCLUSIVE, var_node: AST::Identifier.new(token, "a"))
    second = AST::Capability.new(capability: :EXCLUSIVE, var_node: AST::Identifier.new(token, "b"))
    node = AST::WithBlock.new(token(:WITH, "WITH"), [first, second], [])
    node.arms = [AST::WithMatchArm.new(family: :ATOMIC)]
    attach_capability_plan!(node)

    ann.send(:validate_no_multi_object_atomic!, node)

    error = direct_errors(ann).find { |err| err[1] == :WITH_MULTI_OBJECT_ATOMIC }
    expect(error).not_to be_nil
    expect(error[3][:name]).to eq("this WITH")
    unknown_cap = AST::Capability.new(capability: :unknown, var_node: AST::Identifier.new(token, "x"))
    expect(capability_transition(unknown_cap).sync_constrained?).to be(false)
  end

  it "strips BG error-union result types and rejects arena parallel blocks" do
    ann = quiet_annotator
    analysis = ann.send(:new_capture_analysis)
    ann.define_singleton_method(:visit) { |_node| nil }
    ann.define_singleton_method(:with_fiber_capture_analysis) do |is_parallel: false, mark_moves: false, &blk|
      blk.call
      analysis
    end

    expr = AST::Identifier.new(token, "fallible")
    expr.full_type = Type.new(:"!String")
    bg = AST::BgBlock.new(token(:BG, "BG"), [expr], nil, nil, false, true, true, false)

    ann.send(:visit_BgBlock, bg)

    expect(bg.full_type!.to_s).to eq("~String")
    expect(bg.pinned).to eq(true)
    expect(direct_errors(ann).map { |err| err[1] }).to include(:BG_ARENA_AND_PARALLEL)
  end

  it "reports child BG blocks that capture from pinned parent scopes" do
    ann = quiet_annotator
    analysis = ann.send(:new_capture_analysis)
    analysis.has_outer_ref = true
    ann.send(:phase_receiver_state).current_bg_pinned = true
    ann.define_singleton_method(:visit) { |_node| nil }
    ann.define_singleton_method(:with_fiber_capture_analysis) do |is_parallel: false, mark_moves: false, &blk|
      blk.call
      analysis
    end

    bg = AST::BgBlock.new(token(:BG, "BG"), [], nil, nil, false, false, false, false)

    ann.send(:visit_BgBlock, bg)

    expect(direct_errors(ann).map { |err| err[1] }).to include(:BG_PINNED_CAPTURE_MISMATCH)
  end

  it "records plain string-map capture cleanup and rejects parallel local rc captures" do
    ann = quiet_annotator
    analysis = ann.send(:new_capture_analysis)
    ctx = CapabilityHelper::CaptureContext.new(
      analysis: analysis,
      outer_scope: Scope.new,
      locals: Set.new,
      is_parallel: false,
      mark_moves: false
    )
    map_type = Type.new(:"HashMap<Int64>")
    map_entry = SymbolEntry.new(reg: nil, type: map_type, mutable: true, storage: :stack)
    map_node = AST::Identifier.new(token, "map")
    map_node.full_type = map_type

    ann.send(:record_capture_info!, ctx, "map", map_entry, map_node)

    expect(analysis.resource_captures).to include("map")
    map_close = T.must(analysis.close_plans["map"])
    expect(map_close.actions.map(&:name)).to eq(["deinit"])
    expect(map_close.actions.first.runtime_heap_alloc_args).to eq(2)

    parallel_analysis = ann.send(:new_capture_analysis)
    parallel_analysis.has_local = true
    parallel_analysis.has_rc = true
    conc = AST::ConcurrentOp.new(token(:CONCURRENT, "CONCURRENT"), AST::EachOp.new(token(:EACH, "EACH"), []), {})

    ann.send(:validate_capture_analysis!, conc, parallel_analysis, true, false)

    expect(direct_errors(ann).map { |err| err[1] }).to include(:LOCAL_VAR_NOT_IN_PARALLEL, :MULTIOWNED_NOT_IN_PARALLEL)
  end

  it "keeps capture analysis facts typed and mergeable" do
    parent = CapabilityHelper::CaptureAnalysis.new(
      captures: { "outer" => Type.new(:String) },
      capture_symbols: {
        "outer" => SymbolEntry.new(reg: "outer", type: Type.new(:String), mutable: false, storage: :stack)
      },
      site_copied: Set["outer"],
      strategies: {
        "blocked" => CaptureStrategy::Refuse.new(reason: :heap_backed_without_transfer, owner_name: "blocked")
      }
    )
    nested = CapabilityHelper::CaptureAnalysis.new(
      captures: { "inner" => Type.new(:Int64) },
      capture_symbols: {
        "inner" => SymbolEntry.new(reg: "inner", type: Type.new(:Int64), mutable: false, storage: :stack)
      },
      close_plans: { "inner" => Schemas::ResourceClosePlan.method("deinit") },
      pointer_captures: Set["inner"],
      string_captures: Set["outer"],
      resource_captures: Set["inner"],
      site_moved: Set["inner"],
      move_mark_names: Set["inner"],
      alloc_mark_entries: { "inner" => :heap }
    )

    parent.merge_nested!(nested)

    site_info = CaptureStrategy::CaptureSiteInfo.new(
      copied_names: parent.site_copied,
      moved_names: parent.site_moved
    )

    expect((parent.capture_symbols.keys + parent.captures.keys).uniq.sort).to eq(%w[inner outer])
    expect(site_info.copied_names).to include("outer")
    expect(site_info.moved_names).to include("inner")
    expect(parent.strategies.select { |_name, strategy| strategy.is_a?(CaptureStrategy::Refuse) }.keys).to eq(["blocked"])
    expect(parent.close_plans["inner"]&.actions&.map(&:name)).to eq(["deinit"])
    expect(parent.pointer_captures).to include("inner")
    expect(parent.string_captures).to include("outer")
    expect(parent.resource_captures).to include("inner")
    expect(parent.move_mark_names).to include("inner")
    expect(parent.alloc_mark_entries["inner"]).to eq(:heap)
  end

  it "classifies captures from live storage instead of stale rodata snapshots" do
    literal_snapshot = Type.new(:"Byte[49]", location: :rodata)
    promoted_symbol = SymbolEntry.new(
      reg: "filepath",
      type: Type.new(:"Byte[49]"),
      mutable: false,
      storage: :heap
    )
    analysis = CapabilityHelper::CaptureAnalysis.new(
      captures: { "filepath" => literal_snapshot },
      capture_symbols: { "filepath" => promoted_symbol }
    )

    strategies = BgCaptureClassifier.classify_one!(analysis)

    expect(strategies["filepath"]).to be_a(CaptureStrategy::FreshHeapCopy)
    expect(analysis.alloc_mark_entries["filepath"]).to eq(:heap)
  end

  it "applies capture fact helpers only when their local predicate is active" do
    ann = quiet_annotator
    names = Set.new
    plans = {}
    close_plan = Schemas::ResourceClosePlan.method("drop")

    ann.send(:add_capture_name_when, names, "inactive", false)
    ann.send(:set_capture_close_plan_when, plans, "inactive", close_plan, false)
    ann.send(:add_capture_name_when, names, "active", true)
    ann.send(:set_capture_close_plan_when, plans, "active", close_plan, true)

    expect(names).to eq(Set["active"])
    expect(plans).to eq("active" => close_plan)
  end

  it "covers lock handler reachability branch matrix directly" do
    ann = quiet_annotator

    self_loop_node = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(capability: :EXCLUSIVE, var_node: AST::Identifier.new(token, "looped"))
    ], [])
    attach_capability_plan!(self_loop_node)
    self_loop_node.lock_error_clause = AST::ErrorClause.new(
      action: AST::ErrorActionKind::Raise,
      retries: nil,
      token: nil,
      selectors: [
        AST::ErrorSelector.new(form: :type, name: :Deadlock, token: token(:TYPE_ID, "Deadlock")),
      ],
    )
    ann.instance_variable_set(:@lock_direct_edges, {
      "self_loop" => [
        LockHelper::LockEdge.new(
          held: :Counter,
          acquired: :Counter,
          site_token: token,
          fn_name: "self_loop",
          opted_out: false
        )
      ]
    })
    ann.instance_variable_set(:@lock_clause_sites, [
      LockHelper::LockClauseSite.new(node: self_loop_node, cap_types: [:Counter])
    ])
    ann.send(:check_lock_handler_reachability!)
    expect(direct_errors(ann)).to be_empty

    lock_node = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(capability: :EXCLUSIVE, var_node: AST::Identifier.new(token, "lock")),
      AST::Capability.new(capability: :RESTRICT, var_node: AST::Identifier.new(token, "guarded"), guard_expr: AST::Literal.new(token(:TRUE, "TRUE"), :BOOL, true, :stack)),
    ], [])
    attach_capability_plan!(lock_node)
    lock_node.lock_error_clause = AST::ErrorClause.new(
      action: AST::ErrorActionKind::Raise,
      retries: nil,
      token: nil,
      selectors: [
        AST::ErrorSelector.new(form: :type, name: :LockTimeout, token: token(:TYPE_ID, "LockTimeout")),
        AST::ErrorSelector.new(form: :type, name: :LockCycle, token: token(:TYPE_ID, "LockCycle")),
        AST::ErrorSelector.new(form: :type, name: :Deadlock, token: token(:TYPE_ID, "Deadlock")),
        AST::ErrorSelector.new(form: :type, name: :GuardFail, token: token(:TYPE_ID, "GuardFail")),
        AST::ErrorSelector.new(form: :kind, name: :System, token: token(:TYPE_ID, "System")),
        AST::ErrorSelector.new(form: :message, name: :Ignored, token: token(:STRING, "\"ignored\"")),
      ],
    )
    ann.send(:verify_handler_reachability!,
      LockHelper::LockClauseSite.new(node: lock_node, cap_types: [:Counter]),
      Set[:Counter],
      Set[:Counter])

    atomic_sym = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :heap, sync: :atomic, layout: :indirect)
    atomic_var = AST::Identifier.new(token, "cell")
    atomic_var.symbol = atomic_sym
    atomic_node = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(capability: :SNAPSHOT, var_node: atomic_var)
    ], [])
    attach_capability_plan!(atomic_node)
    atomic_node.snapshot_mode = :transaction
    atomic_node.lock_error_clause = AST::ErrorClause.new(
      action: AST::ErrorActionKind::Raise,
      retries: nil,
      token: nil,
      selectors: [
        AST::ErrorSelector.new(form: :type, name: :AtomicConflict, token: token(:TYPE_ID, "AtomicConflict")),
        AST::ErrorSelector.new(form: :type, name: :MvccConflict, token: token(:TYPE_ID, "MvccConflict")),
      ],
    )
    ann.send(:verify_handler_reachability!,
      LockHelper::LockClauseSite.new(node: atomic_node, cap_types: []),
      Set.new,
      Set.new)

    versioned_node = AST::WithBlock.new(token(:WITH, "WITH"), [
      AST::Capability.new(capability: :SNAPSHOT, var_node: AST::Identifier.new(token, "versioned"))
    ], [])
    attach_capability_plan!(versioned_node)
    versioned_node.snapshot_mode = :transaction
    versioned_node.lock_error_clause = AST::ErrorClause.new(
      action: AST::ErrorActionKind::Raise,
      retries: nil,
      token: nil,
      selectors: [
        AST::ErrorSelector.new(form: :type, name: :MvccConflict, token: token(:TYPE_ID, "MvccConflict")),
        AST::ErrorSelector.new(form: :type, name: :AtomicConflict, token: token(:TYPE_ID, "AtomicConflict")),
      ],
    )
    ann.send(:verify_handler_reachability!,
      LockHelper::LockClauseSite.new(node: versioned_node, cap_types: []),
      Set.new,
      Set.new)

    expect(direct_errors(ann).map { |e| e[1] }.count(:SELECTOR_NOT_POSSIBLE)).to be >= 3
  end

  it "covers stack tier escalation and propagation branch matrix directly" do
    ann = quiet_annotator
    mk = lambda do |name|
      fn = function_from("FN #{name}() RETURNS Void -> RETURN; END", name)
      fn.effects = Set.new
      fn.stack_vars_bytes = 0
      fn
    end

    micro = mk.call("micro")
    standard = mk.call("standard")
    standard.effects = Set[EffectTracker::HEAP]
    large = mk.call("large")
    large.stack_vars_bytes = EffectTracker::STACK_TIER_BUDGET[:standard]
    xl = mk.call("xl")
    xl.stack_vars_bytes = EffectTracker::STACK_TIER_BUDGET[:large]
    unbounded = mk.call("unbounded")
    unbounded.reentrance_kind = :reentrant
    bounded = mk.call("bounded")
    bounded.reentrance_kind = :reentrant_max_depth
    bounded.max_depth_n = 3
    bounded.stack_vars_bytes = 2_000
    mutual = mk.call("mutual")
    mutual.reentrance_kind = :reentrant_max_depth
    mutual.max_depth_n = 3
    caller = mk.call("caller")
    missing_caller = mk.call("missing_caller")

    ann.semantic_function_nodes.replace({
      "micro" => micro,
      "standard" => standard,
      "large" => large,
      "xl" => xl,
      "unbounded" => unbounded,
      "bounded" => bounded,
      "mutual" => mutual,
      "caller" => caller,
      "missing_caller" => missing_caller,
    })
    record_body_summaries(ann, {
      "micro" => Set.new,
      "standard" => Set.new,
      "large" => Set.new,
      "xl" => Set.new,
      "unbounded" => Set.new,
      "bounded" => Set.new,
      "mutual" => Set["mutual_partner"],
      "mutual_partner" => Set["mutual"],
      "caller" => Set["unbounded"],
      "missing_caller" => Set["missing"],
    })

    ann.send(:compute_stack_tiers!)

    expect(micro.stack_tier).to eq(:micro)
    expect(standard.stack_tier).to eq(:standard)
    expect(large.stack_tier).to eq(:large)
    expect(xl.stack_tier).to eq(:xl)
    expect(unbounded.stack_tier).to eq(:unbounded)
    expect(bounded.stack_vars_bytes).to eq(6_000)
    expect(mutual.stack_tier).to eq(:unbounded)
    expect(caller.stack_tier).to eq(:unbounded)
    expect(missing_caller.stack_tier).to eq(:micro)
  end

  it "returns after reporting a quiet mutual MAX_DEPTH stack-size violation" do
    ann = quiet_annotator
    caller = function_def("caller")
    a = function_def("a")
    b = function_def("b")
    a.reentrance_kind = :reentrant_max_depth
    b.reentrance_kind = :reentrant_max_depth
    a.stack_tier = :unbounded
    b.stack_tier = :unbounded
    ann.semantic_function_nodes.replace({ "caller" => caller, "a" => a, "b" => b })
    record_body_summaries(ann, {
      "caller" => Set["a"],
      "a" => Set["b"],
      "b" => Set["a"],
    })

    ann.send(:validate_fiber_stack!, AST::BgBlock.new(token(:BG, "BG"), [], nil), Set["a"], :micro, false)

    expect(direct_errors(ann).map { |err| err[1] }).to include(:STACK_SAFETY_MUTUAL_RECURSION)
  end

  it "walks transitive calls while finding mutual MAX_DEPTH callees" do
    ann = quiet_annotator
    caller = function_def("caller")
    wrapper = function_def("wrapper")
    a = function_def("a")
    b = function_def("b")
    a.reentrance_kind = :reentrant_max_depth
    b.reentrance_kind = :reentrant_max_depth
    ann.semantic_function_nodes.replace({ "caller" => caller, "wrapper" => wrapper, "a" => a, "b" => b })
    record_body_summaries(ann, {
      "caller" => Set["wrapper"],
      "wrapper" => Set["a"],
      "a" => Set["b"],
      "b" => Set["a"],
    })

    expect(ann.send(:find_mutual_max_depth_callee, Set["caller"])).to eq("a")
  end

  it "returns typed BG spawn decisions for opaque and unsafe call graphs" do
    ann = quiet_annotator
    reentrant = function_def("reentrant_callee")
    reentrant.effects = Set[EffectTracker::REENTRANT]
    native = function_def("native_callee")
    native.effects = Set[EffectTracker::EXTERN]
    ann.semantic_function_nodes.replace({
      "reentrant_callee" => reentrant,
      "native_callee" => native,
    })

    fnptr_decision = ann.send(:bg_spawn_form_for, Set.new, true)
    reentrant_decision = ann.send(:bg_spawn_form_for, Set["reentrant_callee"], false)
    extern_decision = ann.send(:bg_spawn_form_for, Set["native_callee"], false)
    fsm_decision = ann.send(:bg_spawn_form_for, Set.new, false)

    expect(fnptr_decision).to be_a(Annotator::Phases::BgSpawnDecision)
    expect(fnptr_decision.spawn_form).to eq(:stackful)
    expect(fnptr_decision.reason).to eq(:fn_pointer)
    expect(reentrant_decision.reason).to eq(:reentrant)
    expect(extern_decision.reason).to eq(:extern)
    expect(fsm_decision.spawn_form).to eq(:fsm)
    expect(fsm_decision.reason).to be_nil
  end

  it "finalizes BG, BG STREAM, and DO execution shapes in one async pass" do
    ann = quiet_annotator
    bg = AST::BgBlock.new(token(:BG, "BG"), [], [], nil, false, false, nil, false)
    stream = AST::BgStreamBlock.new(token(:BG_STREAM, "BG STREAM"), [], [], nil)
    branch = AST::DoBranch.new(body: [], stack_size: nil, can_smash: false)
    do_block = AST::DoBlock.new(token(:DO, "DO"), [branch])
    program = AST::Program.new(token(:PROGRAM, "PROGRAM"), [bg, stream, do_block])

    ann.send(:record_async_body_fact!, bg, empty_body_summary, bg)
    ann.send(:record_async_body_fact!, stream, empty_body_summary, stream)
    ann.send(:record_async_body_fact!, branch, empty_body_summary, do_block)
    ann.send(:finalize_async_execution_shapes!, program)

    expect(bg.spawn_form).to eq(:fsm)
    expect(bg.computed_stack_tier).to eq(:micro)
    expect(stream.spawn_form).to eq(:fsm)
    expect(stream.computed_stack_tier).to eq(:micro)
    expect(branch.computed_stack_tier).to eq(:micro)
  end

  it "reports extern and reentrant method calls inside TIGHT loops" do
    ann = quiet_annotator
    dangerous = function_def("danger")
    dangerous.reentrance_kind = :reentrant
    fn_nodes = { "danger" => dangerous }
    loop = AST::WhileLoop.new(
      token(:WHILE, "WHILE"),
      AST::Literal.new(token(:TRUE, "TRUE"), :BOOL, true, :stack),
      [],
      nil
    )
    method = AST::MethodCall.new(token, AST::Identifier.new(token, "obj"), "danger", [])
    method.extern_call = true

    ann.send(:validate_tight_node!, method, loop, fn_nodes)

    expect(direct_errors(ann).map { |err| err[1] }).to include(:TIGHT_CALLS_EXTERN_FN, :TIGHT_CALLS_REENTRANT_FN)
  end

  it "covers with-block arm effect and snapshot violation branches directly" do
    ann = quiet_annotator
    fn_ctx = FunctionContext.new(name: "with_fn", return_type: Type.new(:Void), lifetime: [], type_params: [])
    ann.send(:push_function_context!, fn_ctx)
    ann.send(:effect_direct_effects).replace({ "with_fn" => Set.new })

    fact_builder = method(:with_capability_fact)
    ann.define_singleton_method(:acquire_capability!) { |_node, cap, expanded| expanded.add(fact_builder.call(cap)) }
    ann.define_singleton_method(:check_nested_lock_reacquire!) { |_node, _caps| nil }
    ann.define_singleton_method(:check_lock_rank_ordering!) { |_node, _caps| nil }
    ann.define_singleton_method(:record_with_acquire!) { |_fn, _cap, _held, _escape| nil }
    ann.define_singleton_method(:cap_var_name) { |node| node.respond_to?(:name) ? node.name : "cap" }
    ann.define_singleton_method(:lock_identity_of) { |_cap| :Counter }
    ann.define_singleton_method(:with_new_scope) { |_scope, &blk| blk.call }
    ann.define_singleton_method(:current_scope) { nil }
    ann.define_singleton_method(:declare_capability_scope!) { |_cap| nil }
    ann.define_singleton_method(:validate_and_visit_with_guards!) { |_node| nil }
    ann.define_singleton_method(:validate_with_guard_no_body_mutation!) { |_node| nil }
    ann.define_singleton_method(:retryable_with_fallible_sources) { |_body| [] }
    ann.define_singleton_method(:retryable_with_universal_poly_candidate?) { |_node| false }
    ann.define_singleton_method(:finalize_scope) { |_node| nil }
    ann.define_singleton_method(:validate_no_multi_object_atomic!) { |_node| nil }
    ann.define_singleton_method(:validate_lock_error_clause!) { |_node, _caps| nil }
    heap_arm = AST::PassStmt.new(token(:KEYWORD, "PASS"))
    ann.define_singleton_method(:visit_stmts) do |body|
      record_effect(EffectTracker::HEAP) if body.include?(heap_arm)
      record_snapshot_txn_violation!(EffectTracker::BLOCKING, "with_fn") if body.include?(:snapshot_violation)
    end

    cap_var = AST::Identifier.new(token, "locked")
    cap = AST::Capability.new(capability: :EXCLUSIVE, var_node: cap_var)
    node = AST::WithBlock.new(token(:WITH, "WITH"), [cap], [:snapshot_violation])
    node.snapshot_mode = :transaction
    node.arms = [
      AST::WithMatchArm.new(family: :LOCKED, body: [heap_arm]),
      AST::WithMatchArm.new(family: :VERSIONED),
      AST::WithMatchArm.new(family: :ATOMIC),
      AST::WithMatchArm.new(family: :OTHER),
    ]

    ann.send(:visit_WithBlock, node)

    effects = ann.send(:effect_direct_effects)["with_fn"]
    expect(effects).to include(EffectTracker::CONTENTION_MAYBE)
    expect(effects).to include(EffectTracker::BLOCKING_MAYBE, EffectTracker::HEAP)
    expect(direct_errors(ann).map { |e| e[1] }).to include(:WITH_SNAPSHOT_BODY_NOT_PURE)
  end

  it "covers auto method-call shape collection branches directly" do
    decl = AST::VarDecl.new(token(:VAR_ID, "xs"), "xs", auto_type, nil, false)
    list_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: decl, sources: [], shape: :list)
    key_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: decl, sources: [], shape: :map_key)
    val_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: decl, sources: [], shape: :map_value)
    slots = AutoShapeSlots.new(list: list_slot, key: key_slot, value: val_slot)
    name_map = { "xs" => slots }

    elem = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    key = AST::Literal.new(token(:STRING, "\"k\""), :STRING, "k", :rodata)
    val = AST::Literal.new(token(:NUMBER, "2_i64"), :INT64, 2, :stack)
    target = AST::Identifier.new(token, "xs")
    collector = ShapeEvidenceCollector.new({}, {})

    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), target, "append", [elem]), name_map)
    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), target, "insert", [key, val]), name_map)
    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), target, "put", [key, val]), name_map)
    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), target, "ignored", [elem]), name_map)
    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), AST::GetField.new(token, target, "field"), "append", [elem]), name_map)
    collector.send(:record_method_call, AST::MethodCall.new(token(:DOT, "."), AST::Identifier.new(token, "missing"), "append", [elem]), name_map)

    expect(list_slot.sources).to eq([elem])
    expect(key_slot.sources).to eq([key, key])
    expect(val_slot.sources).to eq([val, val])
  end

  it "covers capability variable label shapes directly" do
    ann = quiet_annotator
	    root = AST::Identifier.new(token, "root")
	    field = AST::GetField.new(token, root, "field")
	    index = AST::GetIndex.new(token, root, AST::Literal.new(token(:NUMBER, "0_i64"), :INT64, 0, :stack))

	    expect(ann.send(:cap_var_label, root)).to eq("root")
	    expect(ann.send(:cap_var_label, field)).to eq("field")
	    expect(ann.send(:cap_var_label, index)).to eq("root")
    expect(ann.send(:cap_var_label, AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack))).to eq("__unknown")
  end

  it "covers collection method diagnostic recovery returns directly" do
    ann = quiet_annotator
    pool_type = Type.new(:"User[100]", collection: :pool)

    unknown_receiver = AST::Identifier.new(token, "pool")
    unknown_receiver.full_type = pool_type
    unknown_call = AST::MethodCall.new(token(:DOT, "."), unknown_receiver, "frobnicate", [])
    expect(ann.send(:resolve_collection_method, unknown_call)).to eq(true)

    arity_receiver = AST::Identifier.new(token, "pool")
    arity_receiver.full_type = pool_type
    arity_call = AST::MethodCall.new(token(:DOT, "."), arity_receiver, "insert", [])
    expect(ann.send(:resolve_collection_method, arity_call)).to eq(true)

    codes = direct_errors(ann).map { |err| err[1] }
    expect(codes).to include(:TYPO_SUGGESTION_REJECTED, :STDLIB_METHOD_ARITY)
  end

  it "covers pipe analysis recovery and stream branch matrix directly" do
    ann = quiet_annotator
    ann.define_singleton_method(:visit) { |_node| nil }

    invalid_rhs = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    invalid_rhs.full_type = Type.new(:Int64)
    bad_pipe = AST::BinaryOp.new(token(:PIPE, "|>"), typed_identifier("n", Type.new(:Int64)), :SMOOTH, invalid_rhs)
    ann.send(:visit_Smooth, bad_pipe)

    future_scalar = AST::Literal.new(token(:IDENTIFIER, "future"), :IDENTIFIER, "future", :stack)
    future_scalar.full_type = Type.new(:"~Int64")
    collect_pipe = AST::BinaryOp.new(token(:PIPE, "|>"), future_scalar, :SMOOTH, AST::CollectOp.new(token(:COLLECT, "COLLECT")))
    ann.send(:analyze_collect_op, collect_pipe)

    take_predicate = typed_identifier("ok", Type.new(:Bool))
    take_pipe = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      typed_identifier("inf_stream", Type.new(:"~Int64[INF]")),
      :SMOOTH,
      AST::TakeWhileOp.new(token(:TAKE_WHILE, "TAKE_WHILE"), take_predicate)
    )
    ann.send(:analyze_take_while_op, take_pipe)

    size = AST::Literal.new(token(:NUMBER, "3_i64"), :INT64, 3, :stack)
    size.full_type = Type.new(:Int64)
    window_expr = typed_identifier("window_value", Type.new(:String))
    bounded_batch = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      typed_identifier("bounded_stream", Type.new(:"~Int64[4]")),
      :SMOOTH,
      AST::BatchWindowOp.new(token(:WINDOW, "WINDOW"), { "size" => size }, window_expr)
    )
    ann.send(:analyze_batch_window_op, bounded_batch)

    bad_batch = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      typed_identifier("not_a_window_source", Type.new(:Bool)),
      :SMOOTH,
      AST::BatchWindowOp.new(token(:WINDOW, "WINDOW"), { "size" => size }, typed_identifier("fallback_window", Type.new(:Bool)))
    )
    ann.send(:analyze_batch_window_op, bad_batch)

    join_pipe = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      typed_identifier("left_items", Type.new(:"User[]")),
      :SMOOTH,
      AST::JoinOp.new(
        token(:JOIN, "JOIN"),
        typed_identifier("right_items", Type.new(:"Order[]")),
        typed_identifier("shared_key", Type.new(:String))
      )
    )
    ann.send(:analyze_join_op, join_pipe)

    recover_default = AST::Literal.new(token(:NUMBER, "0_i64"), :INT64, 0, :stack)
    recover_default.full_type = Type.new(:Int64)
    recover_pipe = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      typed_identifier("fallible_value", Type.new(:"!Int64")),
      :SMOOTH,
      AST::RecoverOp.new(token(:RECOVER, "RECOVER"), recover_default)
    )
    ann.send(:analyze_recover_op, recover_pipe)

    distinct_source = AST::Literal.new(token(:IDENTIFIER, "stream"), :IDENTIFIER, "stream", :stack)
    distinct_source.full_type = Type.new(:"~Int64[INF]")
    distinct_pipe = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      distinct_source,
      :SMOOTH,
      AST::DistinctOp.new(token(:DISTINCT, "DISTINCT"), typed_identifier("key", Type.new(:String)))
    )
    ann.send(:analyze_distinct_op, distinct_pipe)

    each_pipe = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      typed_identifier("plain_value", Type.new(:Bool)),
      :SMOOTH,
      AST::EachOp.new(token(:EACH, "EACH"), [])
    )
    ann.send(:analyze_each_op, each_pipe)

    tap_pipe = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      typed_identifier("plain_tap", Type.new(:Bool)),
      :SMOOTH,
      AST::TapOp.new(token(:TAP, "TAP"), [])
    )
    ann.send(:analyze_tap_op, tap_pipe)

    notes = []
    ann.define_singleton_method(:note!) { |_node, message| notes << message }
    shard_scope = Scope.new
    shard_scope.install_entry("first", symbol_entry(type: Type.new(:"HashMap<Int64>", shard_count: 4)))
    shard_scope.install_entry("second", symbol_entry(type: Type.new(:"HashMap<Int64>", shard_count: 8)))
    ann.define_singleton_method(:lookup_scope_for) { |_name| shard_scope }
    ann.send(:emit_multi_map_warning,
      AST::ConcurrentOp.new(token(:CONCURRENT, "CONCURRENT"), AST::EachOp.new(token(:EACH, "EACH"), []), {}),
      Set["first", "second"])

    numeric_map_type = Type.new(:"HashMap<Int64, String>", shard_count: 4)
    numeric_map_symbol = symbol_entry(type: numeric_map_type)
    shard_target = typed_identifier("numeric_map", numeric_map_type, symbol: numeric_map_symbol)
    shard_pipe = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      typed_identifier("items", Type.new(:"Int64[]")),
      :SMOOTH,
      AST::ShardOp.new(token(:SHARD, "SHARD"), typed_identifier("string_key", Type.new(:String)), shard_target)
    )
    ann.send(:analyze_shard_op, shard_pipe)

    where_op = AST::WhereOp.new(token(:WHERE, "WHERE"), typed_identifier("not_bool", Type.new(:Int64)))
    concurrent_where = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      typed_identifier("stream_items", Type.new(:"Int64[]")),
      :SMOOTH,
      AST::ConcurrentOp.new(token(:CONCURRENT, "CONCURRENT"), where_op, {})
    )
    ann.send(:validate_concurrent_where_expression!, concurrent_where)

    bad_concurrent = AST::BinaryOp.new(
      token(:PIPE, "|>"),
      typed_identifier("stream_items", Type.new(:"Int64[]")),
      :SMOOTH,
      AST::ConcurrentOp.new(token(:CONCURRENT, "CONCURRENT"), AST::EachOp.new(token(:EACH, "EACH"), []), {})
    )
    expect {
      ann.send(:concurrent_select_family_result_type, bad_concurrent, :Int64)
    }.to raise_error(RuntimeError, /expected CONCURRENT SELECT\/WHERE/)

    expect(take_pipe.full_type!.inf_stream?).to be(true)
    expect(recover_pipe.full_type!.resolved).to eq(:Int64)
    expect(distinct_pipe.full_type!.set_collection?).to be(true)
    expect(notes.last).to include("different shard counts")

    codes = direct_errors(ann).map { |err| err[1] }
    expect(codes).to include(:PIPE_BAD_DESTINATION, :COLLECT_NEEDS_OBSERVABLE,
      :WINDOW_NEEDS_COLLECTION_INPUT, :EACH_NEEDS_COLLECTION, :TAP_NEEDS_COLLECTION,
      :SHARD_KEY_NEEDS_NUMERIC, :WHERE_NEEDS_BOOL)
  end

  it "covers test annotation assert and strict IO traversal branches directly" do
    ann = quiet_annotator
    visited = []
    ann.define_singleton_method(:visit) { |node| visited << node }

    assert_expr = AST::FuncCall.new(token(:VAR_ID, "fallible"), "fallible", [])
    assert_node = AST::AssertRaises.new(token(:ASSERT_RAISES, "ASSERT_RAISES"), :Input, "ExpectedError", assert_expr)
    ann.send(:visit_AssertRaises, assert_node)

    expect(visited).to eq([assert_expr])
    expect(assert_node.full_type!.resolved).to eq(:Void)

    entry = function_def("entry")
    blocking = function_def("blocking_fn")
    blocking.effects = Set[:BLOCKING]
    ann.semantic_function_nodes.replace({ "entry" => entry, "blocking_fn" => blocking })
    record_body_summaries(ann, {
      "entry" => Set["readFile", "blocking_fn"],
      "blocking_fn" => Set.new,
    })

    test = AST::TestThat.new(token(:TEST, "TEST"), "strict io", [
      AST::FuncCall.new(token(:VAR_ID, "entry"), "entry", [])
    ])
    ann.send(:validate_strict_io!, test, Set.new, body_fact_summary(ann, test.body))

    codes = direct_errors(ann).map { |err| err[1] }
    expect(codes).to include(:STRICT_TEST_NEEDS_STUB, :STRICT_TEST_HAS_IO_EFFECTS)
  end

  it "covers WITH MATCH validation error and warning branches directly" do
    errors = []
    param = AST::Param.new(name: "c", type: Type.new(:Counter), default: nil, mutable: true, takes: false)
    cap = AST::Capability.new(capability: :EXCLUSIVE, var_node: AST::Identifier.new(token(:IDENTIFIER, "c"), "c"))
    with_node = AST::WithBlock.new(token(:WITH, "WITH"), [cap], [])
    with_node.arms = []
    attach_capability_plan!(with_node)
    fn = function_def("needs_requires", params: [param])
    fn.body = [with_node]

    WithMatchCheck.check_function!(fn, [with_node], ->(_node, message) { errors << message })

    expect(errors.join).to include("not constrained by REQUIRES")

    borrowed_param = AST::Param.new(name: "data", type: Type.new(:"Int64[]"), default: nil, mutable: false, takes: false)
    borrowed_id = AST::Identifier.new(token(:IDENTIFIER, "data"), "data")
    borrowed_id.symbol = SymbolEntry.new(reg: nil, type: Type.new(:"Int64[]"), mutable: false, storage: :stack)
    borrowed_cap = AST::Capability.new(capability: :BORROWED, var_node: borrowed_id)
    borrowed_with = AST::WithBlock.new(token(:WITH, "WITH"), [borrowed_cap], [])
    attach_capability_plan!(borrowed_with)
    borrowed_fn = function_def("borrow_only", params: [borrowed_param])
    borrowed_errors = []

    WithMatchCheck.check_function!(
      borrowed_fn,
      [borrowed_with],
      ->(_node, message) { borrowed_errors << message },
      warn_handler: ->(_node, message) { borrowed_errors << message },
      policy_handlers: []
    )

    expect(borrowed_errors).to be_empty
    expect(borrowed_fn.requires).to be_nil

    sig = FunctionSignature.new(params: [param], return_type: Type.new(:Void), requires: { "c" => Set[:LOCKED] })
    call_arg = AST::Identifier.new(token(:IDENTIFIER, "plain"), "plain")
    call = AST::FuncCall.new(token(:VAR_ID, "bump"), "bump", [call_arg])
    caller = function_def("caller")
    caller.body = [call]
    call_errors = []

    WithMatchCheck.check_call_sites!([call_site_fact(call)], ->(_name) { sig }, ->(_node, message) { call_errors << message })

    expect(call_errors.join).to include("belongs to no family")

    no_requires = FunctionSignature.new(params: [param], return_type: Type.new(:Void))
    plain_sym = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :stack)
    plain_arg = AST::Identifier.new(token(:IDENTIFIER, "plain_mut"), "plain_mut")
    plain_arg.symbol = plain_sym
    universal_sig = FunctionSignature.new(params: [param], return_type: Type.new(:Void), requires: { "c" => Set.new })
    WithMatchCheck.check_call_sites!(
      [
        call_site_fact(AST::FuncCall.new(token(:VAR_ID, "none"), "none", [plain_arg]), id: 1),
        call_site_fact(AST::FuncCall.new(token(:VAR_ID, "poly"), "poly", [plain_arg]), id: 2)
      ],
      ->(name) { name == "poly" ? universal_sig : no_requires },
      ->(_node, message) { call_errors << message }
    )

    expect(plain_sym.poly_borrow_target).to be(true)

    warnings = []
    poly_node = AST::WithBlock.new(token(:WITH, "WITH"), [cap], [])
    poly_node.polymorphic = true
    attach_capability_plan!(poly_node)
    WithMatchCheck.warn_polymorphic_unhandled_errors!(
      poly_node,
      Set["c"],
      { "c" => Set[:LOCKED] },
      [],
      ->(_node, message) { warnings << message }
    )

    expect(warnings.join).to include("Polymorphic error `LockTimeout`")
  end

  it "covers fallible return enforcement branches directly" do
    ann = quiet_annotator
    good = function_from("FN good() RETURNS !Int64 -> RETURN 1_i64; END", "good")
    good.error_fallible = true
    good.explicit_return_type = true

    caught = function_from("FN caught() RETURNS Int64 -> RETURN 1_i64; CATCH Input RETURN 0_i64; END", "caught")
    caught.error_fallible = true
    caught.explicit_return_type = true
    caught.catch_clauses = [AST::CatchClause.new]

    no_ret = function_from("FN no_ret() RETURNS Int64 -> RETURN 1_i64; END", "no_ret")
    no_ret.error_fallible = true
    no_ret.explicit_return_type = true
    no_ret.return_type = nil

    fixable = function_from("FN fixable() RETURNS Int64 -> RETURN 1_i64; END", "fixable")
    fixable.error_fallible = true
    fixable.explicit_return_type = true
    fixable.return_type_token = token(:TYPE_ID, "Int64")
    record_body_summaries(ann, { "fixable" => Set.new }, raises: Set["fixable"])

    plain_error = function_from("FN plain_error() RETURNS Int64 -> RETURN 1_i64; END", "plain_error")
    plain_error.error_fallible = true
    plain_error.explicit_return_type = true
    plain_error.return_type_token = nil

    main = function_from("FN main() RETURNS Void -> RETURN; END", "main")
    main.error_fallible = true
    main.explicit_return_type = true

    ann.semantic_function_nodes.replace({
      "good" => good,
      "caught" => caught,
      "no_ret" => no_ret,
      "fixable" => fixable,
      "plain_error" => plain_error,
      "main" => main,
    })

    ann.send(:enforce_fallible_returns!)

    codes = direct_errors(ann).map { |e| e[1] }
    expect(codes).to include(:fixable, :FALLIBLE_RETURN_NEEDS_ERROR_UNION)
  end

  it "covers remaining helper guard and fallback branch matrix directly" do
    ann = quiet_annotator

    families = ann.send(:effect_call_site_arg_families)
    families.clear
    maybe = Set[EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE]
    families["caller"]["poly_sync"] << [Set[:ATOMIC, :VERSIONED]]
    poly_sync = ann.send(:resolve_maybe_effects, maybe, "caller", "poly_sync")
    expect(poly_sync).to include(EffectTracker::BLOCKING_MAYBE, EffectTracker::CONTENTION_MAYBE)
    families["caller"]["plain_family"] << [Set[:LOCAL]]
    plain_family = ann.send(:resolve_maybe_effects, maybe, "caller", "plain_family")
    expect(plain_family).to include(EffectTracker::BLOCKING_MAYBE)
    expect(plain_family).not_to include(EffectTracker::CONTENTION_MAYBE)
    families["caller"]["contention_only"] << [Set[:VERSIONED]]
    contention_only = ann.send(:resolve_maybe_effects, Set[EffectTracker::CONTENTION_MAYBE], "caller", "contention_only")
    expect(contention_only).to include(EffectTracker::CONTENTION)

    expect(ann.send(:sum_result_clear_type, :UInt16)).to eq(:UInt64)
    expect(ann.send(:sum_result_clear_type, :Float32)).to eq(:Float32)
    expect(ann.send(:sum_result_clear_type, :String)).to eq(:Float64)

    fn = function_from("FN auto_fn(x: Auto) RETURNS Auto -> RETURN x; END", "auto_fn")
    param_slot = AutoConstraintCollector::Slot.new(kind: :param, fn_name: nil, index: 0, decl_node: fn, sources: [])
    return_slot = AutoConstraintCollector::Slot.new(kind: :return, fn_name: nil, decl_node: fn, sources: [])
    unknown_slot = AutoConstraintCollector::Slot.new(kind: :other, decl_node: fn, sources: [])
    expect(ann.send(:slot_id_for, param_slot)).to be_nil
    expect(ann.send(:slot_id_for, return_slot)).to be_nil
    expect(ann.send(:slot_id_for, unknown_slot)).to be_nil
    expect(ann.send(:build_auto_ambiguity_message, "return of auto_fn", ["Int64", "String"], return_slot)).to include("UNION Result")

    ann.instance_variable_set(:@source_code, nil)
    expect(ann.send(:consumer_source_text, 1)).to be_nil
    ann.instance_variable_set(:@source_code, ";\n  process(GIVE msg);\n")
    expect(ann.send(:consumer_source_text, 1)).to be_nil
    expect(ann.send(:consumer_source_text, 2)).to eq("process(GIVE msg)")
    expect(ann.send(:consumer_source_text, 99)).to be_nil

    expect(ann.send(:variant_anchor_from_getfield, AST::GetField.new(token, AST::Identifier.new(nil, "Shape"), "Wrong"))).to be_nil
    expect(ann.send(:build_cast_wrap_fix, nil, :Int64)).to be_nil
    expect(ann.send(:build_cast_wrap_fix, AST::Identifier.new(nil, "x"), :Int64)).to be_nil
    expect(ann.send(:build_cast_wrap_fix, AST::PassStmt.new(token), :Int64)).to be_nil

    ann.instance_variable_set(:@source_code, "x = 999_i64;\ny: Int64 = 999_i64;\n")
    no_token = AST::Literal.new(nil, :INT64, 999, :stack)
    ann.send(:emit_int_overflow_error!, no_token, 999, :Int8, -128, 127)
    no_best = AST::Literal.new(token(:NUMBER, "999999999999999999999999_i64"), :INT64, 999999999999999999999999, :stack)
    no_best.token.line = 1
    no_best.token.column = 5
    ann.send(:emit_int_overflow_error!, no_best, 999999999999999999999999, :Int8, -128, 127)
    same_suffix = AST::Literal.new(token(:NUMBER, "999_i64"), :INT64, 999, :stack)
    same_suffix.token.line = 2
    same_suffix.token.column = 12
    ann.send(:emit_int_overflow_error!, same_suffix, 999, :Int64, -9_223_372_036_854_775_808, 9_223_372_036_854_775_807)

    atomic_type = Type.new(:Int64)
    atomic_sym = SymbolEntry.new(reg: nil, type: atomic_type, mutable: true, storage: :heap, sync: :atomic)
    expect(ann.send(:build_atomic_escape_migration_fix, SymbolEntry.new(reg: nil, type: Type.new(:Int64), mutable: true, storage: :heap), "cell")).to be_nil
    expect(ann.send(:build_atomic_escape_migration_fix, atomic_sym, "cell")).to be_nil
    ann.instance_variable_set(:@source_code, "cell: Int64 = 0_i64;\n")
    expect(ann.send(:build_atomic_escape_migration_fix, atomic_sym, "cell")).to be_nil
    no_token_decl = AST::VarDecl.new(nil, "cell", Type.new(:Int64), nil, true)
    atomic_sym.reg = no_token_decl
    expect(ann.send(:build_atomic_escape_migration_fix, atomic_sym, "cell")).to be_nil
    no_line_token = token(:VAR_ID, "cell")
    no_line_token.line = nil
    atomic_sym.reg = AST::VarDecl.new(no_line_token, "cell", Type.new(:Int64), nil, true)
    expect(ann.send(:build_atomic_escape_migration_fix, atomic_sym, "cell")).to be_nil
  end

  it "covers auto inference and fixable fallback arms directly" do
    collector = AutoConstraintCollector.new({})
    auto_fn = function_from("FN inferred(x: Auto) RETURNS Auto -> RETURN x; END", "inferred")
    auto_arg = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    collector.instance_variable_set(:@fn_nodes, { "inferred" => auto_fn })
    collector.send(:record_call_site, AST::FuncCall.new(token, "inferred", [auto_arg]))
    collector.send(:record_return, AST::ReturnNode.new(token(:RETURN, "RETURN"), auto_arg), auto_fn)
    collector.send(:record_reassignment_sources, AutoSlotId.local(AST::VarDecl.new(token, "x", auto_type, nil, true)), nil)

    nil_value_decl = AST::VarDecl.new(token(:VAR_ID, "unseen"), "unseen", auto_type, nil, true)
    collector.send(:record_local, nil_value_decl)
    slots = collector.instance_variable_get(:@slots)
    expect(slots[AutoSlotId.local(nil_value_decl)].sources).to be_empty

    list_decl = AST::VarDecl.new(token(:VAR_ID, "list"), "list", auto_type, AST::ListLit.new(token(:LBRACKET, "["), [], :stack), true)
    map_decl = AST::VarDecl.new(token(:VAR_ID, "map"), "map", auto_type, AST::HashLit.new(token(:LBRACE, "{"), [], :stack), true)
    collector.send(:register_list_shape_slot, list_decl)
    collector.send(:register_map_shape_slots, map_decl)

    key_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: map_decl, sources: [], shape: :map_key)
    val_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: map_decl, sources: [], shape: :map_value)
    list_slot = AutoConstraintCollector::Slot.new(kind: :local, decl_node: list_decl, sources: [], shape: :list_element)
    shape = ShapeEvidenceCollector.new({}, {})
    key = AST::Literal.new(token(:STRING, "\"k\""), :STRING, "k", :rodata)
    val = AST::Literal.new(token(:NUMBER, "2_i64"), :INT64, 2, :stack)
    target = AST::Identifier.new(token, "map")
    shape.send(:record_method_call, AST::MethodCall.new(token, target, "insert", [key, val]), { "map" => AutoShapeSlots.new(list: nil, key: key_slot, value: val_slot) })
    shape.send(:record_method_call, AST::MethodCall.new(token, target, "put", [key]), { "map" => AutoShapeSlots.new(list: nil, key: key_slot, value: val_slot) })
    shape.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), AST::GetIndex.new(token, target, key), val), { "map" => AutoShapeSlots.new(list: nil, key: key_slot, value: val_slot) })
    shape.send(:record_index_assign, AST::Assignment.new(token(:EQ, "="), AST::GetIndex.new(token, AST::Identifier.new(token, "list"), key), val), { "list" => AutoShapeSlots.new(list: list_slot, key: nil, value: nil) })
    expect(key_slot.sources).to include(key)
    expect(val_slot.sources).to include(val)
    expect(list_slot.sources).to include(val)

    ann = quiet_annotator
    ann.instance_variable_set(:@source_code, [
      "a: Int64 @local= 1_i64;",
      "b: Int64@local = 2_i64;",
      "c: Int64 = 3_i64",
      "d: Int64 @locked = 4_i64;"
    ].join("\n"))
    audit_record = lambda do |name, line|
      CapabilityAudit::BindingAuditRecord.new(
        fn: "main", var: name, line: line, column: 1,
        sync: :local, ownership: nil, storage: :stack, sharded: false,
        mutated: false, captured_bg: false, captured_parallel: false
      )
    end
    ann.send(:emit_local_never_shared_finding!, audit_record.call("a", 1))
    ann.send(:emit_local_never_shared_finding!, audit_record.call("b", 2))
    ann.send(:emit_local_never_shared_finding!, audit_record.call("noloc", nil))

    scope = Scope.new
    decl_c_tok = token(:VAR_ID, "c")
    decl_c_tok.line = 3
    decl_c_tok.column = 1
    decl_d_tok = token(:VAR_ID, "d")
    decl_d_tok.line = 4
    decl_d_tok.column = 1
    scope.install_entry("c", SymbolEntry.new(reg: AST::VarDecl.new(decl_c_tok, "c", Type.new(:Int64), nil, false), type: Type.new(:Int64), mutable: false, storage: :stack))
    scope.install_entry("d", SymbolEntry.new(reg: AST::VarDecl.new(decl_d_tok, "d", Type.new(:Int64), nil, false), type: Type.new(:Int64), mutable: false, storage: :stack))
    ann.define_singleton_method(:lookup_scope_for) { |_name| scope }
    expect(ann.send(:build_decl_cap_insert_fix, "c", "@locked")).to be_nil
    expect(ann.send(:build_decl_cap_insert_fix, "d", "@locked")).to be_nil
    mutable_tok = token(:MUTABLE, "MUTABLE")
    mutable_tok.line = 1
    mutable_tok.column = 1
    scope.install_entry("m", SymbolEntry.new(reg: AST::VarDecl.new(mutable_tok, "m", Type.new(:Int64), nil, true), type: Type.new(:Int64), mutable: true, storage: :stack))
    expect(ann.send(:build_declare_mutable_fix, "m", scope)).to be_nil
  end

  it "covers phase body-summary accessors directly" do
    ann = SemanticAnnotator.new(source_code: "")
    summary = Annotator::Phases::FunctionBodySummary.new(
      name: "body_fn",
      callees: Set["callee"],
      propagating_callees: Set["callee"],
      has_fnptr_call: false,
      raises_directly: true
    )

    ann.send(:record_function_body_summary!, summary)

    expect(ann.send(:function_body_summaries)).to include("body_fn" => summary)
    expect(ann.send(:function_body_summaries)).not_to have_key("missing")
  end

  it "keeps lambda-contained calls out of function call-site facts" do
    ann = SemanticAnnotator.new(source_code: "")
    outer_call = AST::FuncCall.new(token(:VAR_ID, "outer"), "outer", [])
    lambda_call = AST::FuncCall.new(token(:VAR_ID, "lambda_inner"), "lambda_inner", [])
    lambda_node = AST::LambdaLit.new(token(:LAMBDA, "%"), [], [], [lambda_call], :stack, nil)

    summary = body_fact_summary(ann) do
      ann.send(:record_body_fact_node!, outer_call)
      ann.send(:with_body_fact_nested_body) do
        ann.send(:record_body_fact_node!, lambda_call)
      end
      ann.send(:record_body_fact_node!, lambda_node)
    end

    expect(summary.callees).to include("outer", "lambda_inner")
    expect(summary.call_site_facts.map(&:node)).to eq([outer_call])
    expect(summary.call_site_facts.map(&:callee_name)).to eq(["outer"])
    expect(summary.call_site_facts.map(&:node)).to eq([outer_call])
    expect(summary.call_site_facts.map(&:args)).to eq([outer_call.args])
    expect(summary.call_site_facts.map(&:fn_var_call)).to eq([false])
    expect(summary.raises_directly).to be(false)
  end

  it "records direct failure sources in the function body summary scan" do
    ann = SemanticAnnotator.new(source_code: "")
    call = AST::FuncCall.new(token(:VAR_ID, "callee"), "callee", [])
    direct_raise = AST::Raise.new(token(:RAISE, "RAISE"), :System, nil, nil)
    bg = AST::BgBlock.new(token(:BG, "BG"), [], [], nil, false, false, nil, false)

    summary = body_fact_summary(ann, [call, direct_raise, bg])

    expect(summary.callees).to include("callee")
    expect(summary.call_site_facts.map(&:node)).to eq([call])
    expect(summary.call_site_facts.map(&:callee_name)).to eq(["callee"])
    expect(summary.call_site_facts.map(&:propagates_failure)).to eq([true])
    expect(summary.raises_directly).to be(true)
  end

  it "marks call-site facts as locally absorbed by OR_ELSE fallbacks" do
    ann = SemanticAnnotator.new(source_code: "")
    call = AST::FuncCall.new(token(:VAR_ID, "fallible"), "fallible", [])
    fallback = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    rescue_expr = AST::BinaryOp.new(token(:OR_ELSE, "OR_ELSE"), call, :OR_ELSE, fallback)

    summary = body_fact_summary(ann) do
      rhs_propagates =
        fallback.is_a?(AST::OrElseRaise) ||
        fallback.is_a?(AST::OrElseExit) ||
        fallback.is_a?(AST::ThrowNode) ||
        fallback.is_a?(AST::ReturnNode)
      ann.send(:with_body_fact_failure_absorbed, !rhs_propagates) do
        ann.send(:record_body_fact_node!, call)
      end
      ann.send(:record_body_fact_node!, rescue_expr)
    end

    expect(summary.callees).to include("fallible")
    expect(summary.propagating_callees).to be_empty
    expect(summary.call_site_facts.map(&:callee_name)).to eq(["fallible"])
    expect(summary.call_site_facts.map(&:propagates_failure)).to eq([false])
  end

  it "records binding and assignment body facts during the function body summary scan" do
    ann = SemanticAnnotator.new(source_code: "")
    value = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    decl = AST::VarDecl.new(token(:VAR, "VAR"), "created", Type.new(:Int64), value, false)
    bind = AST::BindExpr.new(token(:IDENTIFIER, "created"), "created", nil, value)
    bind.mode = :assign
    assign = AST::Assignment.new(token(:IDENTIFIER, "created"), "created", value)

    summary = body_fact_summary(ann, [decl, bind, assign])

    expect(summary.binding_nodes).to eq([decl])
    expect(summary.assignment_nodes).to eq([bind, assign])
    expect(summary.escape_nodes).to include(decl, bind, assign)
    expect(summary.local_facts.map(&:name)).to eq(["created"])
    expect(summary.local_facts.map { |fact| fact.id.value }).to all(be > 0)
    expect(summary.local_facts.map { |fact| fact.place_id.value }).to all(be > 0)
  end

  it "treats callees without effect sets as non-suspending body-scan calls" do
    ann = SemanticAnnotator.new(source_code: "")
    callee = AST::FunctionDef.new(token(:FN, "FN"), "plain", [], [], Type.new(:Void), nil, [], [], nil, :private, [], false)
    ann.send(:register_function_node!, callee)
    call = AST::FuncCall.new(token(:VAR_ID, "plain"), "plain", [])

    expect(ann.send(:func_call_suspends?, call)).to be(false)
    expect(body_fact_summary(ann, [call]).suspend_points).to eq([])
  end

  it "records WITH scope nodes without leaking nested WITH or lambda bodies into the outer scope" do
    ann = SemanticAnnotator.new(source_code: "")
    outer_call = AST::FuncCall.new(token(:VAR_ID, "outer"), "outer", [])
    inner_call = AST::FuncCall.new(token(:VAR_ID, "inner"), "inner", [])
    lambda_call = AST::FuncCall.new(token(:VAR_ID, "lambda_inner"), "lambda_inner", [])
    bg_call = AST::FuncCall.new(token(:VAR_ID, "bg_inner"), "bg_inner", [])
    concurrent_call = AST::FuncCall.new(token(:VAR_ID, "concurrent_inner"), "concurrent_inner", [])
    lambda_node = AST::LambdaLit.new(token(:LAMBDA, "%"), [], [], [lambda_call], :stack, nil)
    inner_with = AST::WithBlock.new(token(:WITH, "WITH"), [], [inner_call], nil, nil)
    bg_with = AST::WithBlock.new(token(:WITH, "WITH"), [], [bg_call], nil, nil)
    bg_node = AST::BgBlock.new(token(:BG, "BG"), [bg_with], nil, nil, false, false, nil, false)
    concurrent_with = AST::WithBlock.new(token(:WITH, "WITH"), [], [concurrent_call], nil, nil)
    concurrent_node = AST::ConcurrentOp.new(
      token(:CONCURRENT, "CONCURRENT"),
      AST::EachOp.new(token(:EACH, "EACH"), [concurrent_with]),
      {}
    )
    outer_with = AST::WithBlock.new(token(:WITH, "WITH"), [], [outer_call, lambda_node, inner_with, bg_node, concurrent_node], nil, nil)
    allow(CapabilityPlan).to receive(:require_for).and_call_original
    allow(CapabilityPlan).to receive(:require_for).with(outer_with).and_return(double(locks: []))
    allow(CapabilityPlan).to receive(:require_for).with(inner_with).and_return(double(locks: []))
    allow(CapabilityPlan).to receive(:require_for).with(bg_with).and_return(double(locks: []))
    allow(CapabilityPlan).to receive(:require_for).with(concurrent_with).and_return(double(locks: []))

    summary = body_fact_summary(ann) do
      ann.send(:record_body_fact_with_block!, outer_with)
      ann.send(:with_body_fact_scope, outer_with) do
        [outer_call, lambda_node, inner_with, bg_node, concurrent_node].each { |node| ann.send(:record_body_fact_node!, node) }
        ann.send(:with_body_fact_nested_body) do
          ann.send(:record_body_fact_node!, lambda_call)
        end
        ann.send(:record_body_fact_with_block!, inner_with)
        ann.send(:with_body_fact_scope, inner_with) do
          ann.send(:record_body_fact_node!, inner_call)
        end
        ann.send(:with_body_fact_scopes_cleared) do
          ann.send(:record_body_fact_node!, bg_with)
          ann.send(:record_body_fact_node!, bg_call)
          ann.send(:record_body_fact_node!, concurrent_with)
          ann.send(:record_body_fact_node!, concurrent_call)
        end
      end
    end

    expect(summary.with_blocks).to eq([outer_with, inner_with])
    expect(summary.with_scope_nodes.fetch(outer_with.object_id)).to include(outer_call, lambda_node, inner_with, bg_node, concurrent_node)
    expect(summary.with_scope_nodes.fetch(outer_with.object_id)).not_to include(inner_call, lambda_call, bg_call, bg_with, concurrent_call, concurrent_with)
    expect(summary.with_scope_nodes.fetch(inner_with.object_id)).to include(inner_call)
    expect(summary.callees).to include("concurrent_inner")
  end

  it "keeps lambda calls out of call-site facts while preserving lambda failure facts" do
    ann = SemanticAnnotator.new(source_code: "")
    lambda_raise = AST::Raise.new(token(:RAISE, "RAISE"), :System, nil, nil)
    lambda_call = AST::FuncCall.new(token(:VAR_ID, "lambda_inner"), "lambda_inner", [])
    lambda_node = AST::LambdaLit.new(token(:LAMBDA, "%"), [], [], [lambda_call, lambda_raise], :stack, nil)

    summary = body_fact_summary(ann) do
      ann.send(:with_body_fact_nested_body) do
        ann.send(:record_body_fact_node!, lambda_call)
        ann.send(:record_body_fact_node!, lambda_raise)
      end
      ann.send(:record_body_fact_node!, lambda_node)
    end

    expect(summary.callees).to include("lambda_inner")
    expect(summary.call_site_facts).to be_empty
    expect(summary.raises_directly).to be(true)
  end

  it "records suspension points in the function body summary scan" do
    ann = SemanticAnnotator.new(source_code: "")
    promise = AST::Identifier.new(token(:IDENTIFIER, "promise"), "promise")
    next_expr = AST::NextExpr.new(token(:NEXT, "NEXT"), promise)
    yielded = AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack)
    yield_expr = AST::YieldExpr.new(token(:YIELD, "YIELD"), yielded)

    summary = body_fact_summary(ann, [next_expr, yield_expr])

    expect(summary.suspend_points.map(&:kind)).to eq([:next, :yield])
    expect(summary.suspend_points.map { |point| point.id.value }).to eq([0, 1])
  end

  it "records an error and returns when YIELD has no BG STREAM frame" do
    ann = quiet_annotator
    yielded = AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack)
    yield_expr = AST::YieldExpr.new(token(:YIELD, "YIELD"), yielded)

    ann.send(:visit_YieldExpr, yield_expr)

    expect(direct_errors(ann).map { |entry| entry[1] }).to include(:YIELD_OUTSIDE_BG_STREAM)
  end

  it "covers deferred WITH validation replay diagnostics directly" do
    ann = quiet_annotator
    with_node = AST::WithBlock.new(token(:WITH, "WITH"), [], [])
    unknown = AST::Identifier.new(token(:IDENTIFIER, "unknown"), "unknown")
    read_lock = AST::Identifier.new(token(:IDENTIFIER, "reader"), "reader")
    read_lock.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Int64), mutable: true, storage: :heap, sync: :atomic)

    ann.send(:record_deferred_with_validation!, with_node, capability_transition(
      AST::Capability.new(capability: :EXCLUSIVE, var_node: unknown)
    ))
    ann.send(:record_deferred_with_validation!, with_node, capability_transition(
      AST::Capability.new(capability: :write_locked_read, var_node: read_lock)
    ))
    ann.send(:flush_deferred_with_validations!)

    codes = direct_errors(ann).map { |e| e[1] }
    expect(codes).to include(:WITH_EXCLUSIVE_NEEDS_LOCK_GOT, :WITH_READ_NEEDS_WRITE_LOCK_NAME)
    expect(ann.pending_deferred_validation_count).to eq(0)
  end

  it "covers expression phase dispatcher recovery branches directly" do
    ann = quiet_annotator

    native = AST::FuncCall.new(token(:VAR_ID, "native_call"), "native_call", [])
    ann.send(:visit_FuncCall, native)
    expect(native.full_type!.resolved).to eq(:Any)

    ann.send(:current_scope).declare_type(:Handle, Schemas::ResourceSchema.new(close_plan: Schemas::ResourceClosePlan.method("close")))
    missing_static = AST::StaticCall.new(
      token(:COLON2, "::"),
      AST::Identifier.new(nil, "Handle"),
      "missing",
      []
    )
    ann.send(:visit_StaticCall, missing_static)

    unknown_static = AST::StaticCall.new(
      token(:COLON2, "::"),
      AST::Identifier.new(token(:TYPE_ID, "Missing"), "Missing"),
      "open",
      []
    )
    ann.send(:visit_StaticCall, unknown_static)

    ann.send(:current_scope).declare_type(:FallibleHandle, Schemas::ResourceSchema.new(
      close_plan: Schemas::ResourceClosePlan.method("close"),
      static_methods: {
        "open" => { args: [], return: :FallibleHandle, allocates: true, can_fail: true },
        "noop" => { args: [], return: :FallibleHandle }
      }
    ))
    fallible_static = AST::StaticCall.new(
      token(:COLON2, "::"),
      AST::Identifier.new(token(:TYPE_ID, "FallibleHandle"), "FallibleHandle"),
      "open",
      []
    )
    expect(ann.send(:current_fn_ctx)).to be_nil
    ann.send(:visit_StaticCall, fallible_static)
    expect(fallible_static.stdlib_allocates).to eq(true)
    expect(fallible_static.can_fail).to eq(true)

    with_function_context(ann) do |ctx|
      contextual_static = AST::StaticCall.new(
        token(:COLON2, "::"),
        AST::Identifier.new(token(:TYPE_ID, "FallibleHandle"), "FallibleHandle"),
        "open",
        []
      )
      ann.send(:visit_StaticCall, contextual_static)
      expect(ctx.alloc_count).to eq(1)
    end

    pure_static = AST::StaticCall.new(
      token(:COLON2, "::"),
      AST::Identifier.new(token(:TYPE_ID, "FallibleHandle"), "FallibleHandle"),
      "noop",
      []
    )
    ann.send(:visit_StaticCall, pure_static)
    expect(pure_static.stdlib_allocates).to eq(false)
    expect(pure_static.can_fail).to be_falsey

    ann.send(:current_scope).declare_type(:StaticArgHandle, Schemas::ResourceSchema.new(
      close_plan: Schemas::ResourceClosePlan.method("close"),
      static_methods: {
        "take" => { args: [{ type: :Int64 }], return: :StaticArgHandle },
        "none" => { args: [], return: :StaticArgHandle }
      }
    ))
    int_arg = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    matched_static_arg = AST::StaticCall.new(
      token(:COLON2, "::"),
      AST::Identifier.new(token(:TYPE_ID, "StaticArgHandle"), "StaticArgHandle"),
      "take",
      [int_arg]
    )
    ann.send(:visit_StaticCall, matched_static_arg)
    expect(matched_static_arg.full_type!.resolved).to eq(:StaticArgHandle)

    any_arg = AST::Identifier.new(token(:IDENTIFIER, "missing_any"), "missing_any")
    any_static_arg = AST::StaticCall.new(
      token(:COLON2, "::"),
      AST::Identifier.new(token(:TYPE_ID, "StaticArgHandle"), "StaticArgHandle"),
      "take",
      [any_arg]
    )
    ann.send(:visit_StaticCall, any_static_arg)

    string_arg = AST::Literal.new(token(:STRING, "\"value\""), :STRING, "value", :rodata)
    bad_static_arg = AST::StaticCall.new(
      token(:COLON2, "::"),
      AST::Identifier.new(token(:TYPE_ID, "StaticArgHandle"), "StaticArgHandle"),
      "take",
      [string_arg]
    )
    ann.send(:visit_StaticCall, bad_static_arg)

    extra_static_arg = AST::StaticCall.new(
      token(:COLON2, "::"),
      AST::Identifier.new(token(:TYPE_ID, "StaticArgHandle"), "StaticArgHandle"),
      "none",
      [string_arg]
    )
    ann.send(:visit_StaticCall, extra_static_arg)

    pool_type = Type.new(:"String[]", collection: :pool)
    pool_value = AST::Identifier.new(token(:IDENTIFIER, "pool"), "pool")
    pool_value.full_type = pool_type
    inserted = AST::Literal.new(token(:STRING, "value"), :STRING, "value", :rodata)
    inserted.full_type = Type.new(:String)
    pool_insert = AST::MethodCall.new(token(:DOT, "."), pool_value, "insert", [inserted])
    ann.define_singleton_method(:move_if_takes_ownership!) { |_node, **_kwargs| nil }
    expect(ann.send(:resolve_typed_method, pool_insert, pool_type, POOL_METHODS, :pool_method, "Pool<String>")).to eq(true)
    expect(pool_insert.stdlib_allocates).to eq(true)

    no_overload = AST::FuncCall.new(token(:VAR_ID, "negative?"), "negative?", [])
    ann.send(:visit_IntrinsicFunc, no_overload, [])

    unsigned_arg = AST::Literal.new(token(:NUMBER, "1_u32"), :UINT32, 1, :stack)
    unsigned_arg.full_type = Type.new(:UInt32)
    rejected = AST::FuncCall.new(token(:VAR_ID, "negative?"), "negative?", [unsigned_arg])
    negative_sig = T.must(IntrinsicRegistry.lookup(STD_LIB, "negative?")).first
    ann.send(:visit_IntrinsicFunc, rejected, [unsigned_arg], matched_def: negative_sig)

    with_function_context(ann) do |ctx|
      heap_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void), extern_effects: { alloc: :heap })
      frame_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void), extern_effects: { alloc: :frame })
      ann.send(:record_extern_method_alloc!, heap_sig)
      ann.send(:record_extern_method_alloc!, frame_sig)

      expect(ctx.heap_count).to eq(1)
      expect(ctx.frame_count).to eq(1)
    end

    codes = direct_errors(ann).map { |e| e[1] }
    expect(codes).to include(:STATIC_UNKNOWN_METHOD, :STATIC_UNKNOWN_TYPE, :INTRINSIC_NO_OVERLOAD, :INTRINSIC_REJECTED)
    expect(codes).to include(:STATIC_ARITY, :STATIC_ARG_TYPE)
  end

  it "reifies WITH capabilities into typed facts before local phase consumers read them" do
    ann = quiet_annotator
    locked_type = Type.new(:Counter, sync: :locked)
    symbol = SymbolEntry.new(reg: nil, type: locked_type, mutable: true, storage: :stack, sync: :locked)
    var = typed_identifier("cell", locked_type, symbol: symbol)
    cap = AST::Capability.new(
      capability: :EXCLUSIVE,
      var_node: var,
      alias: "guard",
      alias_mutable: true,
      resolved_type: locked_type,
      old_scope: Scope.new,
    )

    fact = ann.send(:with_capability_fact, cap)

    expect(fact).to be_a(CapabilityHelper::WithCapabilityFact)
    expect(fact).to have_attributes(
      capability: :EXCLUSIVE,
      var_name: "cell",
      alias_name: "guard",
      alias_explicit: true,
      alias_mutable: true,
      sync: :locked,
      storage: :stack,
    )
    expect(fact.send(:lock_capability?)).to eq(true)
    expect(fact.lock_identity).to eq(:Counter)
  end

  it "covers whole-program schema lookup fallback directly" do
    ann = SemanticAnnotator.new(source_code: "")

    allow(EscapeAnalysis).to receive(:propagate_caller_sync!)
    allow(BgCaptureClassifier).to receive(:classify_all!) do |_fn_nodes, schema_lookup:|
      expect(schema_lookup.call(:BrokenType)).to be_nil
    end
    allow(EffectInference).to receive(:analyze!)
    allow(WithMatchCheck).to receive(:check_function!)
    allow(WithMatchCheck).to receive(:check_call_sites!)
    allow(ConcurrencyChecks).to receive(:check_all!)
    ann.define_singleton_method(:lookup_type_schema) { |_type| raise StandardError, "schema failed" }

    ann.send(:run_whole_program_semantics!)
  end

  it "covers extracted match payload and call validation edge branches directly" do
    ann = quiet_annotator
    subject = typed_identifier("shape", Type.new(:Shape))
    node = AST::MatchStatement.new(token(:KEYWORD, "MATCH"), subject, [], nil, [], nil, true, false)
    unit_case = AST::MatchCase.new(
      kind: :eq,
      value: AST::GetField.new(token(:DOT, "."), AST::Identifier.new(token(:TYPE_ID, "Shape"), "Shape"), "Done"),
      binding: "payload",
    )

    enum_plan = Annotator::Domains::ControlFlow::MatchSubjectPlan.new(
      expr_type: Type.new(:Color),
      type_name: :Color,
      schema: Schemas::EnumSchema.new(variants: [:Red]),
      enum_subject: true,
      union_subject: false,
      union_subst: {},
    )
    ann.send(:declare_match_payload_binding!, node, unit_case, enum_plan)

    union_schema = Schemas::UnionSchema.new(
      variants: {
        "Done" => nil,
        "Box" => Type.new(:Payload, layout: :indirect),
        "Named" => Type.new(:NamedPayload),
      },
    )
    union_plan = Annotator::Domains::ControlFlow::MatchSubjectPlan.new(
      expr_type: Type.new(:Shape),
      type_name: :Shape,
      schema: union_schema,
      enum_subject: false,
      union_subject: true,
      union_subst: { Payload: :PayloadImpl, NamedPayload: :NamedPayloadImpl },
    )
    ann.send(:declare_union_payload_binding!, node, unit_case, union_plan, "Done", "payload")

    indirect_case = AST::MatchCase.new(kind: :eq, value: unit_case.value, binding: "payload")
    payload_type = ann.send(:match_payload_binding_type, union_plan, "Box", T.must(union_schema.variants["Box"]), indirect_case)
    expect(payload_type.resolved).to eq(:PayloadImpl)
    expect(payload_type.indirect?).to eq(false)
    expect(indirect_case.indirect_payload_as).to eq(true)

    ann.define_singleton_method(:lookup_type_schema) do |name|
      name == :NamedPayloadImpl ? Schemas::StructSchema.new(fields: { "value" => Type.new(:Int64) }) : nil
    end
    expect(ann.send(:match_payload_struct_schema, union_plan, "Named")).to be_a(Schemas::StructSchema)

    mutable_param = AST::Param.new(name: "slot", type: Type.new(:Int64), mutable: true)
    call_site = FunctionAnalysis::CallSignatureSite.new(
      node: AST::FuncCall.new(token(:VAR_ID, "update"), "update", []),
      name: "update",
      args: [],
    )
    literal_arg = AST::Literal.new(token(:NUMBER, "1_i64"), :INT64, 1, :stack)
    literal_arg.full_type = Type.new(:Int64)
    mutable_facts = FunctionAnalysis::CallArgumentFacts.new(
      site: call_site,
      index: 0,
      param: mutable_param,
      arg_node: literal_arg,
      is_give: false,
      inner_node: literal_arg,
      arg_type: Type.new(:Int64),
      expected_type: Type.new(:Int64),
      actual_type: Type.new(:Int64),
      actual: :Int64,
      path: [],
    )
    ann.send(:verify_mutable_argument!, mutable_facts)

    ann.define_singleton_method(:receiver_container_alloc) { |_node| nil }
    ann.define_singleton_method(:ensure_owned_value!) { |_node, *_args, **_kwargs| nil }
    ann.define_singleton_method(:move_if_takes_ownership!) { |_node, **_kwargs| nil }
    moved_inner = AST::Identifier.new(token(:IDENTIFIER, "owned"), "owned")
    moved_inner.full_type = Type.new(:Int64)
    move_arg = AST::MoveNode.new(token(:KEYWORD, "GIVE"), moved_inner)
    move_arg.full_type = Type.new(:Int64)
    borrow_param = AST::Param.new(name: "borrowed", type: Type.new(:Int64), takes: false)
    give_facts = FunctionAnalysis::CallArgumentFacts.new(
      site: FunctionAnalysis::CallSignatureSite.new(node: AST::FuncCall.new(token(:VAR_ID, "borrow"), "borrow", [move_arg]), name: "borrow", args: [move_arg]),
      index: 0,
      param: borrow_param,
      arg_node: move_arg,
      is_give: true,
      inner_node: moved_inner,
      arg_type: Type.new(:Int64),
      expected_type: Type.new(:Int64),
      actual_type: Type.new(:Int64),
      actual: :Int64,
      path: [],
    )
    ann.send(:verify_takes_argument!, give_facts)

    atomic_type = Type.new(:Int64, sync: :atomic)
    atomic_arg = AST::Identifier.new(token(:IDENTIFIER, "cell"), "cell")
    atomic_arg.full_type = atomic_type
    atomic_arg.symbol = SymbolEntry.new(reg: nil, type: atomic_type, mutable: true, storage: :stack, sync: :atomic)
    atomic_param = AST::Param.new(name: "cell", type: atomic_type, sync: :atomic)
    atomic_facts = FunctionAnalysis::CallArgumentFacts.new(
      site: FunctionAnalysis::CallSignatureSite.new(node: AST::FuncCall.new(token(:VAR_ID, "load"), "load", [atomic_arg]), name: "load", args: [atomic_arg]),
      index: 0,
      param: atomic_param,
      arg_node: atomic_arg,
      is_give: false,
      inner_node: atomic_arg,
      arg_type: atomic_type,
      expected_type: atomic_type,
      actual_type: atomic_type,
      actual: :Int64,
      path: [:cell],
    )
    ann.send(:verify_atomic_argument!, atomic_facts, FunctionSignature.new(params: [atomic_param], return_type: Type.new(:Void)), [])
    expect(atomic_arg.atomic_borrow).to eq(true)

    expect(ann.send(:observable_capability_explanation, nil, :shared)).to include("heap-pointer lifetime")
    codes = direct_errors(ann).map { |e| e[1] }
    expect(codes).to include(:MATCH_ENUM_CAPTURE, :MATCH_UNIT_CAPTURE, :IMMUTABLE_ARG_PASSED_AS_EXPRESSION, :GIVE_TO_BORROW_PARAM)
  end

  it "uses the function registry in execution-boundary, capability, and tight-loop helpers" do
    ann = quiet_annotator
    param_sym = SymbolEntry.new(reg: nil, type: Type.new(:Counter), mutable: true, storage: :stack)
    param_sym.is_param = true
    bound = AST::Identifier.new(token(:IDENTIFIER, "counter"), "counter")
    bound.symbol = param_sym
    with_node = AST::WithBlock.new(
      token(:WITH, "WITH"),
      [AST::Capability.new(capability: :EXCLUSIVE, var_node: bound)],
      []
    )
    with_node.polymorphic = true
    attach_capability_plan!(with_node)
    fn = function_def("owner")
    ann.semantic_function_nodes.replace({ "owner" => fn })
    ctx = FunctionContext.new(name: "owner", return_type: Type.new(:Void))

    ann.send(:mark_unrequired_polymorphic_with_runtime!, with_node, ctx)
    expect(ann.send(:retryable_with_universal_poly_candidate?, with_node)).to eq(true)
    ann.send(:push_function_context!, ctx)
    retry_candidate = ann.send(:retryable_with_universal_poly_candidate?, with_node)
    ann.send(:pop_function_context!)

    expect(ctx.uses_rt).to eq(true)
    expect(fn.can_fail).to eq(true)
    expect(retry_candidate).to eq(true)

    impure = function_def("impure")
    impure.effects = Set[EffectTracker::BLOCKING]
    ann.semantic_function_nodes.replace({ "impure" => impure })
    call = AST::FuncCall.new(token(:VAR_ID, "impure"), "impure", [])
    expect(ann.send(:predicate_impurity_reason, call, "impure")).to include("BLOCKING")

    loop = AST::WhileLoop.new(
      token(:WHILE, "WHILE"),
      AST::Literal.new(token(:TRUE, "TRUE"), :BOOL, true, :stack),
      [],
      nil
    )
    impure.reentrance_kind = :reentrant
    ann.send(:validate_tight_body!, [call], loop)

    expect(direct_errors(ann).map { |err| err[1] }).to include(:TIGHT_CALLS_REENTRANT_FN)

    source_sym = SymbolEntry.new(reg: nil, type: Type.new(:String), mutable: false, storage: :stack)
    returned_sym = SymbolEntry.new(reg: nil, type: Type.new(:String), mutable: false, storage: :stack)
    returned_sym.instance_variable_set(:@lifetime, [source_sym])
    returned = AST::Identifier.new(token(:IDENTIFIER, "returned"), "returned")
    returned.symbol = returned_sym
    ann.send(:verify_tied_return!, AST::ReturnNode.new(token(:RETURN, "RETURN"), returned))

    expect(direct_errors(ann).map { |err| err[1] }).to include(:ATOMIC_ESCAPE_RETURN)
  end

  it "restores function context when function analysis raises" do
    ann = quiet_annotator
    fn = function_def("boom")
    ann.define_singleton_method(:analyze_routine) do |_node, _body, _declared_return, _implicit_return|
      raise "intentional"
    end

    expect {
      ann.send(:visit_FunctionDef, fn)
    }.to raise_error(RuntimeError, "intentional")

    expect(ann.send(:current_fn_ctx)).to be_nil
  end
end
