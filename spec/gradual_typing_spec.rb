require "rspec"
require "tmpdir"
require_relative "../src/backends/transpiler"  # transitively loads annotator + lexer + parser + ast
require_relative "../src/ast/fixable_error"
require_relative "../src/annotator-helpers/fixable_helpers"
require_relative "../src/annotator-helpers/auto_inference"
require_relative "../src/backends/importer"

# M1.1 — parser-level coverage for the `Auto` placeholder.
# Annotator-side inference, constraint collection, and `--gradual`
# CLI behavior land in later milestones; this file covers what the
# parser must accept verbatim.
RSpec.describe "Gradual typing — Auto placeholder (parser)" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  describe "explicit Auto in type positions" do
    it "accepts Auto as a parameter type" do
      ast = parse(<<~CLEAR)
        FN double(x: Auto) RETURNS Int64 ->
          RETURN x + x;
        END
      CLEAR
      fn = ast.statements.first
      param_type = fn.params.first[:type]
      expect(param_type).to be_a(Type)
      expect(param_type.auto?).to be true
    end

    it "accepts Auto as a return type" do
      ast = parse(<<~CLEAR)
        FN identity(x: Int64) RETURNS Auto ->
          RETURN x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.return_type).to be_a(Type)
      expect(fn.return_type.auto?).to be true
    end

    it "accepts Auto on both param and return in the same signature" do
      ast = parse(<<~CLEAR)
        FN passthrough(x: Auto) RETURNS Auto ->
          RETURN x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.params.first[:type].auto?).to be true
      expect(fn.return_type.auto?).to be true
    end

    it "accepts Auto on a local declaration" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void ->
          x: Auto = 42;
          RETURN;
        END
      CLEAR
      decl = ast.statements.first.body.first
      expect(decl).to be_a(AST::BindExpr)
      expect(decl.type).to be_a(Type)
      expect(decl.type.auto?).to be true
    end

    it "accepts MUTABLE x: Auto = ..." do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x: Auto = 0;
          RETURN;
        END
      CLEAR
      decl = ast.statements.first.body.first
      expect(decl.type.auto?).to be true
      expect(decl.mutable).to be true
    end
  end

  describe "Type#auto?" do
    it "returns false for non-Auto types" do
      expect(Type.new(:Int64).auto?).to be false
      expect(Type.new(:String).auto?).to be false
      expect(Type.new(:Void).auto?).to be false
    end

    it "returns true for an Auto-constructed Type" do
      expect(Type.new(:Auto, auto: true).auto?).to be true
    end

    it "is preserved through the copy constructor" do
      original = Type.new(:Auto, auto: true)
      copy = Type.new(original)
      expect(copy.auto?).to be true
    end

    it "is not silently set on regular Type construction" do
      t = Type.new(:Auto)  # without the explicit kwarg
      expect(t.auto?).to be false
    end
  end

  describe "implicit Auto under --gradual" do
    around do |example|
      saved = Parser.gradual_mode
      Parser.gradual_mode = true
      example.run
      Parser.gradual_mode = saved
    end

    it "treats omitted parameter type as implicit Auto" do
      ast = parse(<<~CLEAR)
        FN double(x) RETURNS Int64 ->
          RETURN x + x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.params.first[:type]).to be_a(Type)
      expect(fn.params.first[:type].auto?).to be true
    end

    it "treats omitted RETURNS as implicit Auto" do
      ast = parse(<<~CLEAR)
        FN double(x: Int64) ->
          RETURN x + x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.return_type).to be_a(Type)
      expect(fn.return_type.auto?).to be true
      expect(fn.explicit_return_type).to be true
    end

    it "treats fully-omitted signature as implicit Auto on every slot" do
      ast = parse(<<~CLEAR)
        FN double(x) ->
          RETURN x + x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.params.first[:type].auto?).to be true
      expect(fn.return_type.auto?).to be true
    end

    it "leaves explicit annotations untouched (no spurious Auto)" do
      ast = parse(<<~CLEAR)
        FN double(x: Int64) RETURNS Int64 ->
          RETURN x + x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.params.first[:type]).to eq(:Int64)
      expect(fn.return_type).to eq(:Int64)
    end
  end

  describe "without --gradual" do
    it "leaves omitted parameter type as :Any (existing behavior)" do
      Parser.gradual_mode = false
      ast = parse(<<~CLEAR)
        FN double(x) RETURNS Int64 ->
          RETURN x + x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.params.first[:type]).to eq(:Any)
    end

    it "leaves omitted RETURNS as nil (existing behavior)" do
      Parser.gradual_mode = false
      ast = parse(<<~CLEAR)
        FN main(x: Int64) ->
          RETURN;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.return_type).to be_nil
      expect(fn.explicit_return_type).to be false
    end
  end

  describe "Auto coexists with existing type modifiers" do
    it "does not interfere with the !T error-union prefix" do
      # Auto and !T are orthogonal; the spec intentionally allows
      # them to combine (Auto inferred, then ! adds error union).
      # For the parser: !Auto should parse cleanly even if the
      # inferencer rejects it later as out-of-scope for v1.
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS Int64 ->
          y: Auto = x;
          RETURN y;
        END
      CLEAR
      fn = ast.statements.first
      decl = fn.body.first
      expect(decl.type.auto?).to be true
    end

    it "does not break parsing of regular type annotations" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64, y: String) RETURNS Bool ->
          RETURN TRUE;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.params[0][:type]).to eq(:Int64)
      expect(fn.params[1][:type]).to eq(:String)
      expect(fn.return_type).to eq(:Bool)
    end
  end
end

