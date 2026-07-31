require "rspec"
require "set"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/semantic/escape_analysis" unless defined?(EscapeAnalysis::EscapeSink)

# Retained identity v4, keep-analysis (A1): a plain parameter that flows into
# an @multiowned identity destination is stamped kept_identity on its
# SymbolEntry. Destination-driven, transitive over the call graph, and
# read-only params are never affected (no ABI change without a keep).
# Design: docs/agents/retained-identity-design.md.

RSpec.describe "kept_identity keep-analysis" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    [ast, annotator]
  end

  def fn_nodes_from(ast)
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    fn_nodes
  end

  def param_symbol(fn_nodes, fn_name, param_name)
    fn = fn_nodes.fetch(fn_name)
    param = fn.params.find { |p| p.name == param_name }
    expect(param).not_to be_nil
    param[:symbol]
  end

  let(:shared_budget_prelude) do
    <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }
    CHT
  end

  it "stamps kept_identity on a param stored into an @multiowned field" do
    src = <<~CHT
      #{shared_budget_prelude}
      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget };
      END

      FN main() RETURNS Void ->
        shared = Budget{ count: 0 } @multiowned;
        a = makeHolder(shared);
        b = makeHolder(shared);
        ASSERT a.budget.count == 0, "a sees budget";
        ASSERT b.budget.count == 0, "b sees budget";
        RETURN;
      END
    CHT

    ast, = annotate(src)
    fn_nodes = fn_nodes_from(ast)

    entry = param_symbol(fn_nodes, "makeHolder", "budget")
    expect(entry).not_to be_nil
    contract = entry.kept_identity
    expect(contract).to be_a(KeptIdentityContract)
    expect(contract.family).to eq(:multiowned)
    expect(contract.sink).to eq("Holder.budget")
  end

  it "propagates kept_identity transitively through a pass-through helper" do
    src = <<~CHT
      #{shared_budget_prelude}
      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget };
      END

      FN viaHelper(b: Budget) RETURNS Holder ->
        RETURN makeHolder(b);
      END

      FN main() RETURNS Void ->
        shared = Budget{ count: 0 } @multiowned;
        h = viaHelper(shared);
        ASSERT h.budget.count == 0, "h sees budget";
        RETURN;
      END
    CHT

    ast, = annotate(src)
    fn_nodes = fn_nodes_from(ast)

    expect(param_symbol(fn_nodes, "makeHolder", "budget").kept_identity&.family).to eq(:multiowned)
    # Transitive keeps inherit the originating sink through the fixpoint.
    expect(param_symbol(fn_nodes, "viaHelper", "b").kept_identity&.sink).to eq("Holder.budget")
  end

  it "does not stamp kept_identity on read-only params" do
    src = <<~CHT
      #{shared_budget_prelude}
      FN readBudget(budget: Budget) RETURNS Int64 ->
        RETURN budget.count;
      END

      FN main() RETURNS Void ->
        shared = Budget{ count: 0 } @multiowned;
        n = readBudget(shared);
        ASSERT n == 0, "reads through";
        RETURN;
      END
    CHT

    ast, = annotate(src)
    fn_nodes = fn_nodes_from(ast)

    entry = param_symbol(fn_nodes, "readBudget", "budget")
    expect(entry.kept_identity).to be_nil
  end

  it "still rejects GIVE into a plain borrow param after the keep fixpoint" do
    src = <<~CHT
      STRUCT Node { id: Int64 }

      FN readNode(n: Node) RETURNS Int64 ->
        RETURN n.id;
      END

      FN main() RETURNS Void ->
        node = Node{ id: 2 };
        x = readNode(GIVE node);
        ASSERT x == 2, "reads";
        RETURN;
      END
    CHT

    expect { annotate(src) }.to raise_error(SourceError, /GIVE_TO_BORROW_PARAM|GIVE passed to non-TAKES/i)
  end

  it "accepts GIVE at a kept edge as a relinquishment assertion" do
    src = <<~CHT
      #{shared_budget_prelude}
      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget };
      END

      FN main() RETURNS Void ->
        shared = Budget{ count: 3 } @multiowned;
        h = makeHolder(GIVE shared);
        ASSERT h.budget.count == 3, "keeper owns the moved handle";
        RETURN;
      END
    CHT

    expect { annotate(src) }.not_to raise_error
  end

  it "promotes an immutable plain caller binding to born-as-Rc at its declaration" do
    src = <<~CHT
      #{shared_budget_prelude}
      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget };
      END

      FN main() RETURNS Void ->
        plain = Budget{ count: 4 };
        a = makeHolder(plain);
        ASSERT plain.count == 4, "used after the keep";
        ASSERT a.budget.count == 4, "keeper reads";
        RETURN;
      END
    CHT

    ast, = annotate(src)
    fn_nodes = fn_nodes_from(ast)
    main_fn = fn_nodes.fetch("main")
    decl = main_fn.body.find { |s| s.respond_to?(:name) && s.name == "plain" }
    expect(decl).not_to be_nil
    entry = decl.symbol
    expect(entry.storage).to eq(:multiowned)
    expect(entry.type.multiowned?).to be(true)
  end

  it "errors at the declaration when a plain MUTABLE binding is kept" do
    src = <<~CHT
      #{shared_budget_prelude}
      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget };
      END

      FN main() RETURNS Void ->
        MUTABLE plain = Budget{ count: 4 };
        a = makeHolder(plain);
        plain.count = 5;
        ASSERT a.budget.count == 4, "keeper reads";
        RETURN;
      END
    CHT

    expect { annotate(src) }.to raise_error(SourceError) { |err|
      expect(err.message).to include("KEPT_IDENTITY_NEEDS_MODEL")
      expect(err.message).to include("plain")
      expect(err.message).to include("makeHolder")
      expect(err.message).to include("Holder.budget")
      expect(err.message).to include("@multiowned")
      expect(err.message).to include("@value")
      # Anchored at the declaration line (9), not the call line (10).
      expect(err.message).to match(/[Ll]ine 9\b/)
    }
  end

  describe "cost proofs on emitted Zig" do
    def transpile(src)
      ZigTranspiler.new.transpile(src)
    end

    it "shared model: one retain per edge, no hidden copies, no monomorphization" do
      src = <<~CHT
        #{shared_budget_prelude}
        FN makeHolder(budget: Budget) RETURNS Holder ->
          RETURN Holder{ budget: budget };
        END

        FN main() RETURNS Void ->
          shared = Budget{ count: 0 } @multiowned;
          a = makeHolder(shared);
          b = makeHolder(shared);
          ASSERT a.budget.count == 0, "a";
          ASSERT b.budget.count == 0, "b";
          RETURN;
        END
      CHT

      zig = transpile(src)
      # First edge retains (binding still live); the second is the
      # binding's last use, so the handle moves - retain elided.
      expect(zig.scan("CheatLib.rcRetain(").length).to eq(1)
      expect(zig).not_to include("dupeValue(Budget")
      # One compiled body with the concrete handle ABI - no anytype fork.
      expect(zig.scan(/fn makeHolder\(/).length).to eq(1)
      expect(zig).to include("budget: CheatLib.Rc(Budget)")
    end

    it "GIVE relinquishment elides the retain entirely" do
      src = <<~CHT
        #{shared_budget_prelude}
        FN makeHolder(budget: Budget) RETURNS Holder ->
          RETURN Holder{ budget: budget };
        END

        FN main() RETURNS Void ->
          shared = Budget{ count: 3 } @multiowned;
          h = makeHolder(GIVE shared);
          ASSERT h.budget.count == 3, "h";
          RETURN;
        END
      CHT

      zig = transpile(src)
      expect(zig).not_to include("CheatLib.rcRetain(")
      expect(zig).not_to include("dupeValue(Budget")
    end

    it "two kept params compile to one body with additive edge derivations" do
      src = <<~CHT
        STRUCT Budget { count: Int64 }
        STRUCT Pair { left: Budget @multiowned, right: Budget @multiowned }

        FN makePair(l: Budget, r: Budget) RETURNS Pair ->
          RETURN Pair{ left: l, right: r };
        END

        FN main() RETURNS Void ->
          a = Budget{ count: 1 } @multiowned;
          b = Budget{ count: 2 } @multiowned;
          p = makePair(a, b);
          ASSERT p.left.count == 1, "l";
          ASSERT p.right.count == 2, "r";
          RETURN;
        END
      CHT

      zig = transpile(src)
      expect(zig.scan(/fn makePair\(/).length).to eq(1)
      expect(zig).to include("l: CheatLib.Rc(Budget), r: CheatLib.Rc(Budget)")
      # Both bindings hit their last use at the call: both handles move.
      expect(zig.scan("CheatLib.rcRetain(").length).to eq(0)
    end

    it "born-as-Rc allocates the handle at the declaration, never payload-then-wrap" do
      src = <<~CHT
        #{shared_budget_prelude}
        FN makeHolder(budget: Budget) RETURNS Holder ->
          RETURN Holder{ budget: budget };
        END

        FN main() RETURNS Void ->
          plain = Budget{ count: 4 };
          a = makeHolder(plain);
          ASSERT plain.count == 4, "used after";
          ASSERT a.budget.count == 4, "keeper";
          RETURN;
        END
      CHT

      zig = transpile(src)
      expect(zig).to match(/const plain = try CheatLib\.rcCreate\(Budget/)
      expect(zig).not_to include("dupeValue(Budget")
    end

    it "zero-config optional: null edge for omitted, lazy fresh default in the callee" do
      src = <<~CHT
        #{shared_budget_prelude}
        FN makeHolder(budget: ?Budget = NIL) RETURNS !Holder ->
          RETURN Holder{ budget: budget OR_ELSE Budget{ count: 9 } };
        END

        FN main() RETURNS !Void ->
          fresh = TRY makeHolder();
          ASSERT fresh.budget.count == 9, "fresh";
          RETURN;
        END
      CHT

      zig = transpile(src)
      expect(zig).to include("budget: ?CheatLib.Rc(Budget)")
      expect(zig).to match(/makeHolder\(rt, null\)/)
      # The fresh default stays inside the orelse (lazy), not hoisted before it.
      expect(zig).to match(/orelse.*\n?.*rcCreate/m)
    end
  end

  it "rejects using a retaining function as a plain function value" do
    src = <<~CHT
      #{shared_budget_prelude}
      FN keep(b: Budget) RETURNS Holder ->
        RETURN Holder{ budget: b };
      END

      FN main() RETURNS Void ->
        cb: FN(Budget) -> Holder = keep;
        src = Budget{ count: 1 } @multiowned;
        h = cb(src);
        ASSERT h.budget.count == 1, "cb keeps";
        RETURN;
      END
    CHT

    expect { annotate(src) }.to raise_error(SourceError) { |err|
      expect(err.message).to include("KEPT_FN_VALUE_ABI")
      expect(err.message).to include("keep")
      expect(err.message).to include("Holder.budget")
    }
  end

  it "rejects identity capabilities on generic type parameters at the declaration" do
    src = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder<T> { value: T @multiowned }

      FN keep<T>(value: T) RETURNS Holder<T> ->
        RETURN Holder<T>{ value: value };
      END

      FN main() RETURNS Void ->
        src = Budget{ count: 1 } @multiowned;
        held = keep(src);
        ASSERT held.value.count == 1, "held";
        RETURN;
      END
    CHT

    expect { annotate(src) }.to raise_error(SourceError) { |err|
      expect(err.message).to include("GENERIC_IDENTITY_FIELD_UNSUPPORTED")
      expect(err.message).to include("Holder")
    }
  end

  it "treats inferred retention as interface for incremental invalidation" do
    require_relative "../ruby/incremental/source_catalog"

    with_keep = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget };
      END
    CHT
    # Body-only edit: the param no longer flows into the identity field,
    # so the param's generated ABI changes from Rc(T) back to T. Callers
    # must recompile even though the source signature text is identical.
    without_keep = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN makeHolder(budget: Budget) RETURNS Holder ->
        fresh = Budget{ count: budget.count };
        RETURN Holder{ budget: fresh };
      END
    CHT

    a = Incremental::SourceCatalog.build(with_keep, module_path: "kept.clear")
    b = Incremental::SourceCatalog.build(without_keep, module_path: "kept.clear")
    a_item = a.functions.find { |f| f.name == "makeHolder" } || a.functions["makeHolder"]
    b_item = b.functions.find { |f| f.name == "makeHolder" } || b.functions["makeHolder"]
    expect(a_item.interface_fingerprint).not_to eq(b_item.interface_fingerprint)
  end

  it "treats a field-assignment keep as interface for incremental invalidation" do
    require_relative "../ruby/incremental/source_catalog"

    # `h.budget = b` is a keep sink exactly like a struct-literal store
    # (Variables#visit_assignment_field), so adding it in a body-only edit
    # changes the param ABI and must change the interface fingerprint.
    with_keep = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN reseat(h: Holder, b: Budget) RETURNS Void ->
        h.budget = b;
        RETURN;
      END
    CHT
    without_keep = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN reseat(h: Holder, b: Budget) RETURNS Void ->
        fresh = Budget{ count: b.count };
        h.budget = fresh;
        RETURN;
      END
    CHT

    a = Incremental::SourceCatalog.build(with_keep, module_path: "kept.clear")
    b = Incremental::SourceCatalog.build(without_keep, module_path: "kept.clear")
    a_item = a.functions.find { |f| f.name == "reseat" }
    b_item = b.functions.find { |f| f.name == "reseat" }
    expect(a_item.interface_fingerprint).not_to eq(b_item.interface_fingerprint)
  end

  it "treats an OR_ELSE-wrapped keep as interface for incremental invalidation" do
    require_relative "../ruby/incremental/source_catalog"

    # `param OR_ELSE default` in a keep position keeps the provided
    # identity (Lifetimes#keep_param_identity! unwraps OR_ELSE), so the
    # wrapped flow is interface exactly like the bare identifier.
    with_keep = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN makeHolder(budget: ?Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget OR_ELSE Budget{ count: 0 } };
      END
    CHT
    without_keep = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN makeHolder(budget: ?Budget) RETURNS Holder ->
        provided = budget OR_ELSE Budget{ count: 0 };
        fresh = Budget{ count: provided.count };
        RETURN Holder{ budget: fresh };
      END
    CHT

    a = Incremental::SourceCatalog.build(with_keep, module_path: "kept.clear")
    b = Incremental::SourceCatalog.build(without_keep, module_path: "kept.clear")
    a_item = a.functions.find { |f| f.name == "makeHolder" }
    b_item = b.functions.find { |f| f.name == "makeHolder" }
    expect(a_item.interface_fingerprint).not_to eq(b_item.interface_fingerprint)
  end

  it "survives PROTOCOL statements when a kept function exists" do
    # reject_kept_function_values! walks every non-FN top-level statement;
    # ProtocolRequirement is the AST's only T::Struct Locatable, which
    # each_child_node's Ruby-Struct member walk crashed on.
    src = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      PROTOCOL Sized {
        METHOD size(self: Self) RETURNS Int64;
      }

      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget };
      END

      FN main() RETURNS Void ->
        src = Budget{ count: 1 } @multiowned;
        h = makeHolder(src);
        ASSERT h.budget.count == 1, "kept";
        RETURN;
      END
    CHT

    expect { annotate(src) }.not_to raise_error
  end

  it "distinguishes a bare keep from a COPY store in the interface fingerprint" do
    require_relative "../ruby/incremental/source_catalog"

    # `H{ f: b }` keeps b (ABI Rc(T)); `H{ f: COPY b }` forces an
    # independent identity (plain ABI). A body-only edit between the two
    # changes the param ABI, so the fingerprints must differ.
    kept = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget };
      END
    CHT
    copied = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: COPY budget };
      END
    CHT

    a = Incremental::SourceCatalog.build(kept, module_path: "kept.clear")
    b = Incremental::SourceCatalog.build(copied, module_path: "kept.clear")
    a_item = a.functions.find { |f| f.name == "makeHolder" }
    b_item = b.functions.find { |f| f.name == "makeHolder" }
    expect(a_item.interface_fingerprint).not_to eq(b_item.interface_fingerprint)
  end

  it "distinguishes a bare call arg from a COPY arg in the interface fingerprint" do
    require_relative "../ruby/incremental/source_catalog"

    # Transitive keep propagation only fires on bare identifier args
    # (KeepAnalysis), so `keepIt(b)` keeps the caller's param while
    # `keepIt(COPY b)` does not - the fingerprints must differ.
    bare = <<~CHT
      STRUCT Budget { count: Int64 }

      FN passThrough(b: Budget) RETURNS Void ->
        keepIt(b);
        RETURN;
      END
    CHT
    copied = <<~CHT
      STRUCT Budget { count: Int64 }

      FN passThrough(b: Budget) RETURNS Void ->
        keepIt(COPY b);
        RETURN;
      END
    CHT

    a = Incremental::SourceCatalog.build(bare, module_path: "kept.clear")
    b = Incremental::SourceCatalog.build(copied, module_path: "kept.clear")
    a_item = a.functions.find { |f| f.name == "passThrough" }
    b_item = b.functions.find { |f| f.name == "passThrough" }
    expect(a_item.interface_fingerprint).not_to eq(b_item.interface_fingerprint)
  end

  it "still rejects a param stored into a plain owned field (keep is @multiowned-only)" do
    src = <<~CHT
      UNION Value { Nil, Str: String }
      STRUCT Pair { a: Value, b: Value }

      FN f(v: Value) RETURNS Void ->
        p = Pair{ a: v, b: Value.Nil };
      END

      FN main() RETURNS Void -> f(Value.Nil); END
    CHT

    expect { annotate(src) }.to raise_error(SourceError, /Cannot store borrowed value 'v' into Pair\.a/)
  end

  it "rejects an @shared (Arc) source kept into an @multiowned (Rc) identity" do
    # An Arc cannot be retained where an Rc is expected: the two use
    # incompatible refcount accounting, so this must fail CLOSED at
    # annotation, never reach Zig as 'expected Rc, found Arc'.
    src = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget };
      END

      FN main() RETURNS Void ->
        src = Budget{ count: 11 } @shared;
        kept = makeHolder(src);
        ASSERT kept.budget.count == 11, "kept";
        RETURN;
      END
    CHT

    expect { annotate(src) }.to raise_error(SourceError) { |err|
      expect(err.message).to include("KEPT_IDENTITY_FAMILY_MISMATCH")
    }
  end

  it "accepts COPY of an @shared source into an @multiowned identity" do
    # COPY breaks identity, so the family mismatch does not apply: the
    # keeper constructs an independent Rc from the copied payload.
    src = <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN makeHolder(budget: Budget) RETURNS Holder ->
        RETURN Holder{ budget: budget };
      END

      FN main() RETURNS Void ->
        src = Budget{ count: 11 } @shared;
        kept = makeHolder(COPY src);
        ASSERT kept.budget.count == 11, "kept";
        RETURN;
      END
    CHT

    expect { annotate(src) }.not_to raise_error
  end
end
