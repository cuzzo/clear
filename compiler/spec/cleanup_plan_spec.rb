require "rspec"
require "ostruct"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/mir/cleanup_classifier" unless defined?(CleanupClassifier::CleanupClassificationPlan)
require_relative "../ruby/mir/control_flow" unless defined?(BorrowChecker::BorrowState)
require_relative "../ruby/mir/mir" unless defined?(MIR::StdlibDefFsCoercion)
require_relative "../ruby/mir/mir_pass" unless defined?(MIRPass::OwnershipPreparationPlan)

# Tests CleanupClassifier - classifies which bindings need cleanup.
# MIRPass consumes this to insert MIR::Drop nodes and stamp AST.
#
# Categories tested:
# 1. Container borrows (HashMap/List indexing) -> no cleanup
# 2. TAKES parameters -> cleanup with _moved guard
# 3. MATCH AS bindings -> cleanup with _moved guard (double-free fix)
# 4. has_moved_guard correctness for all types
# 5. Collections, RC, sync, resources
# 6. Heap-promoted bindings
# 7. Structs with RC/string fields
# 8. Non-Copy unions on stack
# 9. Negative tests (primitives, Copy unions, strings)

RSpec.describe CleanupClassifier do
  let(:tok) { Lexer::Token.new(:VAR_ID, "x", 1, 1) }

  def cleanup_for(src, fn_name)
    result = compile_mir_frontend(src)
    ast = result.ast

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    CleanupClassifier.classify(
      fn_node,
      schema_lookup: ->(name) { result.annotator.lookup_type_schema(name) },
    )
  end

  def cleanup_plan_for(src, fn_name)
    result = compile_mir_frontend(src)
    ast = result.ast

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    CleanupClassifier.classify_plan(
      fn_node,
      schema_lookup: ->(name) { result.annotator.lookup_type_schema(name) },
    )
  end

  def schema_lookup_for(schemas = {})
    ->(name) {
      schemas[name] ||
        (name.respond_to?(:to_sym) ? schemas[name.to_sym] : nil) ||
        (name.respond_to?(:to_s) ? schemas[name.to_s] : nil)
    }
  end

  def cleanup_identifier(name, type: Type.new(:String), storage: :heap, moved: false)
    node = AST::Identifier.new(tok, name)
    node.full_type = type
    node.storage = storage
    node.was_moved = moved
    node.symbol = SymbolEntry.new(reg: name, type: type, mutable: true, storage: storage)
    node
  end

  def string_type_without_recursive_cleanup
    type = Type.new(:String)
    type.define_singleton_method(:needs_cleanup?) { |_lookup| false }
    type.define_singleton_method(:recursive_cleanup_shape?) { |_lookup| false }
    type
  end

  def field_type_with_cleanup(needs_cleanup:, recursive_cleanup:)
    type = Type.new(:Blob)
    type.define_singleton_method(:needs_cleanup?) { |_lookup| needs_cleanup }
    type.define_singleton_method(:recursive_cleanup_shape?) { |_lookup| recursive_cleanup }
    type
  end

  def heap_storage_node(value = nil)
    node = OpenStruct.new(value: value)
    node.define_singleton_method(:heap_storage?) { true }
    node
  end

  def var_decl(name:, type:, value:, mutable: false, storage: :heap)
    node = AST::VarDecl.new(tok, name, type, value, mutable)
    node.full_type = type
    node.symbol = SymbolEntry.new(reg: name, type: type, mutable: mutable, storage: storage)
    node
  end

  describe "binding cleanup facts" do
    it "builds cleanup classification plans from legacy binding maps" do
      entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)

      plan = CleanupClassifier::CleanupClassificationPlan.from_bindings("legacy", "item" => entry)
      empty_plan = CleanupClassifier::CleanupClassificationPlan.from_bindings("empty", {})

      expect(plan.function_name).to eq("legacy")
      expect(plan.facts.entry_for("item")).to eq(entry)
      expect(plan.empty?).to be(false)
      expect(empty_plan.empty?).to be(true)
    end

    it "classifies declaration-only functions as empty plans" do
      fn = AST::FunctionDef.new(
        tok,
        "declared",
        [],
        [],
        Type.new(:Void),
        nil,
        nil,
        [],
        nil,
        :public,
        [],
        false,
      )

      plan = CleanupClassifier.classify_plan(fn, schema_lookup: schema_lookup_for)

      expect(plan.function_name).to eq("declared")
      expect(plan.empty?).to eq(true)
      expect(plan.bindings).to eq({})
      expect(plan.facts.entry_for("anything")).to equal(CleanupEntry::NONE)
    end

    it "runs capture binding classification through the public plan entrypoint" do
      weak_value = cleanup_identifier("weak", type: Type.new(:"?String[]"))
      resolve = AST::ResolveNode.new(tok, weak_value)
      resolve.full_type = Type.new(:"?String[]")
      if_bind = AST::IfBind.new(
        tok,
        [AST::Binding.new(expr: resolve, name: "items", name_token: tok)],
        [],
        nil,
      )
      box_schema = Schemas::StructSchema.new(fields: {
        "name" => AST::StructField.new(type: Type.new(:String), default: nil, borrowed: false),
      })
      weak_box = cleanup_identifier("weak_box", type: Type.new(:"?Box"))
      resolve_box = AST::ResolveNode.new(tok, weak_box)
      resolve_box.full_type = Type.new(:"?Box")
      box_bind = AST::IfBind.new(
        tok,
        [AST::Binding.new(expr: resolve_box, name: "box", name_token: tok)],
        [],
        nil,
      )
      fn = AST::FunctionDef.new(
        tok,
        "captures",
        [],
        [],
        Type.new(:Void),
        nil,
        [if_bind, box_bind],
        [],
        nil,
        :public,
        [],
        false,
      )

      plan = CleanupClassifier.classify_plan(fn, schema_lookup: schema_lookup_for(Box: box_schema))
      entry = plan.facts.entry_for("items")
      box_entry = plan.facts.entry_for("box")

      expect(entry).not_to equal(CleanupEntry::NONE)
      expect(entry.kind).to eq(:uniform)
      expect(entry.alloc).to eq(:heap)
      expect(entry.has_moved_guard?).to eq(true)
      expect(entry[:elem_zig_type]).to eq(Type.new(:String).zig_type)
      expect(box_entry).not_to equal(CleanupEntry::NONE)
      expect(box_entry.kind).to eq(:uniform)
      expect(box_entry.alloc).to eq(:heap)
      expect(box_entry.has_moved_guard?).to eq(true)
    end

    it "stamps loop-local cleanup scopes through the public plan entrypoint" do
      plan = cleanup_plan_for(<<~CLEAR, "main")
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 1_i64 DO
            MUTABLE vals: Int64[]@list = List[];
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR

      entry = plan.facts.entry_for("vals")
      expect(entry).not_to equal(CleanupEntry::NONE)
      expect(entry.alloc).to eq(:frame)
      expect(entry.scope).to eq(:iteration)
    end

    it "returns the non-nil cleanup sentinel for missing and inactive facts" do
      inactive = CleanupEntry.no_cleanup(alloc: :frame, scope: :function)
      facts = CleanupClassifier::FrozenCleanupFacts.from_bindings("inactive" => inactive)

      expect(facts.entry_for("missing")).to equal(CleanupEntry::NONE)
      expect(facts.live_entry_for("missing")).to equal(CleanupEntry::NONE)
      expect(facts.entry_for(:inactive)).to eq(inactive)
      expect(facts.live_entry_for(:inactive)).to equal(CleanupEntry::NONE)
    end

    it "falls back from binding-aware places to path facts without nil guards" do
      entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
      node = var_decl(name: "item", type: Type.new(:String), value: nil)
      facts = CleanupClassifier::FrozenCleanupFacts.from_bindings("item" => entry)
      binding_place = CleanupClassifier.place_for_binding_node("item", node)

      expect(facts.entry_for(binding_place)).to eq(entry)
      expect(facts.entry_for_node("item", node)).to eq(entry)
      expect(facts.live_entry_for_node("item", node)).to eq(entry)
      expect(facts.live_entry_for_node("other", node)).to equal(CleanupEntry::NONE)
    end

    it "prefers binding-aware facts for node lookup and path facts for name lookup" do
      path_entry = CleanupEntry.build(:uniform, alloc: :frame, has_moved_guard: false)
      binding_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)
      node = var_decl(name: "item", type: Type.new(:String), value: nil)
      place = CleanupClassifier.place_for_binding_node("item", node)
      facts = CleanupClassifier::FrozenCleanupFacts.build(
        CleanupClassifier::PlaceId.from_path("item") => path_entry,
        place => binding_entry,
      )

      expect(facts.entry_for("item")).to eq(path_entry)
      expect(facts.entry_for(:item)).to eq(path_entry)
      expect(facts.entry_for(place)).to eq(binding_entry)
      expect(facts.entry_for_node(:item, node)).to eq(binding_entry)
      expect(facts.live_entry_for_node(:item, node)).to eq(binding_entry)
    end

    it "filters cleanup facts by path for strings, symbols, and place ids without mutating the source facts" do
      keep_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)
      drop_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
      captured_path_entry = CleanupEntry.build(:uniform, alloc: :frame, has_moved_guard: false)
      captured_binding_entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)
      captured_node = var_decl(name: "captured", type: Type.new(:String), value: nil)
      captured_place = CleanupClassifier.place_for_binding_node("captured", captured_node)
      facts = CleanupClassifier::FrozenCleanupFacts.build(
        CleanupClassifier::PlaceId.from_path("keep") => keep_entry,
        CleanupClassifier::PlaceId.from_path("drop") => drop_entry,
        CleanupClassifier::PlaceId.from_path("captured") => captured_path_entry,
        captured_place => captured_binding_entry,
      )

      filtered = facts.without_names([
        "drop",
        :captured,
        CleanupClassifier::PlaceId.from_path("missing"),
      ])

      expect(filtered.entry_for("keep")).to eq(keep_entry)
      expect(filtered.entry_for("drop")).to equal(CleanupEntry::NONE)
      expect(filtered.entry_for("captured")).to equal(CleanupEntry::NONE)
      expect(filtered.entry_for_node("captured", captured_node)).to equal(CleanupEntry::NONE)
      expect(filtered.bindings).to eq("keep" => keep_entry)
      expect(facts.entry_for("drop")).to eq(drop_entry)
      expect(facts.entry_for_node("captured", captured_node)).to eq(captured_binding_entry)
    end

    it "updates cleanup lifecycle through typed mutators" do
      entry = CleanupEntry.no_cleanup(alloc: :frame, scope: :function)

      entry.promote_to_cleanup!(kind: :uniform, alloc: :heap, has_moved_guard: false)
      expect(entry.needs_cleanup?).to be(true)
      expect(entry.kind).to eq(:uniform)
      expect(entry.alloc).to eq(:heap)
      expect(entry.scope).to eq(:heap)
      expect(entry.has_moved_guard?).to be(false)

      entry.mark_moved_guard!
      expect(entry.has_moved_guard?).to be(true)

      entry.set_alloc!(:frame)
      entry.set_cleanup_scope!(:match_branch)
      expect(entry.alloc).to eq(:frame)
      expect(entry.scope).to eq(:match_branch)

      entry.suppress_cleanup!
      expect(entry.needs_cleanup?).to be(false)
      expect(entry.has_moved_guard?).to be(false)
    end

    it "returns the non-nil cleanup sentinel for non-binding MIRPass lookup nodes" do
      pass = MIRPass.new(fn_nodes: {}, schema_lookup: ->(_name) { nil })
      facts = CleanupClassifier::FrozenCleanupFacts.from_bindings({})
      literal = AST::Literal.new(tok, :INT64, 1, :stack)

      expect(pass.send(:cleanup_entry_for_binding_node, literal, facts)).to equal(CleanupEntry::NONE)
    end

    it "freezes cleanup facts under stable binding-aware places" do
      plan = cleanup_plan_for(<<~CLEAR, "main")
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: User @indirect = User{ id: 1 };
          RETURN;
        END
      CLEAR
      yielded = []

      plan.facts.each_entry { |place, entry| yielded << [place, entry] }

      place, entry = yielded.first
      expect(place.path).to eq("a")
      expect(place.binding_identity).not_to be_nil
      expect(entry).to eq(plan.facts.entry_for("a"))
      expect(plan.bindings.keys).to include("a")
    end

    it "snapshots symbol and node provenance once for classification" do
      node = var_decl(
        name: "name",
        type: Type.new(:String),
        value: AST::Literal.new(tok, :STRING, "borrowed", :rodata),
        storage: :borrow,
      )
      node.resource_close_plan = Schemas::ResourceClosePlan.method("close")

      facts = CleanupClassifier.send(:binding_cleanup_facts, node)

      expect(facts.borrow_provenance).to be(true)
      expect(facts.rodata_provenance).to be(false)
      expect(facts.heap_storage).to be(false)
      expect(facts.empty_initializer).to be(false)
      expect(facts.mutable_binding_mutated).to be(false)
      expect(facts.resource_close_plan&.actions&.map(&:name)).to eq(["close"])
    end

    it "keeps mutated mutable optional nil bindings cleanup-eligible" do
      node = var_decl(
        name: "maybe",
        type: Type.optional_of(:String),
        value: AST::Literal.new(tok, :NIL, nil),
        mutable: true,
      )
      node.var_mutated = true
      facts = CleanupClassifier.send(:binding_cleanup_facts, node)

      expect(facts.empty_initializer).to be(true)
      expect(facts.mutable_binding_mutated).to be(true)
      expect(CleanupClassifier.send(:classify_binding, Type.optional_of(:String), node, schema_lookup_for))
        .to be_present
    end

    it "marks nested moved source identifiers without a late locatable walk" do
      moved_arg = cleanup_identifier("owned", moved: true)
      call = AST::FuncCall.new(tok, "consume", [moved_arg])
      bindings = {
        "owned" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
      }

      CleanupClassifier.send(:walk_moved_source_guards, [call], bindings)

      expect(bindings.fetch("owned").has_moved_guard?).to be(true)
    end

    it "marks moved source guards through the public plan entrypoint" do
      plan = cleanup_plan_for(<<~CLEAR, "main")
        STRUCT Pt { x: Float64, y: Float64 }
        FN consume(TAKES p: Pt[10]@pool) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          MUTABLE pool: Pt[10]@pool = [];
          consume(GIVE pool);
          RETURN;
        END
      CLEAR

      entry = plan.facts.entry_for("pool")
      expect(entry).not_to equal(CleanupEntry::NONE)
      expect(entry.has_moved_guard?).to be(true)
    end
  end

  # =========================================================================
  # Container borrows: data owned by container, no cleanup
  # =========================================================================
  describe "container borrow" do
    context "HashMap get with OR default" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test!")
          UNION Value { Nil, Str: String }
          FN test!(MUTABLE map: HashMap<Value>) RETURNS !String ->
              val = map["t0"] OR Value.Nil;
              PARTIAL MATCH val START
                  Value.Str AS s -> RETURN s;,
                  DEFAULT -> RETURN "";
              END
              RETURN "";
          END
        CLEAR
      end

      it "does NOT mark val for cleanup (container owns the data)" do
        expect(plan["val"]).to be_nil
      end
    end

    context "function call returning non-Copy union (not container)" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          UNION Value { Nil, Str: String }
          FN makeVal() RETURNS Value ->
              RETURN Value.Nil;
          END
          FN test() RETURNS !Void ->
              val = makeVal();
              RETURN;
          END
        CLEAR
      end

      it "marks val for cleanup (non-Copy union)" do
        entry = plan["val"]
        expect(entry).not_to be_nil
        # Provenance-based: :heap_union (heap cleanup_alloc for unions with heap variants)
        expect([:uniform]).to include(entry[:kind])
        expect(entry[:has_moved_guard]).to eq(false)
        expect(entry[:alloc]).to eq(:heap)
      end
    end

    context "COPY of non-Copy union" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          UNION Data { Empty, Text: String, Nested { label: String, inner: Data @indirect } }
          FN makeData() RETURNS Data ->
              RETURN Data{ Text: "hello" };
          END
          FN test() RETURNS !Void ->
              d = makeData();
              d2 = COPY d;
              RETURN;
          END
        CLEAR
      end

      it "marks original for cleanup" do
        entry = plan["d"]
        expect(entry).not_to be_nil
        expect([:uniform]).to include(entry[:kind])
      end

      it "marks COPY result for cleanup" do
        entry = plan["d2"]
        expect(entry).not_to be_nil
        expect([:uniform]).to include(entry[:kind])
        expect(entry[:alloc]).to eq(:heap)
      end
    end
  end

  # =========================================================================
  # TAKES parameters
  # =========================================================================
  describe "TAKES parameters" do
    context "TAKES union parameter" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "consume!")
          UNION Value { Nil, Str: String }
          FN consume!(TAKES v: Value) RETURNS Void ->
              RETURN;
          END
        CLEAR
      end

      it "marks TAKES union param for cleanup" do
        entry = plan["v"]
        expect(entry).not_to be_nil
        expect(entry[:needs_cleanup]).to eq(true)
        expect(entry[:has_moved_guard]).to eq(true)
        expect(entry[:kind]).to eq(:takes_union)
      end
    end

    context "non-TAKES parameter" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "borrow")
          UNION Value { Nil, Str: String }
          FN borrow(v: Value) RETURNS Void ->
              RETURN;
          END
        CLEAR
      end

      it "does NOT mark borrowed param for cleanup" do
        expect(plan["v"]).to be_nil
      end
    end

    context "TAKES string parameter" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "consume!")
          FN consume!(TAKES s: String) RETURNS Void ->
              RETURN;
          END
        CLEAR
      end

      it "marks TAKES string param for cleanup" do
        entry = plan["s"]
        expect(entry).not_to be_nil
        # :takes_string was a vestigial alias of :heap_string (same emit).
        # source_kind: :takes_param now carries the TAKES origin.
        expect(entry[:kind]).to eq(:heap_string)
        expect(entry[:source_kind]).to eq(:takes_param)
        expect(entry[:has_moved_guard]).to eq(true)
      end
    end

    context "TAKES slice parameter" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "process!")
          UNION Value { Nil, Num: Float64 }
          FN process!(TAKES items: Value[]) RETURNS Void ->
              RETURN;
          END
        CLEAR
      end

      it "marks TAKES slice param for cleanup with heap alloc (callee owns buffer)" do
        entry = plan["items"]
        expect(entry).not_to be_nil
        expect(entry[:kind]).to eq(:uniform)
        expect(entry[:alloc]).to eq(:heap)
        expect(entry[:has_moved_guard]).to eq(true)
        expect(entry[:source_kind]).to eq(:takes_param)
      end
    end
  end

  # =========================================================================
  # MATCH AS bindings (the double-free bug fix)
  # =========================================================================
  describe "MATCH AS binding (borrow)" do
    context "plain MATCH AS borrows non-Copy variants" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "eval!")
          UNION Value { Nil, Num: Float64, List: Value[] }
          FN eval!(TAKES ast: Value) RETURNS Value ->
              PARTIAL MATCH ast START
                  Value.List AS items -> RETURN Value.Nil;,
                  DEFAULT -> RETURN Value.Nil;
              END
              RETURN Value.Nil;
          END
        CLEAR
      end

      it "does not synthesize owned cleanup for the AS binding" do
        expect(plan["items"]).to be_nil
      end
    end

    context "MATCH AS variant payload is a map" do
      # match_as_entry_for has a code path for non-array collection
      # payloads (the only reachable case is map?, since list-typed
      # payloads are also array? and hit the :takes_slice arm first).
      # Exercise it on a HashMap-typed variant.
      it "produces :string_map for a HashMap variant payload" do
        map_ty = Type.new(:"HashMap<Int64>")
        entry = CleanupClassifier.send(:match_as_entry_for, map_ty, :U, "Items")
        expect(entry).not_to be_nil
        expect(entry[:kind]).to eq(:uniform)
        expect(entry[:match_as]).to eq(true)
      end

      it "skips unit and indirect payloads" do
        indirect_ty = Type.new(:Box, layout: :indirect)

        expect(CleanupClassifier.send(:match_as_entry_for, nil, :U, "None")).to be_nil
        expect(CleanupClassifier.send(:match_as_entry_for, indirect_ty, :U, "Box")).to be_nil
      end
    end
  end

  describe "optional cleanup classification" do
    it "classifies optional owned payloads when the node has no initializer value" do
      entry = CleanupClassifier.send(
        :classify_optional,
        Type.new(:"?String"),
        ->(_name) { nil },
        node: Object.new,
      )

      expect(entry).not_to be_nil
      expect(entry[:kind]).to eq(:uniform)
      expect(entry[:alloc]).to eq(:frame)
      expect(entry[:has_moved_guard]).to eq(true)
    end
  end

  describe "classifier edge branches" do
    it "stamps pre-cleanups for auto-lock strings and heap-owned string fields" do
      auto_field = AST::GetField.new(tok, cleanup_identifier("locked_box"), "name")
      auto_field.full_type = string_type_without_recursive_cleanup
      auto_assign = AST::Assignment.new(tok, auto_field, AST::Literal.new(tok, :STRING, "next", :rodata))
      auto_assign.auto_lock = true

      CleanupClassifier.stamp_field_pre_cleanups!(
        [auto_assign],
        CleanupClassifier::FrozenCleanupFacts.from_bindings({}),
        schema_lookup: schema_lookup_for,
      )
      expect(auto_assign.field_pre_cleanup).to eq(:heap)

      heap_field = AST::GetField.new(tok, cleanup_identifier("box", storage: :heap), "label")
      heap_field.full_type = string_type_without_recursive_cleanup
      heap_assign = AST::Assignment.new(tok, heap_field, AST::Literal.new(tok, :STRING, "next", :rodata))
      bindings = {
        "box" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
      }

      CleanupClassifier.stamp_field_pre_cleanups!(
        [heap_assign],
        CleanupClassifier::FrozenCleanupFacts.from_bindings(bindings),
        schema_lookup: schema_lookup_for,
      )
      expect(heap_assign.field_pre_cleanup).to eq(:heap)
    end

    it "stamps cleanup-bearing fields with the owner allocator and ignores non-field statements" do
      literal = AST::Literal.new(tok, :STRING, "next", :rodata)
      plain_assign = AST::Assignment.new(tok, cleanup_identifier("plain"), literal)
      frame_field = AST::GetField.new(tok, cleanup_identifier("frame_box", storage: :frame), "label")
      frame_field.full_type = Type.new(:String)
      frame_assign = AST::Assignment.new(tok, frame_field, literal)
      heap_field = AST::GetField.new(tok, cleanup_identifier("heap_box", storage: :heap), "label")
      heap_field.full_type = Type.new(:String)
      heap_assign = AST::Assignment.new(tok, heap_field, literal)
      facts = CleanupClassifier::FrozenCleanupFacts.from_bindings(
        "frame_box" => CleanupEntry.build(:uniform, alloc: :frame, has_moved_guard: false),
        "heap_box" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
      )

      CleanupClassifier.stamp_field_pre_cleanups!(
        [literal, plain_assign, frame_assign, heap_assign],
        facts,
        schema_lookup: schema_lookup_for,
      )

      expect(plain_assign.field_pre_cleanup).to be_nil
      expect(frame_assign.field_pre_cleanup).to eq(:frame)
      expect(heap_assign.field_pre_cleanup).to eq(:heap)
    end

    it "does not treat auto-lock alone as cleanup for non-string fields" do
      field = AST::GetField.new(tok, cleanup_identifier("locked_box"), "count")
      field.full_type = Type.new(:Int64)
      assign = AST::Assignment.new(tok, field, AST::Literal.new(tok, :INT64, 1, nil))
      assign.auto_lock = true

      CleanupClassifier.stamp_field_pre_cleanups!(
        [assign],
        CleanupClassifier::FrozenCleanupFacts.from_bindings({}),
        schema_lookup: schema_lookup_for,
      )

      expect(assign.field_pre_cleanup).to be_nil
    end

    it "uses owner cleanup when the field directly needs cleanup without recursive shape" do
      field = AST::GetField.new(tok, cleanup_identifier("box", storage: :frame), "payload")
      field.full_type = field_type_with_cleanup(needs_cleanup: true, recursive_cleanup: false)
      assign = AST::Assignment.new(tok, field, AST::Literal.new(tok, :INT64, 1, nil))
      facts = CleanupClassifier::FrozenCleanupFacts.from_bindings(
        "box" => CleanupEntry.build(:uniform, alloc: :frame, has_moved_guard: false),
      )

      CleanupClassifier.stamp_field_pre_cleanups!([assign], facts, schema_lookup: schema_lookup_for)

      expect(assign.field_pre_cleanup).to eq(:frame)
    end

    it "walks nested bodies when stamping field pre-cleanups" do
      literal = AST::Literal.new(tok, :STRING, "next", :rodata)
      field = AST::GetField.new(tok, cleanup_identifier("box", storage: :heap), "label")
      field.full_type = Type.new(:String)
      assign = AST::Assignment.new(tok, field, literal)
      condition = AST::Literal.new(tok, :TRUE, true, nil)
      branch = AST::IfStatement.new(tok, condition, [assign], [], [], [])
      facts = CleanupClassifier::FrozenCleanupFacts.from_bindings(
        "box" => CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
      )

      CleanupClassifier.stamp_field_pre_cleanups!([branch], facts, schema_lookup: schema_lookup_for)

      expect(assign.field_pre_cleanup).to eq(:heap)
    end

    it "covers defensive no-cleanup fallback and transferred payload recipes" do
      bad_type = Object.new
      bad_type.define_singleton_method(:to_s) { raise "bad type" }
      expect(CleanupClassifier.send(:no_cleanup_alloc_entry, bad_type, schema_lookup_for)).to be_nil

      moved_string = CleanupClassifier.send(:transferred_payload_entry, Type.new(:String), schema_lookup_for)
      expect(moved_string[:kind]).to eq(:heap_string)

      resource_schema = Schemas::ResourceSchema.new(close_plan: Schemas::ResourceClosePlan.method("close"))
      resource = CleanupClassifier.send(
        :takes_param_base_entry,
        Type.new(:Fileish),
        schema_lookup_for(Fileish: resource_schema),
      )
      expect(resource[:kind]).to eq(:resource)
      expect(resource.resource_close_plan&.actions&.map(&:name)).to eq(["close"])
    end

    it "keeps resource close plans structural through field composition" do
      function_plan = Schemas::ResourceClosePlan.function("closeHandle", runtime_heap_alloc_args: 2)
      nested = function_plan.for_field("handle")

      expect(function_plan.empty?).to eq(false)
      expect(Schemas::ResourceClosePlan.composite([]).empty?).to eq(true)
      expect(nested.actions.first.call_kind).to eq(Schemas::ResourceCloseCallKind::Function)
      expect(nested.actions.first.field_path).to eq(["handle"])
      expect(nested.actions.first.runtime_heap_alloc_args).to eq(2)

      resource_schema = Schemas::ResourceSchema.new(
        close_plan: function_plan,
        fields: {
          raw: :Int64,
          existing: AST::StructField.new(type: Type.new(:Bool)),
          meta: { type: :String, default: AST::Literal.new(tok, :STRING, "x", :rodata), borrowed: true },
        },
        type_params: [:T],
        extern_module: "native",
        as_type: "Native(T)",
        static_methods: {
          "open" => { args: [:String], return: :Handle, zig: "open({0})", can_fail: true },
        },
      )

      expect(resource_schema.fields.fetch("raw").type.resolved).to eq(:Int64)
      expect(resource_schema.fields.fetch("existing").type.resolved).to eq(:Bool)
      expect(resource_schema.fields.fetch("meta").borrowed).to eq(true)
      expect(resource_schema.type_params).to eq([:T])
      expect(resource_schema.static_methods.fetch("open").fetch(:can_fail)).to eq(true)

      direct = Type.new(:Handle).resolve_resource_close(schema_lookup_for(Handle: resource_schema))
      expect(direct.first).to eq(true)
      expect(direct.last&.actions&.first&.name).to eq("closeHandle")

      box_schema = Schemas::StructSchema.new(fields: {
        "handle" => AST::StructField.new(type: Type.new(:Handle)),
      })
      composed = Type.new(:Box).resolve_resource_close(schema_lookup_for(Box: box_schema, Handle: resource_schema))
      expect(composed.first).to eq(true)
      action = composed.last&.actions&.first
      expect(action&.name).to eq("closeHandle")
      expect(action&.field_path).to eq(["handle"])

      resource_decl = var_decl(
        name: "handle",
        type: Type.new(:Handle),
        value: nil,
        storage: :heap,
      )
      resource_entry = CleanupClassifier.send(
        :classify_binding,
        Type.new(:Handle),
        resource_decl,
        schema_lookup_for(Handle: resource_schema),
      )
      expect(resource_entry.kind).to eq(:resource)
      expect(resource_entry.resource_close_plan&.actions&.first&.name).to eq("closeHandle")

      planned_decl = var_decl(
        name: "late",
        type: Type.new(:LateBound),
        value: nil,
        storage: :heap,
      )
      planned_decl.resource_close_plan = Schemas::ResourceClosePlan.method("closeLate")
      planned_entry = CleanupClassifier.send(
        :classify_binding,
        Type.new(:LateBound),
        planned_decl,
        schema_lookup_for,
      )
      expect(planned_entry.kind).to eq(:resource)
      expect(planned_entry.resource_close_plan&.actions&.first&.name).to eq("closeLate")
    end

    it "recognizes MATCH TAKES method-style variants as owned AS bindings" do
      source = cleanup_identifier("ast", type: Type.new(:Value), storage: :heap, moved: true)
      case_value = AST::MethodCall.new(tok, cleanup_identifier("Value", type: Type.new(:Value)), "Items", [])
      match_case = AST::MatchCase.new(kind: :literal, value: case_value, body: [], binding: "items")
      non_variant_case = AST::MatchCase.new(
        kind: :literal,
        value: AST::Literal.new(tok, :NUMBER, "1", :stack),
        body: [],
        binding: "ignored",
      )
      match = AST::MatchStatement.new(tok, source, [match_case, non_variant_case], nil, nil, nil, false, true)
      schema = Schemas::UnionSchema.new(variants: { "Items" => Type.new(:"String[]") })
      bindings = {
        "ast" => CleanupEntry.build(:uniform, alloc: :frame, has_moved_guard: true),
      }

      CleanupClassifier.send(:walk_match_as_bindings, [match], schema_lookup_for(Value: schema), bindings)
      expect(bindings["items"][:kind]).to eq(:uniform)
      expect(bindings["items"][:match_as]).to eq(true)
      expect(bindings["items"][:alloc]).to eq(:frame)
      expect(bindings["ignored"]).to be_nil
    end

    it "classifies ownership-transferring capture bindings and heap call fallbacks" do
      weak_value = cleanup_identifier("weak", type: Type.new(:"?String[]"))
      resolve = AST::ResolveNode.new(tok, weak_value)
      resolve.full_type = Type.new(:"?String[]")
      if_bind = AST::IfBind.new(
        tok,
        [AST::Binding.new(expr: resolve, name: "items", name_token: tok)],
        [],
        nil,
      )
      bindings = {}

      CleanupClassifier.send(:walk_capture_bindings, [if_bind], schema_lookup_for, bindings)
      expect(bindings["items"][:alloc]).to eq(:heap)
      expect(bindings["items"][:elem_zig_type]).to eq(Type.new(:String).zig_type)

      fn_call = AST::FuncCall.new(tok, "make", [])
      fn_call.define_singleton_method(:heap_storage?) { true }
      expect(CleanupClassifier.send(:capture_expr_heap?, fn_call, schema_lookup_for)).to be(true)

      method_call = AST::MethodCall.new(tok, cleanup_identifier("receiver", storage: :frame), "make", [])
      method_call.define_singleton_method(:heap_storage?) { true }
      expect(CleanupClassifier.send(:capture_expr_heap?, method_call, schema_lookup_for)).to be(true)

      receiver_owned = AST::MethodCall.new(tok, cleanup_identifier("receiver", storage: :heap), "maybe", [])
      expect(CleanupClassifier.send(:capture_expr_heap?, receiver_owned, schema_lookup_for)).to be(true)
    end

    it "marks owned return calls and NEXT optionals as fixed heap cleanups" do
      call = AST::FuncCall.new(tok, "makeString", [])
      returned = AST::VarDecl.new(tok, "result", Type.new(:"!String"), call, false)
      returned.symbol = SymbolEntry.new(reg: "result", type: Type.new(:"!String"), mutable: false, storage: :heap)

      owned_return = CleanupClassifier.send(
        :classify_owned_return_call,
        Type.new(:"!String"),
        returned,
        schema_lookup_for,
      )
      expect(owned_return[:kind]).to eq(:heap_string)
      expect(owned_return[:fixed_alloc]).to eq(true)

      next_expr = AST::NextExpr.new(tok, cleanup_identifier("promise", type: Type.new(:"~String")))
      optional_node = AST::VarDecl.new(tok, "maybe", Type.new(:"?String"), next_expr, false)
      optional_node.symbol = SymbolEntry.new(reg: "maybe", type: Type.new(:"?String"), mutable: false, storage: :frame)

      optional = CleanupClassifier.send(
        :classify_optional,
        Type.new(:"?String"),
        schema_lookup_for,
        node: optional_node,
      )
      expect(optional[:alloc]).to eq(:heap)
      expect(optional[:fixed_alloc]).to eq(true)
    end

    it "classifies owned array literals and binary string concatenation" do
      list_lit = AST::ListLit.new(tok, [AST::Literal.new(tok, :STRING, "x", :rodata)], :frame)
      array_node = OpenStruct.new(
        value: list_lit,
        symbol: SymbolEntry.new(reg: "items", type: Type.new(:"String[]"), mutable: false, storage: :frame),
        storage: :frame,
      )
      array_entry = CleanupClassifier.send(
        :classify_array_struct_strings,
        Type.new(:"String[]"),
        array_node,
        schema_lookup_for,
      )
      expect(array_entry[:kind]).to eq(:uniform)
      expect(array_entry[:alloc]).to eq(:frame)

      concat = AST::BinaryOp.new(
        tok,
        cleanup_identifier("left", type: Type.new(:String)),
        :ADD,
        cleanup_identifier("right", type: Type.new(:String)),
      )
      concat.string_concat = true
      string_node = AST::VarDecl.new(tok, "joined", Type.new(:String), concat, false)
      string_entry = CleanupClassifier.send(
        :classify_owned_string,
        Type.new(:String),
        string_node,
        schema_lookup_for,
      )
      expect(string_entry[:kind]).to eq(:heap_string)
    end

    it "skips heap-composite cleanup when fields have no cleanup or borrow it" do
      no_cleanup_schema = Schemas::StructSchema.new(fields: {
        "inner" => AST::StructField.new(type: Type.new(:Inner), default: nil, borrowed: false),
      })
      no_cleanup = CleanupClassifier.send(
        :classify_heap_composite,
        Type.new(:Box),
        heap_storage_node,
        schema_lookup_for(Box: no_cleanup_schema),
        nil,
      )
      expect(no_cleanup).to be_nil

      borrowed_value = cleanup_identifier("name", type: Type.new(:String), storage: :borrow)
      struct_lit = AST::StructLit.new(tok, "Box", { "name" => borrowed_value }, :heap, [])
      borrowed_schema = Schemas::StructSchema.new(fields: {
        "name" => AST::StructField.new(type: Type.new(:String), default: nil, borrowed: false),
      })
      borrowed_cleanup = CleanupClassifier.send(
        :classify_heap_composite,
        Type.new(:Box),
        heap_storage_node(struct_lit),
        schema_lookup_for(Box: borrowed_schema),
        nil,
      )
      expect(borrowed_cleanup).to be_nil
    end

    it "treats borrowed inline struct fields as non-cleanup-bearing" do
      inline = Schemas::InlineStructVariant.new(fields: {
        "borrowed" => Type.new(:String),
      })
      inline.fields["borrowed"] = AST::StructField.new(type: Type.new(:String), default: nil, borrowed: true)

      expect(CleanupClassifier.send(:elem_has_cleanup_fields?, inline, schema_lookup_for)).to eq(false)
    end
  end

  describe "MATCH TAKES binding (move)" do
    context "MATCH TAKES with slice payload" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "eval!")
          UNION Value { Nil, Num: Float64, List: Value[] }
          FN eval!(TAKES ast: Value) RETURNS Value ->
              PARTIAL MATCH TAKES ast START
                  Value.List AS items -> RETURN Value.Nil;,
                  DEFAULT -> RETURN Value.Nil;
              END
              RETURN Value.Nil;
          END
        CLEAR
      end

      it "marks AS binding for cleanup with _moved guard" do
        entry = plan["items"]
        expect(entry).not_to be_nil
        expect(entry[:needs_cleanup]).to eq(true)
        expect(entry[:has_moved_guard]).to eq(true)
        # :match_as_slice was a vestigial alias of :takes_slice (same emit body).
        # match_as: true flag now carries the MATCH AS origin.
        expect(entry[:kind]).to eq(:uniform)
        expect(entry[:match_as]).to eq(true)
      end

      it "uses heap allocator (slice contents may be heap-allocated via COPY/promote)" do
        entry = plan["items"]
        expect(entry[:alloc]).to eq(:heap)
      end
    end

    context "Copy payload (Float64)" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test!")
          UNION Value { Nil, Num: Float64 }
          FN test!(TAKES v: Value) RETURNS Void ->
              PARTIAL MATCH v START
                  Value.Num AS n -> RETURN;,
                  DEFAULT -> RETURN;
              END
              RETURN;
          END
        CLEAR
      end

      it "does NOT mark Copy payload for cleanup" do
        expect(plan["n"]).to be_nil
      end
    end
  end

  # =========================================================================
  # Collections
  # =========================================================================
  describe "collections" do
    context "local @list" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          FN main() RETURNS Void ->
              MUTABLE vals: Int64[]@list = List[];
              vals.append(1_i64);
              RETURN;
          END
        CLEAR
      end

      it "marks for frame cleanup with _moved guard" do
        entry = plan["vals"]
        expect(entry[:alloc]).to eq(:frame)
        expect(entry[:has_moved_guard]).to eq(true)
      end
    end

    context "local HashMap" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          FN main() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m["x"] = 1_i64;
              RETURN;
          END
        CLEAR
      end

      it "marks for map-owned heap cleanup with a moved guard" do
        entry = plan["m"]
        expect(entry[:alloc]).to eq(:heap)
        expect(entry[:kind]).to eq(:uniform)
        expect(entry[:has_moved_guard]).to eq(true)
      end
    end
  end

  # =========================================================================
  # Heap-promoted bindings
  # =========================================================================
  describe "heap-promoted" do
    context "direct binding of promoted list return" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          FN makeList() RETURNS !Int64[] ->
              MUTABLE items: Int64[]@list = List[];
              items.append(1_i64);
              RETURN items;
          END
          FN main() RETURNS Void ->
              list1 = makeList();
              ASSERT list1.length() == 1;
              RETURN;
          END
        CLEAR
      end

      it "marks for heap cleanup" do
        entry = plan["list1"]
        expect(entry[:alloc]).to eq(:heap)
        expect(entry[:has_moved_guard]).to eq(false)
      end
    end

    context "chained promoted return" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          FN makeList() RETURNS !Int64[] ->
              MUTABLE items: Int64[]@list = List[];
              items.append(1_i64);
              RETURN items;
          END
          FN wrapper() RETURNS !Int64[] ->
              RETURN makeList();
          END
          FN main() RETURNS Void ->
              result = wrapper();
              RETURN;
          END
        CLEAR
      end

      it "marks for heap cleanup (transitively promoted)" do
        entry = plan["result"]
        expect(entry[:alloc]).to eq(:heap)
      end
    end

    context "union binding from promoted function" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          UNION Value { Num: Float64, Items: Int64[] }
          FN makeValue() RETURNS !Value ->
              MUTABLE items: Int64[]@list = List[];
              items.append(1_i64);
              RETURN Value{ Items: items };
          END
          FN main() RETURNS Void ->
              v = makeValue();
              RETURN;
          END
        CLEAR
      end

      it "marks for heap cleanup (union returned from promoted function)" do
        entry = plan["v"]
        expect(entry[:alloc]).to eq(:heap)
        expect(entry[:kind]).to eq(:uniform)
      end
    end
  end

  # =========================================================================
  # Non-Copy unions on stack
  # =========================================================================
  describe "non-Copy union on stack" do
    context "union with String variant" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          UNION Value { Nil, Str: String }
          FN test() RETURNS !Void ->
              v = Value{ Str: COPY "hello" };
              RETURN;
          END
        CLEAR
      end

      it "marks for cleanup without a moved guard until a move site exists" do
        entry = plan["v"]
        expect(entry).not_to be_nil
        expect(entry[:needs_cleanup]).to eq(true)
        # Provenance-based: :heap_union (COPY produces :heap provenance)
        expect([:uniform]).to include(entry[:kind])
        expect(entry[:has_moved_guard]).to eq(false)
      end
    end
  end

  # =========================================================================
  # Resources
  # =========================================================================
  # Resource test skipped: File.open requires a real filesystem path and
  # the test harness doesn't mock it. Resource cleanup is covered by the
  # transpile-tests (60_file_resource.clear, 63_resource_return.clear).

  # =========================================================================
  # Negative tests: no cleanup needed
  # =========================================================================
  describe "no cleanup needed" do
    context "primitive binding" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          FN test() RETURNS Void ->
              x = 42_i64;
              RETURN;
          END
        CLEAR
      end

      it "has no entries" do
        expect(plan["x"]).to be_nil
      end
    end

    context "string binding (frame-arena managed)" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          FN test() RETURNS Void ->
              s = "hello";
              RETURN;
          END
        CLEAR
      end

      it "has a no-cleanup frame lifetime entry" do
        expect(plan["s"]&.dig(:needs_cleanup)).to be false
        expect(plan["s"]&.dig(:alloc)).to eq(:frame)
      end
    end

    context "Copy union (all primitive variants)" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          UNION Result { Ok: Float64, Err: Float64 }
          FN test() RETURNS Void ->
              r = Result{ Ok: 42.0 };
              RETURN;
          END
        CLEAR
      end

      it "has no entries (all variants are Copy)" do
        expect(plan["r"]).to be_nil
      end
    end
  end

  # =========================================================================
  # has_moved_guard tests
  # =========================================================================
  describe "has_moved_guard" do
    context "pool is an owned collection with guard" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          STRUCT Pt { x: Float64, y: Float64 }
          FN main() RETURNS Void ->
              MUTABLE pool: Pt[10]@pool = [];
              RETURN;
          END
        CLEAR
      end

      it "pool uses unguarded cleanup until a move site requires a guard" do
        entry = plan["pool"]
        expect(entry[:has_moved_guard]).to eq(false)
        expect(entry[:kind]).to eq(:uniform)
      end
    end
  end

  # =========================================================================
  # Struct with rodata string fields: no cleanup needed
  # =========================================================================
  describe "struct with rodata string fields" do
    let(:src) do
      <<~CLEAR
        STRUCT Pair { name: String, value: Float64 }
        FN f() RETURNS !Void ->
            s = "hello";
            p = Pair{ name: s, value: 1.0 };
            RETURN;
        END
      CLEAR
    end
    let(:plan) { cleanup_for(src, "f") }

    it "classifies struct as needing cleanup (rodata strings auto-duped to heap)" do
      entry = plan["p"]
      expect(entry).not_to be_nil
      # Provenance-based: :heap_struct (CopyNode field gives :heap provenance)
      expect([:uniform]).to include(entry[:kind])
    end
  end

  describe "struct with heap string fields" do
    let(:src) do
      <<~CLEAR
        STRUCT Pair { name: String, value: Float64 }
        FN f(s: String) RETURNS !Void ->
            p = Pair{ name: COPY s, value: 1.0 };
            RETURN;
        END
      CLEAR
    end
    let(:plan) { cleanup_for(src, "f") }

    it "classifies struct as needing cleanup when string field is COPY" do
      entry = plan["p"]
      expect(entry).not_to be_nil
      # Provenance-based: :heap_struct (COPY field gives :heap provenance)
      expect([:uniform]).to include(entry[:kind])
    end
  end

  # ── CATCH string return: caller must cleanup heap-duped result ──────
  describe "CATCH function returning String" do
    it "gives caller a heap_string cleanup for the result" do
      plan = cleanup_for(<<~CLEAR, "main")
        FN riskyOp(mode: String) RETURNS !String ->
            RETURN "ok:" + mode;
        END
        FN handleWithCatch(mode: String) RETURNS !String ->
            result = riskyOp(mode) OR RAISE;
            RETURN result;
        CATCH Transient
            RETURN "recovered";
        END
        FN main() RETURNS Void ->
            r = handleWithCatch("ok");
            RETURN;
        END
      CLEAR
      entry = plan["r"]
      expect(entry).not_to be_nil, "CATCH string return should have cleanup"
      expect(entry[:kind]).to eq(:uniform)
    end
  end

  # ── Inline struct arg: no CopyNode wrapping for rodata strings ──────
  describe "struct literal as function argument" do
    it "does NOT get CopyNode wrapping on rodata string fields" do
      src = <<~CLEAR
        STRUCT User { name: String, age: Int64 }
        FN process(u: User) RETURNS Int64 -> RETURN u.age; END
        FN main() RETURNS Void ->
            x = process(User{ name: "Alice", age: 30_i64 });
            RETURN;
        END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
      # Find the FuncCall to process
      call = nil
      fn.body.each do |stmt|
        next unless stmt.is_a?(AST::BindExpr)
        call = stmt.value if stmt.value.is_a?(AST::FuncCall) && stmt.value.name == "process"
      end
      expect(call).not_to be_nil
      struct_arg = call.args.first
      expect(struct_arg).to be_a(AST::StructLit)
      # The name field should NOT be a CopyNode (rodata is valid for call lifetime)
      name_val = struct_arg.fields["name"]
      expect(name_val).not_to be_a(AST::CopyNode), "rodata string in call-arg struct should not be CopyNode-wrapped"
    end
  end

  # ── Array literal of structs with string fields ────────────────────
  describe "array literal of structs with string fields" do
    it "gets :heap_slice cleanup (uniform slice arm of CheatLib.cleanup)" do
      # No "array of struct with strings" special case: a plain T[] slice
      # with owning element fields routes through the slice arm. Element
      # cleanup recurses into String fields; buffer free is alloc-driven
      # (no-op for frame, real free for heap).
      plan = cleanup_for(<<~CLEAR, "main")
        STRUCT Item { name: String, value: Int64 }
        FN main() RETURNS Void ->
            items = [Item{ name: "a", value: 1_i64 }];
            RETURN;
        END
      CLEAR
      entry = plan["items"]
      expect(entry).not_to be_nil, "struct array literal with string fields should have cleanup"
      expect(entry[:kind]).to eq(:uniform)
    end
  end

  # ── COPY union as non-TAKES call arg needs caller cleanup ──────
  describe "COPY union as non-TAKES call argument" do
    it "COPY union passed to non-TAKES callee is a compile error or requires TAKES" do
      # When a non-Copy union is passed to a non-TAKES function, the caller
      # retains ownership but has no cleanup path for the COPY data.
      # The architecturally correct fix: the callee should declare TAKES
      # when it may consume the input. This test documents that TAKES
      # is required for correct COPY-union ownership transfer.
      src = <<~CLEAR
        UNION Value { Nil, Error { msg: String } }
        FN consume(TAKES v: Value) RETURNS Value -> RETURN Value.Nil; END
        FN main() RETURNS Void ->
            err = Value.Error{ msg: "x" };
            result = consume(COPY err);
            RETURN;
        END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      # With TAKES, the callee owns the COPY and handles cleanup.
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "consume" }
      expect(fn.params.first[:takes]).to be_truthy
    end

    it "TAKES callee does NOT mark COPY arg for caller cleanup" do
      src = <<~CLEAR
        UNION Value { Nil, Error { msg: String } }
        FN consume(TAKES v: Value) RETURNS Value -> RETURN Value.Nil; END
        FN main() RETURNS Void ->
            err = Value.Error{ msg: "x" };
            result = consume(COPY err);
            RETURN;
        END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
      call = nil
      fn.body.each do |stmt|
        next unless stmt.is_a?(AST::BindExpr) && stmt.name == "result"
        call = stmt.value
      end
      copy_arg = call.args.first
      expect(copy_arg).to be_a(AST::CopyNode)
      # TAKES: callee owns the COPY. No @needs_caller_cleanup.
      expect(copy_arg.instance_variable_get(:@needs_caller_cleanup)).to be_nil,
        "TAKES callee: COPY arg should NOT be marked @needs_caller_cleanup"
    end
  end

  # ── HPT hoisting: MIRPass hoists sub-expression calls into VarDecls ──

  # Run the full MIRPass pipeline and return the cleanup plan for a function.
  def mir_plan_for(src, fn_name)
    result = compile_mir_frontend(src)
    fn = result.fn_nodes[fn_name]
    fn&.cleanup_bindings || {}
  end

  # ===========================================================================
  # COPY of non-Copy union consumed by MATCH TAKES: cleanup must survive
  # ===========================================================================
  describe "COPY non-Copy union consumed by MATCH TAKES" do
    it "keeps cleanup for COPY result after refine_moved_guards" do
      plan = mir_plan_for(<<~CLEAR, "main")
        UNION Data { Empty, Text: String, Nested { label: String, inner: Data @indirect } }
        FN makeNested() RETURNS !Data ->
            inner = Data{ Text: "hello" };
            RETURN Data.Nested{ label: "outer", inner: inner };
        END
        FN main() RETURNS Void ->
            d = makeNested();
            d2 = COPY d;
            PARTIAL MATCH TAKES d2 START
                Data.Nested AS n -> print(n.label);,
                DEFAULT -> print("wrong");
            END
        END
      CLEAR
      # d2 is consumed by MATCH TAKES (auto), but cleanup must survive for
      # the DEFAULT branch where no AS binding extracts the payload.
      d2_entry = plan["d2"]
      expect(d2_entry).not_to be_nil, "d2 must have a cleanup entry"
      expect(d2_entry[:needs_cleanup]).to eq(true), "d2 cleanup must not be eliminated"
      expect(d2_entry[:has_moved_guard]).to eq(true), "d2 needs moved guard for MATCH TAKES"
    end
  end
end

# All StaticLeakChecker checks have been migrated to MIRChecker
# (post-lowering). See spec/mir_checker_spec.rb for unit tests.
