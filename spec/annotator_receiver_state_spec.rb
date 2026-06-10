require "spec_helper"

require_relative "../src/annotator/annotator"

RSpec.describe "annotator receiver state boundaries" do
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
    ann = SemanticAnnotator.new(source_code: "")

    expect(ann.scope_stack).to contain_exactly(ann.semantic_root_scope)

    expect do
      ann.send(:with_new_scope) do
        ann.send(:current_scope).declare("local", nil, :Int64, false, false, nil, :stack)
        expect(ann.send(:outer_scope_vars)).to include("local")
        raise "force unwind"
      end
    end.to raise_error("force unwind")

    expect(ann.scope_stack).to contain_exactly(ann.semantic_root_scope)
    expect(ann.send(:outer_scope_vars)).not_to include("local")
  end

  it "restores function, loop, conditional, and smooth contexts on exceptions" do
    ann = SemanticAnnotator.new(source_code: "")
    ctx = FunctionContext.new(name: "stateful", return_type: Type.new(:Void))

    expect do
      ann.send(:push_function_context!, ctx)
      ann.send(:with_loop_context) do
        ann.with_conditional_context do
          ann.send(:with_smooth_context) do
            expect(ann.current_fn_ctx).to eq(ctx)
            expect(ann.current_loop_depth).to eq(1)
            expect(ann.current_conditional_depth).to eq(1)
            expect(ann.smooth_depth).to eq(1)
            raise "force unwind"
          end
        end
      end
    end.to raise_error("force unwind")

    expect(ctx.loop_depth).to eq(0)
    expect(ctx.conditional_depth).to eq(0)
    expect(ann.smooth_depth).to eq(0)
    expect(ann.send(:pop_function_context!)).to eq(ctx)
    expect(ann.current_fn_ctx).to be_nil

    ann.with_conditional_context do
      expect(ann.current_conditional_depth).to eq(1)
    end

    expect(ann.current_conditional_depth).to eq(0)
  end

  it "restores held lock state around nested WITH analysis" do
    ann = SemanticAnnotator.new(source_code: "")
    ident = locked_identifier("cell")
    cap = AST::Capability.new(capability: :EXCLUSIVE, var_node: ident)
    with_node = AST::WithBlock.new(tok(:WITH, "WITH"), [cap], [])
    fact = capability_transition(cap)

    expect do
      ann.send(:with_held_locks, with_node, [fact]) do
        expect(ann.current_held_locks.keys).to eq(["cell"])
        expect(ann.current_held_lock_types.map(&:type)).to eq([:Counter])
        raise "force unwind"
      end
    end.to raise_error("force unwind")

    expect(ann.current_held_locks).to be_empty
    expect(ann.current_held_lock_types).to be_empty
  end

  it "scopes predicate context while preserving recorded predicate call sites" do
    ann = SemanticAnnotator.new(source_code: "")
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
        expect(ann.current_predicate_context).to eq(ctx)
        ann.send(:record_predicate_call_site!, call)
        raise "force unwind"
      end
    end.to raise_error("force unwind")

    expect(ann.current_predicate_context).to be_nil
    expect(ann.predicate_call_sites.map(&:callee)).to eq(["check"])
    expect(ann.capability_audit).to be_empty
  end
end
