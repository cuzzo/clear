require "spec_helper"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/semantic/pass_state" unless defined?(MIRPassState::StageSpec)

RSpec.describe "annotator completion phases" do
  def tok(value = "program")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  def typed_phase(source = "")
    program = parse(source)
    resolution = Annotator::Phases::ResolutionPhase.run(
      program: program, importer: nil, source_dir: Dir.pwd, source_code: source
    )
    session = Annotator::Phases::TypeAnalysisSession.new(source_code: source)
    handoff = Annotator::Phases::TypeAnalysisPhase.run(
      resolution: resolution, session: session
    )
    [session, handoff]
  end

  def audit_session_for(handoff, source = "")
    request = handoff.audit_request
    Annotator::Phases::CapabilityAuditSession.new(
      typed_program: handoff.typed_program,
      inputs: request.inputs,
      source_code: request.source_code || source,
      language_mode: request.language_mode,
      strict_test: request.strict_test
    )
  end

  def boundary_products(program)
    registry = Annotator::FunctionRegistry.new
    program.statements.grep(AST::FunctionDef).each { |fn| registry.nodes[fn.name] = fn }
    resolution = Annotator::Phases::ResolutionFacts.new(
      program: program,
      declarations: Annotator::Phases::DeclarationIndexer.index(program),
      root_scope: Scope.new,
      function_registry: registry,
      type_names: [],
      function_names: registry.names
    )
    typed_program = Annotator::Phases::TypedProgramFacts.new(
      resolution: resolution,
      body_summaries: {},
      typed_node_count: 0,
      unresolved_node_count: 0,
      ownership_graph: OwnershipGraph.new
    )
    audit = Annotator::Phases::CapabilityAuditReport.new(
      typed_program: typed_program,
      checked_functions: registry.names,
      checked_call_sites: 0,
      checked_with_sites: 0,
      violation_count: 0
    )
    Annotator::Phases::AnnotationProducts.new(
      resolution: resolution,
      typed_program: typed_program,
      capability_audit: audit
    )
  end

  it "initializes builtin environment inside the resolution phase" do
    session = Annotator::Phases::ResolutionSession.new(
      importer: nil, source_dir: Dir.pwd, source_code: nil
    )
    scope = session.resolve!(AST::Program.new(tok, [])).root_scope

    expect(scope.resolve_entry!("argv").type.resolved).to eq(:String)
    expect(scope.types.fetch(:Range).schema).to be_a(Schemas::StructSchema)
    expect(scope.types.fetch(:File).schema).to be_a(Schemas::ResourceSchema)
    expect(scope.types.fetch(:TCPServer).schema).to be_a(Schemas::ResourceSchema)
    expect(scope.types.fetch(:TCPClient).schema).to be_a(Schemas::ResourceSchema)
  end

  it "marks an empty program annotated through the boundary phase" do
    program = AST::Program.new(tok, [])

    SemanticAnnotator.new.annotate!(program)

    expect(program.full_type!.resolved).to eq(:Void)
    expect(MIRPassState.for!(program).send(:completed_stages)).to eq([:annotated])
  end

  it "runs body analysis and program finalization for executable statements" do
    program = parse(<<~CLEAR)
      FN one() RETURNS Int64 ->
        RETURN 1;
      END

      one();
    CLEAR

    SemanticAnnotator.new.annotate!(program)

    expect(program.full_type!.resolved).to eq(:Int64)
    expect(MIRPassState.for!(program).send(:completed_stages)).to eq([:annotated])
  end

  it "publishes a frozen semantic index after annotation completes" do
    annotator = SemanticAnnotator.new
    program = parse(<<~CLEAR)
      FN main() RETURNS Int64 ->
        RETURN 1;
      END
    CLEAR

    annotator.annotate!(program)
    index = T.must(annotator.semantic_index)

    expect(index.program).to eq(program)
    expect(index.root_scope).to eq(annotator.semantic_root_scope)
    expect(index.function_node("main")).to eq(index.function_nodes.fetch("main"))
    expect(index.function_nodes.keys).to include("main")
    expect(index.id_index.definition_id_for("main")&.value).to be > 0
    expect(index.id_index.body_id_for("main")&.value).to be > 0
    expect(index.body_summaries.fetch("main").definition_id).to eq(index.id_index.definition_id_for("main"))
    expect(index.body_summaries.fetch("main").body_id).to eq(index.id_index.body_id_for("main"))
    expect(index).to be_frozen
    expect(index.annotation_products).to equal(annotator.annotation_products)
    expect(index.typed_program).to equal(annotator.annotation_products.typed_program)
    expect(index.capability_audit).to equal(annotator.annotation_products.capability_audit)
  end

  it "publishes typed local and call-site facts in function body summaries" do
    annotator = SemanticAnnotator.new
    program = parse(<<~CLEAR)
      FN callee() RETURNS Int64 ->
        RETURN 1;
      END

      FN main() RETURNS Int64 ->
        value = callee();
        RETURN value;
      END
    CLEAR

    annotator.annotate!(program)
    summary = T.must(T.must(annotator.semantic_index).body_summaries["main"])

    expect(summary.definition_id.value).to be > 0
    expect(summary.body_id.value).to be > 0
    expect(summary.local_facts.map(&:name)).to include("value")
    expect(summary.local_facts.map { |fact| fact.id.value }).to all(be > 0)
    expect(summary.local_facts.map { |fact| fact.place_id.value }).to all(be > 0)
    expect(summary.call_site_facts.map(&:callee_name)).to include("callee")
    expect(summary.call_site_facts.map(&:fn_var_call)).to eq([false])
    expect(summary.call_site_facts.map(&:propagates_failure)).to eq([true])
  end

  it "resets compilation state between reused annotator runs" do
    annotator = SemanticAnnotator.new
    first = parse(<<~CLEAR)
      FN stale() RETURNS Int64 ->
        RETURN 1;
      END
    CLEAR
    second = parse(<<~CLEAR)
      stale();
    CLEAR

    annotator.annotate!(first)

    expect {
      annotator.annotate!(second)
    }.to raise_error(CompilerError, /undefined|unknown/i)
    expect(annotator.annotation_products.resolution&.function_registry&.nodes).not_to have_key("stale")
  end

  it "appends synthesized functions during body analysis" do
    annotator = Annotator::Phases::TypeAnalysisSession.new
    program = AST::Program.new(tok, [])
    index = Annotator::Phases::DeclarationIndexer.index(program)
    resolution = Annotator::Phases::ResolutionPhase.run(
      program: program,
      importer: nil,
      source_dir: Dir.pwd,
      source_code: nil
    )
    annotator.send(:adopt_resolution_facts!, resolution)
    synthetic = AST::FunctionDef.new(
      tok("generated"),
      "generated",
      [],
      [],
      Type.new(:Void),
      nil,
      [],
      [],
      nil,
      :pub,
      [],
      false
    )
    annotator.send(:synthetic_function_definitions) << synthetic

    annotator.send(:analyze_program_bodies!, index, program)

    expect(program.statements).to eq([synthetic])
    expect(annotator.send(:semantic_function_nodes).fetch("generated")).to eq(synthetic)
  end

  it "skips non-signature function metadata while finalizing summaries" do
    _type_session, handoff = typed_phase
    annotator = audit_session_for(handoff)
    fn = AST::FunctionDef.new(tok("helper"), "helper", [], [], Type.new(:Void), nil, [], [], nil, :pub, [], false)
    fn.full_type = Type.new(:Void)
    annotator.send(:semantic_function_nodes)["helper"] = fn

    expect {
      annotator.send(:restamp_function_metadata!)
    }.not_to raise_error
  end

  it "drains deferred validations before publishing the audit report" do
    _type_session, handoff = typed_phase
    with_node = AST::WithBlock.new(tok("WITH"), [], [], [])
    var_node = AST::Identifier.new(tok("cell"), "cell")
    var_node.full_type = Type.new(:Int64)
    var_node.symbol = SymbolEntry.new(
      reg: nil, type: Type.new(:Int64), mutable: true, storage: :heap, sync: :locked
    )
    handoff.audit_request.inputs.deferred_with_validations << Annotator::Phases::DeferredWithValidation.new(
      node: with_node,
      fact: capability_transition(AST::Capability.new(capability: :EXCLUSIVE, var_node: var_node))
    )

    report = Annotator::Phases::CapabilityAuditPhase.run(
      typed_program: handoff.typed_program,
      request: handoff.audit_request
    )

    expect(report).to be_success
    expect(handoff.audit_request.inputs.deferred_with_validations).to be_empty
  end

  it "flushes deferred ATOMIC validations instead of dropping them" do
    _type_session, handoff = typed_phase
    with_node = AST::WithBlock.new(tok("WITH"), [], [], [])
    var_node = AST::Identifier.new(tok("cell"), "cell")
    var_node.full_type = Type.new(:Int64)
    var_node.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Int64), mutable: true, storage: :stack)
    var_node.symbol.is_param = true
    handoff.audit_request.inputs.deferred_with_validations << Annotator::Phases::DeferredWithValidation.new(
      node: with_node,
      fact: capability_transition(AST::Capability.new(capability: :ATOMIC, var_node: var_node))
    )
    annotator = audit_session_for(handoff)

      expect {
        annotator.send(:run_deferred_validations!)
      }.to raise_error(CompilerError, /WITH ATOMIC requires/)
  end

  it "rejects annotation completion if the program remains unstamped" do
    program = AST::Program.new(tok, [])

    expect {
      Annotator::Phases::AnnotationBoundary.verify!(program, boundary_products(program))
    }.to raise_error(RuntimeError, /unresolved type info/)
  end

  it "rejects annotation completion if a child node remains unstamped" do
    child = AST::Identifier.new(tok("x"), "x")
    program = AST::Program.new(tok, [child])
    program.full_type = Type.new(:Void)

    expect {
      Annotator::Phases::AnnotationBoundary.verify!(program, boundary_products(program))
    }.to raise_error(RuntimeError, /unresolved AST type facts/)
  end

  it "rejects annotation completion if a child node remains Auto" do
    child = AST::Identifier.new(tok("x"), "x")
    child.full_type = Type.new(:Auto, auto: true)
    program = AST::Program.new(tok, [child])
    program.full_type = Type.new(:Void)

    expect {
      Annotator::Phases::AnnotationBoundary.verify!(program, boundary_products(program))
    }.to raise_error(RuntimeError, /Identifier .* Auto/)
  end

  it "ignores lifetime metadata nodes at the annotation boundary" do
    lifetime = AST::Identifier.new(tok("n"), "n")
    fn = AST::FunctionDef.new(tok("identity"), "identity", [], [], Type.new(:Int64), [lifetime], [], [], nil, :pub, [], false)
    fn.full_type = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
    program = AST::Program.new(tok, [fn])
    program.full_type = Type.new(:Void)

    expect {
      Annotator::Phases::AnnotationBoundary.verify!(program, boundary_products(program))
    }.not_to raise_error
  end

  it "rejects annotation completion if a function lacks a signature" do
    program = AST::Program.new(tok, [])
    fn = AST::FunctionDef.new(tok("bad"), "bad", [], [], Type.new(:Void), nil, [], [], nil, :pub, [], false)
    program.statements << fn
    program.full_type = Type.new(:Void)
    fn.full_type = Type.new(:Void)

    expect {
      Annotator::Phases::AnnotationBoundary.verify!(program, boundary_products(program))
    }.to raise_error(RuntimeError, /missing function signature/)
  end
end