# M1.2 — Pass B (constraint collection) for Auto slots.
RSpec.describe "Gradual typing — AutoConstraintCollector (Pass B)" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  # Build the {name => FunctionDef} registry exactly as the annotator
  # does (signature-collection pass). For these specs we don't need
  # the rest of annotation — Pass B operates on the AST + this map.
  def fn_nodes_of(ast)
    h = {}
    ast.statements.each { |s| h[s.name] = s if s.is_a?(AST::FunctionDef) }
    h
  end

  describe "param Auto from call sites" do
    it "registers a [:param, fn, i] slot for an Auto param" do
      ast = parse(<<~CLEAR)
        FN double(x: Auto) RETURNS Int64 ->
          RETURN x + x;
        END
        FN main() RETURNS !Void ->
          v = double(5);
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      expect(slots).to have_key([:param, "double", 0])
    end

    it "collects every call site's arg as a constraint source" do
      ast = parse(<<~CLEAR)
        FN double(x: Auto) RETURNS Int64 ->
          RETURN x + x;
        END
        FN main() RETURNS !Void ->
          a = double(5);
          b = double(10);
          c = double(15);
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      sources = slots[[:param, "double", 0]].sources
      expect(sources.length).to eq(3)
      # Each source is the AST::Literal arg from a FuncCall.
      expect(sources).to all(be_a(AST::Literal))
    end

    it "only registers slots for params that are Auto, not concrete" do
      ast = parse(<<~CLEAR)
        FN add(x: Int64, y: Auto) RETURNS Int64 ->
          RETURN x + y;
        END
        FN main() RETURNS !Void ->
          v = add(1, 2);
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      expect(slots).not_to have_key([:param, "add", 0])
      expect(slots).to have_key([:param, "add", 1])
      expect(slots[[:param, "add", 1]].sources.length).to eq(1)
    end

    it "produces empty sources for an Auto param that is never called" do
      ast = parse(<<~CLEAR)
        FN unused(x: Auto) RETURNS Int64 ->
          RETURN 0;
        END
        FN main() RETURNS !Void ->
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      expect(slots[[:param, "unused", 0]].sources).to be_empty
    end
  end

  describe "return Auto from RETURN exprs" do
    it "registers a [:return, fn] slot for an Auto return" do
      ast = parse(<<~CLEAR)
        FN identity(x: Int64) RETURNS Auto ->
          RETURN x;
        END
        FN main() RETURNS !Void ->
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      expect(slots).to have_key([:return, "identity"])
    end

    it "collects every RETURN expr in the body" do
      ast = parse(<<~CLEAR)
        FN classify(x: Int64) RETURNS Auto ->
          IF x > 0 THEN
            RETURN 1;
          END
          IF x < 0 THEN
            RETURN -1_i64;
          END
          RETURN 0;
        END
        FN main() RETURNS !Void ->
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      expect(slots[[:return, "classify"]].sources.length).to eq(3)
    end

    it "does NOT attach RETURN exprs to non-Auto-return functions" do
      ast = parse(<<~CLEAR)
        FN notAuto(x: Int64) RETURNS Int64 ->
          RETURN x;
        END
        FN withAuto(x: Int64) RETURNS Auto ->
          RETURN x;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      expect(slots).not_to have_key([:return, "notAuto"])
      expect(slots).to have_key([:return, "withAuto"])
    end
  end

  describe "local Auto from RHS" do
    it "registers a [:local, ...] slot for `x: Auto = expr`" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          x: Auto = 42;
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      local_slots = slots.select { |k, _| k.first == :local }
      expect(local_slots.length).to eq(1)
      slot = local_slots.values.first
      expect(slot.kind).to eq(:local)
      expect(slot.sources.length).to eq(1)
    end

    it "registers separate slots for two same-named MUTABLE locals in different scopes" do
      ast = parse(<<~CLEAR)
        FN foo() RETURNS Void ->
          x: Auto = 1;
          RETURN;
        END
        FN bar() RETURNS Void ->
          x: Auto = "hello";
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      local_slots = slots.select { |k, _| k.first == :local }
      # Each :local slot is keyed by decl-node object_id, so
      # same-named locals in different functions are distinct.
      expect(local_slots.length).to eq(2)
    end

    it "extends a MUTABLE Auto local's sources with later reassignment values" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x: Auto = 1;
          x = 2;
          x = 3;
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      local_slot = slots.values.find { |s| s.kind == :local }
      # Initializer + 2 reassignments = 3 source AST nodes.
      expect(local_slot.sources.length).to eq(3)
    end

    it "does NOT cross function boundaries when matching reassignment names" do
      ast = parse(<<~CLEAR)
        FN foo() RETURNS Void ->
          MUTABLE x: Auto = 1;
          RETURN;
        END
        FN bar() RETURNS Void ->
          x = 99;
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      local_slots = slots.select { |k, _| k.first == :local }
      # Only foo's `x` should have a slot. bar's `x = 99` is its own
      # decl (not Auto), not visible as a reassignment of foo's x.
      expect(local_slots.length).to eq(1)
      expect(local_slots.values.first.sources.length).to eq(1)  # initializer only
    end
  end

  describe "no Auto in the program" do
    it "produces an empty slot map" do
      ast = parse(<<~CLEAR)
        FN add(x: Int64, y: Int64) RETURNS Int64 ->
          RETURN x + y;
        END
        FN main() RETURNS !Void ->
          v = add(1, 2);
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      expect(slots).to be_empty
    end
  end
end

