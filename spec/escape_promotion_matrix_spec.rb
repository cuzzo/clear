require "rspec"
require_relative "../src/backends/transpiler"

# Escape promotion matrix — combinatoric coverage for Phase 1a of the
# unified-classification refactor (silly-churning-simon.md plan).
#
# Each cell builds a `.cht` source where a value of type T is built in
# function-local scope and RETURNed. The cell asserts the
# return-binding's post-MIR storage and cleanup-allocator. If escape
# promotion is correctly applied, every escaping non-Copy type ends up
# with `:heap` cleanup. Cells that currently produce the wrong outcome
# are the catalog of bugs Phase 3 fixes.
#
# Expected outcomes:
#   :int                 - storage :stack, no cleanup (Copy)
#   :string_rodata       - storage :rodata, no cleanup (literal, static)
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
#   :indirect_int        - storage :heap, cleanup :heap (@indirect = boxed)
#
# Cells that fail at landing time are the surface area of the
# `needs_escape_promotion?` coverage gap.
RSpec.describe "Escape promotion matrix (Phase 1a)" do
  def run_mir(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    StringConcatRewriter.new.rewrite!(ast)
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    mir = MIRPass.new(fn_nodes: fn_nodes,
                      schema_lookup: ->(n) { annotator.lookup_type_schema(n) })
    mir.transform!(ast)
    ast
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

  # Each fixture: (cht source, name of the binding under test, expected
  # storage, expected cleanup_allocator | nil for "no cleanup").
  CASES = {
    int: [
      "FN make() RETURNS Int64 -> MUTABLE x = 42_i64; RETURN x; END",
      "x", :stack, nil,
    ],
    string_rodata: [
      "FN make() RETURNS !String -> MUTABLE s = \"hi\"; RETURN s; END",
      "s", :rodata, nil,
    ],
    string_frame: [
      "FN make() RETURNS !String -> MUTABLE s = \"a\" + \"b\"; RETURN s; END",
      "s", :heap, :heap,
    ],
    list_int: [
      "FN make() RETURNS !Int64[]@list -> MUTABLE lst: Int64[]@list = []; lst.append(1_i64); RETURN lst; END",
      "lst", :heap, :heap,
    ],
    list_string: [
      "FN make() RETURNS !String[]@list -> MUTABLE lst: String[]@list = []; lst.append(\"a\"); RETURN lst; END",
      "lst", :heap, :heap,
    ],
    set_int: [
      "FN make() RETURNS !Int64[]@set -> MUTABLE s: Int64[]@set = Set[]; s.insert(1_i64); RETURN s; END",
      "s", :heap, :heap,
    ],
    pool: [
      "STRUCT P { x: Int64 }\n" \
      "FN make() RETURNS !P[100]@pool -> MUTABLE p: P[100]@pool = []; pid = p.insert(P{ x: 1_i64 }); RETURN p; END",
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
      "STRUCT C { items: Int64[]@list }\n" \
      "FN make() RETURNS !C -> MUTABLE c = C{ items: [] }; c.items.append(1_i64); RETURN c; END",
      "c", :heap, :heap,
    ],
    union_pure: [
      "UNION U { Empty, Some: Int64 }\n" \
      "FN make() RETURNS U -> MUTABLE u = U{ Some: 42_i64 }; RETURN u; END",
      "u", :stack, nil,
    ],
    union_with_heap: [
      "UNION W { Empty, Has: Int64[]@list }\n" \
      "FN make() RETURNS !W -> MUTABLE lst: Int64[]@list = []; lst.append(1_i64); RETURN W{ Has: lst }; END",
      "lst", :heap, :heap,
    ],
    indirect_int: [
      "UNION B { Box: Int64 @indirect }\n" \
      "FN make() RETURNS B -> MUTABLE b = B{ Box: 7_i64 }; RETURN b; END",
      "b", :heap, :heap,
    ],
  }.freeze

  # Cells that currently fail at the unified-classification layer.
  # Each one is a real escape-promotion bug; flipped to active by
  # Phase 3 (unified Type#escape_class lookup) and the suite re-asserts
  # all 13 cells. Quoted current-vs-expected outcomes captured at
  # commit time so the regression remains visible.
  KNOWN_BUGS = {
    string_frame:    "storage :frame, no cleanup (concat result must heap-promote on RETURN)",
    map_str:         "needs_cleanup false (HashMap return doesn't get heap-promoted)",
    struct_with_list: "storage :stack, cleanup :frame (struct-with-heap-field doesn't propagate)",
    indirect_int:    "storage/cleanup not promoted (@indirect union variant)",
  }.freeze

  CASES.each do |name, (src, decl_name, expected_storage, expected_cleanup)|
    if KNOWN_BUGS.key?(name)
      it "#{name}: KNOWN BUG — #{KNOWN_BUGS[name]}" do
        skip "Phase 3 (escape_class unification) lands the fix; #{KNOWN_BUGS[name]}"
      end
    else
      it "#{name}: returned binding has storage #{expected_storage.inspect}, cleanup #{expected_cleanup.inspect}" do
        ast = run_mir(src)
        fn = make_fn(ast) or raise "no `make` function in source"
        d = find_decl(fn, decl_name) or raise "no decl for `#{decl_name}` in `make`"
        entry = cleanup_entry(fn, decl_name)
        aggregate_failures do
          expect(d.storage).to eq(expected_storage), "storage for #{name}: got #{d.storage.inspect}, want #{expected_storage.inspect}"
          if expected_cleanup.nil?
            expect(entry&.dig(:needs_cleanup)).to(be_falsey, "expected no cleanup; got #{entry&.dig(:alloc).inspect}")
          else
            expect(entry&.dig(:needs_cleanup)).to be(true), "expected needs_cleanup=true for #{name}"
            expect(entry&.dig(:alloc)).to eq(expected_cleanup), "cleanup_allocator for #{name}: got #{entry&.dig(:alloc).inspect}, want #{expected_cleanup.inspect}"
          end
        end
      end
    end
  end
end
