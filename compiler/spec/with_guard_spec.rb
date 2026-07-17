require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "WITH GUARD clauses" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).parse
  end

  def annotate(src)
    ast = parse(src)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "parses GUARD after the AS alias" do
    ast = parse(<<~CLEAR)
      FN main() RETURNS Void ->
        WITH EXCLUSIVE c AS y GUARD y.value > 0 { RETURN; }
        RETURN;
      END
    CLEAR

    with_node = ast.statements.first.body.first
    cap = with_node.capabilities.first
    expect(cap[:alias]).to eq("y")
    expect(cap[:guard_expr]).to be_a(AST::BinaryOp)
  end

  it "accepts a pure predicate over the guarded alias" do
    ast = annotate(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN positive?(c: Counter) RETURNS Bool ->
        RETURN c.value > 0;
      END
      FN main() RETURNS Void ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD positive?(y) {
          v = y.value;
        }
        RETURN;
      END
    CLEAR

    with_node = ast.statements.last.body[1]
    expect(with_node.capabilities.first[:guard_expr].full_type.resolved).to eq(:Bool)
  end

  it "allows repeated use of the guarded alias inside predicate arguments" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN above?(c: Counter, n: Int64) RETURNS Bool ->
          RETURN c.value > n;
        END
        FN main() RETURNS Void ->
          c = Counter{ value: 2 } @shared:locked;
          WITH EXCLUSIVE c AS y GUARD above?(y, y.value - 1) {
            v = y.value;
          }
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects guard references to any symbol besides the guarded alias" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          other = 0;
          WITH EXCLUSIVE c AS y GUARD y.value > other {
            v = y.value;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /can only reference the guarded alias 'y'.*other/m)
  end

  it "rejects MUTABLE guarded aliases when the body field-assigns through the alias" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE c AS MUTABLE y GUARD y.value > 0 {
            y.value = 2;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /GUARD aliases cannot be MUTABLE and mutated inside the body.*'y'/m)
  end

  it "accepts a MUTABLE guarded alias when the body never mutates it" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE c AS MUTABLE y GUARD y.value > 0 {
            v = y.value;
          }
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects when a MUTABLE guarded alias is reassigned in the body" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE c AS MUTABLE y GUARD y.value > 0 {
            y = Counter{ value: 9 };
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /declared MUTABLE and mutated/)
  end

  it "rejects when a MUTABLE guarded alias is mutated via compound assignment on a field" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE c AS MUTABLE y GUARD y.value > 0 {
            y.value += 1;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /declared MUTABLE and mutated/)
  end

  it "rejects when a MUTABLE guarded alias is mutated via index assignment" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Bin { items: [3]Int64 }
        FN main() RETURNS Void ->
          b = Bin{ items: [0_i64, 0_i64, 0_i64] } @shared:locked;
          WITH EXCLUSIVE b AS MUTABLE y GUARD y.items[0] >= 0 {
            y.items[0] = 7;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /declared MUTABLE and mutated/)
  end

  it "rejects when a MUTABLE guarded alias is passed to a helper that takes MUTABLE" do
    # The caller's binding receives mutation through the callee's
    # MUTABLE-by-ref parameter. Without the mutation-mark on
    # MUTABLE-arg passing in function_analysis.rb, this case slipped
    # through validate_with_guard_no_body_mutation! as a false negative.
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN bump(MUTABLE c: Counter) RETURNS Void ->
          c.value = c.value + 1;
          RETURN;
        END
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE c AS MUTABLE y GUARD y.value > 0 {
            bump(&y);
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /declared MUTABLE and mutated/)
  end

  it "names only the mutated MUTABLE alias when multiple are MUTABLE but only one is mutated" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          a = Counter{ value: 1 } @shared:locked;
          b = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE a AS MUTABLE x GUARD x.value > 0,
               EXCLUSIVE b AS MUTABLE y GUARD y.value > 0 {
            x.value = 9;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError) { |e|
      expect(e.message).to match(/declared MUTABLE and mutated/)
      expect(e.message).to include("'x'")
      expect(e.message).not_to include("'y'")
    }
  end

  it "accepts a multi-object GUARD with MUTABLE aliases when the body mutates none of them" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          a = Counter{ value: 1 } @shared:locked;
          b = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE a AS MUTABLE x GUARD x.value > 0,
               EXCLUSIVE b AS MUTABLE y GUARD y.value > 0 {
            v = x.value + y.value;
          }
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects non-Bool guard expressions" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE c AS y GUARD y.value {
            v = y.value;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /GUARD expression must return Bool/)
  end

  it "rejects impure guard predicates" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { name: String }
        FN main() RETURNS !Void ->
          c = Counter{ name: "12" } @shared:locked;
          WITH EXCLUSIVE c AS y GUARD toInt(y.name) > 0 {
            n = 1;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /GUARD clauses must be pure.*toInt.*can fail/m)
  end

  it "supports guarded polymorphic access" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN positive?(c: Counter) RETURNS Bool ->
          RETURN c.value > 0;
        END
        FN read(c: SHARED Counter) RETURNS Void
          REQUIRES c: LOCKED
        ->
          WITH POLYMORPHIC c AS y GUARD positive?(y) {
            v = y.value;
          }
          RETURN;
        END
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          read(c);
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "wraps the lowered WITH body in an if guard" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          v = y.value;
        }
        RETURN;
      END
    CLEAR

    expect(zig).to include("if ((y.value > 0))")
  end

  it "parses ON GuardFail for guarded WITH blocks" do
    ast = parse(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          v = y.value;
        } ON GuardFail PASS
        RETURN;
      END
    CLEAR

    with_node = ast.statements.last.body[1]
    expect(with_node.lock_error_clause.selectors.first.name).to eq(:GuardFail)
  end

  it "parses ON GuardFail RETURN for guarded WITH blocks" do
    ast = parse(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Bool ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          RETURN TRUE;
        } ON GuardFail RETURN FALSE
      END
    CLEAR

    clause = ast.statements.last.body[1].lock_error_clause
    expect(clause.action).to eq(AST::ErrorActionKind::Return)
    expect(clause.value).to be_a(AST::Literal)
  end

  it "allows ON GuardFail on guard-only non-locking access" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 };
          WITH BORROWED c AS y GUARD y.value > 0 {
            v = y.value;
          } ON GuardFail PASS
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects unrelated ON selectors on guard-only non-locking access" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 };
          WITH BORROWED c AS y GUARD y.value > 0 {
            v = y.value;
          } ON LockTimeout PASS
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /do not match any error.*GuardFail/m)
  end

  it "lowers ON GuardFail PASS as the false branch of the guard" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          v = y.value;
        } ON GuardFail PASS
        RETURN;
      END
    CLEAR

    expect(zig).to include("if ((y.value > 0))")
    expect(zig).to include("else")
    expect(zig).to include("break :__with_")
  end

  it "lowers ON GuardFail RAISE with the GuardFail error name" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS !Void ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          v = y.value;
        } ON GuardFail RAISE
        RETURN;
      END
    CLEAR

    expect(zig).to include("ErrorName.GuardFail")
    expect(zig).to include("WITH GUARD predicate failed")
  end

  it "lowers ON GuardFail RETURN for ordinary guarded WITH blocks" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Bool ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          RETURN TRUE;
        } ON GuardFail RETURN FALSE
      END
    CLEAR

    expect(zig).to include("if ((y.value > 0))")
    expect(zig).to include("else")
    expect(zig).to include("return false;")
  end

  it "uses the flow helper for guarded universal polymorphic WITH returns" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN positive(c: Counter) RETURNS !Bool ->
        WITH POLYMORPHIC c AS y GUARD y.value > 0 {
          RETURN TRUE;
        } ON GuardFail RETURN FALSE
      END
    CLEAR

    expect(zig).to include("CheatLib.polymorphicMutateFlow(")
    expect(zig).to include(".ret_commit")
    expect(zig).to include(".ret_no_commit")
    expect(zig).to include("return __poly_flow.ret")
  end

  it "accepts a multi-binding WITH where each capability has its own self-only GUARD" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          a = Counter{ value: 1 } @shared:locked;
          b = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE a AS x GUARD x.value > 0,
               EXCLUSIVE b AS y GUARD y.value > 0 {
            v = x.value;
          }
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects a GUARD predicate that references a sibling alias from the same WITH" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          a = Counter{ value: 5 };
          c = Counter{ value: 3 };
          WITH BORROWED a AS b, BORROWED c AS d GUARD d.value > b.value {
            v = b.value;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError,
      /sibling alias bound by the same WITH.*Multi-object consistency for aliased objects is not supported.*Use an `IF` guard clause inside the WITH body/m)
  end

  it "rejects a sibling-alias GUARD reference even when the sibling has its own GUARD" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          a = Counter{ value: 1 } @shared:locked;
          b = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE a AS x GUARD x.value > 0,
               EXCLUSIVE b AS y GUARD x.value == y.value {
            v = x.value;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /Multi-object consistency for aliased objects is not supported/)
  end

  it "ANDs multiple per-capability self-only GUARD predicates in the emitted Zig" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS !Void ->
        a = Counter{ value: 1 };
        b = Counter{ value: 1 };
        WITH BORROWED a AS x GUARD x.value > 0,
             BORROWED b AS y GUARD y.value > 0 {
          v = x.value;
        }
        RETURN;
      END
    CLEAR

    expect(zig).to match(/x\.value > 0\) and \(y\.value > 0/)
  end

  it "rejects a MUTABLE participating alias mutated in the body of a multi-binding GUARD" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          a = Counter{ value: 1 } @shared:locked;
          b = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE a AS x GUARD x.value > 0,
               EXCLUSIVE b AS MUTABLE y GUARD y.value > 0 {
            y.value = 2;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError,
      /GUARD aliases cannot be MUTABLE and mutated inside the body.*'y'.*declared MUTABLE and mutated/m)
  end

  it "rejects guard references to a non-alias symbol in a multi-binding WITH" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          a = Counter{ value: 1 } @shared:locked;
          b = Counter{ value: 1 } @shared:locked;
          other = 0;
          WITH EXCLUSIVE a AS x GUARD x.value > other,
               EXCLUSIVE b AS y GUARD y.value > 0 {
            v = x.value;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError,
      /can only reference the guarded alias 'x'.*Found 'other'/m)
  end

  it "rejects sibling-alias references even when the same name shadows an outer binding" do
    # Outer scope has a binding named `b`; the WITH binds something
    # AS `b` too. The predicate-identifier check fires on the
    # sibling-alias set BEFORE outer-scope lookup, so the user gets
    # the multi-object-consistency diagnostic — not a successful
    # compile against the outer `b` (which would be wrong) or a
    # generic "undefined variable" error (which would be confusing).
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          outer_a = Counter{ value: 5 };
          b = 99_i64;
          c = Counter{ value: 3 };
          WITH BORROWED outer_a AS a, BORROWED c AS b GUARD a.value > b.value {
            v = a.value;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError,
      /sibling alias bound by the same WITH.*Multi-object consistency for aliased objects is not supported/m)
  end

  it "keeps mutation-only universal polymorphic WITH on the non-flow helper" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN bump(MUTABLE c: Counter) RETURNS !Void ->
        WITH POLYMORPHIC c AS y {
          y.value = y.value + 1;
        }
        RETURN;
      END
    CLEAR

    expect(zig).to include("CheatLib.polymorphicMutate(")
    expect(zig).not_to include("CheatLib.polymorphicMutateFlow(")
  end

  # ============================================================
  # Annotated examples for `clear explain` / LSP hover.
  # ============================================================

  # @example_for: WITH_GUARD_NOT_WITH_MATCH
  # @fix: WITH MATCH dispatches per sync-family arm; WITH GUARD evaluates
  # @fix: a single predicate after acquire. They aren't integrated yet.
  # @fix: Move the predicate into a regular IF inside each arm body, or
  # @fix: split the polymorphic dispatch and guarded acquire into two
  # @fix: separate WITH blocks.
  describe ":WITH_GUARD_NOT_WITH_MATCH — combining GUARD with MATCH" do
    it "raises when a GUARD clause is attached to WITH ... MATCH" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN poke(c: Counter) RETURNS Void
            REQUIRES c: LOCKED
          ->
            WITH c AS x GUARD x.value > 0 MATCH
              WHEN LOCKED -> { v = x.value; }
            END
          END
        CLEAR
      }.to raise_error(CompilerError, /WITH GUARD is not supported with WITH MATCH/)
    end

    it "compiles when GUARD is dropped (the body checks the predicate itself)" do
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN poke(c: Counter) RETURNS Void
          REQUIRES c: LOCKED
        ->
          WITH c AS x MATCH
            WHEN LOCKED -> { v = x.value; }
          END
        END
      CLEAR
    end
  end

  # @example_for: WITH_GUARD_ALL_BINDINGS_NEED_AS
  # @fix: WITH GUARD's predicate runs against unwrapped values via the
  # @fix: AS alias. Add `AS <name>` to every binding in the WITH clause
  # @fix: so the predicate has something to reference.
  describe ":WITH_GUARD_ALL_BINDINGS_NEED_AS — missing AS on a guarded binding" do
    it "raises when a guarded WITH has another binding without AS" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            a = Counter{ value: 1 } @shared:locked;
            b = Counter{ value: 1 } @shared:locked;
            WITH EXCLUSIVE a AS x GUARD x.value > 0,
                 EXCLUSIVE b {
              v = x.value;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /WITH GUARD requires every participating binding/)
    end

    it "compiles when every binding carries an AS alias" do
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          a = Counter{ value: 1 } @shared:locked;
          b = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE a AS x GUARD x.value > 0,
               EXCLUSIVE b AS y GUARD y.value > 0 {
            v = x.value + y.value;
          }
          RETURN;
        END
      CLEAR
    end
  end

  # @example_for: WITH_GUARD_EXPR_MUST_BE_BOOL
  # @fix: GUARD predicates gate body execution: TRUE proceeds, FALSE
  # @fix: raises GuardFail. Wrap the expression in a comparison or Bool
  # @fix: method so it has a defined truth value.
  describe ":WITH_GUARD_EXPR_MUST_BE_BOOL — non-Bool guard expression" do
    it "raises when the GUARD predicate isn't Bool" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            c = Counter{ value: 1 } @shared:locked;
            WITH EXCLUSIVE c AS x GUARD x.value {
              v = x.value;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /GUARD expression must return Bool/)
    end

    it "compiles when the GUARD predicate is Bool-typed" do
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE c AS x GUARD x.value > 0 {
            v = x.value;
          }
          RETURN;
        END
      CLEAR
    end
  end

  # @example_for: WITH_GUARD_MUTABLE_MUTATED
  # @fix: GUARD predicates evaluate ONCE on acquire. Mutating a MUTABLE
  # @fix: alias inside the body would let the value drift past the
  # @fix: predicate without a re-check. Drop MUTABLE from the alias if
  # @fix: you only need to read, drop the body's mutation, or move the
  # @fix: write outside the guarded WITH.
  describe ":WITH_GUARD_MUTABLE_MUTATED — guarded MUTABLE alias mutated in body" do
    it "raises when a MUTABLE guarded alias is mutated inside the body" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            c = Counter{ value: 1 } @shared:locked;
            WITH EXCLUSIVE c AS MUTABLE y GUARD y.value > 0 {
              y.value = 2;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /declared MUTABLE and mutated/)
    end

    it "compiles when the guarded alias is NOT MUTABLE" do
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE c AS y GUARD y.value > 0 {
            v = y.value;
          }
          RETURN;
        END
      CLEAR
    end
  end
end