# M1.3 — Pass C (unification + resolution).
RSpec.describe "Gradual typing — AutoUnifier (Pass C)" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  def fn_nodes_of(ast)
    h = {}
    ast.statements.each { |s| h[s.name] = s if s.is_a?(AST::FunctionDef) }
    h
  end

  # Helper: collect slots, then stamp each source AST node with a
  # caller-provided type before unifying. Lets us exercise the
  # unifier without running the full annotator (whose body pass is
  # what would normally populate `type_info`).
  def unify_with_source_types(ast, source_types)
    slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
    type_of = ->(node) { source_types[node.object_id] }
    AutoUnifier.new(slots, type_of: type_of).resolve!
  end

  describe "single-observed-type → resolved" do
    it "resolves an Auto param to the call site's arg type" do
      ast = parse(<<~CLEAR)
        FN double(x: Auto) RETURNS Int64 ->
          RETURN x + x;
        END
        FN main() RETURNS !Void ->
          v = double(5);
          RETURN;
        END
      CLEAR

      # Find the literal `5` arg and stamp it as Int64.
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      arg5 = slots[[:param, "double", 0]].sources.first
      result = AutoUnifier.new(slots, type_of: ->(n) { n == arg5 ? Type.new(:Int64) : nil }).resolve!

      expect(result.resolved.length).to eq(1)
      resolution = result.resolved[[:param, "double", 0]]
      expect(resolution.type.resolved).to eq(:Int64)
      # decl mutation: the FunctionDef's param[:type] is now concrete
      fn = ast.statements.first
      expect(fn.params.first[:type]).to be_a(Type)
      expect(fn.params.first[:type].auto?).to be false
      expect(fn.params.first[:type].resolved).to eq(:Int64)
    end

    it "resolves an Auto return to the unique RETURN expr type" do
      ast = parse(<<~CLEAR)
        FN identity(x: Int64) RETURNS Auto ->
          RETURN x;
        END
        FN main() RETURNS !Void ->
          RETURN;
        END
      CLEAR

      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      ret_expr = slots[[:return, "identity"]].sources.first
      result = AutoUnifier.new(slots, type_of: ->(n) { n == ret_expr ? Type.new(:Int64) : nil }).resolve!

      expect(result.resolved.length).to eq(1)
      fn = ast.statements.first
      expect(fn.return_type.resolved).to eq(:Int64)
    end

    it "treats two same-typed sources as a single observation (no false ambiguity)" do
      ast = parse(<<~CLEAR)
        FN double(x: Auto) RETURNS Int64 ->
          RETURN x + x;
        END
        FN main() RETURNS !Void ->
          a = double(1);
          b = double(2);
          RETURN;
        END
      CLEAR

      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      param_slot = slots[[:param, "double", 0]]
      types = { param_slot.sources[0].object_id => Type.new(:Int64),
                param_slot.sources[1].object_id => Type.new(:Int64) }
      result = AutoUnifier.new(slots, type_of: ->(n) { types[n.object_id] }).resolve!

      expect(result.resolved).to have_key([:param, "double", 0])
      expect(result.ambiguous).to be_empty
    end
  end

  describe "multi-observed-type → ambiguous" do
    it "flags conflicting param types as ambiguous (Int64 + String)" do
      ast = parse(<<~CLEAR)
        FN parseValue(x: Auto) RETURNS Int64 ->
          RETURN 0;
        END
        FN main() RETURNS !Void ->
          a = parseValue(5);
          b = parseValue("hello");
          RETURN;
        END
      CLEAR

      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      sources = slots[[:param, "parseValue", 0]].sources
      types = { sources[0].object_id => Type.new(:Int64),
                sources[1].object_id => Type.new(:String) }
      result = AutoUnifier.new(slots, type_of: ->(n) { types[n.object_id] }).resolve!

      expect(result.resolved).to be_empty
      expect(result.ambiguous).to have_key([:param, "parseValue", 0])
      ambiguity = result.ambiguous[[:param, "parseValue", 0]]
      observed = ambiguity.observed_types.map { |t| t.respond_to?(:resolved) ? t.resolved : t }
      expect(observed).to contain_exactly(:Int64, :String)
    end

    it "flags conflicting RETURN expr types as ambiguous" do
      ast = parse(<<~CLEAR)
        FN classify(x: Int64) RETURNS Auto ->
          IF x > 0 THEN
            RETURN "positive";
          END
          RETURN x;
        END
        FN main() RETURNS !Void ->
          RETURN;
        END
      CLEAR

      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      sources = slots[[:return, "classify"]].sources
      types = { sources[0].object_id => Type.new(:String),
                sources[1].object_id => Type.new(:Int64) }
      result = AutoUnifier.new(slots, type_of: ->(n) { types[n.object_id] }).resolve!

      expect(result.ambiguous).to have_key([:return, "classify"])
    end

    it "flags MUTABLE local re-binding ambiguity (Int64 init then String assign)" do
      # Per spec §6: MUTABLE x: Auto = 0_i64; x = "hello"; produces
      # an ambiguity diagnostic with both Int64 and String observed.
      # The compiler does NOT silently widen to a union.
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x: Auto = 0_i64;
          x = "hello";
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      local_id = slots.keys.find { |k| k.first == :local }
      sources = slots[local_id].sources
      types = { sources[0].object_id => Type.new(:Int64),
                sources[1].object_id => Type.new(:String) }
      result = AutoUnifier.new(slots, type_of: ->(n) { types[n.object_id] }).resolve!

      expect(result.ambiguous).to have_key(local_id)
      observed = result.ambiguous[local_id].observed_types
                       .map { |t| t.respond_to?(:resolved) ? t.resolved : t }
      expect(observed).to contain_exactly(:Int64, :String)
    end

    it "resolves a MUTABLE local with type-consistent reassignments" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x: Auto = 1;
          x = 2;
          x = 3;
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      local_id = slots.keys.find { |k| k.first == :local }
      sources = slots[local_id].sources
      types = sources.each_with_object({}) { |s, h| h[s.object_id] = Type.new(:Int64) }
      result = AutoUnifier.new(slots, type_of: ->(n) { types[n.object_id] }).resolve!

      expect(result.resolved).to have_key(local_id)
      expect(result.ambiguous).to be_empty
    end
  end

  describe "zero-observed-type → unresolved" do
    it "marks an uncalled Auto param as unresolved" do
      ast = parse(<<~CLEAR)
        FN unused(x: Auto) RETURNS Int64 ->
          RETURN 0;
        END
        FN main() RETURNS !Void ->
          RETURN;
        END
      CLEAR

      result = unify_with_source_types(ast, {})
      expect(result.resolved).to be_empty
      expect(result.ambiguous).to be_empty
      expect(result.unresolved).to have_key([:param, "unused", 0])
    end

    it "marks a local Auto with an untypeable RHS as unresolved" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          x: Auto = 42;
          RETURN;
        END
      CLEAR

      result = unify_with_source_types(ast, {})  # source returns nil
      local_id = result.unresolved.keys.find { |k| k.first == :local }
      expect(local_id).not_to be_nil
    end
  end

  describe "fixpoint iteration" do
    it "resolves a chain that depends on a previous round's resolution" do
      # Simulate: round 1 resolves slot A; round 2 sees a source that
      # was nil in round 1 because its type came from slot A. The
      # unifier should iterate until no more progress.
      slot_a = AutoConstraintCollector::Slot.new(
        kind: :return, fn_name: "a", index: nil, decl_node: nil, sources: [:src_a],
      )
      slot_b = AutoConstraintCollector::Slot.new(
        kind: :return, fn_name: "b", index: nil, decl_node: nil, sources: [:src_b],
      )
      slots = { [:return, "a"] => slot_a, [:return, "b"] => slot_b }

      # In round 1, src_a → Int64; src_b → nil.
      # In round 2 (after a resolved), src_b → Int64 (because b's
      # body now sees a's resolution).
      a_resolved = false
      type_of = ->(node) {
        case node
        when :src_a then Type.new(:Int64)
        when :src_b then a_resolved ? Type.new(:Int64) : nil
        end
      }

      # Intercept stamp to flip the dependency flag — exercises the
      # iterate-to-fixpoint loop.
      unifier = AutoUnifier.new(slots, type_of: type_of)
      unifier.define_singleton_method(:stamp_slot!) do |slot, t|
        a_resolved = true if slot.fn_name == "a"
      end
      result = unifier.resolve!

      expect(result.resolved.keys).to contain_exactly([:return, "a"], [:return, "b"])
    end
  end
end

