require "rspec"
require "set"

require_relative "../src/backends/transpiler"
require_relative "../src/semantic/escape_analysis"

# P1.4 / P1.5 / P1.6: pin the transitive sync propagation pass.
#
# These specs work directly against EscapeAnalysis.propagate_caller_sync!
# and the surrounding plumbing (param[:symbol] stash, FunctionSignature
# :sync field). They do NOT route through annotator-time WITH validation,
# which P1.7 will defer; the annotator-integrated version is pinned by
# transpile-tests/201_capability_passthrough.cht.disabled (enabled when
# P1.7 lands).

RSpec.describe "P1.4 caller-sync propagation" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    [ast, annotator]
  end

  def fn_nodes_from(ast)
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    fn_nodes
  end

  def body_summaries_from(annotator)
    annotator.send(:function_body_summaries)
  end

  it "stamps entry.sync on a callee param when one caller passes a @shared:locked binding" do
    src = <<~CHT
      STRUCT Counter { value: Int64 }

      FN bumpIt(c: Counter) ->
        x = c.value;
      END

      FN main() ->
        c = Counter{ value: 0 } @shared:locked;
        bumpIt(c);
      END
    CHT

    ast, annotator = annotate(src)
    fn_nodes = fn_nodes_from(ast)
    EscapeAnalysis.propagate_caller_sync!(fn_nodes, body_summaries_from(annotator))

    bump_param = fn_nodes["bumpIt"].params.first
    expect(bump_param[:symbol]).not_to be_nil
    expect(bump_param[:symbol].sync).to eq(:locked)
  end

  it "leaves entry.sync nil when callers disagree" do
    src = <<~CHT
      STRUCT Counter { value: Int64 }

      FN bumpIt(c: Counter) ->
        x = c.value;
      END

      FN useA() ->
        a = Counter{ value: 0 } @shared:locked;
        bumpIt(a);
      END

      FN useB() ->
        b = Counter{ value: 0 };
        bumpIt(b);
      END
    CHT

    ast, annotator = annotate(src)
    fn_nodes = fn_nodes_from(ast)
    EscapeAnalysis.propagate_caller_sync!(fn_nodes, body_summaries_from(annotator))

    bump_param = fn_nodes["bumpIt"].params.first
    # One caller passes :locked; the other passes nil. Mixed → leave nil.
    expect(bump_param[:symbol].sync).to be_nil
  end

  it "leaves entry.sync nil when no caller passes a sync binding" do
    src = <<~CHT
      STRUCT Counter { value: Int64 }

      FN bumpIt(c: Counter) ->
        x = c.value;
      END

      FN main() ->
        c = Counter{ value: 0 };
        bumpIt(c);
      END
    CHT

    ast, annotator = annotate(src)
    fn_nodes = fn_nodes_from(ast)
    EscapeAnalysis.propagate_caller_sync!(fn_nodes, body_summaries_from(annotator))

    expect(fn_nodes["bumpIt"].params.first[:symbol].sync).to be_nil
  end

  it "does not override a pre-set entry.sync (idempotency under iteration)" do
    # The propagation pass guards against re-writing entry.sync when a
    # different unifying value would result. Construct a callee whose
    # param entry has been pre-stamped with :locked, and a caller that
    # passes a bare binding. The pre-stamped sync must survive — bare
    # caller arg sync (nil) cannot unify and overwrite.
    src = <<~CHT
      STRUCT Counter { value: Int64 }

      FN bumpIt(c: Counter) ->
        x = c.value;
      END

      FN main() ->
        c = Counter{ value: 0 };
        bumpIt(c);
      END
    CHT

    ast, annotator = annotate(src)
    fn_nodes = fn_nodes_from(ast)
    # Pre-stamp the param's entry.sync as if it had been declared :locked.
    fn_nodes["bumpIt"].params.first[:symbol].sync = :locked

    EscapeAnalysis.propagate_caller_sync!(fn_nodes, body_summaries_from(annotator))

    # Caller passes nil (bare binding), so unify produces no override.
    expect(fn_nodes["bumpIt"].params.first[:symbol].sync).to eq(:locked)
  end

  it "propagates transitively through a two-hop call chain" do
    # main → outer → inner. A @shared:locked binding in main should reach
    # inner's param via two propagation rounds.
    src = <<~CHT
      STRUCT Counter { value: Int64 }

      FN inner(c: Counter) ->
        x = c.value;
      END

      FN outer(c: Counter) ->
        inner(c);
      END

      FN main() ->
        c = Counter{ value: 0 } @shared:locked;
        outer(c);
      END
    CHT

    ast, annotator = annotate(src)
    fn_nodes = fn_nodes_from(ast)
    EscapeAnalysis.propagate_caller_sync!(fn_nodes, body_summaries_from(annotator))

    expect(fn_nodes["outer"].params.first[:symbol].sync).to eq(:locked)
    expect(fn_nodes["inner"].params.first[:symbol].sync).to eq(:locked)
  end
end

RSpec.describe "P1.5 FunctionSignature carries per-param sync" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    [ast, annotator]
  end

  it "exposes a :sync field on signature params (defaulting to nil today)" do
    # The annotator currently refuses capability annotations on param types
    # ("Counter @locked" on a param errors). The :sync field is therefore
    # always nil in source-level tests; this spec pins that the FIELD is
    # *present* on the signature, ready for Phase 2's REQUIRES to populate
    # it across module boundaries.
    src = <<~CHT
      STRUCT Counter { value: Int64 }

      PUB FN bumpIt(c: Counter) ->
        x = c.value;
      END
    CHT

    ast, annotator = annotate(src)
    sig = FunctionSignature.unwrap(annotator.semantic_root_scope.resolve_entry!("bumpIt").type)
    expect(sig).to be_a(FunctionSignature)
    # The field is present on the Param struct (defaulting to nil).
    expect(sig.params.first).to be_a(AST::Param)
    expect(sig.params.first.sync).to be_nil
  end

  it "leaves :sync nil for params with no sync annotation" do
    src = <<~CHT
      STRUCT Counter { value: Int64 }

      PUB FN bumpIt(c: Counter) ->
        x = c.value;
      END
    CHT

    ast, annotator = annotate(src)
    sig = FunctionSignature.unwrap(annotator.semantic_root_scope.resolve_entry!("bumpIt").type)
    expect(sig.params.first[:sync]).to be_nil
  end
end
