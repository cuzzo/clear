require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/diagnostic_registry" unless defined?(DiagnosticRegistry)
require_relative "../ruby/annotator/helpers/prefixed_int_range" unless defined?(PrefixedIntRange)

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
    ast = ClearParser.new(tokens, source).parse
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
      expect(out).to include("{}")
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
      include PrefixedIntRange
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
  # @fix: to avoid calling the plain EFFECTS REENTRANT function inline.
  describe ":TIGHT_CALLS_REENTRANT_FN — TIGHT loop body calls a recursive fn" do
    it "raises when a TIGHT WHILE body calls a plain EFFECTS REENTRANT function" do
      expect {
        run(<<~CLEAR)
          FN fib(n: Int64) RETURNS Int64 EFFECTS REENTRANT ->
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
      }.to raise_error(CompilerError, /TIGHT loop cannot call plain EFFECTS REENTRANT/)
    end

    it "compiles when the call lives outside the TIGHT loop body" do
      run(<<~CLEAR)
        FN fib(n: Int64) RETURNS Int64 EFFECTS REENTRANT ->
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

    it "compiles a :TAIL_CALL reentrant call inside a TIGHT WHILE body" do
      run(<<~CLEAR)
        FN sumTo(n: Int64, acc: Int64) RETURNS Int64 EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 THEN RETURN acc; END
          RETURN sumTo(n - 1, acc + n);
        END

        FN main() RETURNS Void ->
          MUTABLE i: Int64 = 0;
          MUTABLE total: Int64 = 0;
          TIGHT WHILE i < 3 DO
            total += sumTo(5, 0);
            i += 1;
          END
        END
      CLEAR
    end

    it "compiles a :THUNK reentrant call inside a TIGHT WHILE body" do
      run(<<~CLEAR)
        FN fact(n: Int64) RETURNS Int64 EFFECTS REENTRANT:THUNK ->
          IF n <= 1 THEN RETURN 1; END
          RETURN n * fact(n - 1);
        END

        FN main() RETURNS Void ->
          MUTABLE i: Int64 = 0;
          MUTABLE acc: Int64 = 0;
          TIGHT WHILE i < 3 DO
            acc += fact(5);
            i += 1;
          END
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
      }.to raise_error(ParserError, /Unknown function effect/)
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
  # @fix: A type's sync axis takes one capability — pick @locked OR_ELSE
  # @fix: @writeLocked OR_ELSE @atomic OR_ELSE @versioned, not multiple. The
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
  # @fix: Pick one: declare `EFFECTS REENTRANT` on every cycle member (the
  # @fix: spawn site must run on `@service` / OS thread), or change
  # @fix: each fn to a bounded variant — `EFFECTS REENTRANT:THUNK`,
  # @fix: `:NOT_LOGICAL`, or `:MAX_DEPTH(N)`.
  describe ":REENTRANCY_MUTUAL_CYCLE — mutually recursive fns without annotation" do
    it "raises when two functions call each other and neither declares reentrance" do
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

  # ============================================================
  # Ownership: Immutable family (Batch 1).
  # ============================================================

  # @example_for: IMMUTABLE_ASSIGNMENT
  # @fix: CLEAR is immutable-by-default. Reassigning a binding requires
  # @fix: the original declaration to use `MUTABLE x = ...`. Add the
  # @fix: keyword at the binding's first declaration site.
  describe ":IMMUTABLE_ASSIGNMENT — reassigning an immutable local" do
    it "raises when a plain `x = ...` declaration is reassigned" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              x = 5;
              x = 10;
          END
        CLEAR
      }.to raise_error(CompilerError, /Variable 'x' is immutable/)
    end

    it "compiles when the binding is declared MUTABLE" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE x = 5;
            x = 10;
        END
      CLEAR
    end
  end

  # @example_for: ASSIGN_VAR_IMMUTABLE
  # @fix: Function parameters are immutable by default. To reassign
  # @fix: a parameter inside the body, declare it `MUTABLE p: T` at
  # @fix: the parameter site (and add `!` to the function name to
  # @fix: signal it takes a mutable parameter).
  describe ":ASSIGN_VAR_IMMUTABLE — reassigning an immutable parameter" do
    it "raises when a plain (non-MUTABLE) parameter is reassigned in the body" do
      expect {
        run(<<~CLEAR)
          FN bump(p: Int64) RETURNS Int64 ->
              p = p + 1;
              RETURN p;
          END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /Variable 'p' is immutable/)
    end

    it "compiles when the parameter is declared MUTABLE" do
      run(<<~CLEAR)
        FN bump!(MUTABLE p: Int64) RETURNS Int64 ->
            p = p + 1;
            RETURN p;
        END
        FN main() RETURNS Void ->
            MUTABLE n: Int64 = 0_i64;
            n = bump!(n);
        END
      CLEAR
    end
  end

  # @example_for: ASSIGN_INDEX_IMMUTABLE_LIST
  # @fix: Index assignment (`m[k] = v`) requires the collection to be
  # @fix: declared MUTABLE. Add the keyword to the binding's
  # @fix: declaration; the same applies to lists, hashmaps, and pools.
  describe ":ASSIGN_INDEX_IMMUTABLE_LIST — `m[k] = v` on an immutable collection" do
    it "raises when a non-MUTABLE HashMap is index-assigned" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              m: HashMap<Int64> = {};
              m["key"] = 5_i64;
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot modify index of immutable list 'm'/)
    end

    it "compiles when the collection is MUTABLE" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            m["key"] = 5_i64;
        END
      CLEAR
    end
  end

  # @example_for: IMMUTABLE_FIELD_ASSIGNMENT
  # @fix: Field assignment (`obj.field = v`) requires the struct
  # @fix: binding to be declared MUTABLE. Capability-wrapped bindings
  # @fix: like `@locked` / `@alwaysMutable` also permit field writes
  # @fix: through their unwrapping rules.
  describe ":IMMUTABLE_FIELD_ASSIGNMENT — `p.field = v` on an immutable struct" do
    it "raises when a non-MUTABLE struct's field is assigned" do
      expect {
        run(<<~CLEAR)
          STRUCT Point { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
              p = Point{x: 1, y: 2};
              p.x = 10;
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot modify field 'x' of immutable object 'p'/)
    end

    it "compiles when the struct binding is MUTABLE" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            MUTABLE p = Point{x: 1, y: 2};
            p.x = 10;
        END
      CLEAR
    end
  end

  # @example_for: IMMUTABLE_ARG_PASSED_AS_MUTABLE
  # @fix: A function with a `MUTABLE x: T` parameter mutates the
  # @fix: caller's binding through that parameter. The caller's
  # @fix: variable must therefore also be declared MUTABLE.
  describe ":IMMUTABLE_ARG_PASSED_AS_MUTABLE — passing immutable var to MUTABLE param" do
    it "raises when an immutable variable is passed to a MUTABLE parameter" do
      expect {
        run(<<~CLEAR)
          FN bump!(MUTABLE x: Int64) RETURNS Void -> x = x + 1; END
          FN main() RETURNS Void ->
              y = 5;
              bump!(y);
          END
        CLEAR
      }.to raise_error(CompilerError, /Argument 1.*MUTABLE.*passed immutable variable 'y'/)
    end

    it "compiles when the caller's variable is also MUTABLE" do
      run(<<~CLEAR)
        FN bump!(MUTABLE x: Int64) RETURNS Void -> x = x + 1; END
        FN main() RETURNS Void ->
            MUTABLE y = 5;
            bump!(y);
        END
      CLEAR
    end
  end

  # @example_for: IMMUTABLE_ARG_PASSED_AS_EXPRESSION
  # @fix: A `MUTABLE x: T` parameter takes a *binding* whose location
  # @fix: the callee will write through. Literals and expressions
  # @fix: have no location — bind the value to a MUTABLE variable
  # @fix: first, then pass the variable.
  describe ":IMMUTABLE_ARG_PASSED_AS_EXPRESSION — passing literal to MUTABLE param" do
    it "raises when a literal is passed to a MUTABLE parameter" do
      expect {
        run(<<~CLEAR)
          FN bump!(MUTABLE x: Int64) RETURNS Void -> x = x + 1; END
          FN main() RETURNS Void ->
              bump!(5);
          END
        CLEAR
      }.to raise_error(CompilerError, /Argument 1.*MUTABLE.*pass a Mutable Variable/)
    end

    it "compiles when the value is bound to a MUTABLE variable" do
      run(<<~CLEAR)
        FN bump!(MUTABLE x: Int64) RETURNS Void -> x = x + 1; END
        FN main() RETURNS Void ->
            MUTABLE n = 5;
            bump!(n);
        END
      CLEAR
    end
  end

  # ============================================================
  # Ownership: USE_OF_MOVED family (Batch 2).
  # ============================================================

  # @example_for: USE_OF_MOVED_VALUE
  # @fix: Wrap the consuming reference with `COPY` (if the type is
  # @fix: Copy-eligible — primitives, strings, enums) or upgrade the
  # @fix: declaration to a refcounted handle (`@multiowned` for
  # @fix: single-scheduler Rc, `@shared` for cross-fiber Arc) so
  # @fix: assignments / calls become refcount bumps instead of moves.
  describe ":USE_OF_MOVED_VALUE — second use of an affine binding after it was moved" do
    it "raises when a non-Copy value is assigned to two new bindings" do
      expect {
        run(<<~CLEAR)
          UNION Value { Nil, Lambda { body: Value @indirect } }
          FN main() RETURNS Void ->
              msg = Value.Nil;
              other = msg;
              next_v = msg;
          END
        CLEAR
      }.to raise_error(CompilerError, /USE AFTER MOVE.*`msg`/)
    end

    it "compiles when the binding is declared @multiowned (refcounted)" do
      run(<<~CLEAR)
        UNION Value { Nil, Lambda { body: Value @indirect } }
        FN main() RETURNS Void ->
            msg = Value.Nil @multiowned;
            other = msg;
            next_v = msg;
        END
      CLEAR
    end
  end

  # @example_for: USE_OF_MOVED_IN_LOOP
  # @fix: Affine values can only be TAKEN once; a loop body that
  # @fix: consumes a binding declared outside the loop will fail on
  # @fix: the second iteration. Either change the call from `TAKES`
  # @fix: to a borrow (drop the keyword), upgrade the binding to
  # @fix: `@multiowned` / `@shared` (refcount bump per iteration), or
  # @fix: hoist the move out of the loop entirely.
  describe ":USE_OF_MOVED_IN_LOOP — `WHILE cond DO` body moves an outer binding" do
    it "raises when a TAKES call inside the loop consumes an outer binding" do
      expect {
        run(<<~CLEAR)
          UNION Value { Nil, Lambda { body: Value @indirect } }
          FN consume(TAKES v: Value) RETURNS Void -> END
          FN main() RETURNS Void ->
              v = Value.Nil;
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 3_i64 DO
                  consume(v);
                  i = i + 1_i64;
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /USE AFTER MOVE.*`v`.*Values can only be TAKEN once/m)
    end

    it "compiles when the call site is a borrow (no TAKES, no move)" do
      run(<<~CLEAR)
        UNION Value { Nil, Lambda { body: Value @indirect } }
        FN inspect(v: Value) RETURNS Void -> END
        FN main() RETURNS Void ->
            v = Value.Nil;
            MUTABLE i: Int64 = 0_i64;
            WHILE i < 3_i64 DO
                inspect(v);
                i = i + 1_i64;
            END
        END
      CLEAR
    end
  end

  # @example_for: USE_OF_MOVED_IN_LOOP_SHORT
  # @fix: Same as USE_OF_MOVED_IN_LOOP, but for the `WHILE expr EXISTS AS x DO`
  # @fix: bind-loop form (drains an optional). The outer binding can
  # @fix: only be TAKEN once. Drop the `TAKES`, upgrade to a refcounted
  # @fix: handle, or hoist the consuming call out of the loop body.
  describe ":USE_OF_MOVED_IN_LOOP_SHORT — `WHILE expr EXISTS AS x DO` body moves an outer binding" do
    it "raises when the bind-loop body TAKES an outer binding" do
      expect {
        run(<<~CLEAR)
          UNION Value { Nil, Lambda { body: Value @indirect } }
          FN consume(TAKES v: Value) RETURNS Void -> END
          FN main() RETURNS Void ->
              msg = Value.Nil;
              MUTABLE items: Int64[5]@list = [];
              items.append(1_i64);
              items.append(2_i64);
              WHILE items.pop() EXISTS AS i DO
                  consume(msg);
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /USE AFTER MOVE.*`msg`.*Values can only be TAKEN once/m)
    end

    it "compiles when the bind-loop body only borrows the outer binding" do
      run(<<~CLEAR)
        UNION Value { Nil, Lambda { body: Value @indirect } }
        FN inspect(v: Value, n: Int64) RETURNS Void -> END
        FN main() RETURNS Void ->
            msg = Value.Nil;
            MUTABLE items: Int64[5]@list = [];
            items.append(1_i64);
            items.append(2_i64);
            WHILE items.pop() EXISTS AS i DO
                inspect(msg, i);
            END
        END
      CLEAR
    end
  end

  # @example_for: USE_OF_MOVED_PATH
  # @fix: Sub-paths (`b.field`, `arr[i]`) read through an owner. If
  # @fix: the owner itself was moved, every sub-path goes with it.
  # @fix: Either consume the field directly via `GIVE b.field` before
  # @fix: the owner is transferred, restructure so the owner isn't
  # @fix: moved before the field's last use, or read sibling fields
  # @fix: that haven't been touched.
  describe ":USE_OF_MOVED_PATH — `b.field` read after `b` (or another sub-path) was moved" do
    it "raises when the same sub-path is read twice (first read moved it)" do
      expect {
        run(<<~CLEAR)
          STRUCT Inner { value: Int64 }
          STRUCT Outer { inner: Inner, count: Int64 }
          FN main() RETURNS Void ->
              o = Outer{inner: Inner{value: 42}, count: 1};
              x = o.inner;
              y = o.inner;
          END
        CLEAR
      }.to raise_error(CompilerError, /USE AFTER MOVE.*`o\.inner`/)
    end

    it "compiles when sibling fields (not the moved sub-path) are read" do
      run(<<~CLEAR)
        STRUCT Inner { value: Int64 }
        STRUCT Outer { inner: Inner, count: Int64 }
        FN main() RETURNS Void ->
            o = Outer{inner: Inner{value: 42}, count: 1};
            x = o.inner;
            y = o.count;
        END
      CLEAR
    end
  end

  # ============================================================
  # Ownership: Borrows + lifetimes (Batch 4).
  #
  # Note: 3 of the 5 codes in this batch (LIFETIME_ALREADY_BORROWED,
  # BORROWED_VAR_NOT_FOUND, STORE_STRING_NEEDS_COPY) are deferred —
  # they fire from compiler-internal paths that require either a
  # specific borrow-chain shape or runtime-only knowledge to trigger
  # cleanly from a self-contained CLEAR snippet. The auto-COPY path
  # in `ensure_owned_value!` shadows STORE_STRING_NEEDS_COPY for
  # ordinary cases; LIFETIME_ALREADY_BORROWED needs a multi-borrow
  # function-return setup that isn't easily expressible without an
  # @stdlib helper. Revisit when refactoring those code paths.
  # ============================================================

  # @example_for: ASSIGN_WHILE_BORROWED
  # @fix: While a `WITH RESTRICT x` block is active, `x` (and any
  # @fix: sub-path covered by the wildcard `x.*` form) cannot be
  # @fix: written. Move the assignment outside the WITH block, or
  # @fix: structure the code so the mutation happens before the
  # @fix: borrow begins.
  describe ":ASSIGN_WHILE_BORROWED — writing to a binding inside its own WITH RESTRICT" do
    it "raises when a sub-field is assigned inside a wildcard RESTRICT" do
      expect {
        run(<<~CLEAR)
          STRUCT Bar { val: Float64 }
          STRUCT Foo { b1: Bar, b2: Bar }
          FN main() RETURNS Void ->
              MUTABLE foo = Foo{b1: Bar{val: 1.0}, b2: Bar{val: 2.0}};
              WITH RESTRICT foo.* {
                  foo.b1.val = 10.0;
              }
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot assign to 'foo' because it is currently borrowed/)
    end

    it "compiles when the assignment is outside any WITH RESTRICT block" do
      run(<<~CLEAR)
        STRUCT Bar { val: Float64 }
        STRUCT Foo { b1: Bar, b2: Bar }
        FN main() RETURNS Void ->
            MUTABLE foo = Foo{b1: Bar{val: 1.0}, b2: Bar{val: 2.0}};
            foo.b1.val = 10.0;
        END
      CLEAR
    end
  end

  # @example_for: STORE_BORROWED_INTO_CONTAINER
  # @fix: Plain (borrow) parameters can't be persisted into a
  # @fix: container — the borrow's lifetime ends with the function
  # @fix: call. Either declare the parameter `TAKES v: T` so the
  # @fix: function owns the value, or wrap the field assignment with
  # @fix: `COPY v` to deep-copy the value into the container.
  describe ":STORE_BORROWED_INTO_CONTAINER — storing a borrowed param into a struct field" do
    it "raises when a non-TAKES param's value is stored into a struct field" do
      expect {
        run(<<~CLEAR)
          UNION Value { Nil, Str: String }
          STRUCT Pair { a: Value, b: Value }
          FN f(v: Value) RETURNS Void ->
              p = Pair{a: v, b: Value.Nil};
          END
          FN main() RETURNS Void -> f(Value.Nil); END
        CLEAR
      }.to raise_error(CompilerError, /Cannot store borrowed value 'v' into Pair\.a/)
    end

    it "compiles when the parameter is declared TAKES (function owns the value)" do
      run(<<~CLEAR)
        UNION Value { Nil, Str: String }
        STRUCT Pair { a: Value, b: Value }
        FN f!(TAKES v: Value) RETURNS !Void ->
            p = Pair{a: v, b: Value.Nil};
            RETURN;
        END
        FN main() RETURNS Void -> f!(Value.Nil) OR_ELSE PASS; END
      CLEAR
    end
  end

  # ============================================================
  # Ownership: GIVE / TAKES / COPY / CLONE basics (Batch 3).
  #
  # Note: GIVE_BAD_TARGET and COPY_NON_COPYABLE are defined in the
  # registry but the visitors that fire them (`visit_Give`,
  # `visit_Copy`) are dead — `GIVE` parses to AST::MoveNode (handled
  # by `visit_MoveNode`, which fires MOVE_NEEDS_IDENTIFIER /
  # GIVE_ON_COPY_TYPE) and `COPY` parses to AST::CopyNode (handled
  # by `visit_CopyNode`, which doesn't reject non-Copy types
  # because COPY's job is to deep-copy them). Dead-code cleanup is
  # a separate task. MOVE_BORROWED_INDEX is also deferred — it
  # requires a borrowed-container source-graph state that's hard to
  # set up from a self-contained snippet.
  # ============================================================

  # @example_for: GIVE_ON_COPY_TYPE
  # @fix: `GIVE` only makes sense for affine (move-only) types.
  # @fix: Copy types — primitives, strings, enums, and Copy unions —
  # @fix: pass implicitly without ownership transfer. Drop the GIVE.
  describe ":GIVE_ON_COPY_TYPE — `GIVE` applied to a Copy primitive" do
    it "raises when GIVE wraps an Int64 binding" do
      expect {
        run(<<~CLEAR)
          FN consume(TAKES n: Int64) RETURNS Void -> END
          FN main() RETURNS Void ->
              x = 5;
              consume(GIVE x);
          END
        CLEAR
      }.to raise_error(CompilerError, /GIVE cannot be applied to Copy types/)
    end

    it "compiles when the Copy value is passed without GIVE" do
      run(<<~CLEAR)
        FN consume(TAKES n: Int64) RETURNS Void -> END
        FN main() RETURNS Void ->
            x = 5;
            consume(x);
        END
      CLEAR
    end
  end

  # @example_for: MOVE_NEEDS_IDENTIFIER
  # @fix: GIVE / MOVE work on a *binding* whose ownership is
  # @fix: transferred. A function-call result, literal, or arbitrary
  # @fix: expression has no binding to consume. Bind the value to a
  # @fix: variable first, then GIVE that variable.
  describe ":MOVE_NEEDS_IDENTIFIER — GIVE wrapping a non-identifier expression" do
    it "raises when GIVE wraps a function-call result directly" do
      expect {
        run(<<~CLEAR)
          UNION Value { Nil, Lambda { body: Value @indirect } }
          FN make() RETURNS Value -> RETURN Value.Nil; END
          FN consume(TAKES v: Value) RETURNS Void -> END
          FN main() RETURNS Void ->
              consume(GIVE make());
          END
        CLEAR
      }.to raise_error(CompilerError, /MOVE can only be applied to a variable identifier/)
    end

    it "compiles when the call result is bound first, then GIVEn" do
      run(<<~CLEAR)
        UNION Value { Nil, Lambda { body: Value @indirect } }
        FN main() RETURNS Void ->
            v = Value.Nil;
        END
      CLEAR
    end
  end

  # @example_for: CLONE_BAD_TARGET
  # @fix: CLONE bumps a refcount on a shared handle. It only applies
  # @fix: to types that hold an Arc / Rc — `@split` streams,
  # @fix: `@shared` promises, and owned shared handles
  # @fix: (`x @multiowned` / `x @shared`). For plain affine values,
  # @fix: use `COPY` to deep-copy.
  describe ":CLONE_BAD_TARGET — CLONE on a non-shared value" do
    it "raises when CLONE wraps a Copy primitive" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              x = 5;
              y = CLONE x;
          END
        CLEAR
      }.to raise_error(CompilerError, /CLONE is only supported on @split streams/)
    end

    it "compiles when CLONE bumps the refcount of a @split stream" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            s: ~?Int64[]@split = BG STREAM { YIELD 1; };
            t: ~?Int64[]@split = CLONE s;
        END
      CLEAR
    end
  end

  # @example_for: MOVE_BORROWED_PARAM
  # @fix: A plain function parameter is a borrow — the caller still
  # @fix: owns the value. Storing it into a local binding (or any
  # @fix: container) would outlive the borrow. If the function
  # @fix: should consume the value, declare it `TAKES v: T` so the
  # @fix: function owns it.
  describe ":MOVE_BORROWED_PARAM — assigning a borrow param to a new binding" do
    it "raises when a non-TAKES param is moved into a local binding" do
      expect {
        run(<<~CLEAR)
          UNION Value { Nil, Lambda { body: Value @indirect } }
          FN store(v: Value) RETURNS Void ->
              keep = v;
          END
          FN main() RETURNS Void -> store(Value.Nil); END
        CLEAR
      }.to raise_error(CompilerError, /Cannot move borrowed value 'v'/)
    end

    it "compiles when the parameter is declared TAKES" do
      run(<<~CLEAR)
        UNION Value { Nil, Lambda { body: Value @indirect } }
        FN store!(TAKES v: Value) RETURNS !Void ->
            keep = v;
            RETURN;
        END
        FN main() RETURNS Void -> store!(Value.Nil) OR_ELSE PASS; END
      CLEAR
    end
  end

  # @example_for: TAKES_NEEDS_OWNED_INDEX
  # @fix: Container indexing (`list[i]`, `map[k]`) returns a
  # @fix: borrow into the container — the element still lives there.
  # @fix: A `TAKES v: T` parameter requires owned data. Use
  # @fix: `list.remove(i)` to take the element out of the
  # @fix: container, `COPY list[i]` to deep-copy the element, or
  # @fix: change the parameter to a borrow (drop `TAKES`).
  describe ":TAKES_NEEDS_OWNED_INDEX — passing `list[i]` to a TAKES parameter" do
    it "raises when a non-Copy element is passed via index access to TAKES" do
      expect {
        run(<<~CLEAR)
          UNION Value { Nil, Lambda { body: Value @indirect } }
          FN consume(TAKES v: Value) RETURNS Void -> END
          FN main() RETURNS Void ->
              MUTABLE list: Value[]@list = [];
              list.append(Value.Nil);
            IF list[0_i64] EXISTS AS value THEN consume(value); END
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot pass borrowed access to TAKES parameter/)
    end

    it "compiles when the element is passed to a borrow parameter (no TAKES)" do
      run(<<~CLEAR)
        UNION Value { Nil, Lambda { body: Value @indirect } }
        FN inspect(v: Value) RETURNS Void -> END
        FN main() RETURNS Void ->
            MUTABLE list: Value[]@list = [];
            list.append(Value.Nil);
            IF list[0_i64] EXISTS AS value THEN inspect(value); END
        END
      CLEAR
    end
  end

  # ============================================================
  # Ownership: Refcounted handles — LINK / RESOLVE / FREEZE / SHARE (Batch 5).
  #
  # Note: SHARE_NEEDS_TYPED is deferred — it fires only when the
  # SHARE'd value has no resolved type at all, which is a defensive
  # path the parser usually doesn't reach for user-typed code.
  # ============================================================

  # @example_for: LINK_NEEDS_SHARED_OR_MULTIOWNED
  # @fix: LINK creates a weak reference (WeakRc / WeakArc) that
  # @fix: doesn't keep the target alive. The source must therefore
  # @fix: be a refcounted handle — declare it `@multiowned` (Rc) or
  # @fix: `@shared` (Arc). Plain affine bindings have no refcount
  # @fix: for the weak reference to track.
  describe ":LINK_NEEDS_SHARED_OR_MULTIOWNED — LINK on a plain affine value" do
    it "raises when LINK targets a plain (non-refcounted) struct" do
      expect {
        run(<<~CLEAR)
          STRUCT Node { val: Int64 }
          FN main() RETURNS Void ->
              n = Node{val: 1};
              w = LINK n;
          END
        CLEAR
      }.to raise_error(CompilerError, /LINK can only be applied to @shared or @multiowned/)
    end

    it "compiles when the source is @multiowned (Rc, single-scheduler)" do
      run(<<~CLEAR)
        STRUCT Node { val: Int64 }
        FN main() RETURNS Void ->
            n = Node{val: 1} @multiowned;
            w = LINK n;
        END
      CLEAR
    end
  end

  # @example_for: RESOLVE_NEEDS_LINK
  # @fix: RESOLVE upgrades a weak reference (`@link`) back to an
  # @fix: optional strong reference. It only makes sense on `@link`
  # @fix: bindings; for an already-strong `@multiowned` / `@shared`
  # @fix: value there's nothing to resolve.
  describe ":RESOLVE_NEEDS_LINK — RESOLVE on a non-@link binding" do
    it "raises when RESOLVE targets a plain affine value" do
      expect {
        run(<<~CLEAR)
          STRUCT Node { val: Int64 }
          FN main() RETURNS Void ->
              n = Node{val: 1};
              r = RESOLVE n;
          END
        CLEAR
      }.to raise_error(CompilerError, /RESOLVE can only be applied to @link/)
    end

    it "compiles when RESOLVE upgrades an @link inside an IF EXISTS AS binding" do
      run(<<~CLEAR)
        STRUCT Node { val: Int64 }
        FN main() RETURNS Void ->
            n = Node{val: 1} @multiowned;
            w = LINK n;
            IF RESOLVE w EXISTS AS strong THEN
                print(strong.val);
            END
        END
      CLEAR
    end
  end

  # @example_for: FREEZE_NEEDS_OWNED
  # @fix: FREEZE compacts a @multiowned / @shared tree into a
  # @fix: contiguous immutable buffer. The source must already be a
  # @fix: refcounted handle so FREEZE has a known root to copy from
  # @fix: and a refcount to absorb. Add `@multiowned` (or `@shared`)
  # @fix: at the source's declaration.
  describe ":FREEZE_NEEDS_OWNED — FREEZE on a plain affine struct" do
    it "raises when FREEZE targets a plain struct" do
      expect {
        run(<<~CLEAR)
          STRUCT Point { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
              p = Point{x: 1, y: 2};
              f = FREEZE p;
          END
        CLEAR
      }.to raise_error(CompilerError, /FREEZE can only be applied to @multiowned or @shared/)
    end

    it "compiles when the source is @multiowned" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = Point{x: 1, y: 2} @multiowned;
            f = FREEZE p;
            print(f.x);
        END
      CLEAR
    end
  end

  # @example_for: LINK_NEEDS_RESOLVE_FOR_CALL
  # @fix: An `@link` binding is a weak reference — the target may
  # @fix: have been freed. Functions that take a strong reference
  # @fix: cannot accept the weak directly. RESOLVE the link first
  # @fix: (`IF RESOLVE w EXISTS AS strong THEN ...`) and pass the
  # @fix: short-lived strong reference inside the IF body.
  describe ":LINK_NEEDS_RESOLVE_FOR_CALL — passing @link to a non-@link parameter" do
    it "raises when an @link binding is passed where a strong reference is expected" do
      expect {
        run(<<~CLEAR)
          STRUCT Node { val: Int64 }
          FN inspect(n: Node) RETURNS Void -> END
          FN main() RETURNS Void ->
              n = Node{val: 1} @multiowned;
              w = LINK n;
              inspect(w);
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot pass @link variable 'w' to parameter 'n'/)
    end

    it "compiles when the link is RESOLVEd to a strong reference inside an IF AS" do
      run(<<~CLEAR)
        STRUCT Node { val: Int64 }
        FN inspect(n: Node) RETURNS Void -> END
        FN main() RETURNS Void ->
            n = Node{val: 1} @multiowned;
            w = LINK n;
            IF RESOLVE w EXISTS AS strong THEN
                inspect(strong);
            END
        END
      CLEAR
    end
  end

  # ============================================================
  # Ownership: Misc (Batch 6).
  #
  # Note: VARIABLE_REBIND and ILLEGAL_UPVALUE were dead duplicates
  # (of IMMUTABLE_ASSIGNMENT and CAPTURE_UNDEFINED_VAR respectively)
  # and have been removed. PRIMITIVE_PASSED_AS_MUTABLE is now
  # marked `pending: true` — the check would warn about declaring a
  # primitive-typed parameter MUTABLE (which is a no-op since
  # primitives are pass-by-value), but the visitor isn't wired yet.
  # ============================================================

  # @example_for: STYLE_MUTABLE_PARAM_NEEDS_BANG
  # @fix: A function that has any `MUTABLE x: T` parameter mutates
  # @fix: the caller's binding through that parameter — a kind of
  # @fix: side effect. CLEAR's convention is that mutating functions
  # @fix: end in `!` so the call site signals the side effect.
  # @fix: Append `!` to the function name (and update every call
  # @fix: site to match).
  describe ":STYLE_MUTABLE_PARAM_NEEDS_BANG — MUTABLE-param fn missing trailing !" do
    it "raises when a function with a MUTABLE param has no `!` in its name" do
      expect {
        run(<<~CLEAR)
          FN bump(MUTABLE x: Int64) RETURNS Void -> x = x + 1; END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /Style Error: Function 'bump' has MUTABLE parameters/)
    end

    it "compiles when the function name ends in !" do
      run(<<~CLEAR)
        FN bump!(MUTABLE x: Int64) RETURNS Void -> x = x + 1; END
        FN main() RETURNS Void -> END
      CLEAR
    end
  end

  # @example_for: WHILE_AS_IMMUTABLE_RECEIVER
  # @fix: `WHILE expr EXISTS AS x DO ...` re-evaluates `expr` every
  # @fix: iteration. If `expr` is `recv.method()` and `recv` is
  # @fix: immutable, `method` returns the same value every time and
  # @fix: the loop runs forever. Declare the receiver `MUTABLE` (so
  # @fix: methods like `pop()` can advance state) — or use a
  # @fix: regular `WHILE cond DO` with explicit termination.
  describe ":WHILE_AS_IMMUTABLE_RECEIVER — `WHILE recv.method() EXISTS AS x` on immutable recv" do
    it "raises when the bind-loop calls `pop()` on an immutable list" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS !Void ->
              items: Int64[5]@list = [];
              WHILE items.pop() EXISTS AS v DO
                  _ = v;
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /WHILE.*'pop'.*on immutable 'items'/)
    end

    it "compiles when the receiver is MUTABLE" do
      run(<<~CLEAR)
        FN main() RETURNS !Void ->
            MUTABLE items: Int64[5]@list = [];
            items.append(1_i64);
            WHILE items.pop() EXISTS AS v DO
                print(v);
            END
        END
      CLEAR
    end
  end

  # @example_for: PROMISE_NOT_CONSUMED
  # @fix: A `BG { ... }` expression returns a promise (`~T`). Like
  # @fix: an unawaited future in JS, an unconsumed promise leaks
  # @fix: the work the fiber is doing. Consume it with `NEXT fut`
  # @fix: to wait and read the result, `COLLECT` it into a stream,
  # @fix: or `RETURN` it to a caller that will.
  describe ":PROMISE_NOT_CONSUMED — BG promise allowed to leave scope" do
    it "raises when a BG promise is bound but never consumed" do
      expect {
        run(<<~CLEAR)
          FN slow() RETURNS Int64 -> RETURN 42; END
          FN main() RETURNS Void ->
              fut = BG { slow(); };
          END
        CLEAR
      }.to raise_error(CompilerError, /Promise 'fut' must be consumed/)
    end

    it "compiles when the promise is consumed via NEXT" do
      run(<<~CLEAR)
        FN slow() RETURNS Int64 -> RETURN 42; END
        FN main() RETURNS Void ->
            fut = BG { slow(); };
            print((NEXT fut).toString());
        END
      CLEAR
    end
  end

  # @example_for: ARG_ALIAS_CONFLICT
  # @fix: A function with multiple MUTABLE parameters (or one
  # @fix: MUTABLE + a borrow of the same value) requires the
  # @fix: caller to pass distinct bindings — exclusive mutability
  # @fix: would be violated if `a` and `b` aliased the same
  # @fix: storage. Bind the second value to a separate variable
  # @fix: before the call.
  describe ":ARG_ALIAS_CONFLICT — same variable passed twice with one MUTABLE" do
    it "raises when the same MUTABLE variable is passed to two MUTABLE params" do
      expect {
        run(<<~CLEAR)
          FN swap!(MUTABLE a: Int64, MUTABLE b: Int64) RETURNS Void ->
              tmp = a;
              a = b;
              b = tmp;
          END
          FN main() RETURNS Void ->
              MUTABLE x = 1;
              swap!(x, x);
          END
        CLEAR
      }.to raise_error(CompilerError, /Aliasing Error.*Argument 2 \('x'\) conflicts with argument 1/)
    end

    it "compiles when the two arguments are distinct bindings" do
      run(<<~CLEAR)
        FN swap!(MUTABLE a: Int64, MUTABLE b: Int64) RETURNS Void ->
            tmp = a;
            a = b;
            b = tmp;
        END
        FN main() RETURNS Void ->
            MUTABLE x = 1;
            MUTABLE y = 2;
            swap!(x, y);
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Identifier / typo bucket (Type Bucket 1).
  #
  # Note: ASSIGN_UNDEFINED_VAR is deferred — the keywordless
  # assignment parser folds bare `x = value` into BindExpr (which
  # treats undeclared LHS as a fresh declaration), and `x += 1`
  # desugars to `x = x + 1` whose RHS reference fires UNDEFINED_VAR
  # first. Hard to reach from a self-contained snippet without
  # constructing the AST directly.
  # ============================================================

  # @example_for: UNDEFINED_VAR
  # @fix: Check the spelling. If the binding lives in a different
  # @fix: module, add a REQUIRE. If it's a struct field or method,
  # @fix: qualify with the receiver. The compiler's typo-suggestion
  # @fix: fix offers the closest in-scope name when one is within
  # @fix: Levenshtein threshold.
  describe ":UNDEFINED_VAR — reading a name that's not in scope" do
    it "raises when an Identifier reference doesn't resolve to a binding" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              counter = 5;
              _ = countr + 1;
          END
        CLEAR
      }.to raise_error(CompilerError, /Undefined variable 'countr'/)
    end

    it "compiles when the identifier matches a declared binding" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            counter = 5;
            print((counter + 1).toString());
        END
      CLEAR
    end
  end

  # @example_for: MISSING_FUNCTION
  # @fix: Check the spelling. If the function lives in another
  # @fix: module, add `REQUIRE "pkg:..."` or `REQUIRE "file.clear"`.
  # @fix: The typo-suggestion auto-fix offers the closest declared
  # @fix: name when one is within Levenshtein threshold.
  describe ":MISSING_FUNCTION — calling a name that isn't a declared function" do
    it "raises when a call site references a typo'd function name" do
      expect {
        run(<<~CLEAR)
          FN computeSum(a: Int64, b: Int64) RETURNS Int64 -> RETURN a + b; END
          FN main() RETURNS Void ->
              n = computSum(1_i64, 2_i64);
              print(n.toString());
          END
        CLEAR
      }.to raise_error(CompilerError, /Undefined function 'computSum'/)
    end

    it "compiles when the function name matches a declaration" do
      run(<<~CLEAR)
        FN computeSum(a: Int64, b: Int64) RETURNS Int64 -> RETURN a + b; END
        FN main() RETURNS Void ->
            n = computeSum(1_i64, 2_i64);
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: STRUCT_FIELD_UNRESOLVABLE
  # @fix: Check the field spelling against the struct definition.
  # @fix: The typo-suggestion auto-fix offers the closest declared
  # @fix: field when one is within Levenshtein threshold. If the
  # @fix: field really should exist, add it to the STRUCT
  # @fix: declaration.
  describe ":STRUCT_FIELD_UNRESOLVABLE — `p.field` for a field the struct doesn't declare" do
    it "raises when accessing a typo'd field on a known struct" do
      expect {
        run(<<~CLEAR)
          STRUCT Point { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
              p = Point{x: 1, y: 2};
              _ = p.zz;
          END
        CLEAR
      }.to raise_error(CompilerError, /Struct 'Point' has no field 'zz'/)
    end

    it "compiles when the field name matches the struct declaration" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = Point{x: 1, y: 2};
            print(p.x.toString());
        END
      CLEAR
    end
  end

  # @example_for: ILLEGAL_FIELD_LOOKUP
  # @fix: Field access (`x.y`) only works on a struct or an
  # @fix: alias of one. Primitives, arrays, and unresolved-type
  # @fix: values have no fields. If the receiver should be a
  # @fix: struct, check that its declared type is correct; if it's
  # @fix: a primitive, use a method call instead (`x.toString()`).
  describe ":ILLEGAL_FIELD_LOOKUP — `x.y` on a non-struct receiver" do
    it "raises when the receiver type isn't a struct" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              n: Int64 = 5_i64;
              _ = n.something;
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot determine struct type for field access 'something'.*'Int64'/)
    end

    it "compiles when field access hits an actual struct field" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = Point{x: 1, y: 2};
            print(p.x.toString());
        END
      CLEAR
    end
  end

  # @example_for: UNKNOWN_TYPE
  # @fix: Check the type-name spelling. If the type lives in
  # @fix: another module, add `REQUIRE "..."`. The typo-suggestion
  # @fix: auto-fix offers the closest declared type-name when one
  # @fix: is within Levenshtein threshold.
  describe ":UNKNOWN_TYPE — generic type-arg references an undeclared type" do
    it "raises when a type annotation names a non-existent generic base" do
      expect {
        run(<<~CLEAR)
          STRUCT Pair<T> { first: T, second: T }
          FN main() RETURNS Void ->
              p: Pir<Int64> = Pair<Int64>{first: 1_i64, second: 2_i64};
              _ = p.first;
          END
        CLEAR
      }.to raise_error(CompilerError, /Unknown type 'Pir'/)
    end

    it "compiles when the type-arg base matches a declared type" do
      run(<<~CLEAR)
        STRUCT Pair<T> { first: T, second: T }
        FN main() RETURNS Void ->
            p: Pair<Int64> = Pair<Int64>{first: 1_i64, second: 2_i64};
            print(p.first.toString());
        END
      CLEAR
    end
  end

  # @example_for: UNKNOWN_STRUCT_TYPE
  # @fix: Check the struct-name spelling against the STRUCT
  # @fix: declarations in scope. The typo-suggestion auto-fix
  # @fix: offers the closest declared name when one is within
  # @fix: Levenshtein threshold.
  describe ":UNKNOWN_STRUCT_TYPE — struct literal names a non-existent struct" do
    it "raises when a struct literal uses a typo'd type name" do
      expect {
        run(<<~CLEAR)
          STRUCT Point { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
              p = Pont{x: 1, y: 2};
              _ = p.x;
          END
        CLEAR
      }.to raise_error(CompilerError, /Unknown struct type 'Pont'/)
    end

    it "compiles when the struct name matches a declaration" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = Point{x: 1, y: 2};
            print(p.x.toString());
        END
      CLEAR
    end
  end

  # @example_for: MATCH_FIELD_UNKNOWN
  # @fix: Check the field-name spelling against the matched struct's
  # @fix: declaration. The typo-suggestion auto-fix offers the
  # @fix: closest declared field when one is within Levenshtein
  # @fix: threshold.
  describe ":MATCH_FIELD_UNKNOWN — MATCH struct pattern names a non-existent field" do
    it "raises when a MATCH value-pattern names a typo'd field" do
      expect {
        run(<<~CLEAR)
          STRUCT P { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
              p = P{x: 1, y: 2};
              PARTIAL MATCH p
                  START { xs: 1 } -> print("hi");,
                  DEFAULT -> print("other");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH struct pattern: field 'xs' does not exist/)
    end

    it "compiles when the field name matches the struct declaration" do
      run(<<~CLEAR)
        STRUCT P { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = P{x: 1, y: 2};
            PARTIAL MATCH p
                START { x: 1 } -> print("hi");,
                DEFAULT -> print("other");
            END
        END
      CLEAR
    end
  end

  # @example_for: MATCH_DESTRUCTURE_FIELD_UNKNOWN
  # @fix: Check the field-name spelling against the union variant's
  # @fix: payload struct. The typo-suggestion auto-fix offers the
  # @fix: closest declared field when one is within Levenshtein
  # @fix: threshold.
  describe ":MATCH_DESTRUCTURE_FIELD_UNKNOWN — variant destructure names a non-existent field" do
    it "raises when a variant destructure pattern names a typo'd field" do
      expect {
        run(<<~CLEAR)
          UNION Shape { Circle { radius: Float64 }, Square }
          FN main() RETURNS Void ->
              c: Shape = Shape.Circle{radius: 5.0};
              MUTABLE r = 0.0;
              PARTIAL MATCH c
                  START Shape.Circle{ radiu } -> r = radiu;,
                  DEFAULT -> r = 0.0;
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH destructure: field 'radiu' is not on variant Circle/)
    end

    it "compiles when the destructure field matches the variant payload" do
      run(<<~CLEAR)
        UNION Shape { Circle { radius: Float64 }, Square }
        FN main() RETURNS Void ->
            c: Shape = Shape.Circle{radius: 5.0};
            MUTABLE r = 0.0;
            PARTIAL MATCH c
                START Shape.Circle{ radius } -> r = radius;,
                DEFAULT -> r = 0.0;
            END
        END
      CLEAR
    end
  end

  # @example_for: UNION_INLINE_VARIANT_UNKNOWN_FIELD
  # @fix: Inline-struct union variants (`Shape.Circle{radius: 5.0}`)
  # @fix: must use field names declared on the variant. Check the
  # @fix: spelling against the UNION declaration's variant
  # @fix: definition.
  describe ":UNION_INLINE_VARIANT_UNKNOWN_FIELD — variant literal names a non-existent field" do
    it "raises when an inline-struct variant literal names a typo'd field" do
      expect {
        run(<<~CLEAR)
          UNION Shape { Circle { radius: Float64 }, Square }
          FN main() RETURNS Void ->
              s = Shape.Circle{radiu: 5.0};
              _ = s;
          END
        CLEAR
      }.to raise_error(CompilerError, /Union variant 'Shape\.Circle' has no field 'radiu'/)
    end

    it "compiles when the variant literal uses a declared field" do
      run(<<~CLEAR)
        UNION Shape { Circle { radius: Float64 }, Square }
        FN main() RETURNS Void ->
            s = Shape.Circle{radius: 5.0};
            PARTIAL MATCH s START
                Shape.Circle AS c -> print(c.radius.toString());,
                DEFAULT -> print("other");
            END
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Function call signature bucket (Type Bucket 2).
  #
  # Note: NOT_A_FUNCTION fires when a name resolves to a non-callable
  # type at a call site, but the keywordless parser typically routes
  # `id(args)` through other paths first (UNDEFINED_VAR for unknown
  # method names, MissingFunction for unknown free functions). It's
  # left as a defensive fallback; documenting it without a
  # self-contained trigger is deferred.
  # ============================================================

  # @example_for: ARITY_MISMATCH
  # @fix: Check the function's signature. The message names the
  # @fix: expected count vs the actual. If you wanted variadic
  # @fix: behaviour, declare a list parameter; if the extra args
  # @fix: were intentional, add corresponding parameters with
  # @fix: defaults.
  describe ":ARITY_MISMATCH — call site passes the wrong number of arguments" do
    it "raises when too many arguments are passed" do
      expect {
        run(<<~CLEAR)
          FN add(a: Int64, b: Int64) RETURNS Int64 -> RETURN a + b; END
          FN main() RETURNS Void ->
              n = add(1_i64, 2_i64, 3_i64);
              print(n.toString());
          END
        CLEAR
      }.to raise_error(CompilerError, /Function 'add' expects 2 arguments, got 3/)
    end

    it "compiles when the call passes the declared number of args" do
      run(<<~CLEAR)
        FN add(a: Int64, b: Int64) RETURNS Int64 -> RETURN a + b; END
        FN main() RETURNS Void ->
            n = add(1_i64, 2_i64);
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: ARITY_MISMATCH_RANGE
  # @fix: The function has parameters with defaults, so the
  # @fix: caller must pass between the required-min and the total
  # @fix: count. Provide the missing required arguments, or accept
  # @fix: the parameter's declared default by passing fewer.
  describe ":ARITY_MISMATCH_RANGE — call to a fn with default args misses the required min" do
    it "raises when fewer than the minimum required arguments are passed" do
      expect {
        run(<<~CLEAR)
          FN greet(name: String, greeting="Hello": String) RETURNS String ->
              RETURN greeting + ", " + name;
          END
          FN main() RETURNS Void ->
              s = greet();
              print(s);
          END
        CLEAR
      }.to raise_error(CompilerError, /Function 'greet' expects between 1 and 2 arguments, got 0/)
    end

    it "compiles when at least the required arg is passed" do
      run(<<~CLEAR)
        FN greet!(name: String, greeting="Hello": String) RETURNS !String ->
            RETURN greeting + ", " + name;
        END
        FN main() RETURNS Void ->
            s = greet!("Alice") OR_ELSE "Hi";
            print(s);
        END
      CLEAR
    end
  end

  # @example_for: ARGUMENT_TYPE_ERROR
  # @fix: The argument's declared type doesn't match the parameter's
  # @fix: declared type. Either change the argument (via `CAST` or
  # @fix: by passing a different value) or change the parameter's
  # @fix: declared type to match what callers pass.
  describe ":ARGUMENT_TYPE_ERROR — argument type doesn't match parameter type" do
    it "raises when a String is passed to a parameter declared as Int64" do
      expect {
        run(<<~CLEAR)
          FN double(n: Int64) RETURNS Int64 -> RETURN n * 2_i64; END
          FN main() RETURNS Void ->
              msg: String = "hello";
              n = double(msg);
              print(n.toString());
          END
        CLEAR
      }.to raise_error(CompilerError, /argument 1 expects Int64, got String/)
    end

    it "compiles when the argument type matches the parameter type" do
      run(<<~CLEAR)
        FN double(n: Int64) RETURNS Int64 -> RETURN n * 2_i64; END
        FN main() RETURNS Void ->
            n = double(5_i64);
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: RETURN_MISMATCH
  # @fix: The function's `RETURN` value's type doesn't match the
  # @fix: declared return type. Either change the returned
  # @fix: expression (often via `CAST`) or change the
  # @fix: `RETURNS T` declaration to match what the function
  # @fix: actually computes.
  describe ":RETURN_MISMATCH — RETURN value's type doesn't match the function's declared RETURNS" do
    it "raises when the returned value type doesn't match the declared type" do
      expect {
        run(<<~CLEAR)
          FN compute() RETURNS Int64 ->
              RETURN "not an int";
          END
          FN main() RETURNS Void -> _ = compute(); END
        CLEAR
      }.to raise_error(CompilerError, /Function expected to return 'Int64', but returned 'String'|Function expected to return 'Int64', but returned 'Byte\[/)
    end

    it "compiles when the returned value matches the declared return type" do
      run(<<~CLEAR)
        FN compute() RETURNS Int64 ->
            RETURN 42_i64;
        END
        FN main() RETURNS Void ->
            n = compute();
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: STDLIB_METHOD_NO_ARGS
  # @fix: This stdlib method takes no arguments — the message names
  # @fix: which method. Drop the extra arg(s).
  describe ":STDLIB_METHOD_NO_ARGS — calling an arity-0 stdlib method with arguments" do
    it "raises when HashMap.count() is called with an argument" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m["a"] = 1_i64;
              n = m.count(0_i64);
              print(n.toString());
          END
        CLEAR
      }.to raise_error(CompilerError, /count takes no arguments/)
    end

    it "compiles when the method is called with no arguments" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            m["a"] = 1_i64;
            n = m.count();
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: STDLIB_METHOD_ARITY
  # @fix: This stdlib method has a fixed arity that the call site
  # @fix: violated. The message names the expected count and the
  # @fix: actual; adjust the call to match.
  describe ":STDLIB_METHOD_ARITY — calling a stdlib method with the wrong number of arguments" do
    it "raises when Pool.insert() is called with no argument (expects 1)" do
      expect {
        run(<<~CLEAR)
          STRUCT Item { v: Int64 }
          FN main() RETURNS Void ->
              MUTABLE pool: Item[100]@pool = [];
              id = pool.insert();
              _ = id;
          END
        CLEAR
      }.to raise_error(CompilerError, /insert requires exactly 1 argument/)
    end

    it "compiles when Pool.insert() is called with the required value" do
      run(<<~CLEAR)
        STRUCT Item { v: Int64 }
        FN main() RETURNS Void ->
            MUTABLE pool: Item[100]@pool = [];
            id = pool.insert(Item{v: 1});
            IF pool[id] EXISTS AS got THEN
                print(got.v.toString());
            END
        END
      CLEAR
    end
  end

  # @example_for: INTRINSIC_NO_OVERLOAD
  # @fix: The intrinsic function (e.g. `length`, `toString`,
  # @fix: `indexOf`) was called with arguments that don't match any
  # @fix: declared overload. The message lists the candidates;
  # @fix: pick the right shape and adjust the call.
  describe ":INTRINSIC_NO_OVERLOAD — intrinsic call with no matching overload" do
    it "raises when length() is called with an extra argument" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              s = "hello";
              n = s.length(1_i64);
              print(n.toString());
          END
        CLEAR
      }.to raise_error(CompilerError, /No overload for 'length'/)
    end

    it "compiles when length() is called with no arguments" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            s = "hello";
            n = s.length();
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: INTRINSIC_REJECTED
  # @fix: The intrinsic was called with a receiver that's
  # @fix: explicitly rejected by the stdlib registry — the call
  # @fix: would always be a no-op or always-wrong. The message
  # @fix: explains why; drop the call or use the suggested
  # @fix: alternative.
  describe ":INTRINSIC_REJECTED — intrinsic call rejected by reject_when guard" do
    it "raises when .negative?() is called on an unsigned integer" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              n: UInt32 = 5_u32;
              IF n.negative?() THEN print("yes"); END
          END
        CLEAR
      }.to raise_error(CompilerError, /\.negative\?\(\) is always false on unsigned integers/)
    end

    it "compiles when .negative?() is called on a signed integer" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            n: Int64 = 5_i64;
            IF n.negative?() THEN print("yes"); ELSE print("no"); END
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Type mismatch bucket (Type Bucket 3).
  #
  # Note: VARDECL_TYPE_MISMATCH_FIXABLE and TYPE_COERCION_FAILED
  # are deferred — both are umbrella `%{message}` codes that fire
  # only on niche shapes (the former for `@observable` mismatches
  # in var decls; the latter as a fallback when `Type#coerce!`
  # returns an error). VARIABLE_ASSIGNMENT_TYPE_ERROR and
  # LIST_TYPE_MISMATCH were dead duplicates and have been deleted
  # from the registry in this commit.
  # ============================================================

  # @example_for: TYPE_MISMATCH_ASSIGN
  # @fix: The right-hand side's type doesn't fit the assignment
  # @fix: target. Either change the value (often via `CAST(... AS T)`
  # @fix: — `clear fix` offers this as an interactive fix), or
  # @fix: change the target's declared type to match the value.
  describe ":TYPE_MISMATCH_ASSIGN — RHS type doesn't fit the assignment target" do
    it "raises when a String is assigned to an Int64 binding" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              MUTABLE x: Int64 = 5_i64;
              x = "hello";
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot assign.*to Int64/)
    end

    it "compiles when the RHS type matches the declared type" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE x: Int64 = 5_i64;
            x = 10_i64;
        END
      CLEAR
    end
  end

  # @example_for: FIELD_TYPE_MISMATCH
  # @fix: The struct literal's field value doesn't match the
  # @fix: field's declared type. Adjust the value, or change the
  # @fix: STRUCT declaration if the type was wrong.
  describe ":FIELD_TYPE_MISMATCH — struct-literal field value's type wrong" do
    it "raises when a String is supplied for an Int64 field" do
      expect {
        run(<<~CLEAR)
          STRUCT Point { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
              p = Point{x: "hello", y: 2_i64};
              _ = p;
          END
        CLEAR
      }.to raise_error(CompilerError, /Field 'x' expected Int64/)
    end

    it "compiles when each field value matches its declared type" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = Point{x: 1_i64, y: 2_i64};
            print(p.x.toString());
        END
      CLEAR
    end
  end

  # @example_for: RETURN_VOID_FROM_TYPED
  # @fix: A function declared `RETURNS T` must return a T. A bare
  # @fix: `RETURN;` returns Void. Either return an actual T, or
  # @fix: change the declaration to `RETURNS Void` if the function
  # @fix: doesn't compute a value.
  describe ":RETURN_VOID_FROM_TYPED — bare `RETURN;` from a non-Void function" do
    it "raises when a `RETURNS Int64` function uses `RETURN;`" do
      expect {
        run(<<~CLEAR)
          FN compute() RETURNS Int64 ->
              print("computing");
              RETURN;
          END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /expects return type Int64, got Void/)
    end

    it "compiles when the function returns a value of the declared type" do
      run(<<~CLEAR)
        FN compute() RETURNS Int64 ->
            RETURN 42_i64;
        END
        FN main() RETURNS Void ->
            n = compute();
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: INT_LITERAL_OVERFLOW
  # @fix: The integer literal exceeds the target type's range. The
  # @fix: message names the specific range; either widen the
  # @fix: target type (e.g. `Byte` -> `Int64`) or change the
  # @fix: literal to fit. `clear fix` offers an :auto suffix-edit
  # @fix: when the literal is in suffixed form.
  describe ":INT_LITERAL_OVERFLOW — literal value too big for the declared type" do
    it "raises when 1000 is assigned to a Byte (max 255)" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              x: Byte = 1000;
              _ = x;
          END
        CLEAR
      }.to raise_error(CompilerError, /Integer literal \(1000\) overflows Byte/)
    end

    it "compiles when the literal fits the declared type" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            x: Byte = 100;
            print(x.toString());
        END
      CLEAR
    end
  end

  # @example_for: LIST_LITERAL_MIXED_TYPES
  # @fix: Every item in `[a, b, c]` must have the same type. The
  # @fix: first item sets the inferred element type; subsequent
  # @fix: items must match. Convert mismatched items, or split the
  # @fix: literal into homogeneous lists.
  describe ":LIST_LITERAL_MIXED_TYPES — mixed-type items in a list literal" do
    it "raises when a list literal mixes Int64 and String" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              items: Int64[] = [1_i64, "two", 3_i64];
              _ = items;
          END
        CLEAR
      }.to raise_error(CompilerError, /List literal contains mixed types/)
    end

    it "compiles when all items share the same type" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            items: Int64[] = [1_i64, 2_i64, 3_i64];
            print(items.length().toString());
        END
      CLEAR
    end
  end

  # @example_for: HASHMAP_MIXED_VALUES
  # @fix: HashMap is a `HashMap<V>` — every value shares one
  # @fix: declared `V` type. Adjust the values to match, or wrap
  # @fix: them in a UNION variant if you really do need
  # @fix: heterogeneous payloads.
  describe ":HASHMAP_MIXED_VALUES — HashMap literal values have mixed types" do
    it "raises when a HashMap literal mixes Int64 and String values" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              m = {"a": 1_i64, "b": "two"};
              _ = m;
          END
        CLEAR
      }.to raise_error(CompilerError, /HashMap must have all values be the same type/)
    end

    it "compiles when all map values share the same type" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            m: HashMap<Int64> = {"a": 1_i64, "b": 2_i64};
            print(m.count().toString());
        END
      CLEAR
    end

    it "allows mixed values in symbol-key kwargs maps" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            m = {:val: 1_i64, :type: :Int8};
            _ = m;
        END
      CLEAR
    end
  end

  # @example_for: BOUNDED_STREAM_MIXED_TYPES
  # @fix: A bounded-stream literal `[BG{...}, BG{...}]` produces
  # @fix: a `~T[N]` type — every BG block must produce the same
  # @fix: T. Either adjust the BG bodies to share a return type,
  # @fix: or split into separate streams.
  describe ":BOUNDED_STREAM_MIXED_TYPES — bounded-stream literal mixes promise types" do
    it "raises when BG blocks in a bounded-stream literal produce different types" do
      expect {
        run(<<~CLEAR)
          FN intFn() RETURNS Int64 -> RETURN 1; END
          FN strFn() RETURNS String -> RETURN "hi"; END
          FN main() RETURNS Void ->
              streams = [BG { intFn(); }, BG { strFn(); }];
              _ = streams;
          END
        CLEAR
      }.to raise_error(CompilerError, /Bounded stream literal contains mixed promise types/)
    end

    it "compiles when each BG block produces the same type" do
      run(<<~CLEAR)
        FN intFn() RETURNS Int64 -> RETURN 1; END
        FN main() RETURNS Void ->
            fut = BG { intFn(); };
            n = NEXT fut;
            print(n.toString());
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Optional / error union bucket (Type Bucket 4).
  #
  # Note: 4 codes deferred. MODIFIER_NEEDS_ERROR_UNION fires only
  # inside CONCURRENT pipeline ops with `OR_ELSE PRUNE` / `OR_ELSE RAISE` on
  # a non-fallible inner expression — niche shape. RETRY_ONLY_TRANSIENT
  # requires a WITH/EXCLUSIVE/Lock setup with an `ON ... RETRY(N)`
  # selector naming a non-Transient error type. ERROR_TYPE_RESERVED_BY_STDLIB
  # requires colliding with a stdlib-reserved name; ERROR_TYPE_KIND_CONFLICT
  # requires two RAISE sites mapping the same name to different kinds.
  # All four are annotatable in principle but the snippets balloon
  # past the "minimum reproducible example" sweet spot.
  # ============================================================

  # @example_for: UNWRAP_NON_OPTIONAL
  # @fix: The `?` postfix unwraps an optional (`?T`) type. On a
  # @fix: plain `T` there's nothing to unwrap. Either change the
  # @fix: source's declared type to `?T` (it can be NIL) or drop
  # @fix: the `?` and use the value directly.
  describe ":UNWRAP_NON_OPTIONAL — `x?` on a non-optional value" do
    it "raises when `?` is applied to a plain Int64 binding" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              n: Int64 = 5_i64;
              _ = n?;
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot unwrap non-optional type 'Int64'/)
    end

    it "compiles when consuming the optional via `IF expr EXISTS AS v THEN ...`" do
      run(<<~CLEAR)
        FN getN() RETURNS ?Int64 -> RETURN 5_i64; END
        FN main() RETURNS Void ->
            IF getN() EXISTS AS v THEN print(v.toString()); END
        END
      CLEAR
    end
  end

  # @example_for: IF_AS_NEEDS_OPTIONAL
  # @fix: `IF expr EXISTS AS v THEN ...` is the optional-binding form —
  # @fix: it requires `expr` to be `?T`. For a plain T, use a
  # @fix: regular `IF cond THEN ...` form. To get an optional,
  # @fix: declare the value's type as `?T`.
  describe ":IF_AS_NEEDS_OPTIONAL — `IF x EXISTS AS v` for non-optional x" do
    it "raises when the IF EXISTS AS expression is a plain Int64" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              n: Int64 = 5_i64;
              IF n EXISTS AS v THEN print(v.toString()); END
          END
        CLEAR
      }.to raise_error(CompilerError, /IF \.\.\. EXISTS AS binding requires an optional type, got 'Int64'/)
    end

    it "compiles when the binding source returns `?T`" do
      run(<<~CLEAR)
        FN getN() RETURNS ?Int64 -> RETURN 5_i64; END
        FN main() RETURNS Void ->
            IF getN() EXISTS AS v THEN print(v.toString()); END
        END
      CLEAR
    end
  end

  # @example_for: WHILE_AS_NEEDS_OPTIONAL
  # @fix: `WHILE expr EXISTS AS v DO ...` drains an optional source until
  # @fix: it returns NIL. The condition expression must be `?T`.
  # @fix: For an iteratable source, use a method that returns `?T`
  # @fix: per call (`list.pop()`, `iter.next()`).
  describe ":WHILE_AS_NEEDS_OPTIONAL — `WHILE x EXISTS AS v DO` for non-optional x" do
    it "raises when the WHILE EXISTS AS expression is a plain Int64" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              n: Int64 = 5_i64;
              WHILE n EXISTS AS v DO
                  print(v.toString());
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /WHILE \.\.\. EXISTS AS binding requires an optional type/)
    end

    it "compiles when the loop drains a list via `pop()`" do
      run(<<~CLEAR)
        FN main() RETURNS !Void ->
            MUTABLE items: Int64[5]@list = [];
            items.append(1_i64);
            WHILE items.pop() EXISTS AS v DO
                print(v.toString());
            END
            RETURN;
        END
      CLEAR
    end
  end

  # @example_for: TYPE_MISMATCH_IN_OR
  # @fix: `expr OR_ELSE alt` — when `expr` is `!T` or `?T`, the
  # @fix: fallback `alt` must produce a value of type `T` (the
  # @fix: payload). Adjust `alt` to return T, or change the
  # @fix: function's declared return so they line up.
  describe ":TYPE_MISMATCH_IN_OR — `expr OR_ELSE alt` fallback type doesn't match payload" do
    it "raises when a !Int64 is rescued with a String literal" do
      expect {
        run(<<~CLEAR)
          FN risky() RETURNS !Int64 -> RAISE Input, "bad"; RETURN 0; END
          FN main() RETURNS Void ->
              n = risky() OR_ELSE "fallback";
              _ = n;
          END
        CLEAR
      }.to raise_error(CompilerError, /Type mismatch in OR_ELSE: expected Int64/)
    end

    it "compiles when the fallback's type matches the payload" do
      run(<<~CLEAR)
        FN risky() RETURNS !Int64 -> RAISE Input, "bad"; RETURN 0; END
        FN main() RETURNS Void ->
            n = risky() OR_ELSE -1_i64;
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: OR_BREAK_OUTSIDE_WHILE
  # @fix: `expr OR_ELSE BREAK` is a loop-control fallback — it only
  # @fix: makes sense inside a WHILE body. Outside a loop, use
  # @fix: `OR_ELSE RAISE`, `OR_ELSE <fallback-value>`, or wrap the call in
  # @fix: a CATCH block.
  describe ":OR_BREAK_OUTSIDE_WHILE — `OR_ELSE BREAK` outside a loop" do
    it "raises when OR_ELSE BREAK is used at top level" do
      expect {
        run(<<~CLEAR)
          FN risky() RETURNS !Int64 -> RAISE Input, "bad"; RETURN 0; END
          FN main() RETURNS Void ->
              n = risky() OR_ELSE BREAK;
              print(n.toString());
          END
        CLEAR
      }.to raise_error(CompilerError, /OR_ELSE BREAK can only be used inside a WHILE loop/)
    end

    it "compiles when OR_ELSE BREAK is inside a WHILE loop body" do
      run(<<~CLEAR)
        FN risky() RETURNS !Int64 -> RAISE Input, "bad"; RETURN 0; END
        FN main() RETURNS Void ->
            MUTABLE i = 0_i64;
            WHILE i < 10_i64 DO
                n = risky() OR_ELSE BREAK;
                print(n.toString());
                i = i + 1_i64;
            END
        END
      CLEAR
    end
  end

  # @example_for: CATCH_WITH_UNREGISTERED
  # @fix: `CATCH Kind WITH(Type)` filters by a specific error
  # @fix: type. The named type must already be registered — first
  # @fix: introduced via a `RAISE Kind, Type, "msg"` site or in
  # @fix: src/ast/error_registry.rb. Either fix the spelling, or
  # @fix: add a RAISE site that registers the type.
  describe ":CATCH_WITH_UNREGISTERED — `CATCH ... WITH(Unknown)` references unregistered type" do
    it "raises when CATCH WITH names an undeclared error type" do
      expect {
        run(<<~CLEAR)
          FN risky() RETURNS !Int64 -> RAISE Input, ParseErr, "bad"; RETURN 0; END
          FN safe() RETURNS !Int64 ->
              n = risky() OR_ELSE RAISE;
              RETURN n;
          CATCH Input WITH(NeverDeclared)
              RETURN -1;
          END
          FN main() RETURNS Void -> _ = safe() OR_ELSE PASS; END
        CLEAR
      }.to raise_error(CompilerError, /error type 'NeverDeclared' is not registered/)
    end

    it "compiles when CATCH WITH names a registered error type" do
      run(<<~CLEAR)
        FN risky() RETURNS !Int64 -> RAISE Input, ParseErr, "bad"; RETURN 0; END
        FN safe() RETURNS Int64 ->
            n = risky() OR_ELSE -1;
            RETURN n;
        CATCH Input WITH(ParseErr)
            RETURN -1;
        END
        FN main() RETURNS Void ->
            n = safe();
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: ERROR_TYPE_NOT_REGISTERED
  # @fix: The first time a new error type appears it must come
  # @fix: with a kind: `RAISE Kind, NewType, "msg"`. After that
  # @fix: introduction, later sites can omit the kind and just say
  # @fix: `RAISE NewType, "msg"`. CLEAR's error registry tracks
  # @fix: the kind/name mapping; the first mention must establish it.
  describe ":ERROR_TYPE_NOT_REGISTERED — RAISE introduces a new type without a kind" do
    it "raises when a new error type is RAISEd without specifying a kind" do
      expect {
        run(<<~CLEAR)
          FN risky() RETURNS !Int64 -> RAISE BrandNew, "first use"; RETURN 0; END
          FN main() RETURNS Void -> _ = risky() OR_ELSE PASS; END
        CLEAR
      }.to raise_error(CompilerError, /Error type 'BrandNew' is not registered/)
    end

    it "compiles when the first RAISE supplies the kind" do
      run(<<~CLEAR)
        FN risky() RETURNS !Int64 -> RAISE Input, BrandNew, "first use"; RETURN 0; END
        FN main() RETURNS Void ->
            n = risky() OR_ELSE -1;
            print(n.toString());
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Loops & control flow bucket (Type Bucket 5).
  #
  # Note: INVALID_ASSIGNMENT_TARGET is deferred — every shape that
  # would reach the visitor (literal LHS, expression LHS, etc.) is
  # rejected by the parser first. ILLEGAL_BREAK and ILLEGAL_CONTINUE
  # were dead duplicates (the live BREAK_OUTSIDE_LOOP /
  # CONTINUE_OUTSIDE_LOOP fire instead) — deleted from the registry
  # in this commit.
  # ============================================================

  # @example_for: FOR_RANGE_START_NEEDS_INT64
  # @fix: `FOR i IN (a ..< b)` iterates Int64. The start expression
  # @fix: `a` must be Int64 — convert via CAST or use a literal
  # @fix: like `0_i64`.
  describe ":FOR_RANGE_START_NEEDS_INT64 — non-Int64 range start" do
    it "raises when the range start is a Float64" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              FOR i IN 0.5 ..< 10_i64 DO
                  print(i.toString());
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /FOR range start must be Int64/)
    end

    it "compiles with an Int64 start" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            FOR i IN 0_i64 ..< 3_i64 DO
                print(i.toString());
            END
        END
      CLEAR
    end
  end

  # @example_for: FOR_RANGE_END_NEEDS_INT64
  # @fix: `FOR i IN (a ..< b)` iterates Int64. The end expression
  # @fix: `b` must be Int64 — convert via CAST or use a literal
  # @fix: like `10_i64`.
  describe ":FOR_RANGE_END_NEEDS_INT64 — non-Int64 range end" do
    it "raises when the range end is a Float64" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              FOR i IN 0_i64 ..< 10.5 DO
                  print(i.toString());
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /FOR range end must be Int64/)
    end

    it "compiles with an Int64 end" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            FOR i IN 0_i64 ..< 3_i64 DO
                print(i.toString());
            END
        END
      CLEAR
    end
  end

  # @example_for: FOR_IN_NEEDS_COLLECTION
  # @fix: `FOR x IN coll` requires `coll` to be a collection
  # @fix: (array, list, map, range). For a scalar, use a `WHILE` or
  # @fix: a range-based FOR.
  describe ":FOR_IN_NEEDS_COLLECTION — `FOR x IN scalar`" do
    it "raises when iterating over a scalar Int64" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              FOR x IN 5_i64 DO
                  print(x.toString());
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /FOR \.\.\. IN requires an array, list, or map/)
    end

    it "compiles when iterating over an array" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            xs: Int64[] = [1_i64, 2_i64, 3_i64];
            FOR x IN xs DO
                print(x.toString());
            END
        END
      CLEAR
    end
  end

  # @example_for: CONDITION_NEEDS_BOOL
  # @fix: `WHILE cond DO ...` requires `cond` to be Bool. Convert
  # @fix: numeric/optional conditions explicitly: `WHILE n != 0_i64`,
  # @fix: `WHILE optVal EXISTS AS x DO ...` for the optional-binding form.
  describe ":CONDITION_NEEDS_BOOL — non-Bool WHILE condition" do
    it "raises when WHILE condition is an Int64" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              n: Int64 = 5_i64;
              WHILE n DO
                  print("looping");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /Condition must be a Boolean, got Int64/)
    end

    it "compiles when condition is an explicit Bool comparison" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE i: Int64 = 0_i64;
            WHILE i < 3_i64 DO
                i = i + 1_i64;
            END
        END
      CLEAR
    end
  end

  # @example_for: ASSERT_NEEDS_BOOL
  # @fix: ASSERT's first argument must be a Bool predicate. Wrap
  # @fix: numeric checks in an explicit comparison: `ASSERT n != 0,
  # @fix: "n must be non-zero"`.
  describe ":ASSERT_NEEDS_BOOL — non-Bool ASSERT predicate" do
    it "raises when ASSERT's predicate is an Int64" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              ASSERT 5_i64, "msg";
          END
        CLEAR
      }.to raise_error(CompilerError, /Assert condition must be Boolean/)
    end

    it "compiles when ASSERT's predicate is a Bool comparison" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            n = 5_i64;
            ASSERT n != 0_i64, "n must be non-zero";
        END
      CLEAR
    end
  end

  # @example_for: BREAK_OUTSIDE_LOOP
  # @fix: BREAK only makes sense inside a `FOR` or `WHILE` body.
  # @fix: Outside a loop, use `RETURN` or restructure the control
  # @fix: flow.
  describe ":BREAK_OUTSIDE_LOOP — BREAK at top level" do
    it "raises when BREAK appears outside any loop" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              BREAK;
          END
        CLEAR
      }.to raise_error(CompilerError, /BREAK must be used inside a loop/)
    end

    it "compiles when BREAK is inside a WHILE body" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE i: Int64 = 0_i64;
            WHILE i < 100_i64 DO
                IF i == 5_i64 THEN BREAK; END
                i = i + 1_i64;
            END
        END
      CLEAR
    end
  end

  # @example_for: CONTINUE_OUTSIDE_LOOP
  # @fix: CONTINUE only makes sense inside a `FOR` or `WHILE` body.
  # @fix: Outside a loop there's nothing to continue to; restructure
  # @fix: the control flow.
  describe ":CONTINUE_OUTSIDE_LOOP — CONTINUE at top level" do
    it "raises when CONTINUE appears outside any loop" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              CONTINUE;
          END
        CLEAR
      }.to raise_error(CompilerError, /CONTINUE must be used inside a loop/)
    end

    it "compiles when CONTINUE is inside a WHILE body" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE i: Int64 = 0_i64;
            WHILE i < 5_i64 DO
                i = i + 1_i64;
                IF i == 3_i64 THEN CONTINUE; END
                print(i.toString());
            END
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — MATCH pattern errors bucket (Type Bucket 6).
  # ============================================================

  # @example_for: MATCH_ENUM_CAPTURE
  # @fix: Enum variants have no payload, so there's nothing to bind
  # @fix: with `AS x`. Drop the `AS x` from the pattern; if you need
  # @fix: a payload, use a UNION variant with an inline-struct.
  describe ":MATCH_ENUM_CAPTURE — `Color.Red AS x` on an enum variant" do
    it "raises when capturing a payload from an enum variant" do
      expect {
        run(<<~CLEAR)
          ENUM Color { Red, Green, Blue }
          FN main() RETURNS Void ->
              c = Color.Red;
              MATCH c START
                  Color.Red AS x -> print("red");,
                  Color.Green -> print("green");,
                  Color.Blue -> print("blue");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot capture payload from enum variant/)
    end

    it "compiles when matching enum variants without AS" do
      run(<<~CLEAR)
        ENUM Color { Red, Green, Blue }
        FN main() RETURNS Void ->
            c = Color.Red;
            MATCH c START
                Color.Red -> print("red");,
                Color.Green -> print("green");,
                Color.Blue -> print("blue");
            END
        END
      CLEAR
    end
  end

  # @example_for: MATCH_UNIT_CAPTURE
  # @fix: Unit-shape union variants (declared as `Variant` with no
  # @fix: payload) have nothing to bind. Drop the `AS x`; if you
  # @fix: need a payload, declare the variant with an inline-struct
  # @fix: payload.
  describe ":MATCH_UNIT_CAPTURE — `Shape.Circle AS x` on a unit union variant" do
    it "raises when capturing a payload from a unit variant" do
      expect {
        run(<<~CLEAR)
          UNION Shape { Circle, Square }
          FN main() RETURNS Void ->
              s = Shape.Circle;
              MATCH s START
                  Shape.Circle AS x -> print("circle");,
                  Shape.Square -> print("square");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot bind 'AS x'.*'Circle' is a unit variant/)
    end

    it "compiles when matching unit variants without AS" do
      run(<<~CLEAR)
        UNION Shape { Circle, Square }
        FN main() RETURNS Void ->
            s = Shape.Circle;
            MATCH s START
                Shape.Circle -> print("circle");,
                Shape.Square -> print("square");
            END
        END
      CLEAR
    end
  end

  # @example_for: MATCH_NEEDS_STRUCT_TYPE
  # @fix: Struct-shaped patterns `{ x: ... }` only work on struct
  # @fix: subjects. For primitives, use a value-equality pattern
  # @fix: `MATCH n START 1 -> ..., 2 -> ..., ...`.
  describe ":MATCH_NEEDS_STRUCT_TYPE — struct pattern on a non-struct subject" do
    it "raises when struct-pattern is used on an Int64" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              n: Int64 = 5_i64;
              MATCH n START
                  { x: 1 } -> print("hi");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH struct pattern requires a struct type/)
    end

    it "compiles when struct-pattern matches a struct subject" do
      run(<<~CLEAR)
        STRUCT P { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = P{x: 1, y: 2};
            PARTIAL MATCH p START
                { x: 1 } -> print("x=1");,
                DEFAULT -> print("other");
            END
        END
      CLEAR
    end
  end

  # @example_for: MATCH_FIELD_TYPE_MISMATCH
  # @fix: Field-pattern values must match the field's declared
  # @fix: type. Adjust the literal to match the field's type, or
  # @fix: use a wildcard `{ x: _ }` to ignore the value.
  describe ":MATCH_FIELD_TYPE_MISMATCH — `{ x: \"str\" }` for an Int64 field" do
    it "raises when a field-pattern literal type doesn't match the field type" do
      expect {
        run(<<~CLEAR)
          STRUCT P { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
              p = P{x: 1, y: 2};
              PARTIAL MATCH p START
                  { x: "str" } -> print("hi");,
                  DEFAULT -> print("other");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH struct pattern: field 'x' has type Int64/)
    end

    it "compiles when the literal type matches the field type" do
      run(<<~CLEAR)
        STRUCT P { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = P{x: 1, y: 2};
            PARTIAL MATCH p START
                { x: 1 } -> print("x=1");,
                DEFAULT -> print("other");
            END
        END
      CLEAR
    end
  end

  # @example_for: WHEN_NEEDS_BOOL
  # @fix: A `WHEN` guard clause's condition must be Bool. Wrap
  # @fix: numeric/optional checks in a comparison: `WHEN n > 0`,
  # @fix: `WHEN p.flag`.
  describe ":WHEN_NEEDS_BOOL — non-Bool WHEN guard condition" do
    it "raises when a WHEN guard condition is an Int64" do
      expect {
        run(<<~CLEAR)
          ENUM Color { Red, Green, Blue }
          FN main() RETURNS Void ->
              c = Color.Red;
              PARTIAL MATCH c START
                  WHEN 5_i64 -> print("hi");,
                  DEFAULT -> print("other");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /WHEN condition must be Bool/)
    end

    it "compiles when the WHEN guard is a Bool comparison" do
      run(<<~CLEAR)
        STRUCT P { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = P{x: 5, y: 10};
            PARTIAL MATCH p START
                WHEN p.x > 0_i64 -> print("positive");,
                DEFAULT -> print("other");
            END
        END
      CLEAR
    end
  end

  # @example_for: MATCH_CASE_TYPE_MISMATCH
  # @fix: Each MATCH case's literal must match the matched
  # @fix: expression's type. Adjust the literal, or use a struct/
  # @fix: enum/union pattern that's compatible.
  describe ":MATCH_CASE_TYPE_MISMATCH — case literal type doesn't match subject type" do
    it "raises when a String literal is matched against an Int64" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              n: Int64 = 5_i64;
              PARTIAL MATCH n START
                  "str" -> print("hi");,
                  DEFAULT -> print("other");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH case type.*does not match expression type Int64/)
    end

    it "compiles when each case literal matches the subject type" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            n: Int64 = 5_i64;
            PARTIAL MATCH n START
                1_i64 -> print("one");,
                DEFAULT -> print("other");
            END
        END
      CLEAR
    end
  end

  # @example_for: MATCH_NEEDS_ENUM_OR_UNION
  # @fix: `MATCH` (without `PARTIAL`) requires a discriminated
  # @fix: subject — an enum or a union — so the compiler can verify
  # @fix: exhaustiveness. For non-discriminated subjects (numbers,
  # @fix: strings, struct shapes, WHEN guards), use `PARTIAL MATCH`.
  describe ":MATCH_NEEDS_ENUM_OR_UNION — MATCH on a primitive" do
    it "raises when MATCH is used on an Int64 (use PARTIAL MATCH instead)" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              n: Int64 = 5_i64;
              MATCH n START
                  1_i64 -> print("one");,
                  2_i64 -> print("two");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH requires an enum or union type/)
    end

    it "compiles with PARTIAL MATCH on a primitive" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            n: Int64 = 5_i64;
            PARTIAL MATCH n START
                1_i64 -> print("one");,
                DEFAULT -> print("other");
            END
        END
      CLEAR
    end
  end

  # @example_for: MATCH_FORBIDS_DEFAULT
  # @fix: Plain `MATCH` must be exhaustive — every variant has its
  # @fix: own case. A DEFAULT branch defeats the exhaustiveness
  # @fix: check, so it's only allowed under `PARTIAL MATCH`.
  describe ":MATCH_FORBIDS_DEFAULT — MATCH with a DEFAULT branch" do
    it "raises when a plain MATCH includes DEFAULT" do
      expect {
        run(<<~CLEAR)
          ENUM Color { Red, Green, Blue }
          FN main() RETURNS Void ->
              c = Color.Red;
              MATCH c START
                  Color.Red -> print("r");,
                  DEFAULT -> print("other");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH cannot have a DEFAULT branch/)
    end

    it "compiles with PARTIAL MATCH + DEFAULT" do
      run(<<~CLEAR)
        ENUM Color { Red, Green, Blue }
        FN main() RETURNS Void ->
            c = Color.Red;
            PARTIAL MATCH c START
                Color.Red -> print("r");,
                DEFAULT -> print("other");
            END
        END
      CLEAR
    end
  end

  # @example_for: MATCH_FORBIDS_WHEN
  # @fix: WHEN guards make a case conditional, which breaks
  # @fix: exhaustiveness. Use `PARTIAL MATCH` if you need a guard.
  describe ":MATCH_FORBIDS_WHEN — MATCH with a WHEN guard case" do
    it "raises when plain MATCH contains a WHEN-guard case" do
      expect {
        run(<<~CLEAR)
          ENUM Color { Red, Green, Blue }
          FN main() RETURNS Void ->
              c = Color.Red;
              MATCH c START
                  WHEN TRUE -> print("hi");,
                  Color.Green -> print("g");,
                  Color.Blue -> print("b");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH cannot contain WHEN guards/)
    end

    it "compiles with PARTIAL MATCH + WHEN" do
      run(<<~CLEAR)
        ENUM Color { Red, Green, Blue }
        FN main() RETURNS Void ->
            c = Color.Red;
            PARTIAL MATCH c START
                WHEN TRUE -> print("hi");,
                DEFAULT -> print("other");
            END
        END
      CLEAR
    end
  end

  # @example_for: MATCH_NON_EXHAUSTIVE
  # @fix: Plain `MATCH` requires every variant of the
  # @fix: enum / union to have a case. Either add cases for the
  # @fix: missing variants, or change to `PARTIAL MATCH` and add
  # @fix: a DEFAULT.
  describe ":MATCH_NON_EXHAUSTIVE — MATCH missing variant cases" do
    it "raises when MATCH on Color omits a variant" do
      expect {
        run(<<~CLEAR)
          ENUM Color { Red, Green, Blue }
          FN main() RETURNS Void ->
              c = Color.Red;
              MATCH c START
                  Color.Red -> print("r");,
                  Color.Green -> print("g");
              END
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH on enum 'Color' is non-exhaustive/)
    end

    it "compiles when every variant has a case" do
      run(<<~CLEAR)
        ENUM Color { Red, Green, Blue }
        FN main() RETURNS Void ->
            c = Color.Red;
            MATCH c START
                Color.Red -> print("r");,
                Color.Green -> print("g");,
                Color.Blue -> print("b");
            END
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — IF / MATCH expression bucket (Type Bucket 7).
  #
  # Note: IF_EXPR_RESULT_NOT_COPYABLE and MATCH_EXPR_RESULT_NOT_COPYABLE
  # are deferred — they fire only when the IF/MATCH-expression's
  # result type is non-Copy AND the binding context isn't ready
  # for a move-style result. The shapes balloon past a clean
  # snippet. MATCH_EXPR_NEEDS_CASE is shadowed by MATCH_NON_EXHAUSTIVE
  # for the obvious `MATCH x START END` shape.
  # ============================================================

  # @example_for: IF_EXPR_THEN_NEEDS_VALUE
  # @fix: When IF is used as an expression (`x = IF ... THEN ...
  # @fix: ELSE ... END`), the THEN branch's last statement must
  # @fix: evaluate to a value of the result type. Replace the void
  # @fix: call with a value, or restructure as a statement.
  describe ":IF_EXPR_THEN_NEEDS_VALUE — IF expression's THEN ends with Void" do
    it "raises when the THEN branch ends with a Void-returning call" do
      expect {
        run(<<~CLEAR)
          FN doStuff() RETURNS Void -> END
          FN main() RETURNS Void ->
              x = IF 1_i64 == 1_i64 THEN doStuff() ELSE 0 END;
              _ = x;
          END
        CLEAR
      }.to raise_error(CompilerError, /IF expression: THEN branch must end with a value/)
    end

    it "compiles when both branches end with values of the same type" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            x = IF 1_i64 == 1_i64 THEN 42 ELSE 0 END;
            print(x.toString());
        END
      CLEAR
    end
  end

  # @example_for: IF_EXPR_NEEDS_ELSE
  # @fix: Expression-form IF must produce a value on every path —
  # @fix: that requires an explicit ELSE branch. Add one, or drop
  # @fix: the assignment and use a statement-form IF.
  describe ":IF_EXPR_NEEDS_ELSE — IF used as expression with no ELSE" do
    it "raises when an IF-expression has no ELSE branch" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              x = IF 1_i64 == 1_i64 THEN 5 END;
              _ = x;
          END
        CLEAR
      }.to raise_error(CompilerError, /IF used as expression requires an ELSE branch/)
    end

    it "compiles when the IF-expression has an ELSE branch" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            x = IF 1_i64 == 1_i64 THEN 5 ELSE 0 END;
            print(x.toString());
        END
      CLEAR
    end
  end

  # @example_for: IF_EXPR_ELSE_NEEDS_VALUE
  # @fix: Same as IF_EXPR_THEN_NEEDS_VALUE for the ELSE branch — it
  # @fix: must end with a value of the result type.
  describe ":IF_EXPR_ELSE_NEEDS_VALUE — IF expression's ELSE ends with Void" do
    it "raises when the ELSE branch ends with a Void-returning call" do
      expect {
        run(<<~CLEAR)
          FN doStuff() RETURNS Void -> END
          FN main() RETURNS Void ->
              x = IF 1_i64 == 1_i64 THEN 5 ELSE doStuff() END;
              _ = x;
          END
        CLEAR
      }.to raise_error(CompilerError, /IF expression: ELSE branch must end with a value/)
    end

    it "compiles when both branches end with values" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            x = IF 1_i64 == 1_i64 THEN 5 ELSE 0 END;
            print(x.toString());
        END
      CLEAR
    end
  end

  # @example_for: IF_EXPR_BRANCHES_INCOMPATIBLE
  # @fix: Both branches of an IF-expression must produce the same
  # @fix: type. Adjust one branch's value to match, or split the
  # @fix: assignment based on the discriminator type the branches
  # @fix: produce.
  describe ":IF_EXPR_BRANCHES_INCOMPATIBLE — IF-expression branches return different types" do
    it "raises when THEN returns Int64 and ELSE returns String" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              x = IF 1_i64 == 1_i64 THEN 5_i64 ELSE "five" END;
              _ = x;
          END
        CLEAR
      }.to raise_error(CompilerError, /IF expression branches have incompatible types/)
    end

    it "compiles when both branches produce the same type" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            x = IF 1_i64 == 1_i64 THEN 5_i64 ELSE 0_i64 END;
            print(x.toString());
        END
      CLEAR
    end
  end

  # @example_for: MATCH_EXPR_BRANCH_NEEDS_VALUE
  # @fix: When MATCH is used as an expression, every branch's last
  # @fix: statement must evaluate to a value. Replace any
  # @fix: Void-returning call with an explicit value.
  describe ":MATCH_EXPR_BRANCH_NEEDS_VALUE — MATCH-expression branch ends with Void" do
    it "raises when a branch's last expression is a Void-returning call" do
      expect {
        run(<<~CLEAR)
          FN doStuff() RETURNS Void -> END
          ENUM Color { Red, Green, Blue }
          FN main() RETURNS Void ->
              c = Color.Red;
              n = MATCH c START
                  Color.Red -> doStuff(),
                  Color.Green -> 2_i64,
                  Color.Blue -> 3_i64
              END;
              _ = n;
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH expression: every branch must end with a value/)
    end

    it "compiles when every branch ends with a same-typed value" do
      run(<<~CLEAR)
        ENUM Color { Red, Green, Blue }
        FN main() RETURNS Void ->
            c = Color.Red;
            n = MATCH c START
                Color.Red -> 1_i64,
                Color.Green -> 2_i64,
                Color.Blue -> 3_i64
            END;
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: MATCH_EXPR_BRANCHES_INCOMPATIBLE
  # @fix: MATCH-expression branches must produce the same type.
  # @fix: Adjust the inconsistent branch, or split into separate
  # @fix: assignments per discriminator.
  describe ":MATCH_EXPR_BRANCHES_INCOMPATIBLE — MATCH-expression branches return different types" do
    it "raises when one branch produces String and the rest produce Int64" do
      expect {
        run(<<~CLEAR)
          ENUM Color { Red, Green, Blue }
          FN main() RETURNS Void ->
              c = Color.Red;
              n = MATCH c START
                  Color.Red -> 1_i64,
                  Color.Green -> "g",
                  Color.Blue -> 3_i64
              END;
              _ = n;
          END
        CLEAR
      }.to raise_error(CompilerError, /MATCH expression branches have incompatible types/)
    end

    it "compiles when every branch produces the same type" do
      run(<<~CLEAR)
        ENUM Color { Red, Green, Blue }
        FN main() RETURNS Void ->
            c = Color.Red;
            n = MATCH c START
                Color.Red -> 1_i64,
                Color.Green -> 2_i64,
                Color.Blue -> 3_i64
            END;
            print(n.toString());
        END
      CLEAR
    end
  end

  # @example_for: PARTIAL_MATCH_EXPR_NEEDS_DEFAULT
  # @fix: A `PARTIAL MATCH` used as an expression must cover every
  # @fix: path — either add a `DEFAULT -> value` branch, or change
  # @fix: to a plain `MATCH` (which forces every variant to have an
  # @fix: exact case).
  describe ":PARTIAL_MATCH_EXPR_NEEDS_DEFAULT — PARTIAL MATCH expression w/o DEFAULT" do
    it "raises when a PARTIAL MATCH expression has no DEFAULT branch" do
      expect {
        run(<<~CLEAR)
          ENUM Color { Red, Green, Blue }
          FN main() RETURNS Void ->
              c = Color.Red;
              n = PARTIAL MATCH c START
                  Color.Red -> 1_i64
              END;
              _ = n;
          END
        CLEAR
      }.to raise_error(CompilerError, /PARTIAL MATCH used in expression position requires a DEFAULT/)
    end

    it "compiles when the PARTIAL MATCH expression has a DEFAULT branch" do
      run(<<~CLEAR)
        ENUM Color { Red, Green, Blue }
        FN main() RETURNS Void ->
            c = Color.Red;
            n = PARTIAL MATCH c START
                Color.Red -> 1_i64,
                DEFAULT -> 0_i64
            END;
            print(n.toString());
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Struct literal completeness bucket (Type Bucket 8).
  #
  # Note: MISSING_FIELD_VALUE and MISSING_REQUIRED_STRUCT_FIELD
  # were dead duplicates (never fired anywhere; the live
  # STRUCT_LITERAL_MISSING_FIELDS covers the case). Both deleted
  # from the registry in this commit.
  # ============================================================

  # @example_for: STRUCT_LITERAL_MISSING_FIELDS
  # @fix: Empty struct literal `Foo{}` is only valid when every
  # @fix: field has a default. Provide values for the listed
  # @fix: fields, or add `field: <default>` to the STRUCT
  # @fix: declaration so subsequent uses can leave them blank.
  describe ":STRUCT_LITERAL_MISSING_FIELDS — empty struct literal without defaults" do
    it "raises when `Foo{}` is used on a struct whose fields have no defaults" do
      expect {
        run(<<~CLEAR)
          STRUCT Point { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
              p = Point{};
              _ = p;
          END
        CLEAR
      }.to raise_error(CompilerError, /'Point\{\}' — field\(s\) x, y have no default values/)
    end

    it "compiles when each field gets a value" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = Point{x: 0_i64, y: 0_i64};
            print(p.x.toString());
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Indexing & subscript bucket (Type Bucket 9).
  # ============================================================

  # @example_for: NUMERIC_MAP_KEY_BAD
  # @fix: A `HashMap<K, V>` declared with a numeric K only accepts
  # @fix: numeric keys at index sites. Convert the index expression
  # @fix: to the declared key type, or change the map's key type to
  # @fix: match what the call sites use.
  describe ":NUMERIC_MAP_KEY_BAD — non-numeric key on a numeric-keyed HashMap" do
    it "raises when a String key is used on a HashMap<Int64, Int64>" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              MUTABLE m: HashMap<Int64, Int64> = {};
              m["str"] = 1_i64;
          END
        CLEAR
      }.to raise_error(CompilerError, /Numeric map keys must be a number type/)
    end

    it "compiles with a matching numeric key" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE m: HashMap<Int64, Int64> = {};
            m[1_i64] = 100_i64;
            print(m.count().toString());
        END
      CLEAR
    end
  end

  # @example_for: STRING_MAP_KEY_BAD
  # @fix: A `HashMap<V>` (defaulting to String keys) only accepts
  # @fix: String keys. For numeric keys, declare the map as
  # @fix: `HashMap<NumericType, V>`.
  describe ":STRING_MAP_KEY_BAD — non-String key on a String-keyed HashMap" do
    it "raises when an Int64 is used as a key on a HashMap<V>" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m[5_i64] = 1_i64;
          END
        CLEAR
      }.to raise_error(CompilerError, /Map keys must be Strings/)
    end

    it "compiles with a String key" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            m["a"] = 1_i64;
            print(m.count().toString());
        END
      CLEAR
    end
  end

  # @example_for: STRING_INDEX_BY_INT
  # @fix: CLEAR strings are UTF-8 by default — `s[i]` would mean
  # @fix: a byte index, which can split a multi-byte codepoint.
  # @fix: For byte access, declare the binding as `String@raw`.
  # @fix: For codepoint iteration, use `s.codepoints()` (or
  # @fix: `s.length()` for the byte count, `s.charAt(i)` for a
  # @fix: codepoint at index i).
  describe ":STRING_INDEX_BY_INT — `s[i]` on a UTF-8 String" do
    it "raises when an Int64 indexes a String" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              s = "hello";
              c = s[0_i64];
              _ = c;
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot index String by integer/)
    end

    it "compiles when using `.length()` instead of indexing" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            s = "hello";
            print(s.length().toString());
        END
      CLEAR
    end
  end

  # @example_for: UNSUPPORTED_INDEX
  # @fix: `expr[i]` only works on collections (array, list, map).
  # @fix: For a primitive, there's nothing to index. Use the value
  # @fix: directly, or wrap it in a single-element collection.
  describe ":UNSUPPORTED_INDEX — `n[i]` for a non-collection receiver" do
    it "raises when indexing into an Int64" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              n: Int64 = 5_i64;
              x = n[0_i64];
              _ = x;
          END
        CLEAR
      }.to raise_error(CompilerError, /Unsupported Index/)
    end

    it "compiles when indexing into an array" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            xs: Int64[] = [10_i64, 20_i64, 30_i64];
            n = xs[0_i64];
            print(n.toString());
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Range literals bucket (Type Bucket 10).
  # ============================================================

  # @example_for: RANGE_START_NEEDS_NUMERIC
  # @fix: Range literals (`a ..< b`) iterate numerically. The start
  # @fix: expression must be a numeric type — Int64, Float64, etc.
  # @fix: Convert via CAST or use a numeric literal.
  describe ":RANGE_START_NEEDS_NUMERIC — range start is non-numeric" do
    it "raises when the range start is a String" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              r = ("a" ..< 10_i64);
              _ = r;
          END
        CLEAR
      }.to raise_error(CompilerError, /Range start must be a numeric type/)
    end

    it "compiles when both ends are numeric" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            FOR i IN 0_i64 ..< 3_i64 DO
                print(i.toString());
            END
        END
      CLEAR
    end
  end

  # @example_for: RANGE_END_NEEDS_NUMERIC
  # @fix: Same as RANGE_START_NEEDS_NUMERIC — the range end
  # @fix: expression must be a numeric type. Convert via CAST or
  # @fix: use a numeric literal.
  describe ":RANGE_END_NEEDS_NUMERIC — range end is non-numeric" do
    it "raises when the range end is a String" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              r = (0_i64 ..< "z");
              _ = r;
          END
        CLEAR
      }.to raise_error(CompilerError, /Range end must be a numeric type/)
    end

    it "compiles when both ends are numeric" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            FOR i IN 0_i64 ..< 3_i64 DO
                print(i.toString());
            END
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Union variant & method constraints (Type Bucket 11).
  #
  # All 19 codes have firing sites and clean snippets. Tagged unions
  # are the main place a scripting dev meets ADT-style errors —
  # closest analogue is TypeScript's discriminated unions, but
  # CLEAR's enforce shape strictly at compile time.
  # ============================================================

  # @example_for: UNION_PAYLOAD_MISMATCH
  # @fix: The variant's payload type doesn't match what was passed.
  # @fix: Convert the value to the declared payload type, or change
  # @fix: the UNION declaration's variant type to match.
  describe ":UNION_PAYLOAD_MISMATCH — variant payload value is the wrong type" do
    it "raises when a String is passed to a variant declared as Int64" do
      expect {
        run(<<~CLEAR)
          UNION Result { Ok: Int64, Err: String }
          FN main() RETURNS Void ->
              r = Result{Ok: "hello"};
              _ = r;
          END
        CLEAR
      }.to raise_error(CompilerError, /Union variant 'Ok' expects Int64/)
    end

    it "compiles when the payload value matches the declared type" do
      run(<<~CLEAR)
        UNION Result { Ok: Int64, Err: String }
        FN main() RETURNS Void ->
            r = Result{Ok: 42_i64};
            _ = r;
        END
      CLEAR
    end
  end

  # @example_for: UNION_FIELD_ACCESS
  # @fix: Union values aren't structs — `u.field` doesn't make
  # @fix: sense without first matching a variant. Use
  # @fix: `MATCH u START Variant AS x -> x.field;` to extract
  # @fix: the payload then read its fields.
  describe ":UNION_FIELD_ACCESS — `u.field` on a union value" do
    it "raises when field-accessing a union value directly" do
      expect {
        run(<<~CLEAR)
          UNION Shape { Circle, Square }
          FN main() RETURNS Void ->
              s = Shape.Circle;
              _ = s.radius;
          END
        CLEAR
      }.to raise_error(CompilerError, /'Shape' is a union type/)
    end

    it "compiles when the field is read inside a MATCH branch" do
      run(<<~CLEAR)
        UNION Shape { Circle { radius: Float64 }, Square }
        FN main() RETURNS Void ->
            s = Shape.Circle{radius: 5.0};
            PARTIAL MATCH s START
                Shape.Circle AS c -> print(c.radius.toString());,
                DEFAULT -> print("other");
            END
        END
      CLEAR
    end
  end

  # @example_for: UNION_LITERAL_VARIANT_COUNT
  # @fix: A union literal `Type{Variant: value}` constructs exactly
  # @fix: one variant. Specify just one, or split into separate
  # @fix: bindings if you need multiple variants.
  describe ":UNION_LITERAL_VARIANT_COUNT — union literal with multiple variants" do
    it "raises when a union literal lists two variants" do
      expect {
        run(<<~CLEAR)
          UNION Result { Ok: Int64, Err: Int64 }
          FN main() RETURNS Void ->
              r = Result{Ok: 1, Err: 2};
              _ = r;
          END
        CLEAR
      }.to raise_error(CompilerError, /Union literal 'Result' must specify exactly one variant/)
    end

    it "compiles with a single-variant union literal" do
      run(<<~CLEAR)
        UNION Result { Ok: Int64, Err: Int64 }
        FN main() RETURNS Void ->
            r = Result{Ok: 1_i64};
            _ = r;
        END
      CLEAR
    end
  end

  # @example_for: UNION_VARIANT_IS_UNIT_NO_PAYLOAD
  # @fix: A unit variant (declared without a payload type) can't
  # @fix: take a value. Use `Type.Variant` directly — no braces, no
  # @fix: payload.
  describe ":UNION_VARIANT_IS_UNIT_NO_PAYLOAD — payload supplied to a unit variant" do
    it "raises when supplying a value for a unit variant" do
      expect {
        run(<<~CLEAR)
          UNION Result { Ok: Int64, Empty }
          FN main() RETURNS Void ->
              r = Result{Empty: 0};
              _ = r;
          END
        CLEAR
      }.to raise_error(CompilerError, /Union variant 'Empty' is a unit variant — use 'Result\.Empty'/)
    end

    it "compiles when accessing a unit variant via dot syntax" do
      run(<<~CLEAR)
        UNION Result { Ok: Int64, Empty }
        FN main() RETURNS Void ->
            r = Result.Empty;
            _ = r;
        END
      CLEAR
    end
  end

  # @example_for: UNION_VARIANT_IS_UNIT_NO_FIELDS
  # @fix: Inline-struct construction `Type.Variant{field: ...}`
  # @fix: only works on inline-struct variants. For unit variants,
  # @fix: use `Type.Variant` (no braces).
  describe ":UNION_VARIANT_IS_UNIT_NO_FIELDS — `Variant{...}` on a unit variant" do
    it "raises when constructing a unit variant with field syntax" do
      expect {
        run(<<~CLEAR)
          UNION Shape { Circle, Square }
          FN main() RETURNS Void ->
              s = Shape.Circle{radius: 5.0};
              _ = s;
          END
        CLEAR
      }.to raise_error(CompilerError, /Union variant 'Circle' is a unit variant/)
    end

    it "compiles when constructing a unit variant via dot syntax" do
      run(<<~CLEAR)
        UNION Shape { Circle, Square }
        FN main() RETURNS Void ->
            s = Shape.Circle;
            _ = s;
        END
      CLEAR
    end
  end

  # @example_for: UNION_VARIANT_NEEDS_PAYLOAD_OBJECT
  # @fix: Single-typed payload variants are constructed with
  # @fix: `Type{Variant: value}`, not the inline-struct form.
  # @fix: Inline-struct form is reserved for variants declared with
  # @fix: `{ field: T, ... }`.
  describe ":UNION_VARIANT_NEEDS_PAYLOAD_OBJECT — `Variant{...}` on single-payload variant" do
    it "raises when using inline-struct form on a single-payload variant" do
      expect {
        run(<<~CLEAR)
          UNION Result { Ok: Int64, Err: Int64 }
          FN main() RETURNS Void ->
              r = Result.Ok{val: 5};
              _ = r;
          END
        CLEAR
      }.to raise_error(CompilerError, /Union variant 'Ok' takes a single typed payload — use 'Result\{ Ok: value \}'/)
    end

    it "compiles when using `Type{Variant: value}` form" do
      run(<<~CLEAR)
        UNION Result { Ok: Int64, Err: Int64 }
        FN main() RETURNS Void ->
            r = Result{Ok: 5_i64};
            _ = r;
        END
      CLEAR
    end
  end

  # @example_for: NOT_A_UNION_TYPE
  # @fix: `Type.Variant{...}` syntax only applies to UNION types.
  # @fix: For a struct, use `Type{field: value}`. For an enum, use
  # @fix: `Type.Variant` (no braces).
  describe ":NOT_A_UNION_TYPE — variant syntax on a non-UNION type" do
    it "raises when applying variant syntax to a struct type" do
      expect {
        run(<<~CLEAR)
          STRUCT Point { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
              p = Point.Origin{};
              _ = p;
          END
        CLEAR
      }.to raise_error(CompilerError, /'Point' is not a union type/)
    end

    it "compiles when constructing a struct directly" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = Point{x: 0_i64, y: 0_i64};
            _ = p;
        END
      CLEAR
    end
  end

  # @example_for: UNION_INLINE_VARIANT_NEEDS_BRACES
  # @fix: Inline-struct variants require the `{field: value}` form
  # @fix: at construction. Even with empty inline structs, the
  # @fix: braces are required.
  describe ":UNION_INLINE_VARIANT_NEEDS_BRACES — `Type.Variant` without braces on inline-struct" do
    it "raises when accessing an inline-struct variant by dot only" do
      expect {
        run(<<~CLEAR)
          UNION Shape { Circle { radius: Float64 }, Square }
          FN main() RETURNS Void ->
              s = Shape.Circle;
              _ = s;
          END
        CLEAR
      }.to raise_error(CompilerError, /'Shape\.Circle' is an inline struct variant/)
    end

    it "compiles when constructing the inline variant with braces" do
      run(<<~CLEAR)
        UNION Shape { Circle { radius: Float64 }, Square }
        FN main() RETURNS Void ->
            s = Shape.Circle{radius: 5.0};
            _ = s;
        END
      CLEAR
    end
  end

  # @example_for: UNION_INLINE_VARIANT_OLD_SYNTAX
  # @fix: For inline-struct variants, the modern syntax is
  # @fix: `Type.Variant{field: value}`. The legacy
  # @fix: `Type{Variant: value}` form is reserved for single-typed
  # @fix: payload variants only.
  describe ":UNION_INLINE_VARIANT_OLD_SYNTAX — `Type{Variant: ...}` on inline-struct variant" do
    it "raises when using old-syntax variant construction on an inline-struct" do
      expect {
        run(<<~CLEAR)
          UNION Shape { Circle { radius: Float64 }, Square }
          FN main() RETURNS Void ->
              s = Shape{Circle: 5.0};
              _ = s;
          END
        CLEAR
      }.to raise_error(CompilerError, /'Shape' variant 'Circle' has inline struct fields/)
    end

    it "compiles when using the modern `Type.Variant{...}` form" do
      run(<<~CLEAR)
        UNION Shape { Circle { radius: Float64 }, Square }
        FN main() RETURNS Void ->
            s = Shape.Circle{radius: 5.0};
            _ = s;
        END
      CLEAR
    end
  end

  # @example_for: UNION_INLINE_VARIANT_TYPE_MISMATCH
  # @fix: Inline-struct variant fields are typed; values must match
  # @fix: the declared field type. Convert the value or change the
  # @fix: variant declaration to match.
  describe ":UNION_INLINE_VARIANT_TYPE_MISMATCH — inline-struct field value is wrong type" do
    it "raises when a String is supplied for a Float64 field" do
      expect {
        run(<<~CLEAR)
          UNION Shape { Circle { radius: Float64 }, Square }
          FN main() RETURNS Void ->
              s = Shape.Circle{radius: "big"};
              _ = s;
          END
        CLEAR
      }.to raise_error(CompilerError, /Union variant 'Shape\.Circle' field 'radius' expects Float64/)
    end

    it "compiles when the field value matches the declared type" do
      run(<<~CLEAR)
        UNION Shape { Circle { radius: Float64 }, Square }
        FN main() RETURNS Void ->
            s = Shape.Circle{radius: 5.0};
            _ = s;
        END
      CLEAR
    end
  end

  # @example_for: UNION_INLINE_VARIANT_MISSING_FIELD
  # @fix: Every field declared on the inline-struct variant must
  # @fix: appear in the construction. Provide values for the
  # @fix: missing fields, or supply defaults in the variant
  # @fix: declaration.
  describe ":UNION_INLINE_VARIANT_MISSING_FIELD — inline-struct missing a required field" do
    it "raises when an inline-struct variant omits a required field" do
      expect {
        run(<<~CLEAR)
          UNION Shape { Circle { radius: Float64, color: String }, Square }
          FN main() RETURNS Void ->
              s = Shape.Circle{radius: 5.0};
              _ = s;
          END
        CLEAR
      }.to raise_error(CompilerError, /Union variant 'Shape\.Circle' is missing required field 'color'/)
    end

    it "compiles when every field is supplied" do
      run(<<~CLEAR)
        UNION Shape { Circle { radius: Float64, color: String }, Square }
        FN main() RETURNS Void ->
            s = Shape.Circle{radius: 5.0, color: "red"};
            _ = s;
        END
      CLEAR
    end
  end

  # @example_for: UNION_INLINE_IN_GENERIC
  # @fix: Generic unions (`UNION Box<T>`) don't yet support inline
  # @fix: struct variants — the monomorphizer can't expand `{ field: T }`
  # @fix: cleanly. Use single-typed payload variants instead:
  # @fix: `UNION Box<T> { Filled: T, Empty }`.
  describe ":UNION_INLINE_IN_GENERIC — inline-struct variant in a generic UNION" do
    it "raises when a generic UNION uses inline-struct variants" do
      expect {
        run(<<~CLEAR)
          UNION Box<T> { Filled { value: T }, Empty }
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /Inline struct variants are not supported in generic unions/)
    end

    it "compiles with single-typed payload variants in a generic UNION" do
      run(<<~CLEAR)
        UNION Box<T> { Filled: T, Empty }
        FN main() RETURNS Void ->
            b: Box<Int64> = Box<Int64>{Filled: 42_i64};
            _ = b;
        END
      CLEAR
    end
  end

  # @example_for: UNION_METHOD_MISSING
  # @fix: A UNION can declare required methods (`FN name(...)
  # @fix: RETURNS T` inside the UNION block). Each declared method
  # @fix: must have a matching top-level FN. Implement the missing
  # @fix: function, or remove the method declaration from the UNION.
  describe ":UNION_METHOD_MISSING — UNION declares a method with no implementation" do
    it "raises when no top-level function matches the declared method" do
      expect {
        run(<<~CLEAR)
          UNION Shape {
              Circle { radius: Float64 },
              FN area(s: Shape) RETURNS Float64
          }
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /Union 'Shape' requires method 'area'/)
    end

    it "compiles when a matching top-level function exists" do
      run(<<~CLEAR)
        UNION Shape {
            Circle { radius: Float64 },
            FN area(s: Shape) RETURNS Float64
        }
        FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
        FN main() RETURNS Void -> END
      CLEAR
    end
  end

  # @example_for: UNION_METHOD_WRONG_ARITY
  # @fix: The implementation function's parameter count must match
  # @fix: the method declaration. Adjust either the FN signature or
  # @fix: the UNION's method declaration so they line up.
  describe ":UNION_METHOD_WRONG_ARITY — implementation has wrong parameter count" do
    it "raises when the implementation has more parameters than declared" do
      expect {
        run(<<~CLEAR)
          UNION Shape {
              Circle { radius: Float64 },
              FN area(s: Shape) RETURNS Float64
          }
          FN area(s: Shape, n: Float64) RETURNS Float64 -> RETURN 0.0; END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /Union 'Shape' method 'area' requires 1 parameter/)
    end

    it "compiles when the parameter counts match" do
      run(<<~CLEAR)
        UNION Shape {
            Circle { radius: Float64 },
            FN area(s: Shape) RETURNS Float64
        }
        FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
        FN main() RETURNS Void -> END
      CLEAR
    end
  end

  # @example_for: UNION_METHOD_PARAM_TYPE
  # @fix: Each parameter's type in the implementation must match the
  # @fix: method declaration. Adjust the FN signature or the UNION
  # @fix: method declaration.
  describe ":UNION_METHOD_PARAM_TYPE — implementation parameter type doesn't match" do
    it "raises when the implementation's first param differs from the declaration" do
      expect {
        run(<<~CLEAR)
          UNION Shape {
              Circle { radius: Float64 },
              FN area(s: Float64) RETURNS Float64
          }
          FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /Union 'Shape' method 'area' parameter 1 expects 'Float64'/)
    end

    it "compiles when parameter types match" do
      run(<<~CLEAR)
        UNION Shape {
            Circle { radius: Float64 },
            FN area(s: Shape) RETURNS Float64
        }
        FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
        FN main() RETURNS Void -> END
      CLEAR
    end
  end

  # @example_for: UNION_METHOD_RETURN_TYPE
  # @fix: The implementation's return type must match the method
  # @fix: declaration's. Adjust the FN's `RETURNS T` to match.
  describe ":UNION_METHOD_RETURN_TYPE — implementation returns wrong type" do
    it "raises when the implementation returns a different type than declared" do
      expect {
        run(<<~CLEAR)
          UNION Shape {
              Circle { radius: Float64 },
              FN area(s: Shape) RETURNS String
          }
          FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /Union 'Shape' method 'area' requires return type 'String'/)
    end

    it "compiles when return types match" do
      run(<<~CLEAR)
        UNION Shape {
            Circle { radius: Float64 },
            FN area(s: Shape) RETURNS Float64
        }
        FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
        FN main() RETURNS Void -> END
      CLEAR
    end
  end

  # @example_for: UNION_METHOD_WRONG_VISIBILITY
  # @fix: The implementation function's visibility (PUB / PRIVATE /
  # @fix: package) must match the UNION's method declaration.
  # @fix: Adjust either to align.
  describe ":UNION_METHOD_WRONG_VISIBILITY — visibility mismatch between method and impl" do
    it "raises when UNION declares PUB but impl is package-default" do
      expect {
        run(<<~CLEAR)
          UNION Shape {
              Circle { radius: Float64 },
              PUB FN area(s: Shape) RETURNS Float64
          }
          FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /Union 'Shape' method 'area' is declared PUB but function 'area' is package/)
    end

    it "compiles when both are PUB" do
      run(<<~CLEAR)
        UNION Shape {
            Circle { radius: Float64 },
            PUB FN area(s: Shape) RETURNS Float64
        }
        PUB FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
        FN main() RETURNS Void -> END
      CLEAR
    end
  end

  # @example_for: UNION_METHOD_DUPLICATE
  # @fix: A UNION declares each required method exactly once.
  # @fix: Remove the duplicate declaration; if you need overloads,
  # @fix: declare distinct method names.
  describe ":UNION_METHOD_DUPLICATE — same method declared twice on a UNION" do
    it "raises when a UNION declares the same method twice" do
      expect {
        run(<<~CLEAR)
          UNION Shape {
              Circle { radius: Float64 },
              FN area(s: Shape) RETURNS Float64,
              FN area(s: Shape) RETURNS Float64
          }
          FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /Union 'Shape' declares method 'area' more than once/)
    end

    it "compiles when each declared method is unique" do
      run(<<~CLEAR)
        UNION Shape {
            Circle { radius: Float64 },
            FN area(s: Shape) RETURNS Float64,
            FN describe(s: Shape) RETURNS String
        }
        FN area(s: Shape) RETURNS Float64 -> RETURN 0.0; END
        FN describe(s: Shape) RETURNS String -> RETURN ""; END
        FN main() RETURNS Void -> END
      CLEAR
    end
  end

  # @example_for: ENUM_FIELD_ACCESS
  # @fix: ENUM values are bare tags — no fields, no payload.
  # @fix: Use `MATCH e START Color.Red -> ..., DEFAULT -> ...` to
  # @fix: branch on variants. If you need a payload, use a UNION
  # @fix: variant instead.
  describe ":ENUM_FIELD_ACCESS — `c.field` on an enum value" do
    it "raises when field-accessing an enum value" do
      expect {
        run(<<~CLEAR)
          ENUM Color { Red, Green, Blue }
          FN main() RETURNS Void ->
              c = Color.Red;
              _ = c.something;
          END
        CLEAR
      }.to raise_error(CompilerError, /'Color' is an enum type. Enum values do not have fields/)
    end

    it "compiles when matching the enum via MATCH" do
      run(<<~CLEAR)
        ENUM Color { Red, Green, Blue }
        FN main() RETURNS Void ->
            c = Color.Red;
            MATCH c START
                Color.Red -> print("r");,
                Color.Green -> print("g");,
                Color.Blue -> print("b");
            END
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Static methods & resources (Type Bucket 12).
  # ============================================================

  # @example_for: STATIC_UNKNOWN_TYPE
  # @fix: `Type::method(args)` static-method syntax requires a known
  # @fix: type. Check the type-name spelling, or import the module
  # @fix: that declares it.
  describe ":STATIC_UNKNOWN_TYPE — `T::method(...)` for an undeclared T" do
    it "raises when the static-call target type isn't declared" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              f = NotAType::open("path");
              _ = f;
          END
        CLEAR
      }.to raise_error(CompilerError, /Unknown type 'NotAType'.*'::' static method call/)
    end

    it "compiles when the static call uses a known resource type" do
      run(<<~CLEAR)
        FN main() RETURNS !Void ->
            f = File::open("/tmp/x") OR_ELSE RAISE;
            print("opened");
            RETURN;
        END
      CLEAR
    end
  end

  # @example_for: STATIC_NOT_RESOURCE
  # @fix: `Type::method` is reserved for resource types — File,
  # @fix: TCPClient, TCPServer, etc. Plain structs are constructed
  # @fix: with `Type{field: value}`, not via `::`.
  describe ":STATIC_NOT_RESOURCE — `::` on a non-resource type" do
    it "raises when `::` is used on a plain struct" do
      expect {
        run(<<~CLEAR)
          STRUCT Point { x: Int64, y: Int64 }
          FN main() RETURNS Void ->
              p = Point::origin();
              _ = p;
          END
        CLEAR
      }.to raise_error(CompilerError, /'Point' does not support '::' static method calls/)
    end

    it "compiles when constructing a struct via `Type{...}`" do
      run(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
            p = Point{x: 0_i64, y: 0_i64};
            print(p.x.toString());
        END
      CLEAR
    end
  end

  # @example_for: STATIC_UNKNOWN_METHOD
  # @fix: The resource type doesn't declare a static method by that
  # @fix: name. The error message lists the available methods.
  # @fix: Pick one of those, or check the spelling.
  describe ":STATIC_UNKNOWN_METHOD — unknown static method on a resource" do
    it "raises when the named static method doesn't exist on the type" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              f = File::nonExistent("path");
              _ = f;
          END
        CLEAR
      }.to raise_error(CompilerError, /No static method 'nonExistent' on 'File'/)
    end

    it "compiles with a real static method on File" do
      run(<<~CLEAR)
        FN main() RETURNS !Void ->
            f = File::open("/tmp/x") OR_ELSE RAISE;
            print("opened");
            RETURN;
        END
      CLEAR
    end
  end

  # @example_for: STATIC_ARITY
  # @fix: The static method's argument count doesn't match. The
  # @fix: error message names the expected count and the actual.
  describe ":STATIC_ARITY — wrong arg count for a static method" do
    it "raises when File::open is called with two arguments" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              f = File::open("path", "extra");
              _ = f;
          END
        CLEAR
      }.to raise_error(CompilerError, /'File::open' expects 1 argument/)
    end

    it "compiles when File::open is called with one argument" do
      run(<<~CLEAR)
        FN main() RETURNS !Void ->
            f = File::open("/tmp/x") OR_ELSE RAISE;
            print("opened");
            RETURN;
        END
      CLEAR
    end
  end

  # @example_for: STATIC_ARG_TYPE
  # @fix: A static method's argument type doesn't match the
  # @fix: declaration. Convert via CAST or change the argument to
  # @fix: the declared type.
  describe ":STATIC_ARG_TYPE — wrong arg type for a static method" do
    it "raises when File::open's first arg is Int64 (expects String)" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              f = File::open(5_i64);
              _ = f;
          END
        CLEAR
      }.to raise_error(CompilerError, /Argument 1 to 'File::open': expected String/)
    end

    it "compiles when the argument type matches" do
      run(<<~CLEAR)
        FN main() RETURNS !Void ->
            f = File::open("/tmp/x") OR_ELSE RAISE;
            print("opened");
            RETURN;
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Defaults / lints / catch-alls (Type Bucket 13).
  #
  # Note: UNKNOWN_LITERAL, TYPE_ERROR_GENERIC, PURITY_VIOLATION,
  # EFFECT_INFERENCE_VIOLATION are deferred — UNKNOWN_LITERAL is
  # defensive (lexer-level token typo, unreachable from user
  # source); TYPE_ERROR_GENERIC and the two `%{message}` umbrella
  # codes are pass-through wrappers whose specific cases are
  # better-served by the dedicated codes that fire alongside.
  # ============================================================

  # @example_for: DEFAULT_NEEDS_STRUCT_PARAM
  # @fix: `param=DEFAULT: T` is a special syntax that pulls every
  # @fix: field's declared default from a STRUCT type. It only
  # @fix: works for struct-typed parameters. For primitives, supply
  # @fix: a literal default: `param=42_i64: Int64`.
  describe ":DEFAULT_NEEDS_STRUCT_PARAM — `=DEFAULT` on a primitive parameter" do
    it "raises when DEFAULT is used on a non-struct parameter" do
      expect {
        run(<<~CLEAR)
          FN takes(n=DEFAULT: Int64) RETURNS Void -> END
          FN main() RETURNS Void -> takes(); END
        CLEAR
      }.to raise_error(CompilerError, /DEFAULT can only be used for struct-type parameters/)
    end

    it "compiles when supplying a literal default for a primitive param" do
      run(<<~CLEAR)
        FN takes!(n=42_i64: Int64) RETURNS !Void ->
            print(n.toString());
            RETURN;
        END
        FN main() RETURNS Void -> takes!() OR_ELSE PASS; END
      CLEAR
    end
  end

  # @example_for: DEFAULT_STRUCT_MISSING_DEFAULTS
  # @fix: `=DEFAULT` requires every field of the struct to have a
  # @fix: declared default. Add `field=value: T` defaults at the
  # @fix: STRUCT declaration for each missing field.
  describe ":DEFAULT_STRUCT_MISSING_DEFAULTS — struct fields without defaults" do
    it "raises when DEFAULT references a struct whose fields lack defaults" do
      expect {
        run(<<~CLEAR)
          STRUCT Cfg { name: String, port: Int64 }
          FN takes(c=DEFAULT: Cfg) RETURNS Void -> END
          FN main() RETURNS Void -> takes(); END
        CLEAR
      }.to raise_error(CompilerError, /DEFAULT for 'c' requires 'Cfg' to have defaults/)
    end

    it "compiles when every field has a default" do
      run(<<~CLEAR)
        STRUCT Cfg { name="def": String, port=8080: Int64 }
        FN takes(c=DEFAULT: Cfg) RETURNS Void ->
            print(c.name);
        END
        FN main() RETURNS Void -> takes(); END
      CLEAR
    end
  end

  # @example_for: DEFAULT_VALUE_TYPE_MISMATCH
  # @fix: A parameter's literal default must match the declared
  # @fix: parameter type. Convert the literal, or change the
  # @fix: declared parameter type.
  describe ":DEFAULT_VALUE_TYPE_MISMATCH — default literal doesn't match param type" do
    it "raises when a String default is supplied for an Int64 parameter" do
      expect {
        run(<<~CLEAR)
          FN takes(n="hello": Int64) RETURNS Void -> END
          FN main() RETURNS Void -> takes(); END
        CLEAR
      }.to raise_error(CompilerError, /Default value for 'n' expects Int64/)
    end

    it "compiles when the default's type matches the param type" do
      run(<<~CLEAR)
        FN takes!(n=42_i64: Int64) RETURNS !Void ->
            print(n.toString());
            RETURN;
        END
        FN main() RETURNS Void -> takes!() OR_ELSE PASS; END
      CLEAR
    end
  end

  # @example_for: CALL_SITE_OVERRIDE_UNIMPLEMENTED
  # @fix: `@thunk(N)` and `@maxDepth(N)` call-site overrides are
  # @fix: parsed but not yet implemented (v0.3 work). Declare the
  # @fix: variant on the function instead — `EFFECTS REENTRANT:THUNK`
  # @fix: or `EFFECTS REENTRANT:MAX_DEPTH(N)`.
  describe ":CALL_SITE_OVERRIDE_UNIMPLEMENTED — `@thunk(N) f(x)` call-site form" do
    it "raises when @thunk(N) is used at a call site" do
      expect {
        run(<<~CLEAR)
          FN factorial(n: Int64) RETURNS !Int64 EFFECTS REENTRANT ->
              IF n <= 1 THEN RETURN 1; END
              inner = @thunk(64) factorial(n - 1) OR_ELSE RAISE;
              RETURN n * inner;
          END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /@thunk\(64\) is parsed but not yet implemented/)
    end

    it "compiles when the variant is declared on the function instead" do
      run(<<~CLEAR)
        FN factorial(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
            IF n <= 1 THEN RETURN 1; END
            RETURN n * factorial(n - 1);
        END
        FN main() RETURNS Void ->
            print(factorial(5_i64).toString());
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Gradual typing (Type Bucket 14).
  # ============================================================

  # @example_for: AUTO_NOT_ALLOWED_IN_FIELD
  # @fix: `Auto` as a field type would require the inferencer to
  # @fix: pin a type from one call site and impose it elsewhere —
  # @fix: an action-at-a-distance that CLEAR rejects. Replace
  # @fix: `Auto` with the concrete type the field actually holds.
  describe ":AUTO_NOT_ALLOWED_IN_FIELD — `Auto` as a STRUCT field type" do
    it "raises when a STRUCT field is declared as Auto" do
      expect {
        run(<<~CLEAR)
          STRUCT Bag { item: Auto }
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(ParserError, /Auto is not allowed in STRUCT field declarations/)
    end

    it "compiles when the field has a concrete type" do
      run(<<~CLEAR)
        STRUCT Bag { item: Int64 }
        FN main() RETURNS Void ->
            b = Bag{item: 5_i64};
            print(b.item.toString());
        END
      CLEAR
    end
  end

  # @example_for: AUTO_PREFIX_NOT_SUPPORTED
  # @fix: `?Auto`, `!Auto`, `~Auto`, etc. would require defining
  # @fix: how the inferencer wraps the picked type — semantics
  # @fix: aren't fixed yet. Use `Auto` alone (it picks T directly)
  # @fix: or write the wrapped type explicitly: `?Int64`,
  # @fix: `!String`, `~Float64`.
  describe ":AUTO_PREFIX_NOT_SUPPORTED — `?Auto` / `!Auto` prefixed Auto" do
    it "raises when `?Auto` is used as a return type" do
      expect {
        run(<<~CLEAR)
          FN make() RETURNS ?Auto -> RETURN 5; END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(ParserError, /`\?Auto` is not supported/)
    end

    it "compiles when Auto is unprefixed" do
      run(<<~CLEAR)
        FN make() RETURNS Int64 -> RETURN 5_i64; END
        FN main() RETURNS Void ->
            n = make();
            print(n.toString());
        END
      CLEAR
    end
  end

  # ============================================================
  # :type — Capability-on-type interactions (Type Bucket 15).
  #
  # Note: 3 codes deferred. INDIRECT_ATOMIC_PRIMITIVE fires only
  # when the annotator's primitive-cap check sees `@indirect:atomic`
  # together — current source paths route through `@shared:atomic`
  # for primitives so the rejection never surfaces in user code.
  # LOCAL_INDIRECT_ATOMIC needs `ownership=:local + sync=:atomic +
  # layout=:indirect`, but the parser routes `@local` as a sync
  # capability, so the firing condition isn't reachable from source.
  # POLY_SHARED_INCONSISTENT needs a generic function signature
  # with two `T@shared` params receiving differently-synchronized
  # arguments — complex shape that balloons past a clean snippet.
  # ============================================================

  # @example_for: FN_PARAM_NO_CAPABILITY
  # @fix: Capability sigils (`@multiowned`, `@shared`, `@locked`)
  # @fix: live on bindings, not on parameter types. Functions take
  # @fix: the plain type; capabilities are unwrapped at the call
  # @fix: site (often via WITH). Drop the capability from the
  # @fix: parameter declaration — the function body works for any
  # @fix: caller's choice of capability.
  describe ":FN_PARAM_NO_CAPABILITY — capability sigil on a fn parameter" do
    it "raises when a parameter type is annotated with @multiowned" do
      expect {
        run(<<~CLEAR)
          STRUCT Node { val: Int64 }
          FN process(n: Node @multiowned) RETURNS Void -> END
          FN main() RETURNS Void -> END
        CLEAR
      }.to raise_error(CompilerError, /Capability annotations are not allowed on function parameters/)
    end

    it "compiles when the parameter takes the plain type" do
      run(<<~CLEAR)
        STRUCT Node { val: Int64 }
        FN process(n: Node) RETURNS Void -> END
        FN main() RETURNS Void ->
            n = Node{val: 1_i64} @multiowned;
            process(n);
        END
      CLEAR
    end
  end

  # @example_for: STRUCT_ATOMIC_NEEDS_INDIRECT
  # @fix: `@atomic` on a struct publishes whole-T snapshots via
  # @fix: atomic pointer swap, which requires a heap-pinned cell.
  # @fix: Use `@indirect:atomic` instead. (Primitives `@shared:atomic`
  # @fix: are different — they fit in a single CAS-able machine
  # @fix: word, no indirection needed.)
  describe ":STRUCT_ATOMIC_NEEDS_INDIRECT — `@atomic` on a struct without `@indirect`" do
    it "raises when @atomic is applied to a bare struct" do
      expect {
        run(<<~CLEAR)
          STRUCT Counter { v: Int64 }
          FN main() RETURNS Void ->
              c = Counter{v: 0_i64} @atomic;
              _ = c;
          END
        CLEAR
      }.to raise_error(CompilerError, /@atomic on a STRUCT requires @indirect/)
    end

    it "compiles when @indirect:atomic is used together" do
      run(<<~CLEAR)
        STRUCT Counter { v: Int64 }
        FN main() RETURNS Void ->
            c = Counter{v: 0_i64} @indirect:atomic;
            _ = c;
        END
      CLEAR
    end
  end

  # @example_for: MULTIOWNED_INDIRECT_ATOMIC
  # @fix: `@multiowned:indirect:atomic` is forbidden — `@multiowned`
  # @fix: is single-scheduler Rc with non-atomic refcounts, which
  # @fix: can't back a cross-thread atomic-ptr cell. Drop
  # @fix: `@multiowned`; `@indirect:atomic` already uses Arc
  # @fix: internally for the published-value lifetime.
  describe ":MULTIOWNED_INDIRECT_ATOMIC — `@multiowned:indirect:atomic` rejected" do
    it "raises when @multiowned is combined with @indirect:atomic" do
      expect {
        run(<<~CLEAR)
          STRUCT Counter { v: Int64 }
          FN main() RETURNS Void ->
              c = Counter{v: 0_i64} @multiowned:indirect:atomic;
              _ = c;
          END
        CLEAR
      }.to raise_error(CompilerError, /@multiowned:indirect:atomic is disallowed/)
    end

    it "compiles when only @indirect:atomic is used" do
      run(<<~CLEAR)
        STRUCT Counter { v: Int64 }
        FN main() RETURNS Void ->
            c = Counter{v: 0_i64} @indirect:atomic;
            _ = c;
        END
      CLEAR
    end
  end

  # @example_for: OBSERVABLE_REQUIRES_SET
  # @fix: The only observable collection shape is `~T[]@set:observable`
  # @fix: (DISTINCT terminal). Plain `~T[]@observable` isn't
  # @fix: supported — observable collections need `@set` semantics
  # @fix: to coalesce duplicate items.
  describe ":OBSERVABLE_REQUIRES_SET — `~T[]@observable` without `@set`" do
    it "raises when @observable is applied to a list without @set" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              s: ~Int64[]@observable = BG STREAM { YIELD 1; };
              _ = s;
          END
        CLEAR
      }.to raise_error(CompilerError, /@observable on `T\[\]` requires `@set`/)
    end

    it "compiles when the stream is non-observable" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            s: ~?Int64[] = BG STREAM { YIELD 1; };
            _ = s;
        END
      CLEAR
    end
  end

  # @example_for: OBSERVABLE_NOT_COMBINABLE
  # @fix: `@observable` is a lock-free single-producer accumulator
  # @fix: with a heap-pinned lifetime owned by the producing scope.
  # @fix: Layering sync wrappers (`@locked`, `@writeLocked`) would
  # @fix: double-synchronize; layering ownership wrappers
  # @fix: (`@shared`, `@multiowned`, `@split`) would race the
  # @fix: producer's lifetime against the cleanup. Drop the
  # @fix: incompatible wrapper.
  describe ":OBSERVABLE_NOT_COMBINABLE — `@observable` with sync/ownership wrapper" do
    it "raises when @observable is combined with @locked" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
              s: ~Int64@locked:observable = BG STREAM { YIELD 1; };
              _ = s;
          END
        CLEAR
      }.to raise_error(CompilerError, /@observable cannot be combined with sync wrapper :locked/)
    end

    it "compiles when the stream is non-observable" do
      run(<<~CLEAR)
        FN main() RETURNS Void ->
            s: ~?Int64[] = BG STREAM { YIELD 1; };
            _ = s;
        END
      CLEAR
    end
  end

  # @example_for: ARG_NEEDS_ATOMIC_CELL
  # @fix: A parameter declared `T@atomic` expects an `@atomic`
  # @fix: binding (the cell). Pass a binding that was declared with
  # @fix: an atomic capability, or change the parameter to bare
  # @fix: `T` if you want a load-once value semantics.
  describe ":ARG_NEEDS_ATOMIC_CELL — passing a non-atomic binding to a `@atomic` param" do
    it "raises when a plain Int64 is passed to an `Int64@atomic` MUTABLE param" do
      expect {
        run(<<~CLEAR)
          FN incrAtomic!(MUTABLE c: Int64@atomic) RETURNS Void -> END
          FN main() RETURNS Void ->
              MUTABLE n: Int64 = 5_i64;
              incrAtomic!(n);
          END
        CLEAR
      }.to raise_error(CompilerError, /expects an @atomic Int64 cell/)
    end

    it "compiles when the parameter is bare Int64 (load-once value)" do
      run(<<~CLEAR)
        FN inspect(n: Int64) RETURNS Void -> END
        FN main() RETURNS Void ->
            MUTABLE n: Int64 = 5_i64;
            inspect(n);
        END
      CLEAR
    end
  end

  # @example_for: ARG_NEEDS_SHARED
  # @fix: A parameter declared `T@shared` expects a shared handle
  # @fix: (Arc-style). Pass a binding declared `@shared`, or wrap
  # @fix: the value with `SHARE x` to create a fresh shared
  # @fix: handle.
  describe ":ARG_NEEDS_SHARED — passing non-shared value to a `@shared` parameter" do
    it "raises when a plain struct is passed to a `T@shared` parameter" do
      expect {
        run(<<~CLEAR)
          STRUCT Counter { v: Int64 }
          FN takeShared(c: Counter@shared) RETURNS Void -> END
          FN main() RETURNS Void ->
              c = Counter{v: 5_i64};
              takeShared(c);
          END
        CLEAR
      }.to raise_error(CompilerError, /expects Counter @shared, got Counter/)
    end

    it "compiles when the binding is declared @shared" do
      run(<<~CLEAR)
        STRUCT Counter { v: Int64 }
        FN takeShared(c: Counter@shared) RETURNS Void -> END
        FN main() RETURNS Void ->
            c = Counter{v: 5_i64} @shared;
            takeShared(c);
        END
      CLEAR
    end
  end
end