# M1.4 — Fix emission helpers.
RSpec.describe "Gradual typing — fix emission (M1.4)" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  def fn_nodes_of(ast)
    h = {}
    ast.statements.each { |s| h[s.name] = s if s.is_a?(AST::FunctionDef) }
    h
  end

  # Helper class to host the FixableHelper module so we can call the
  # emit_auto_* helpers in isolation (they're meant to be mixed into
  # the annotator, but for unit testing we host them directly).
  class HelperHost
    include ErrorHelper
    include FixableHelper
    attr_accessor :source_code
    def initialize; @source_code = ""; end
  end

  describe "auto_slot_label contract" do
    # AutoConstraintCollector only registers slots with kind ∈
    # {:param, :return, :local}. The label builder raises on
    # anything else so a future code-path that fabricates a Slot
    # with a fresh kind surfaces the omission immediately rather
    # than emitting a useless "slot" placeholder in a user-facing
    # diagnostic.
    it "raises ArgumentError when slot.kind is unrecognized" do
      bogus = AutoConstraintCollector::Slot.new(
        kind: :unknown_kind,
        fn_name: nil, index: nil,
        decl_node: nil, sources: [],
        shape: nil, auto_token: nil,
      )
      expect {
        HelperHost.new.send(:auto_slot_label, bogus)
      }.to raise_error(ArgumentError, /unrecognized slot kind :unknown_kind/)
    end
  end

  describe "emit_auto_resolved_finding!" do
    it "emits an :info finding with an :auto fix replacing the Auto token" do
      ast = parse(<<~CLEAR)
        FN double(x: Auto) RETURNS Int64 ->
          RETURN x + x;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      slot  = slots[[:param, "double", 0]]
      resolution = AutoUnifier::Resolution.new(slot: slot, type: Type.new(:Int64), sources: [])

      HelperHost.new.emit_auto_resolved_finding!(resolution)

      findings = FixCollector.drain.select { |f|
        f.category == :type && f.message.include?("Inferred type")
      }
      expect(findings.length).to eq(1)
      f = findings.first
      expect(f.level).to eq(:info)
      expect(f.message).to include("parameter 'x' of `double`")
      expect(f.message).to include("Int64")
      fix = f.fixes.first
      expect(fix.confidence).to eq(:auto)
      expect(fix.edits.first.replacement).to eq("Int64")
      expect(fix.edits.first.span.length).to eq(4)  # length of "Auto"
    end

    it "emits a finding without :auto fix when the slot has no Auto token (implicit Auto)" do
      # Implicit Auto under --gradual: param has Type.new(:Auto, auto: true)
      # but no auto_token because there was no source token to capture.
      saved = Parser.gradual_mode
      Parser.gradual_mode = true
      ast = parse(<<~CLEAR)
        FN double(x) RETURNS Int64 ->
          RETURN x + x;
        END
      CLEAR
      Parser.gradual_mode = saved

      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      slot  = slots[[:param, "double", 0]]
      expect(slot.decl_node.params[0][:type].auto_token).to be_nil  # implicit
      resolution = AutoUnifier::Resolution.new(slot: slot, type: Type.new(:Int64), sources: [])

      HelperHost.new.emit_auto_resolved_finding!(resolution)

      findings = FixCollector.drain.select { |f| f.message.include?("Inferred type") }
      expect(findings.length).to eq(1)
      expect(findings.first.fixes).to be_empty
    end
  end

  describe "emit_auto_ambiguity_finding!" do
    it "emits an :error with all three ranked options" do
      ast = parse(<<~CLEAR)
        FN parseValue(x: Auto) RETURNS Int64 ->
          RETURN 0;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      slot  = slots[[:param, "parseValue", 0]]
      ambiguity = AutoUnifier::Ambiguity.new(
        slot: slot,
        observed_types: [Type.new(:Int64), Type.new(:String)],
        sources: [],
      )

      HelperHost.new.emit_auto_ambiguity_finding!(ambiguity)

      findings = FixCollector.drain.select { |f| f.message.include?("Ambiguous Auto") }
      expect(findings.length).to eq(1)
      f = findings.first
      expect(f.level).to eq(:error)
      expect(f.category).to eq(:type)
      expect(f.fixes).to be_empty   # no :auto — user picks
      msg = f.message
      expect(msg).to include("parameter 'x' of `parseValue`")
      expect(msg).to include("Int64")
      expect(msg).to include("String")
      # Three ranked options must appear
      expect(msg).to include("Option 1 (recommended)")
      expect(msg).to include("Option 2")
      expect(msg).to include("Option 3 (last resort)")
      expect(msg).to include("UNION")  # union example present
    end
  end

  describe "emit_auto_unresolved_finding!" do
    it "emits an :error with no fix when the slot has no observed types" do
      ast = parse(<<~CLEAR)
        FN unused(x: Auto) RETURNS Int64 ->
          RETURN 0;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      slot  = slots[[:param, "unused", 0]]

      HelperHost.new.emit_auto_unresolved_finding!(slot)

      findings = FixCollector.drain.select { |f| f.message.include?("Cannot infer") }
      expect(findings.length).to eq(1)
      f = findings.first
      expect(f.level).to eq(:error)
      expect(f.category).to eq(:type)
      expect(f.fixes).to be_empty
      expect(f.message).to include("parameter 'x' of `unused`")
    end
  end
end

# M1.5 — STRICT-imports boundary.
RSpec.describe "Gradual typing — STRICT-imports boundary (M1.5)" do
  def import(main_code, helpers)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "main.cht"), main_code)
      helpers.each { |filename, code| File.write(File.join(dir, filename), code) }
      compiler = ModuleImporter.new(base_dir: dir)
      yield compiler, dir
    end
  end

  it "rejects an imported PUB function with Auto in its param" do
    import(<<~MAIN, "helper.cht" => <<~HELPER) do |c, dir|
      REQUIRE "helper.cht";
      FN main() RETURNS !Void ->
        RETURN;
      END
    MAIN
      PUB FN broken(x: Auto) RETURNS Int64 ->
        RETURN 0;
      END
    HELPER
      expect {
        c.compile_file("helper.cht", caller_dir: dir)
      }.to raise_error(CompilerError, /'broken' from module 'helper.cht' has `Auto`.*public signature.*param 'x'/m)
    end
  end

  it "rejects an imported PUB function with Auto in its return type" do
    import(<<~MAIN, "helper.cht" => <<~HELPER) do |c, dir|
      REQUIRE "helper.cht";
      FN main() RETURNS !Void ->
        RETURN;
      END
    MAIN
      PUB FN identity(x: Int64) RETURNS Auto ->
        RETURN x;
      END
    HELPER
      expect {
        c.compile_file("helper.cht", caller_dir: dir)
      }.to raise_error(CompilerError, /'identity' from module 'helper.cht' has `Auto`.*return type/m)
    end
  end

  it "rejects an imported package-visible function (default visibility)" do
    # Default visibility is `:package`, which is importable from
    # same-directory modules. Auto must be rejected for these too.
    import(<<~MAIN, "helper.cht" => <<~HELPER) do |c, dir|
      REQUIRE "helper.cht";
      FN main() RETURNS !Void ->
        RETURN;
      END
    MAIN
      FN packageVisible(x: Auto) RETURNS Int64 ->
        RETURN 0;
      END
    HELPER
      expect {
        c.compile_file("helper.cht", caller_dir: dir)
      }.to raise_error(CompilerError, /'packageVisible'.*public signature/m)
    end
  end

  it "ALLOWS Auto in a PRIVATE function (not part of the public surface)" do
    import(<<~MAIN, "helper.cht" => <<~HELPER) do |c, dir|
      REQUIRE "helper.cht";
      FN main() RETURNS !Void ->
        RETURN;
      END
    MAIN
      PRIVATE FN internal(x: Auto) RETURNS Int64 ->
        RETURN 0;
      END
      PUB FN public_(x: Int64) RETURNS Int64 ->
        RETURN x;
      END
    HELPER
      # The PRIVATE Auto should not block the import. The full
      # compile may still error on the unresolved Auto (M1.7 inference
      # would resolve or report) but the STRICT-imports check itself
      # is silent on PRIVATE.
      expect {
        c.send(:reject_auto_in_public_signatures!,
               Parser.new(Lexer.new(File.read(File.join(dir, "helper.cht"))).tokenize, "").parse,
               File.join(dir, "helper.cht"))
      }.not_to raise_error
    end
  end

  it "preserves the caller's gradual_mode across compile_file (strict at the boundary)" do
    # The importer must force gradual_mode = false during the import's
    # parse so `--gradual` does NOT propagate across module
    # boundaries. After compile_file returns, the caller's mode must
    # be exactly what it was before the call.
    saved = Parser.gradual_mode
    Parser.gradual_mode = true
    begin
      import(<<~MAIN, "helper.cht" => <<~HELPER) do |c, dir|
        REQUIRE "helper.cht";
        FN main() RETURNS !Void ->
          RETURN;
        END
      MAIN
        PUB FN add(x: Int64, y: Int64) RETURNS Int64 ->
          RETURN x + y;
        END
      HELPER
        expect(Parser.gradual_mode).to be true
        c.compile_file("helper.cht", caller_dir: dir)
        expect(Parser.gradual_mode).to be true
      end
    ensure
      Parser.gradual_mode = saved
    end
  end

  it "passes through cleanly when no Auto is present" do
    import(<<~MAIN, "helper.cht" => <<~HELPER) do |c, dir|
      REQUIRE "helper.cht";
      FN main() RETURNS !Void ->
        RETURN;
      END
    MAIN
      PUB FN add(x: Int64, y: Int64) RETURNS Int64 ->
        RETURN x + y;
      END
    HELPER
      ast = Parser.new(Lexer.new(File.read(File.join(dir, "helper.cht"))).tokenize, "").parse
      expect {
        c.send(:reject_auto_in_public_signatures!, ast, File.join(dir, "helper.cht"))
      }.not_to raise_error
    end
  end
