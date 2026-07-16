require "spec_helper"

require_relative "../ruby/annotator/annotator" unless defined?(SemanticAnnotator::ReceiverState)

RSpec.describe "annotator receiver state boundaries" do
  def type_session(source_code: "")
    Annotator::Phases::TypeAnalysisSession.new(source_code: source_code)
  end

  def tok(type = :VAR_ID, value = "x")
    Lexer::Token.new(type, value, 1, 1)
  end

  def locked_identifier(name)
    ident = AST::Identifier.new(tok(:VAR_ID, name), name)
    ident.full_type = Type.new(:Counter, sync: :locked)
    ident.symbol = SymbolEntry.new(
      reg: nil,
      type: Type.new(:Counter),
      mutable: true,
      storage: :stack,
      sync: :locked
    )
    ident
  end

  it "keeps scope stack access typed and restores pushed scopes on exceptions" do
    ann = type_session

    expect(ann.send(:scope_stack)).to contain_exactly(ann.send(:semantic_root_scope))

    expect do
      ann.send(:with_new_scope) do
        ann.send(:current_scope).declare("local", nil, :Int64, false, false, nil, :stack)
        expect(ann.send(:outer_scope_vars)).to include("local")
        raise "force unwind"
      end
    end.to raise_error("force unwind")

    expect(ann.send(:scope_stack)).to contain_exactly(ann.send(:semantic_root_scope))
    expect(ann.send(:outer_scope_vars)).not_to include("local")
  end

  it "restores function, loop, conditional, and smooth contexts on exceptions" do
    ann = type_session
    ctx = FunctionContext.new(name: "stateful", return_type: Type.new(:Void))

    expect do
      ann.send(:push_function_context!, ctx)
      ann.send(:with_loop_context) do
        ann.send(:with_conditional_context) do
          ann.send(:with_smooth_context) do
            expect(ann.send(:current_fn_ctx)).to eq(ctx)
            expect(ann.send(:current_loop_depth)).to eq(1)
            expect(ann.send(:current_conditional_depth)).to eq(1)
            expect(ann.send(:smooth_depth)).to eq(1)
            raise "force unwind"
          end
        end
      end
    end.to raise_error("force unwind")

    expect(ctx.loop_depth).to eq(0)
    expect(ctx.conditional_depth).to eq(0)
    expect(ann.send(:smooth_depth)).to eq(0)
    expect(ann.send(:pop_function_context!)).to eq(ctx)
    expect(ann.send(:current_fn_ctx)).to be_nil

    ann.send(:with_conditional_context) do
      expect(ann.send(:current_conditional_depth)).to eq(1)
    end

    expect(ann.send(:current_conditional_depth)).to eq(0)
  end

  it "restores held lock state around nested WITH analysis" do
    ann = type_session
    ident = locked_identifier("cell")
    cap = AST::Capability.new(capability: :EXCLUSIVE, var_node: ident)
    with_node = AST::WithBlock.new(tok(:WITH, "WITH"), [cap], [])
    fact = capability_transition(cap)

    expect do
      ann.send(:with_held_locks, with_node, [fact]) do
        expect(ann.send(:current_held_locks).keys).to eq(["cell"])
        expect(ann.send(:current_held_lock_types).map(&:type)).to eq([:Counter])
        raise "force unwind"
      end
    end.to raise_error("force unwind")

    expect(ann.send(:current_held_locks)).to be_empty
    expect(ann.send(:current_held_lock_types)).to be_empty
  end

  it "scopes predicate context while preserving recorded predicate call sites" do
    ann = type_session
    pred_expr = AST::Literal.new(tok(:TRUE, "TRUE"), :BOOL, true, :stack)
    call = AST::FuncCall.new(tok(:VAR_ID, "check"), "check", [])
    ctx = CapabilityHelper::PredicateContext.new(
      kind: :pre,
      with_node: nil,
      fn_node: nil,
      pred_expr: pred_expr,
      guard_alias: nil,
      sibling_aliases: [],
      param_names: ["value"],
      allowed_names: [],
      rejected_param_names: Set.new,
      fn_name: "guarded",
    )

    expect do
      ann.send(:with_predicate_context, ctx) do
        expect(ann.send(:current_predicate_context)).to eq(ctx)
        ann.send(:record_predicate_call_site!, call)
        raise "force unwind"
      end
    end.to raise_error("force unwind")

    expect(ann.send(:current_predicate_context)).to be_nil
    expect(ann.send(:predicate_call_sites).map(&:callee)).to eq(["check"])
    expect(ann.send(:capability_audit)).to be_empty
  end

  it "restores auto-locked assignment context when RHS analysis raises" do
    ann = type_session
    ann.send(:current_scope).declare("cell", nil, Type.new(:Counter), true, false, nil, :heap, Set.new, [], sync: :locked)
    locked_target = AST::GetField.new(tok(:DOT, "."), AST::Identifier.new(tok(:VAR_ID, "cell"), "cell"), "value")
    value = AST::Literal.new(tok(:INT64, "1"), :INT64, 1, :stack)
    assignment = AST::Assignment.new(tok(:EQUAL, "="), locked_target, value)
    ann.send(:phase_traversal_state).auto_locked_assign_name = "outer"
    ann.define_singleton_method(:visit) do |node|
      raise "force unwind" if node.equal?(value)
    end

    expect { ann.send(:visit_Assignment, assignment) }.to raise_error("force unwind")

    expect(ann.send(:phase_traversal_state).auto_locked_assign_name).to eq("outer")
  end

  it "restores pipeline SOA tracking around pipeline body analysis" do
    ann = type_session
    node = AST::BinaryOp.new(tok(:PIPE, "|>"), AST::Identifier.new(tok(:VAR_ID, "xs"), "xs"), :PIPE, AST::Identifier.new(tok(:VAR_ID, "ys"), "ys"))

    expect do
      ann.send(:phase_traversal_state).pipeline_accessed_fields = Set.new
      begin
        T.must(ann.send(:phase_traversal_state).pipeline_accessed_fields).add("name")
        expect(ann.send(:phase_traversal_state).pipeline_accessed_fields&.to_a).to eq(["name"])
        raise "force unwind"
      ensure
        ann.send(:phase_traversal_state).pipeline_accessed_fields = nil
      end
    end.to raise_error("force unwind")

    expect(ann.send(:phase_traversal_state).pipeline_accessed_fields).to be_nil

    ann.send(:with_soa_tracking, node, :Unknown) do
      T.must(ann.send(:phase_traversal_state).pipeline_accessed_fields).add("id")
      expect { ann.send(:check_soa_opportunity!, node, :Unknown) }.not_to raise_error
    end
  end
end
