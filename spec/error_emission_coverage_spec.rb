require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"
require_relative "../src/ast/diagnostic_registry"

# Coverage spec for error sites added/touched by the error-audit branch.
#
# Each user-facing error code gets a `describe` block annotated with
# `@example_for:` and `@fix:` lines, plus two `it` blocks: one BAD
# example proving the error fires, one GOOD example proving the fix
# compiles. `clear explain CODE` parses these files and surfaces the
# pair as the canonical example/fix.
#
# The annotation is a comment block immediately above the `describe`:
#
#   # @example_for: CODE_NAME
#   # @fix: short prose explaining what to change.
#   describe ":CODE_NAME — short label" do
#     it "raises when ..." do
#       expect { run(<<~CLEAR) }.to raise_error(...)
#         <bad source>
#       CLEAR
#     end
#
#     it "compiles when ..." do
#       run(<<~CLEAR)
#         <good source>
#       CLEAR
#     end
#   end
#
# Specs that test internal helpers (no user-facing CLEAR) skip the
# annotation and stay regular RSpec.
RSpec.describe "error emission coverage" do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  # ============================================================
  # Internal helpers (no annotation — not user-facing CLEAR errors).
  # ============================================================

  describe "ErrorHelper#format_diagnostic_template" do
    let(:dummy) do
      Class.new do
        include ErrorHelper
        attr_reader :source_code
        def initialize; @source_code = ""; end
        public :format_diagnostic_template
      end.new
    end

    it "embeds Internal Args Error when kwargs miss a %{name} key" do
      out = dummy.format_diagnostic_template("Hello %{name}", [], {})
      expect(out).to include("Internal Args Error")
      expect(out).to include("kwargs=")
    end

    it "uses positional template % args when no kwargs and no %{name}" do
      out = dummy.format_diagnostic_template("Hello %s", ["world"], {})
      expect(out).to eq("Hello world")
    end

    it "embeds Internal Args Error when positional args mismatch" do
      out = dummy.format_diagnostic_template("Hello %s and %s", ["world"], {})
      expect(out).to include("Internal Args Error")
    end
  end

  it "raises INT_LITERAL_OVERFLOW from the TypeHelper fallback path" do
    # The fallback at type.rb:2098 only fires when the host class
    # doesn't mix in fixable_helpers. Real callers always do; this
    # test exercises the dead defensive path via a mock host.
    stub_const("FallbackHost", Class.new do
      include ErrorHelper
      include TypeHelper
      attr_reader :source_code
      def initialize; @source_code = ""; end
    end)
    host = FallbackHost.new

    tok = Struct.new(:line, :column, :value, :type, keyword_init: true).new(
      line: 1, column: 1, value: "999", type: :INT64
    )
    node = AST::Literal.new(tok, :INT64, 999)
    type_obj = Type.new(:Int8)

    expect {
      host.check_prefixed_int_range!(node, type_obj)
    }.to raise_error(CompilerError, /overflows/)
  end

  # ============================================================
  # User-facing error codes (annotated for `clear explain`).
  # ============================================================

  # @example_for: ENUM_UNKNOWN_VARIANT
  # @fix: Use one of the variants declared on the enum, or add the
  # @fix: missing variant to the ENUM declaration.
  describe ":ENUM_UNKNOWN_VARIANT — accessing a variant that doesn't exist" do
    it "raises when the variant name is misspelled" do
      expect {
        run(<<~CLEAR)
          ENUM Color { Red, Green, Blue }
          FN main() RETURNS Void ->
            c: Color = Color.Yellow;
          END
        CLEAR
      }.to raise_error(CompilerError, /Enum 'Color' has no variant/)
    end

    it "compiles when the variant exists on the enum" do
      run(<<~CLEAR)
        ENUM Color { Red, Green, Blue }
        FN main() RETURNS Void ->
          c: Color = Color.Red;
        END
      CLEAR
    end
  end

  # @example_for: SOA_NEEDS_FIXED_ARRAY
  # @fix: Give the @soa array a fixed capacity (`T[N]@soa`). SOA
  # @fix: storage allocates per-field arrays and needs to know N up front.
  describe ":SOA_NEEDS_FIXED_ARRAY — @soa on a dynamic array" do
    it "raises when @soa is on T[]" do
      expect {
        run(<<~CLEAR)
          STRUCT Particle { x: Float64, y: Float64 }
          FN main() RETURNS Void ->
            ps: Particle[]@soa = [];
          END
        CLEAR
      }.to raise_error(CompilerError, /@soa requires a fixed-size array/)
    end

    it "compiles when @soa is on T[N]" do
      run(<<~CLEAR)
        STRUCT Particle { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
          ps: Particle[100]@soa = [];
        END
      CLEAR
    end
  end

  # @example_for: POOL_NEEDS_FIXED_CAPACITY
  # @fix: Give the @pool a fixed capacity (`T[N]@pool`). Pools
  # @fix: pre-allocate slots and need to know N up front.
  describe ":POOL_NEEDS_FIXED_CAPACITY — @pool with no capacity" do
    it "raises when @pool is on T[]" do
      expect {
        run(<<~CLEAR)
          STRUCT Item { v: Int64 }
          FN main() RETURNS Void ->
            xs: Item[]@pool = [];
          END
        CLEAR
      }.to raise_error(CompilerError, /Pool requires a fixed capacity/)
    end

    it "compiles when @pool is on T[N]" do
      run(<<~CLEAR)
        STRUCT Item { v: Int64 }
        FN main() RETURNS Void ->
          xs: Item[64]@pool = [];
        END
      CLEAR
    end
  end

  # @example_for: COLLECTION_NEEDS_ARRAY_TYPE
  # @fix: @list / @pool / @set must annotate an array type — a
  # @fix: scalar binding can't be a collection. Either make the
  # @fix: type an array or drop the collection sigil.
  describe ":COLLECTION_NEEDS_ARRAY_TYPE — @set on a non-array" do
    it "raises when @set is applied to a scalar" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            x: Int64@set = 0;
          END
        CLEAR
      }.to raise_error(StandardError, /@set requires an array type|@set/)
    end

    it "compiles when @set is applied to an array of strings" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
          xs: String[]@set = [];
        END
      CLEAR
    end
  end

  # @example_for: WITH_RESTRICT_NEEDS_MUTABLE
  # @fix: RESTRICT establishes an exclusive mutable borrow. Declare
  # @fix: the binding `MUTABLE` so it has something to RESTRICT.
  describe ":WITH_RESTRICT_NEEDS_MUTABLE — RESTRICT on an immutable" do
    it "raises when RESTRICTing an immutable binding" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            x = 5;
            WITH RESTRICT x { _ = x; }
          END
        CLEAR
      }.to raise_error(CompilerError, /RESTRICT.*[Mm]utable/)
    end

    it "compiles when the binding is MUTABLE" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x = 5;
          WITH RESTRICT x { _ = x; }
        END
      CLEAR
    end
  end

  # ============================================================
  # Tranche 9.1 — type-shape errors (union, function, capture)
  # ============================================================

  # @example_for: UNION_TYPE_UNKNOWN
  # @fix: Either declare the union with a UNION block at module scope,
  # @fix: or change the literal's prefix to a type that exists.
  describe ":UNION_TYPE_UNKNOWN — variant literal naming an undeclared union" do
    it "raises when the union name doesn't resolve to anything" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            x = Nope.Variant{ field: 1 };
          END
        CLEAR
      }.to raise_error(CompilerError, /Unknown (union|type)/)
    end

    it "compiles when the union is declared" do
      run(<<~CLEAR)
        UNION Result { Ok { field: Int64 }, Empty }
        FN main() RETURNS Void ->
          x = Result.Ok{ field: 1 };
        END
      CLEAR
    end
  end

  # @example_for: NOT_A_UNION_TYPE
  # @fix: The variant-literal syntax `Type.Variant{...}` is for unions.
  # @fix: For structs, drop the `.Variant` and use plain `Type{...}`.
  describe ":NOT_A_UNION_TYPE — variant literal on a struct type" do
    it "raises when the type is a struct, not a union" do
      expect {
        run(<<~CLEAR)
          STRUCT Point { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
            p = Point.A{ field: 1 };
          END
        CLEAR
      }.to raise_error(CompilerError, /(not a union|no field|no variant)/)
    end

    it "compiles when the construction matches the type's kind" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
          p = Point{ x: 1, y: 2 };
        END
      CLEAR
    end
  end

  # @example_for: UNION_UNKNOWN_VARIANT
  # @fix: Use one of the variants declared on the union, or add the
  # @fix: missing variant to the UNION declaration.
  describe ":UNION_UNKNOWN_VARIANT — accessing a variant the union doesn't declare" do
    it "raises when the variant name is misspelled" do
      expect {
        run(<<~CLEAR)
          UNION Result { Ok: Int64, Err: Int64, Empty }
          FN main() RETURNS Void ->
            r: Result = Result.Bogus;
          END
        CLEAR
      }.to raise_error(CompilerError, /Union 'Result' has no variant/)
    end

    it "compiles when the variant exists" do
      run(<<~CLEAR)
        UNION Result { Ok: Int64, Err: Int64, Empty }
        FN main() RETURNS Void ->
          r: Result = Result.Empty;
        END
      CLEAR
    end
  end

  # @example_for: AMBIGUOUS_RETURN
  # @fix: Either unify the branches' types (CAST one side, or change
  # @fix: the function's logic so every RETURN produces the same type),
  # @fix: or declare the return type as `:Any` to opt into runtime
  # @fix: discrimination.
  describe ":AMBIGUOUS_RETURN — function returns differently-typed values" do
    it "raises when RETURN branches produce incompatible types" do
      expect {
        run(<<~CLEAR)
          FN classify(n: Int64) ->
            IF n > 0 THEN
              RETURN n;
            ELSE
              RETURN "negative";
            END
          END
          FN main() RETURNS Void ->
            _ = classify(1);
          END
        CLEAR
      }.to raise_error(CompilerError, /Ambiguous Return|multiple types/)
    end

    it "compiles when every RETURN produces the same type" do
      run(<<~CLEAR)
        FN classify(n: Int64) RETURNS Int64 ->
          IF n > 0 THEN
            RETURN n;
          ELSE
            RETURN 0 - n;
          END
        END
        FN main() RETURNS Void ->
          _ = classify(1);
        END
      CLEAR
    end
  end

  # @example_for: CAPTURE_NO_DEFAULT
  # @fix: Drop the `=value` from the capture. Captures inherit their
  # @fix: value from the enclosing scope; a default would have nothing
  # @fix: to apply against.
  describe ":CAPTURE_NO_DEFAULT — capture list entry with a default value" do
    it "raises when a USE() entry has `=value`" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            x = 10;
            FN getter() USE(x = 5) RETURNS Int64 ->
              RETURN x;
            END
          END
        CLEAR
      }.to raise_error(CompilerError, /Captures cannot have default/)
    end

    it "compiles when USE() captures the binding without a default" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 10;
          FN getter() USE(x) RETURNS Int64 ->
            RETURN x;
          END
        END
      CLEAR
    end
  end

  # @example_for: CAPTURE_UNDEFINED_VAR
  # @fix: Either declare the captured name in an enclosing scope, or
  # @fix: remove it from the USE() list if it isn't actually needed.
  describe ":CAPTURE_UNDEFINED_VAR — USE() captures a name that doesn't exist" do
    it "raises when the captured name isn't declared in any enclosing scope" do
      expect {
        run(<<~CLEAR)
          FN ghost() USE(missing) RETURNS Int64 ->
            RETURN 1;
          END
        CLEAR
      }.to raise_error(CompilerError, /capture undefined/i)
    end

    it "compiles when the captured name resolves to a real binding" do
      run(<<~CLEAR)
        x = 5;
        FN ghost() USE(x) RETURNS Int64 ->
          RETURN x;
        END
      CLEAR
    end
  end

  # @example_for: CAPTURE_IMMUTABLE_AS_MUTABLE
  # @fix: Either declare the captured binding `MUTABLE`, or drop the
  # @fix: `MUTABLE` qualifier from the capture if you only need to
  # @fix: read the value.
  describe ":CAPTURE_IMMUTABLE_AS_MUTABLE — USE(MUTABLE x) on an immutable" do
    it "raises when the captured binding is immutable" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            x = 5;
            FN g() USE(MUTABLE x) RETURNS Int64 -> RETURN x; END
          END
        CLEAR
      }.to raise_error(CompilerError, /capture immutable.*MUTABLE/i)
    end

    it "compiles when the captured binding is MUTABLE" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x = 5;
          FN g() USE(MUTABLE x) RETURNS Int64 -> RETURN x; END
        END
      CLEAR
    end
  end

  # ============================================================
  # Tranche 9.2 — capability / WITH-block / reentrance errors
  # ============================================================

  # @example_for: TIGHT_CALLS_REENTRANT_FN
  # @fix: Either remove TIGHT from the loop (so the scheduler can
  # @fix: handle the recursive call's stack), or refactor the body
  # @fix: to avoid calling the @reentrant function inline.
  describe ":TIGHT_CALLS_REENTRANT_FN — TIGHT loop body calls a recursive fn" do
    it "raises when a TIGHT WHILE body calls an @reentrant function" do
      expect {
        run(<<~CLEAR)
          FN fib(n: Int64) RETURNS Int64 @reentrant ->
            IF n <= 1 THEN RETURN n; END
            RETURN fib(n - 1) + fib(n - 2);
          END

          FN main() RETURNS Void ->
            MUTABLE i: Int64 = 0;
            MUTABLE acc: Int64 = 0;
            TIGHT WHILE i < 3 DO
              acc += fib(i);
              i += 1;
            END
          END
        CLEAR
      }.to raise_error(CompilerError, /TIGHT loop cannot call @reentrant/)
    end

    it "compiles when the call lives outside the TIGHT loop body" do
      run(<<~CLEAR)
        FN fib(n: Int64) RETURNS Int64 @reentrant ->
          IF n <= 1 THEN RETURN n; END
          RETURN fib(n - 1) + fib(n - 2);
        END

        FN main() RETURNS Void ->
          MUTABLE i: Int64 = 0;
          TIGHT WHILE i < 3 DO i += 1; END
          _ = fib(i);
        END
      CLEAR
    end
  end

  # @example_for: BORROW_WILDCARD_NEEDS_STRUCT
  # @fix: Wildcard borrow `foo.*` borrows every field of a struct.
  # @fix: Use it on a struct-typed binding, or borrow the value
  # @fix: directly with `WITH BORROWED foo`.
  describe ":BORROW_WILDCARD_NEEDS_STRUCT — wildcard borrow on a non-struct" do
    it "raises when the target of foo.* isn't a struct" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            x: Int64 = 5;
            WITH BORROWED x.* { _ = x; }
          END
        CLEAR
      }.to raise_error(CompilerError, /Wildcard borrow.*requires a struct/)
    end

    it "compiles when the target is a struct" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
          p = Point{ x: 1, y: 2 };
          WITH BORROWED p.* { _ = p.x; }
        END
      CLEAR
    end
  end

  # ============================================================
  # Tranche 9.5 — parser sigil / visibility / extern errors
  # ============================================================

  # @example_for: VISIBILITY_BAD_KIND
  # @fix: Visibility modifiers (PUB / PRIVATE) only apply to FN,
  # @fix: METHOD, STRUCT, ENUM, or UNION declarations. For value
  # @fix: bindings, drop the modifier — top-level visibility for
  # @fix: variables isn't supported.
  describe ":VISIBILITY_BAD_KIND — PUB on a non-declaration" do
    it "raises when PUB precedes MUTABLE" do
      expect {
        run(<<~CLEAR)
          PUB MUTABLE x = 5;
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(ParserError, /visibility modifier/)
    end

    it "compiles when PUB precedes a real declaration" do
      run(<<~CLEAR)
        PUB FN greet() RETURNS Void -> END
        FN main() RETURNS Void -> END
      CLEAR
    end
  end

  # @example_for: EXTERN_BAD_KIND
  # @fix: EXTERN only declares native FN or STRUCT bindings (the
  # @fix: kinds with a stable C ABI). Drop the EXTERN keyword for
  # @fix: anything else.
  describe ":EXTERN_BAD_KIND — EXTERN on a non-FN/STRUCT" do
    it "raises when EXTERN precedes MUTABLE" do
      expect {
        run(<<~CLEAR)
          EXTERN MUTABLE x = 5;
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(ParserError, /Expected FN or STRUCT after EXTERN/)
    end

    it "compiles when EXTERN precedes a function declaration" do
      run(<<~CLEAR)
        EXTERN FN sin(x: Float64) RETURNS Float64 FROM "math";
        FN main() RETURNS Void -> _ = sin(0.5); END
      CLEAR
    end
  end

  # @example_for: UNKNOWN_EFFECT
  # @fix: Function-level EFFECTS only accepts REENTRANT (with
  # @fix: optional :THUNK / :NOT_LOGICAL / :MAX_DEPTH(N) / :TAIL_CALL
  # @fix: variants). Other effect kinds are inferred per-function;
  # @fix: don't list them on the signature.
  describe ":UNKNOWN_EFFECT — non-REENTRANT effect on a fn signature" do
    it "raises when EFFECTS names something other than REENTRANT" do
      expect {
        run(<<~CLEAR)
          FN doIt() RETURNS Void EFFECTS BOGUS_KIND -> END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(ParserError, /Unknown effect/)
    end

    it "compiles when EFFECTS names REENTRANT" do
      run(<<~CLEAR)
        FN fib(n: Int64) RETURNS Int64 EFFECTS REENTRANT:THUNK ->
          IF n <= 1 -> RETURN n;
          RETURN fib(n - 1);
        END
        FN main() RETURNS Void -> _ = fib(3); END
      CLEAR
    end
  end

  # @example_for: UNKNOWN_REQUIRES_FAMILY
  # @fix: REQUIRES clauses constrain a parameter to a sync family —
  # @fix: LOCKED, SNAPSHOTTED, VERSIONED, ATOMIC, LOCAL, ACTOR — or a
  # @fix: reentrance kind (REENTRANT / NON_REENTRANT). Pick one.
  describe ":UNKNOWN_REQUIRES_FAMILY — REQUIRES with an unrecognised family" do
    it "raises when the REQUIRES family isn't known" do
      expect {
        run(<<~CLEAR)
          FN f(x: Int64) RETURNS Void
            REQUIRES x: BOGUS
          -> END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(ParserError, /Unknown REQUIRES family/)
    end

    it "compiles when the REQUIRES family is valid" do
      run(<<~CLEAR)
        FN f(x: Int64) RETURNS Void
          REQUIRES x: LOCAL
        -> END
        FN main() RETURNS Void -> END
      CLEAR
    end
  end

  # @example_for: DUPLICATE_SYNC_CAP
  # @fix: A type's sync axis takes one capability — pick @locked OR
  # @fix: @writeLocked OR @atomic OR @versioned, not multiple. The
  # @fix: capability chain `@a:b` is only for combining different
  # @fix: axes (e.g. @shared:locked = ownership + sync).
  describe ":DUPLICATE_SYNC_CAP — two sync capabilities on one type" do
    it "raises when both sync caps appear in a chain" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            x: Int64@locked:writeLocked = 0;
            _ = x;
          END
        CLEAR
      }.to raise_error(ParserError, /Duplicate sync/)
    end

    it "compiles when only one sync cap is named" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
          x: Int64@shared:locked = 0;
          _ = x;
        END
      CLEAR
    end
  end

  # @example_for: UNKNOWN_CAPABILITY_MODIFIER
  # @fix: Capability chains use a closed set of axis modifiers
  # @fix: (locked, writeLocked, atomic, versioned, observable, ...).
  # @fix: A typo or invented name doesn't bind to any axis.
  describe ":UNKNOWN_CAPABILITY_MODIFIER — unrecognised modifier in @cap chain" do
    it "raises when an @cap chain names an unknown modifier" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            x: Int64@shared:bogus = 0;
            _ = x;
          END
        CLEAR
      }.to raise_error(ParserError, /Unknown capability modifier/)
    end

    it "compiles when every modifier in the chain is valid" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
          x: Int64@shared:locked = 0;
          _ = x;
        END
      CLEAR
    end
  end

  # @example_for: SHARDED_TOO_FEW
  # @fix: @sharded(N) splits a collection into N independently-locked
  # @fix: shards; with N < 2 there's nothing to shard. Use @sharded(2)
  # @fix: or higher, or pick a different sync capability.
  describe ":SHARDED_TOO_FEW — @sharded(N) with N < 2" do
    it "raises when @sharded is given 1" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            xs: Int64[]@sharded(1) = [];
            _ = xs;
          END
        CLEAR
      }.to raise_error(CompilerError, /@sharded requires N >= 2/)
    end

    it "compiles when @sharded is given a valid count" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
          xs: Int64[]@sharded(4) = [];
          _ = xs;
        END
      CLEAR
    end
  end

  # ============================================================
  # Tranche 9.4 — pipeline operators
  # ============================================================

  # @example_for: WHERE_NEEDS_BOOL
  # @fix: WHERE filters items by a Bool predicate. Make the body
  # @fix: return Bool — use a comparison, `MOD` test, equality check,
  # @fix: etc. — instead of a value transform (use SELECT for that).
  describe ":WHERE_NEEDS_BOOL — WHERE clause body doesn't return Bool" do
    it "raises when the WHERE body produces a non-Bool" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            xs: Float64[] = [1.0, 2.0, 3.0];
            r = xs |> WHERE _ + 1.0;
            _ = r;
          END
        CLEAR
      }.to raise_error(CompilerError, /WHERE.*Bool|Bool.*WHERE/i)
    end

    it "compiles when the WHERE body returns Bool" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
          xs: Float64[] = [1.0, 2.0, 3.0, 4.0];
          r = xs |> WHERE _ > 2.0;
          _ = r;
        END
      CLEAR
    end
  end

  # @example_for: LIMIT_COUNT_NEEDS_NUMBER
  # @fix: LIMIT takes an integer count. Pass an Int64 literal or a
  # @fix: numeric expression instead of a string / other type.
  describe ":LIMIT_COUNT_NEEDS_NUMBER — non-numeric LIMIT count" do
    it "raises when LIMIT is given a non-numeric value" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            xs: Float64[] = [1.0, 2.0, 3.0];
            r = xs |> LIMIT "three";
            _ = r;
          END
        CLEAR
      }.to raise_error(CompilerError, /LIMIT.*[Nn]umber/)
    end

    it "compiles when LIMIT is given a number" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
          xs: Float64[] = [1.0, 2.0, 3.0];
          r = xs |> LIMIT 2;
          _ = r;
        END
      CLEAR
    end
  end

  # @example_for: SKIP_COUNT_NEEDS_NUMBER
  # @fix: SKIP takes an integer count. Pass an Int64 literal or
  # @fix: numeric expression.
  describe ":SKIP_COUNT_NEEDS_NUMBER — non-numeric SKIP count" do
    it "raises when SKIP is given a non-numeric value" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            xs: Float64[] = [1.0, 2.0, 3.0];
            r = xs |> SKIP "two";
            _ = r;
          END
        CLEAR
      }.to raise_error(CompilerError, /SKIP.*[Nn]umber/)
    end

    it "compiles when SKIP is given a number" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
          xs: Float64[] = [1.0, 2.0, 3.0];
          r = xs |> SKIP 1;
          _ = r;
        END
      CLEAR
    end
  end

  # @example_for: PIPE_NOT_CALLABLE
  # @fix: The right-hand side of `|>` must be a callable — a function
  # @fix: name, a pipe stage (WHERE/SELECT/...), or a lambda. Passing
  # @fix: a value binding has no defined pipe semantics.
  describe ":PIPE_NOT_CALLABLE — piping into a non-callable name" do
    it "raises when the pipeline target is a value binding" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            xs: Float64[] = [1.0, 2.0];
            notfn = 5;
            r = xs |> notfn;
            _ = r;
          END
        CLEAR
      }.to raise_error(CompilerError, /pipe into non-callable/)
    end

    it "compiles when the pipeline target is a function" do
      run(<<~CLEAR)
        FN total(xs: Float64[]) RETURNS Float64 ->
          MUTABLE s: Float64 = 0.0;
          MUTABLE i: Int64 = 0;
          WHILE i < xs.length() DO
            s += xs[i];
            i += 1;
          END
          RETURN s;
        END
        FN main() RETURNS Void ->
          xs: Float64[] = [1.0, 2.0];
          r = xs |> total;
          _ = r;
        END
      CLEAR
    end
  end

  # @example_for: JOIN_LAMBDA_NEEDS_BOOL
  # @fix: The JOIN predicate must return Bool — a comparison or
  # @fix: equality test that decides whether two rows match. A
  # @fix: non-Bool result has no defined semantics for matching.
  describe ":JOIN_LAMBDA_NEEDS_BOOL — JOIN predicate doesn't return Bool" do
    it "raises when the JOIN lambda body produces a non-Bool" do
      expect {
        run(<<~CLEAR)
          STRUCT User { id: Int64, name: String }
          STRUCT Order { userId: Int64, total: Float64 }
          FN main() RETURNS Void ->
            users: User[] = [User{ id: 1, name: "a" }];
            orders: Order[] = [Order{ userId: 1, total: 9.0 }];
            joined = users |> JOIN(orders) %(u, o) -> u.id;
            _ = joined;
          END
        CLEAR
      }.to raise_error(CompilerError, /JOIN.*Bool|Bool.*JOIN/i)
    end

    it "compiles when the JOIN lambda returns Bool" do
      run(<<~CLEAR)
        STRUCT User { id: Int64, name: String }
        STRUCT Order { userId: Int64, total: Float64 }
        FN main() RETURNS Void ->
          users: User[] = [User{ id: 1, name: "a" }];
          orders: Order[] = [Order{ userId: 1, total: 9.0 }];
          joined = users |> JOIN(orders) %(u, o) -> u.id == o.userId;
          _ = joined;
        END
      CLEAR
    end
  end

  # ============================================================
  # Tranche 9.3 — lifetime / borrow tracking
  # ============================================================

  # @example_for: MUTABLE_ARG_RESTRICTED
  # @fix: End the RESTRICT block (close the WITH) before calling the
  # @fix: function that needs mutable access. RESTRICT establishes an
  # @fix: exclusive borrow; while it's live, the binding can't be
  # @fix: passed to MUTABLE parameters elsewhere.
  describe ":MUTABLE_ARG_RESTRICTED — passing a RESTRICTed binding as MUTABLE" do
    it "raises when a RESTRICTed binding is passed to a MUTABLE param" do
      expect {
        run(<<~CLEAR)
          FN inc!(MUTABLE x: Int64) -> x += 1; END
          FN main() RETURNS Void ->
            MUTABLE n: Int64 = 5;
            WITH RESTRICT n {
              inc!(n);
            }
          END
        CLEAR
      }.to raise_error(CompilerError, /currently RESTRICTed/)
    end

    it "compiles when the call is outside the RESTRICT block" do
      run(<<~CLEAR)
        FN inc!(MUTABLE x: Int64) -> x += 1; END
        FN main() RETURNS Void ->
          MUTABLE n: Int64 = 5;
          inc!(n);
        END
      CLEAR
    end
  end

  # @example_for: LIFETIME_ROOT_NOT_PARAM
  # @fix: The lifetime root in `RETURNS name:T` must name a parameter.
  # @fix: Either rename to an actual parameter, or drop the lifetime
  # @fix: annotation if the return doesn't borrow from any parameter.
  describe ":LIFETIME_ROOT_NOT_PARAM — RETURNS lifetime references unknown name" do
    it "raises when the named root isn't a parameter" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS notaparam:Int64 ->
            RETURN 5;
          END
          FN main() RETURNS Void -> _ = f(); END
        CLEAR
      }.to raise_error(CompilerError, /Scoped lifetime.*not a parameter/)
    end

    it "compiles when the lifetime root names an actual parameter" do
      run(<<~CLEAR)
        FN identity(n: Int64) RETURNS n:Int64 ->
          RETURN n;
        END
        FN main() RETURNS Void -> _ = identity(5); END
      CLEAR
    end
  end

  # @example_for: LIFETIME_NOT_A_STRUCT
  # @fix: Field-path lifetime annotations like `RETURNS x.field:T`
  # @fix: only make sense when `x` is struct-typed. Either change the
  # @fix: parameter to a struct, or drop the `.field` from the
  # @fix: lifetime annotation.
  describe ":LIFETIME_NOT_A_STRUCT — lifetime path drills into non-struct type" do
    it "raises when the path traverses a non-struct parameter" do
      expect {
        run(<<~CLEAR)
          FN f(x: Int64) RETURNS x.field:Int64 ->
            RETURN x;
          END
          FN main() RETURNS Void -> _ = f(5); END
        CLEAR
      }.to raise_error(CompilerError, /Type 'Int64' is not a struct/)
    end

    it "compiles when the path's root is a struct" do
      run(<<~CLEAR)
        STRUCT Box { val: Int64 }
        FN f(b: Box) RETURNS b.val:Int64 ->
          RETURN b.val;
        END
        FN main() RETURNS Void ->
          b = Box{ val: 5 };
          _ = f(b);
        END
      CLEAR
    end
  end

  # @example_for: LIFETIME_NO_FIELD
  # @fix: The named field must exist on the struct. Either fix the
  # @fix: spelling, add the field to the STRUCT declaration, or
  # @fix: change the lifetime annotation to a real field.
  describe ":LIFETIME_NO_FIELD — lifetime path references a missing field" do
    it "raises when the field isn't declared on the struct" do
      expect {
        run(<<~CLEAR)
          STRUCT Point { x: Int64, y: Int64 }
          FN f(p: Point) RETURNS p.z:Int64 ->
            RETURN p.x;
          END
          FN main() RETURNS Void ->
            p = Point{ x: 1, y: 2 };
            _ = f(p);
          END
        CLEAR
      }.to raise_error(CompilerError, /Type 'Point' has no field 'z'/)
    end

    it "compiles when the field exists" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN f(p: Point) RETURNS p.x:Int64 ->
          RETURN p.x;
        END
        FN main() RETURNS Void ->
          p = Point{ x: 1, y: 2 };
          _ = f(p);
        END
      CLEAR
    end
  end

  # @example_for: REENTRANCY_MUTUAL_CYCLE
  # @fix: Pick one: declare `@reentrant` on every cycle member (the
  # @fix: spawn site must run on `@service` / OS thread), or change
  # @fix: each fn to a bounded variant — `EFFECTS REENTRANT:THUNK`,
  # @fix: `:NOT_LOGICAL`, or `:MAX_DEPTH(N)`.
  describe ":REENTRANCY_MUTUAL_CYCLE — mutually recursive fns without annotation" do
    it "raises when two functions call each other and neither carries @reentrant" do
      expect {
        run(<<~CLEAR)
          FN ping(n: Int64) RETURNS Int64 ->
            IF n <= 0 THEN RETURN 0; END
            RETURN pong(n - 1);
          END

          FN pong(n: Int64) RETURNS Int64 ->
            IF n <= 0 THEN RETURN 0; END
            RETURN ping(n - 1);
          END

          FN main() RETURNS Void ->
            _ = ping(5);
          END
        CLEAR
      }.to raise_error(CompilerError, /Reentrancy|mutually recursive/)
    end

    it "compiles when both cycle members declare REENTRANT:THUNK" do
      run(<<~CLEAR)
        FN ping(n: Int64) RETURNS Bool
          EFFECTS REENTRANT:THUNK ->
          IF n <= 0 -> RETURN TRUE;
          RETURN pong(n - 1);
        END

        FN pong(n: Int64) RETURNS Bool
          EFFECTS REENTRANT:THUNK ->
          IF n <= 0 -> RETURN FALSE;
          RETURN ping(n - 1);
        END

        FN main() RETURNS Void ->
          _ = ping(5);
        END
      CLEAR
    end
  end
end