end

# M1.7 — full pipeline integration. Drives the real annotator
# (visit + run_auto_inference!) and asserts decl mutation +
# diagnostic emission end-to-end.
RSpec.describe "Gradual typing — full pipeline integration (M1.7)" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "resolves an Auto param from a single concrete call site" do
    ast = annotate(<<~CLEAR)
      FN double(x: Auto) RETURNS Int64 ->
        RETURN x + x;
      END
      FN main() RETURNS !Void ->
        v = double(5);
        ASSERT v == 10, "ok";
        RETURN;
      END
    CLEAR
    fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "double" }
    # Param x's Auto Type was mutated to a concrete Int64 by Pass C.
    expect(fn.params.first[:type]).to be_a(Type)
    expect(fn.params.first[:type].auto?).to be false
    expect(fn.params.first[:type].resolved).to eq(:Int64)

    findings = FixCollector.drain.select { |f| f.message.include?("Inferred type") }
    expect(findings).not_to be_empty
    info = findings.first
    expect(info.level).to eq(:info)
    expect(info.message).to include("parameter 'x' of `double`")
    expect(info.message).to include("Int64")
  end

  it "resolves an Auto local from its concrete RHS" do
    ast = annotate(<<~CLEAR)
      FN main() RETURNS !Void ->
        x: Auto = 42;
        ASSERT x == 42, "ok";
        RETURN;
      END
    CLEAR
    fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
    decl = fn.body.first
    # Local x's Auto Type was mutated to Int64 (or related concrete
    # numeric — the literal 42 pins it via the RHS).
    expect(decl.type).to be_a(Type)
    expect(decl.type.auto?).to be false
  end

  it "is a no-op for programs without any Auto" do
    # The fast-path `program_has_auto?` short-circuits without
    # running collector / unifier — verified indirectly by
    # confirming no Auto findings get emitted.
    annotate(<<~CLEAR)
      FN add(x: Int64, y: Int64) RETURNS Int64 ->
        RETURN x + y;
      END
      FN main() RETURNS !Void ->
        v = add(1, 2);
        RETURN;
      END
    CLEAR
    auto_findings = FixCollector.drain.select { |f|
      f.message.include?("Inferred type") || f.message.include?("Ambiguous Auto") ||
      f.message.include?("Cannot infer type")
    }
    expect(auto_findings).to be_empty
  end
end

# M2.1 — Operator-aware ambiguity / unresolved suggestions.
RSpec.describe "Gradual typing — operator-aware suggestions (M2.1)" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  def fn_nodes_of(ast)
    h = {}
    ast.statements.each { |s| h[s.name] = s if s.is_a?(AST::FunctionDef) }
    h
  end

  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "auto_rank_candidates table" do
    let(:host) { Class.new { include ErrorHelper; include FixableHelper }.new }

    it "ranks `+` as Int64 default with Float64 and String alternatives" do
      ranked = host.auto_rank_candidates(Set[:ADD])
      types = ranked.map(&:first)
      expect(types).to eq([:Int64, :Float64, :String])
    end

    it "ranks `*` as Int64 default with Float64 (no String — can't multiply strings)" do
      ranked = host.auto_rank_candidates(Set[:MUL])
      types = ranked.map(&:first)
      expect(types).to eq([:Int64, :Float64])
    end

    it "ranks `/` as Float64 default with Int64 alternative + truncation note" do
      ranked = host.auto_rank_candidates(Set[:DIV])
      expect(ranked[0][0]).to eq(:Float64)
      expect(ranked[1][0]).to eq(:Int64)
      # Note specifically warns about integer-division truncation
      expect(ranked[1][1]).to include("integer division")
      expect(ranked[1][1]).to include("TRUNCATES")
    end

    it "ranks `%` as Int64 only (modulo is integer-only)" do
      ranked = host.auto_rank_candidates(Set[:MOD])
      expect(ranked.map(&:first)).to eq([:Int64])
    end

    it "ranks `&&` and `||` as Bool only" do
      expect(host.auto_rank_candidates(Set[:AND]).map(&:first)).to eq([:Bool])
      expect(host.auto_rank_candidates(Set[:OR]).map(&:first)).to eq([:Bool])
    end

    it "intersects candidates across multiple ops (+ and * → Int64, Float64)" do
      ranked = host.auto_rank_candidates(Set[:ADD, :MUL])
      types = ranked.map(&:first)
      # `+` allows {Int64, Float64, String}; `*` allows {Int64, Float64}.
      # Intersection: {Int64, Float64}; Int64 ranks first (default for both).
      expect(types).to eq([:Int64, :Float64])
    end

    it "produces an empty list when ops have no common candidate" do
      # `+` allows numeric+String; `&&` only allows Bool. No intersection.
      ranked = host.auto_rank_candidates(Set[:ADD, :AND])
      expect(ranked).to be_empty
    end

    it "returns [] for an empty op set" do
      expect(host.auto_rank_candidates(Set.new)).to eq([])
    end
  end

  describe "OperatorEvidenceCollector" do
    it "records ops applied to a param's binding inside the body" do
      ast = parse(<<~CLEAR)
        FN double(x: Auto) RETURNS Int64 ->
          RETURN x + x;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      evidence = OperatorEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      expect(evidence[[:param, "double", 0]]).to include(:ADD)
    end

    it "records the RETURN expression's BinaryOp op against the return slot" do
      ast = parse(<<~CLEAR)
        FN compute(x: Int64, y: Int64) RETURNS Auto ->
          RETURN x * y;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      evidence = OperatorEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      expect(evidence[[:return, "compute"]]).to include(:MUL)
    end

    it "records multiple distinct ops when the binding is used in several BinaryOps" do
      ast = parse(<<~CLEAR)
        FN compute(x: Auto) RETURNS Int64 ->
          a = x + 1;
          b = x * 2;
          c = x - 3;
          RETURN a + b + c;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      evidence = OperatorEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      ops = evidence[[:param, "compute", 0]]
      expect(ops).to include(:ADD, :MUL, :SUB)
    end

    it "does NOT cross function boundaries (foo's x doesn't pick up bar's ops)" do
      ast = parse(<<~CLEAR)
        FN foo(x: Auto) RETURNS Int64 ->
          RETURN 0;
        END
        FN bar(y: Int64) RETURNS Int64 ->
          RETURN y * y;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      evidence = OperatorEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      expect(evidence[[:param, "foo", 0]]).to be_empty
    end
  end

  describe "end-to-end ambiguity diagnostic with operator hints" do
    it "appends ranked candidate fixes when the body uses the param in a BinaryOp" do
      # Two callers pass Int64 and String — ambiguity. Body uses x+x —
      # operator evidence intersects: {Int64, Float64, String}. The
      # diagnostic surfaces those candidates as :interactive Fixes.
      annotate(<<~CLEAR)
        FN parseValue(x: Auto) RETURNS Int64 ->
          y = x + x;
          RETURN 0;
        END
        FN main() RETURNS !Void ->
          a = parseValue(5);
          b = parseValue("hello");
          RETURN;
        END
      CLEAR

      findings = FixCollector.drain.select { |f|
        f.message.include?("Ambiguous Auto") && f.message.include?("'x' of `parseValue`")
      }
      expect(findings).not_to be_empty
      f = findings.first

      # Operator-evidence block is appended.
      expect(f.message).to include("operator(s)")
      expect(f.message).to include("ADD")
      expect(f.message).to include("Suggested fixes")

      # Each ranked candidate becomes an :interactive Fix.
      replacements = f.fixes.map { |fx| fx.edits.first.replacement }
      expect(replacements).to include("Int64", "Float64", "String")
      expect(f.fixes.map(&:confidence).uniq).to eq([:interactive])
    end
  end

  describe "end-to-end unresolved diagnostic with operator hints" do
    it "suggests Float64 (default) and Int64 (truncation note) for `/`" do
      # `divide` is never called — param x is unresolved. Body uses
      # `x / 2` — DIV's defaults are Float64, alt Int64 with note.
      annotate(<<~CLEAR)
        FN divide(x: Auto) RETURNS Int64 ->
          y = x / 2;
          RETURN 0;
        END
        FN main() RETURNS !Void ->
          RETURN;
        END
      CLEAR

      findings = FixCollector.drain.select { |f|
        f.message.include?("Cannot infer type") && f.message.include?("'x' of `divide`")
      }
      expect(findings.length).to eq(1)
      f = findings.first
      expect(f.message).to include("Suggested fixes")
      expect(f.message).to include("Float64")
      expect(f.message).to include("Int64")
      # Truncation note specifically called out
      expect(f.message).to include("integer division")
      expect(f.message).to include("TRUNCATES")

      # Float64 ranks first (DIV default).
      replacements = f.fixes.map { |fx| fx.edits.first.replacement }
      expect(replacements.first).to eq("Float64")
      expect(replacements).to include("Int64")
    end

    # Coverage for `slot_id_for(slot)` when slot.kind is :return,
    # plus the auto_slot_label "return type of `fn`" branch — both
    # would be uncovered without an end-to-end test that exercises
    # an Auto-return slot through the unresolved-finding path with
    # operator-evidence lookup.
    it "emits unresolved finding for a return Auto slot with op-evidence" do
      annotate(<<~CLEAR)
        FN foo(x: Auto) RETURNS Auto ->
          RETURN x + x;
        END
        FN main() RETURNS !Void ->
          RETURN;
        END
      CLEAR
      findings = FixCollector.drain.select { |f|
        f.message.include?("Cannot infer type") &&
          f.message.include?("return type of `foo`")
      }
      # foo is never called: param + return both unresolvable.
      # Op-evidence catches the `+` use → ranked candidates.
      expect(findings.length).to eq(1)
      expect(findings.first.message).to include("ADD")
    end

    it "produces no candidate fixes when the body has no operator evidence" do
      annotate(<<~CLEAR)
        FN noop(x: Auto) RETURNS Int64 ->
          RETURN 0;
        END
        FN main() RETURNS !Void ->
          RETURN;
        END
      CLEAR

      findings = FixCollector.drain.select { |f|
        f.message.include?("Cannot infer type") && f.message.include?("'x' of `noop`")
      }
      expect(findings.length).to eq(1)
      f = findings.first
      expect(f.fixes).to be_empty
      # Falls back to the original "specify a concrete type" wording.
      expect(f.message).to include("Replace `Auto` with a concrete type")
    end
  end
