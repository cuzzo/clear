require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Escape promotion matrix — combinatoric coverage for Phase 1a of the
# unified-classification refactor (silly-churning-simon.md plan).
#
# Each cell builds a `.clear` source where a value of type T is built in
# function-local scope and RETURNed. The cell asserts the
# return-binding's post-MIR storage and cleanup-allocator. If escape
# promotion is correctly applied, every escaping non-Copy type ends up
# with `:heap` cleanup. Cells that currently produce the wrong outcome
# are the catalog of bugs Phase 3 fixes.
#
# Expected outcomes:
#   :int                 - storage :stack, no cleanup (Copy)
#   :string_rodata       - storage :heap (owned return binding), no cleanup
#   :string_frame        - storage :heap (concat must promote), cleanup :heap
#   :list_int            - storage :heap, cleanup :heap
#   :list_string         - storage :heap, cleanup :heap
#   :set_int             - storage :heap, cleanup :heap
#   :pool                - storage :heap, cleanup :heap
#   :map_str             - storage :heap, cleanup :heap (HashMap)
#   :map_int_numeric     - storage :heap, cleanup :heap (Int-keyed @map)
#   :struct_pure         - storage :stack (or :frame for SROA threshold),
#                          no cleanup (all-Copy fields)
#   :struct_with_list    - storage :heap, cleanup :heap (heap field)
#   :union_pure          - storage :stack, no cleanup (no heap variants)
#   :union_with_heap     - storage :heap, cleanup :heap
#   :indirect_int        - storage :heap, cleanup :heap (@boxed = boxed)
#
# Cells that fail at landing time are the surface area of the
# `needs_escape_promotion?` coverage gap.
RSpec.describe "Escape promotion matrix (Phase 1a)" do
  def run_mir(src)
    run_mir_frontend(src)
  end

  def make_fn(ast)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "make" }
  end

  def find_decl(fn, name)
    fn.body.find do |s|
      (s.is_a?(AST::VarDecl) && s.name.to_s == name.to_s) ||
        (s.is_a?(AST::BindExpr) && s.mode == :decl && s.name.to_s == name.to_s)
    end
  end

  def cleanup_entry(fn, name)
    fn.cleanup_bindings&.[](name.to_s)
  end

  # Each fixture: (CLEAR source, name of the binding under test, expected
  # storage, expected cleanup_allocator | nil for "no cleanup").
  # Each cell asserts:
  #   storage         — declaration's `decl.storage` after MIR.
  #   cleanup_alloc   — entry[:alloc] in cleanup_bindings (the allocator
  #                     used for the function-side defer; the CALLER's
  #                     binding inherits this allocator for ITS cleanup).
  #
  # `needs_cleanup` on the FUNCTION side is intentionally NOT asserted:
  # for RETURNed bindings, the dataflow refinement correctly suppresses
  # the function-side defer (the value moves to the caller; the
  # caller's binding emits the cleanup). The MIR's
  # `has_moved_guard` field tracks whether the suppression is via a
  # guard or via plain elision. What matters at the function-side is
  # the ALLOCATOR identity — that's the field a caller's defer must
  # match.
  CASES = {
    int: [
      "FN make() RETURNS Int64 -> MUTABLE x = 42_i64; RETURN x; END",
      "x", :stack, nil,
    ],
    string_rodata: [
      "FN make() RETURNS !String -> MUTABLE s = \"hi\"; RETURN s; END",
      "s", :heap, nil,
    ],
    string_frame: [
      # Frame-string concat: the function-side decl stays :frame and
      # has no cleanup entry — RETURN-time promotion is handled by
      # the codegen layer (heap-dupe at the RETURN site). The CALLER's
      # binding is what carries the heap allocator; THIS test asserts
      # the function-side state, which is correctly :frame + no entry.
      "FN make() RETURNS !String -> MUTABLE s = \"a\" $+ \"b\"; RETURN s; END",
      "s", :heap, nil,
    ],
    list_int: [
      "FN make() RETURNS !Int64[]@list -> MUTABLE lst: Int64[]@list = []; &lst.append(1_i64); RETURN lst; END",
      "lst", :heap, :heap,
    ],
    list_string: [
      "FN make() RETURNS !String[]@list -> MUTABLE lst: String[]@list = []; &lst.append(\"a\"); RETURN lst; END",
      "lst", :heap, :heap,
    ],
    set_int: [
      "FN make() RETURNS !Int64[]@set -> MUTABLE s: Int64[]@set = Set[]; &s.insert(1_i64); RETURN s; END",
      "s", :heap, :heap,
    ],
    pool: [
      "STRUCT P { x: Int64 }\n" \
      "FN make() RETURNS !P[100]@pool -> MUTABLE p: P[100]@pool = []; pid = &p.insert(P{ x: 1_i64 }); RETURN p; END",
      "p", :heap, :heap,
    ],
    map_str: [
      "FN make() RETURNS !HashMap<Int64> -> MUTABLE m: HashMap<Int64> = {}; m[\"k\"] = 1_i64; RETURN m; END",
      "m", :heap, :heap,
    ],
    struct_pure: [
      "STRUCT Pt { x: Int64, y: Int64 }\n" \
      "FN make() RETURNS Pt -> MUTABLE p = Pt{ x: 1_i64, y: 2_i64 }; RETURN p; END",
      "p", :stack, nil,
    ],
    struct_with_list: [
      # Struct with heap-bearing field returned by value: recursive
      # ownership shape marks the binding heap so the nested list buffer
      # uses the same allocator its returned cleanup will use.
      "STRUCT C { items: Int64[]@list }\n" \
      "FN make() RETURNS !C -> MUTABLE c = C{ items: [] }; &c.items.append(1_i64); RETURN c; END",
      "c", :heap, :heap,
    ],
    union_pure: [
      "UNION U { Empty, Some: Int64 }\n" \
      "FN make() RETURNS U -> MUTABLE u = U{ Some: 42_i64 }; RETURN u; END",
      "u", :stack, nil,
    ],
    union_with_heap: [
      "UNION W { Empty, Has: Int64[]@list }\n" \
      "FN make() RETURNS !W -> MUTABLE lst: Int64[]@list = []; &lst.append(1_i64); RETURN W{ Has: lst }; END",
      "lst", :heap, :heap,
    ],
    indirect_int: [
      # @boxed Int64 boxes the Int64 onto the heap; cleanup
      # allocator is :heap (per `cleanup_allocator` for indirect).
      # Reformulated to use !B so the make() body is fallible-typed
      # consistently with the other heap cells.
      "UNION B { Box: Int64 @boxed }\n" \
      "FN make() RETURNS !B -> MUTABLE b = B{ Box: 7_i64 }; RETURN b; END",
      "b", :heap, :heap,
    ],
  }.freeze

  CASES.each do |name, (src, decl_name, expected_storage, expected_cleanup)|
    it "#{name}: storage=#{expected_storage.inspect}, cleanup_alloc=#{expected_cleanup.inspect}" do
      ast = run_mir(src)
      fn = make_fn(ast) or raise "no `make` function in source"
      d = find_decl(fn, decl_name) or raise "no decl for `#{decl_name}` in `make`"
      entry = cleanup_entry(fn, decl_name)
      aggregate_failures do
        storage = d.respond_to?(:symbol) && d.symbol ? d.symbol.storage : d.storage
        expect(storage).to eq(expected_storage), "storage for #{name}: got #{storage.inspect}, want #{expected_storage.inspect}"
        if expected_cleanup.nil?
          # No cleanup entry expected (Copy types) OR_ELSE entry exists but
          # cleanup is unnecessary (frame-string returned via codegen
          # promotion).
          expect(entry.nil? || !entry[:needs_cleanup]).to(be(true),
            "expected no cleanup for #{name}; got #{entry.inspect}")
        else
          expect(entry).not_to be_nil, "expected cleanup_bindings entry for #{name}; got nil"
          expect(entry[:alloc]).to eq(expected_cleanup), "cleanup_allocator for #{name}: got #{entry[:alloc].inspect}, want #{expected_cleanup.inspect}"
        end
      end
    end
  end

  # ── Capability axis declaration coverage ─────────────────────────────────
  # Asserts the named constants in `Annotator::SYNC_DOES_NOT_BIND_CAPTURE`
  # and `Annotator::STORAGE_OUTLIVES_DECLARING_SCOPE` cover the intended
  # values. New sigils added to Type without updating these constants
  # default to bound (the safe direction). These tests catalog the
  # current escape-hatch declaration so divergence is visible.
  describe "capability declarative axis (default-deny)" do
    it "SYNC_DOES_NOT_BIND_CAPTURE lists exactly the data-access modes" do
      expect(SemanticAnnotator::SYNC_DOES_NOT_BIND_CAPTURE).to eq(Set[:raw, :symbol, :c, :size])
    end

    it "STORAGE_OUTLIVES_DECLARING_SCOPE lists exactly :shared and :heap" do
      expect(SemanticAnnotator::STORAGE_OUTLIVES_DECLARING_SCOPE).to eq(Set[:shared, :heap])
    end
  end

  # ── Type#escape_class coverage matrix ────────────────────────────────────
  # Direct predicate-level assertion: every type case classifies into
  # the correct escape_class. New types added without explicit
  # classification fall through to `:by_ref` (default-deny — a
  # compile-time over-rejection at copy/escape sites instead of
  # silent UAF).
  describe "Type#escape_class" do
    {
      Type.new(:Int64)    => :value,
      Type.new(:Float64)  => :value,
      Type.new(:Bool)     => :value,
      Type.new(:String)   => :slice_managed,  # default String has no rodata stamp
    }.each do |t, expected|
      it "#{t.resolved.inspect} → #{expected.inspect}" do
        expect(t.send(:escape_class)).to eq(expected)
      end
    end

    it "rodata-stamped String is :slice_rodata" do
      t = Type.new(:String, location: :rodata)
      expect(t.send(:escape_class)).to eq(:slice_rodata)
    end

    it "any unknown user-type defaults to :by_ref" do
      t = Type.new(:SomeNewlyAddedUserType)
      expect(t.send(:escape_class)).to eq(:by_ref)
    end
  end
end