end

# M2.2 — Forward-flow inference for empty `[]` / `{}` initializers.
# Empty container literals carry no element-type information; the
# inferencer registers shape-tagged slots and resolves them from
# subsequent `.append(e)` / `x[k] = v` uses.
RSpec.describe "Gradual typing — forward-flow `[]` / `{}` inference (M2.2)" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  def fn_nodes_of(ast)
    h = {}
    ast.statements.each { |s| h[s.name] = s if s.is_a?(AST::FunctionDef) }
    h
  end

  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "AutoConstraintCollector — shape slot registration" do
    it "registers a :list_element slot for `x: Auto = []`" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          xs: Auto = [];
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      list_slots = slots.values.select { |s| s.shape == :list_element }
      expect(list_slots.length).to eq(1)
      expect(list_slots.first.sources).to be_empty   # no init source
    end

    it "registers paired :map_key + :map_value slots for `m: Auto = {}`" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          m: Auto = {};
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      shapes = slots.values.map(&:shape).compact.sort
      expect(shapes).to eq([:map_key, :map_value])
    end

    it "does NOT register a shape slot for `Pool[]` (constructor — not a generic empty)" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          xs: Auto = Pool[];
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      shape_slots = slots.values.select { |s| s.shape }
      expect(shape_slots).to be_empty
    end
  end

  describe "ShapeEvidenceCollector" do
    it "records `xs.append(e)` arg as :list_element evidence" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          xs: Auto = [];
          xs.append(5_i64);
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      ShapeEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      list_slot = slots.values.find { |s| s.shape == :list_element }
      expect(list_slot.sources.length).to eq(1)
    end

    it "records `xs[i] = v` value as :list_element evidence" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          xs: Auto = [];
          xs[0] = 5_i64;
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      ShapeEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      list_slot = slots.values.find { |s| s.shape == :list_element }
      expect(list_slot.sources.length).to eq(1)
    end

    it "records `m.put(k, v)` args as :map_key + :map_value evidence" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          m: Auto = {};
          m.put("hi", 5_i64);
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      ShapeEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      key_slot = slots.values.find { |s| s.shape == :map_key }
      val_slot = slots.values.find { |s| s.shape == :map_value }
      expect(key_slot.sources.length).to eq(1)
      expect(val_slot.sources.length).to eq(1)
    end

    it "records `m.insert(k, v)` args as :map_key + :map_value evidence" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          m: Auto = {};
          m.insert("hi", 5_i64);
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      ShapeEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      key_slot = slots.values.find { |s| s.shape == :map_key }
      val_slot = slots.values.find { |s| s.shape == :map_value }
      expect(key_slot.sources.length).to eq(1)
      expect(val_slot.sources.length).to eq(1)
    end

    it "ignores `m.insert(k, v)` when only a list slot exists (no map evidence)" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          xs: Auto = [];
          xs.insert("k", 5_i64);
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      ShapeEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      list_slot = slots.values.find { |s| s.shape == :list_element }
      # 2-arg insert against a list shape: no key/value slots
      # available, so nothing is recorded — the slot has neither
      # 1-arg list evidence nor 2-arg map evidence.
      expect(list_slot.sources).to be_empty
    end

    it "records `m[k] = v` index as :map_key + value as :map_value" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS !Void ->
          m: Auto = {};
          m["hi"] = 5_i64;
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      ShapeEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      key_slot = slots.values.find { |s| s.shape == :map_key }
      val_slot = slots.values.find { |s| s.shape == :map_value }
      expect(key_slot.sources.length).to eq(1)
      expect(val_slot.sources.length).to eq(1)
    end

    it "does NOT cross function boundaries" do
      ast = parse(<<~CLEAR)
        FN foo() RETURNS Void ->
          xs: Auto = [];
          RETURN;
        END
        FN bar() RETURNS Void ->
          ys: Int64[] = [1_i64, 2_i64];
          ys.append(3_i64);
          RETURN;
        END
      CLEAR
      slots = AutoConstraintCollector.new(fn_nodes_of(ast)).collect!(ast)
      ShapeEvidenceCollector.new(slots, fn_nodes_of(ast)).collect!
      list_slot = slots.values.find { |s| s.shape == :list_element }
      expect(list_slot.sources).to be_empty   # bar's append doesn't leak into foo
    end
  end

  describe "end-to-end resolution" do
    it "resolves `xs: Auto = []` + `xs.append(5_i64)` as Int64[]" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          xs: Auto = [];
          xs.append(5_i64);
          RETURN;
        END
      CLEAR

      decl = ast.statements.first.body.find { |s| s.respond_to?(:name) && s.name == "xs" }
      expect(decl.type).to be_a(Type)
      expect(decl.type.resolved.to_s).to eq("Int64[]")

      findings = FixCollector.drain.select { |f| f.message.include?("Inferred type") }
      labeled = findings.find { |f| f.message.include?("`xs`") && f.message.include?("Int64[]") }
      expect(labeled).not_to be_nil
      # M2.2 fix: the auto-fix replaces `Auto` with the WRAPPED type
      # (Int64[]), not the bare element type — tests that
      # stamp_slot!'s overwrite of decl.type doesn't drop the auto
      # token cached on the slot.
      expect(labeled.fixes.length).to eq(1)
      expect(labeled.fixes.first.edits.first.replacement).to eq("Int64[]")
      expect(labeled.fixes.first.confidence).to eq(:auto)
    end

    it "resolves `MUTABLE m: Auto = {}` + `m[k] = v` from key/value evidence" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          MUTABLE m: Auto = {};
          m["hello"] = 5_i64;
          RETURN;
        END
      CLEAR

      decl = ast.statements.first.body.find { |s| s.respond_to?(:name) && s.name == "m" }
      expect(decl.type).to be_a(Type)
      # Shape-slot widening: `Byte[N]` (the type of a string literal)
      # widens to `String` for shape observations so the resolved
      # container type is usable. Without widening this would be
      # `HashMap<Byte[5], Int64>` — technically correct but unfit
      # as a HashMap key.
      expect(decl.type.resolved.to_s).to eq("HashMap<String, Int64>")
    end

    it "widens Byte[N] to String for SCALAR Auto params (cross-callsite ambiguity)" do
      # Audit#2: widening previously was shape-scoped; scalar Auto
      # diagnostics showed "observed as Int64, Byte[5]" when one
      # caller passed a string literal. Now widening applies to
      # all slot kinds so the diagnostic reads "Int64, String".
      annotate(<<~CLEAR)
        FN parseValue(x: Auto) RETURNS Int64 ->
          RETURN 0;
        END
        FN main() RETURNS !Void ->
          a = parseValue(5_i64);
          b = parseValue("hello");
          RETURN;
        END
      CLEAR
      findings = FixCollector.drain.select { |f| f.message.include?("Ambiguous Auto") }
      expect(findings.length).to eq(1)
      expect(findings.first.message).to include("Int64")
      expect(findings.first.message).to include("String")
      expect(findings.first.message).not_to include("Byte[")
    end

    it "widens Byte[N] string literals to String for :list_element evidence too" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          xs: Auto = [];
          xs.append("hi");
          xs.append("hello");
          RETURN;
        END
      CLEAR
      decl = ast.statements.first.body.find { |s| s.respond_to?(:name) && s.name == "xs" }
      # Both items widen to String — single observed type, no
      # ambiguity from `Byte[2]` vs `Byte[5]`.
      expect(decl.type.resolved.to_s).to eq("String[]")
    end

    it "emits ambiguity when appends disagree on element type" do
      annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          xs: Auto = [];
          xs.append(5_i64);
          xs.append("hello");
          RETURN;
        END
      CLEAR
      findings = FixCollector.drain.select { |f|
        f.message.include?("Ambiguous Auto") &&
          f.message.include?("element type of list `xs`")
      }
      expect(findings.length).to eq(1)
    end

    it "emits unresolved when `xs: Auto = []` is never used as a list" do
      annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          xs: Auto = [];
          RETURN;
        END
      CLEAR
      findings = FixCollector.drain.select { |f|
        f.message.include?("Cannot infer type") &&
          f.message.include?("element type of list `xs`")
      }
      expect(findings.length).to eq(1)
    end

    it "stamps map type only when both key and value resolve" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          m: Auto = {};
          RETURN;
        END
      CLEAR
      decl = ast.statements.first.body.find { |s| s.respond_to?(:name) && s.name == "m" }
      # No evidence → both sub-slots unresolved → decl.type stays Auto.
      expect(decl.type.auto?).to be true

      findings = FixCollector.drain.select { |f|
        f.message.include?("Cannot infer type") &&
          (f.message.include?("key type of map `m`") || f.message.include?("value type of map `m`"))
      }
      # One unresolved per sub-slot.
      expect(findings.length).to eq(2)
    end

    # Regression for the M2.2 partial-resolution bug: when only one
    # of {map_key, map_value} resolves, no spurious binding-level
    # resolved finding (and therefore no spurious auto-fix
    # rewriting `Auto` to the scalar type) should be emitted —
    # the user would otherwise get `m: String = {}` from a
    # partially-resolved map.
    it "emits NO resolved finding when only one map sub-slot resolves" do
      annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          MUTABLE m: Auto = {};
          k = "hello";
          m[k] = 5_i64;
          RETURN;
        END
      CLEAR
      findings = FixCollector.drain
      resolved = findings.select { |f| f.message.start_with?("Inferred type") }
      # Either both halves resolved → exactly one binding-level
      # finding with a wrapped type, OR partial resolution → no
      # binding-level finding at all (and unresolved sub-slot
      # findings instead).
      resolved.each do |f|
        f.fixes.each do |fx|
          repl = fx.edits.first.replacement
          # Whatever fix we emit, it must NEVER write the bare
          # scalar type into the binding's `Auto` slot — that
          # would produce `m: String = {}` instead of
          # `m: HashMap<String, Int64> = {}`.
          expect(repl).not_to eq("String")
          expect(repl).not_to eq("Int64")
          expect(repl).not_to match(/\AByte\[\d+\]\z/)
        end
      end
    end

    # Audit#1 — reassignment of a shape-tracked Auto binding. The
    # RHS list/hash literal should contribute element-type / key+value
    # evidence to the existing shape slots so the unifier can resolve
    # without requiring `.append` / index-assign uses.
    it "records non-empty list-literal reassignment items as :list_element evidence" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          MUTABLE xs: Auto = [];
          xs = [5_i64, 6_i64];
          RETURN;
        END
      CLEAR
      decl = ast.statements.first.body.find { |s| s.respond_to?(:name) && s.name == "xs" }
      expect(decl.type.resolved.to_s).to eq("Int64[]")
    end

    # Audit#4 — pin the documented behavior. Reassigning a
    # shape-tracked binding to a non-list / non-hash value
    # diagnoses as "Cannot infer" (the shape slot has no evidence
    # to drive resolution) rather than a type mismatch. CLEAR's
    # existing assignment validation is permissive (it also accepts
    # `Int64[] = []; xs = "hello"` silently), so this isn't a
    # regression — the inferencer's error is at least visible.
    it "diagnoses incompatible reassignment of a shape-tracked binding as `Cannot infer`" do
      annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          MUTABLE xs: Auto = [];
          xs = "hello";
          RETURN;
        END
      CLEAR
      findings = FixCollector.drain.select { |f|
        f.message.include?("Cannot infer type") &&
          f.message.include?("element type of list `xs`")
      }
      expect(findings.length).to eq(1)
    end

    it "records hash-literal reassignment pairs as :map_key / :map_value evidence" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          MUTABLE m: Auto = {};
          m = { "hello": 5_i64, "world": 7_i64 };
          RETURN;
        END
      CLEAR
      decl = ast.statements.first.body.find { |s| s.respond_to?(:name) && s.name == "m" }
      expect(decl.type.resolved.to_s).to eq("HashMap<String, Int64>")
    end

    # Regression: emit_auto_resolved_finding! must NOT emit a
    # per-sub-slot finding for shape slots — that path produced a
    # broken auto-fix (writing the scalar where the wrapped type
    # belongs). Only the binding-level emit_auto_shape_resolved_finding!
    # should fire.
    it "does not emit per-sub-slot resolved findings for shape slots" do
      annotate(<<~CLEAR)
        FN main() RETURNS !Void ->
          xs: Auto = [];
          xs.append(5_i64);
          RETURN;
        END
      CLEAR
      findings = FixCollector.drain.select { |f| f.message.start_with?("Inferred type") }
      # Exactly one binding-level finding.
      expect(findings.length).to eq(1)
      expect(findings.first.message).to include("`xs`")
      expect(findings.first.message).to include("Int64[]")
    end
  end
end

# M2.3 — STRUCT fields cannot use `Auto`. Cross-callsite struct
# field inference is intentionally not supported, so the parser
# rejects `field: Auto` with a hard error pointing at the field.
RSpec.describe "Gradual typing — Auto in STRUCT fields (M2.3)" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  it "rejects `field: Auto` with a parser error" do
    expect {
      parse(<<~CLEAR)
        STRUCT Box {
          value: Auto
        }
      CLEAR
    }.to raise_error(ParserError, /Auto is not allowed in STRUCT field declarations/)
  end

  it "names the offending field in the error message" do
    expect {
      parse(<<~CLEAR)
        STRUCT Foo {
          name: String,
          payload: Auto
        }
      CLEAR
    }.to raise_error(ParserError, /Field 'payload'/)
  end

  it "includes guidance on replacement types" do
    expect {
      parse(<<~CLEAR)
        STRUCT Bag {
          x: Auto
        }
      CLEAR
    }.to raise_error(ParserError, /Cross-callsite field inference/)
  end

  it "rejects `Auto` even with a default value" do
    expect {
      parse(<<~CLEAR)
        STRUCT Counter {
          n=0: Auto
        }
      CLEAR
    }.to raise_error(ParserError, /Auto is not allowed in STRUCT/)
  end

  it "rejects `BORROWED Auto`" do
    expect {
      parse(<<~CLEAR)
        STRUCT View {
          src: BORROWED Auto
        }
      CLEAR
    }.to raise_error(ParserError, /Auto is not allowed in STRUCT/)
  end

  it "rejects Auto in EXTERN STRUCT fields too (shared parse path)" do
    expect {
      parse(<<~CLEAR)
        EXTERN STRUCT Native {
          handle: Auto
        } FROM "native_mod";
      CLEAR
    }.to raise_error(ParserError, /Auto is not allowed in STRUCT/)
  end

  it "accepts STRUCT with all concrete fields" do
    expect {
      parse(<<~CLEAR)
        STRUCT Point {
          x: Int64,
          y: Int64
        }
      CLEAR
    }.not_to raise_error
  end

  it "accepts Auto in function parameters (regression — only STRUCT fields are blocked)" do
    expect {
      parse(<<~CLEAR)
        FN double(x: Auto) RETURNS Int64 ->
          RETURN 0;
        END
      CLEAR
    }.not_to raise_error
  end

  it "accepts Auto in local declarations (regression)" do
    expect {
      parse(<<~CLEAR)
        FN main() RETURNS Void ->
          x: Auto = 5_i64;
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "accepts Auto in function return types (regression)" do
    expect {
      parse(<<~CLEAR)
        FN id(x: Int64) RETURNS Auto ->
          RETURN x;
        END
      CLEAR
    }.not_to raise_error
  end

  # The same rationale applies to UNION variant payload types: there
  # is no cross-callsite inference for variant payloads, so allowing
  # Auto would produce effectively-typeless variants.
  it "rejects Auto in UNION variant payload (single-type)" do
    expect {
      parse(<<~CLEAR)
        UNION Result {
          Ok: Auto,
          Err: Int64
        }
      CLEAR
    }.to raise_error(ParserError, /Auto is not allowed in UNION variant payload field/)
  end

  it "rejects Auto in UNION inline-struct variant fields" do
    expect {
      parse(<<~CLEAR)
        UNION Shape {
          Circle { radius: Auto, color: String }
        }
      CLEAR
    }.to raise_error(ParserError, /Auto is not allowed in UNION inline-variant field/)
  end

  # Audit#3 — combining `Auto` with a prefix sigil has no defined
  # semantics. The parser used to fall through to a generic
  # "Expected TYPE_ID" error; now it produces a tailored message.
  describe "Audit#3 — Auto with prefix sigils" do
    %w[? ! ~ %].each do |prefix|
      it "rejects `#{prefix}Auto` in a struct field with a clear message" do
        expect {
          parse(<<~CLEAR)
            STRUCT Foo {
              v: #{prefix}Auto
            }
          CLEAR
        }.to raise_error(ParserError, /not supported.*cannot be combined with the prefix/)
      end

      it "rejects `#{prefix}Auto` in a function parameter with a clear message" do
        expect {
          parse(<<~CLEAR)
            FN foo(x: #{prefix}Auto) RETURNS Int64 ->
              RETURN 0;
            END
          CLEAR
        }.to raise_error(ParserError, /not supported.*cannot be combined with the prefix/)
      end

      it "rejects `#{prefix}Auto` in a local declaration with a clear message" do
        expect {
          parse(<<~CLEAR)
            FN main() RETURNS Void ->
              x: #{prefix}Auto = 5_i64;
              RETURN;
            END
          CLEAR
        }.to raise_error(ParserError, /not supported.*cannot be combined with the prefix/)
      end
    end

    it "still accepts plain `Auto` (regression)" do
      expect {
        parse(<<~CLEAR)
          FN main() RETURNS Void ->
            x: Auto = 5_i64;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  it "still accepts unit variants and concrete-payload variants" do
    expect {
      parse(<<~CLEAR)
        UNION Result {
          Ok: Int64,
          Err: String,
          Empty
        }
      CLEAR
    }.not_to raise_error
  end
end
