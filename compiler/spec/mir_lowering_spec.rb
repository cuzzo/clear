require "rspec"
require "ostruct"
require "stringio"
require_relative "../ruby/mir/mir" unless defined?(MIR::StdlibDefFsCoercion)
require_relative "../ruby/ast/std_lib" unless defined?(StdLibTypeBinding)
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering::OwnershipSurfaceScan)
require_relative "../ruby/backends/mir_emitter" unless defined?(MIREmitter)
require_relative "../ruby/mir/mir_checker" unless defined?(MIRChecker::FsmStructureError)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/type" unless defined?(Type)
require_relative "../ruby/compiler/module_importer" unless defined?(ModuleImporter)
require_relative "../ruby/compiler/compiler_frontend" unless defined?(CompilerFrontend)

RSpec.describe MIRLowering do
  let(:tok) { Lexer::Token.new(:KEYWORD, "test", 1, 1) }
  let(:emitter) { MIREmitter.new }

  def lowering(**opts)
    schema_lookup = opts[:schema_lookup] || lambda do |name|
      opts.fetch(:struct_schemas, {})[name.to_sym] ||
        opts.fetch(:enum_schemas, {})[name.to_sym] ||
        opts.fetch(:union_schemas, {})[name.to_sym]
    end
    opts[:lifecycle_registry] ||= spec_lifecycle_registry(schema_lookup: schema_lookup)
    MIRLowering.new(input: MIRLoweringInput.new(**opts))
  end

  def emit(mir_node)
    return mir_node.map { |n| emit(n) }.join("\n") if mir_node.is_a?(Array)
    emitter.emit(mir_node)
  end

  def install_function_context(low, **overrides)
    defaults = {
      bindings: {},
      binding_types: {},
      collection_params: Set.new,
      protocol_map_allocators: {},
      mutable_scalar_params: Set.new,
      param_names: Set.new,
      takes_param_names: Set.new,
      heap_carry_return_vars: Set.new,
      returned_names: Set.new,
      snapshot_types: Set.new,
      fn_alloc_marked_names: {},
      lowered_alloc_names: Set.new,
      lowered_guarded_cleanup_names: Set.new,
      decl_zig_name_map: {},
      guarded_cleanup_names: {},
      fn_name_rename_map: {},
      has_rt: false,
      tail_call: false,
      zig_name: "test",
      return_payload_zig: "void",
      return_type: Type.new(:Void),
      heap_carry_return: false,
      has_catch: false,
    }
    low.send(:activate_function_context,
      MIRLoweringFunctions::FunctionLoweringContext.new(**defaults.merge(overrides)))
  end

  def make_lit(type, value, full_type: nil, storage: nil)
    node = AST::Literal.new(tok, type, value, storage)
    node.full_type = full_type || case type
                                  when :NUMBER then :Number
                                  when :INT64 then :Int64
                                  when :STRING then :String
                                  when :BOOLEAN then :Boolean
                                  when :NIL then :Nil
                                  else :Any
                                  end
    node
  end

  def make_id(name, full_type: :Int64, sync: nil)
    node = AST::Identifier.new(tok, name)
    node.full_type = full_type
    if sync
      node.symbol = SymbolEntry.new(reg: name, type: full_type, mutable: true, storage: :stack, sync: sync)
    end
    node
  end

  def capture_analysis(captures: {}, capture_symbols: {}, close_plans: {},
                       pointer_captures: Set.new, string_captures: Set.new,
                       resource_captures: Set.new, strategies: {})
    typed_captures = captures.to_h { |name, type| [name.to_s, type.is_a?(Type) ? type : Type.new(type)] }
    CapabilityHelper::CaptureAnalysis.new(
      has_local: false, has_rc: false, has_shared: false,
      has_sharded: false, has_affine_locked: false, has_outer_ref: false,
      has_non_escaping_capture: false,
      captures: typed_captures, capture_symbols: capture_symbols,
      close_plans: close_plans,
      pointer_captures: pointer_captures, string_captures: string_captures,
      resource_captures: resource_captures,
      site_moved: Set.new, site_copied: Set.new,
      strategies: strategies, move_mark_names: Set.new, alloc_mark_entries: {},
    )
  end

  def make_binop(left, op, right)
    node = AST::BinaryOp.new(tok, left, op, right)
    node.full_type = left.full_type
    node
  end

  def stamp_or_else_plan(node)
    stored = node.left.respond_to?(:error_union_type) ? T.unsafe(node.left).error_union_type : nil
    left_type = stored ? Type.new(stored) : node.left.full_type!
    operation, recovery = case node.right
                          when AST::OrElseRaise then [TenseOperationKind::OrElseRaise, TenseRecovery::Raise]
                          when AST::OrElseExit then [TenseOperationKind::OrElseExit, TenseRecovery::Exit]
                          when AST::OrElsePass then [TenseOperationKind::OrElsePass, TenseRecovery::Pass]
                          when AST::OrElseBreak then [TenseOperationKind::OrElseBreak, TenseRecovery::Break]
                          when AST::OrElsePrune then [TenseOperationKind::OrElsePrune, TenseRecovery::Prune]
                          else [TenseOperationKind::OrElseValue, TenseRecovery::Fallback]
                          end
    fallback_type = recovery == TenseRecovery::Fallback ? node.right.full_type! : Type.new(:NoReturn)
    node.tense_plan = TenseOperationPlanner.or_else(
      left_type,
      fallback_type,
      operation: operation,
      recovery: recovery,
    )
    node
  end

  def compile_first_assignment(src, target: :zig)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    result = CompilerFrontend.compile(src, importer: importer, source_dir: Dir.pwd)
    fn = result.ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" } ||
      result.ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
    assignment = fn.body.find { |s| s.is_a?(AST::Assignment) }
    low = lowering(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      lifecycle_registry: result.lifecycle_registry,
      importer: importer,
      source_dir: Dir.pwd,
      target: target
    )
    [low, assignment]
  end

  def compile_first_binding_value(src, name, target: :zig)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    result = CompilerFrontend.compile(src, importer: importer, source_dir: Dir.pwd)
    fn = result.ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" } ||
      result.ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
    binding = fn.body.find { |s| s.is_a?(AST::BindExpr) && s.name == name }
    low = lowering(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      lifecycle_registry: result.lifecycle_registry,
      importer: importer,
      source_dir: Dir.pwd,
      target: target
    )
    [low, binding.value]
  end

  def each_mir_node(root, &block)
    seen = {}
    visit = nil
    visit = lambda do |obj|
      return if obj.nil?
      case obj
      when Array
        obj.each { |v| visit.call(v) }
      when Hash
        obj.each { |k, v| visit.call(k); visit.call(v) }
      else
        return unless obj.class.name&.start_with?("MIR::")
        return if seen[obj.object_id]
        seen[obj.object_id] = true
        block.call(obj)
        obj.each_pair { |_name, value| visit.call(value) } if obj.respond_to?(:each_pair)
      end
    end
    visit.call(root)
  end

  def compile_fixture_lowering(path)
    src_path = File.expand_path(path, Dir.pwd)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    result = nil
    begin
      original_stdout = $stdout
      original_stderr = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      result = CompilerFrontend.compile(File.read(src_path), importer: importer, source_dir: File.dirname(src_path))
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
    low = lowering(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      lifecycle_registry: result.lifecycle_registry,
      moved_guard_info: result.moved_guard_info,
      importer: importer,
      source_dir: File.dirname(src_path),
      debug_mode: true
    )
    [low, result]
  end

  def lower_source_mir(src)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    result = CompilerFrontend.compile(src, importer: importer, source_dir: Dir.pwd)
    low = lowering(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      schema_lookup: ->(name) { result.annotator.lookup_type_schema(name) },
      lifecycle_registry: result.lifecycle_registry,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: importer,
      source_dir: Dir.pwd,
      debug_mode: true
    )
    low.lower_program(result.ast)
  end

  def lower_fixture_mir(path)
    low, result = compile_fixture_lowering(path)
    low.lower_program(result.ast)
  end

  def lower_fixture_program(path)
    emit(lower_fixture_mir(path))
  end

  def expect_checker_clean(mir_program, strict: true)
    errors = MIRChecker.new.check_program!(mir_program, strict: strict)
    expect(errors).to be_empty
  end

  def collect_mir_nodes(root, klass)
    seen = {}
    nodes = []
    visit = nil
    visit = lambda do |obj|
      return if obj.nil?
      if obj.is_a?(Array)
        obj.each { |v| visit.call(v) }
        return
      end
      if obj.is_a?(Hash)
        obj.each { |k, v| visit.call(k); visit.call(v) }
        return
      end
      return unless obj.class.name&.start_with?("MIR::")
      oid = obj.object_id
      return if seen[oid]
      seen[oid] = true
      nodes << obj if obj.is_a?(klass)
      obj.each_pair { |_name, value| visit.call(value) } if obj.respond_to?(:each_pair)
      obj.instance_variables.each { |ivar| visit.call(obj.instance_variable_get(ivar)) }
    end
    visit.call(root)
    nodes
  end

  describe "task profile helpers" do
    it "injects profile fields into typed task configs" do
      low = lowering
      base = low.send(:task_config_plan, nil, :large)
      profiled = low.send(:profiled_task_config_plan, base, 9, :parallel)

      expect(profiled).to be_a(MIR::TaskConfigPlan)
      expect(MIREmitter.new.send(:emit_task_config_plan, profiled))
        .to eq(".{ .stack_size = .Large, .profile_site_id = 9, .profile_dispatch = 2 }")
    end

    it "maps unknown dispatches to local and emits profile comments" do
      low = lowering

      expect(low.send(:profile_dispatch_id, :unexpected)).to eq(1)
      expect(low.send(:bg_profile_site_comment, 5, 12, 3, :unexpected, :stack))
        .to eq("// CLEAR_PROFILE_TASK_SITE id=5 kind=BG line=12 column=3 dispatch=unexpected form=stack")
    end

    it "routes parallel fiber spawn through spawnBest" do
      low = lowering

      task_config = MIR::TaskConfigPlan.new(stack_variant: "Standard")
      spawn = low.send(:fiber_spawn_call_plan, "__rt", "__Worker", "__worker", task_config, :parallel)
      out = MIREmitter.new.send(:emit_fiber_spawn_call, spawn)

      expect(out).to include("CheatHeader.spawnBest")
      expect(out).to include("&__Worker.run")
      expect(out).to include("__worker")
    end

    it "builds typed BG lowering, scheduler, and FSM transform plans" do
      low = lowering
      id = MIRLoweringGeneratedId.new(kind: MIRLoweringCounterKind::BackgroundBlock, value: 12)
      node = AST::BgBlock.new(tok, [], nil, nil, true, nil, true, nil)
      node.full_type = :"~Void"

      names = low.send(:bg_lowering_names, id)
      types = low.send(:bg_type_plan, node)
      capture = low.send(:bg_capture_materialization, names, nil, {}, {}, Set.new)
      scheduler = low.send(:bg_scheduler_plan, node, names, "rt")
      body = MIRLoweringConcurrency::BgBodyMaterialization.new(run_body: [])
      ctx = MIRLoweringConcurrency::BgFsmTransformContext.new(
        node: node,
        names: names,
        types: types,
        capture: capture,
        body: body,
        scheduler: scheduler,
        captured: {},
        capture_close_plans: {},
        pointer_captures: Set.new,
        rt_name: "rt",
      )

      expect(names.ctx_type).to eq("__BgCtx12")
      expect(types.promise_zig).to include("Promise")
      expect(capture.capture_inits.map(&:name)).to include(:inner, :alloc)
      expect(MIREmitter.new.send(:emit_struct_init_fields, capture.capture_inits))
        .to include(".inner = __bg12_promise.inner")
      expect(scheduler.dispatch).to eq(true)
      expect(MIREmitter.new.emit(T.must(scheduler.arena_init))).to eq("__rt_bg12.arena_mode = true;")
      expect(MIREmitter.new.emit(low.send(:bg_alloc_expr, node, "rt"))).to eq("rt.getSched().allocator")
      expect(ctx.to_transform_hash.fetch(:ctx_type)).to eq("__BgCtx12")
      expect(ctx.to_transform_hash.fetch(:parallel)).to eq(false)
    end

    it "renders stackful BG resource capture cleanup with explicit runtime placeholder" do
      low = lowering
      names = MIRLoweringConcurrency::BgLoweringNames.new(
        id: 2,
        ctx_type: "__BgCtx2",
        alloc_var: "__alloc_2",
        promise_var: "__promise_2",
        ctx_var: "__ctx_2_ptr",
        blk_label: "__bg2",
        bg_rt: "__rt_bg2",
      )

      capture = low.send(
        :bg_capture_materialization,
        names,
        nil,
        { "map" => Type.new(:StringMap) },
        { "map" => Schemas::ResourceClosePlan.method("deinit", runtime_heap_alloc_args: 2) },
        Set.new,
      )

      expect(MIREmitter.new.send(:emit_capture_cleanup_actions, capture.capture_frees))
        .to include("defer __ctx_2.map.deinit(rt.heapAlloc(), rt.heapAlloc());")
    end

    it "strips leading try when assigning a BG value result" do
      fake = Object.new
      fake.extend(MIRLoweringConcurrency)
      expr = make_lit(:INT64, 1)
      step = MIRLoweringConcurrency::BgBodyStep.new(expr: expr, binding: nil)
      lowered = MIR::Call.new("compute", [], true)

      fake.define_singleton_method(:escaping_value_alloc) { |_inner| :heap }
      fake.define_singleton_method(:with_decl_alloc) { |_alloc, &blk| blk.call }
      fake.define_singleton_method(:lower) { |_node| lowered }
      fake.define_singleton_method(:place_value_for_destination) { |mir, _node, _alloc, _type| mir }
      fake.define_singleton_method(:mir_allocates?) { |_mir| false }
      fake.define_singleton_method(:async_payload_storage_value) { |mir, _shape| mir }
      fake.define_singleton_method(:flush_pending) { [] }
      fake.define_singleton_method(:ownership_marks_for_transferred_temp) { |_mir, target_alloc:| [] }

      body = []
      id = MIRLoweringGeneratedId.new(kind: MIRLoweringCounterKind::BackgroundBlock, value: 7)
      fake.send(:lower_bg_value_result, step, body, id, Type.new(:Int64))
      expect(body).to include(an_instance_of(MIR::Set))
      expect(body.last.value).to eq(lowered)
    end
  end

  describe "small MIR text-shape helpers" do
    it "classifies synthetic pipeline bindings without regex parsing" do
      low = lowering

      expect(low.send(:synthetic_pipeline_binding_name?, "$a")).to be true
      expect(low.send(:synthetic_pipeline_binding_name?, "$")).to be false
      expect(low.send(:synthetic_pipeline_binding_name?, "$A")).to be false
    end

    it "normalizes union match fallback variants without regex parsing" do
      fake = Object.new
      fake.extend(MIRLoweringControlFlow)
      fake.define_singleton_method(:lower) { |value| value }
      arm = AST::MatchCase.new(kind: :eq, value: AST::Identifier.new(tok, "fallback"), body: [], extra_values: [])

      expect(fake.send(:union_match_case_variants, arm)).to eq(["fallback"])
    end

    it "builds pointer return payloads without regex parsing" do
      fake = Object.new
      fake.extend(MIRLoweringControlFlow)
      fake.define_singleton_method(:current_function_return_payload_zig) { "*Payload" }
      fake.define_singleton_method(:return_value_already_payload_pointer?) { |_value| false }
      fake.define_singleton_method(:mir_ident_names) { |_value| [] }
      fake.define_singleton_method(:with_ownership_consumption) { |value, *_args, **_kwargs| value }
      node = AST::ReturnNode.new(tok, make_lit(:INT64, 1))

      result = fake.send(:return_payload_pointer_value, node, MIR::Ident.new("value"))
      expect(result).to be_a(MIR::HeapCreate)
      expect(result.zig_type).to eq("Payload")
    end

    it "heap-boxes indirect fallible return payloads at the return site" do
      program = lower_fixture_program("transpile-tests/06_heap_return.clear")

      expect(program).to include("fn makeUser(rt: *Runtime) !*User")
      expect(program).to include("try rt.heapAlloc().create(User)")
      expect(program).not_to include("__p.* = @as(*User")
      expect(program).not_to include("return u;")
    end
  end

  # =========================================================================
  # Old MIR translation
  # =========================================================================

  describe "old MIR node translation" do
    it "translates MIR::Drop to MIR::Cleanup" do
      type = Type.new(:"Int64[]")
      entry = CleanupEntry.build(:uniform, zig_type: "ArrayList(i64)", alloc: :frame, has_moved_guard: false)
      entry.set_lifecycle_plan!(Semantic::LifecyclePlanner.plan(type, ->(_name) { nil }))
      drop = MIR::Drop.new(tok, "items")
      drop.cleanup_entry = entry

      l = lowering
      result = l.lower(drop)
      expect(result).to be_a(MIR::Cleanup)
      expect(result.name).to eq("items")
      expect(result.cleanup_entry).to eq(entry)
    end

    it "translates MIR::SuppressCleanup to explicit transfer and move marks when a cleanup guard is visible" do
      suppress = MIR::SuppressCleanup.new(tok, "buf")
      l = lowering
      l.function_state.guarded_cleanup_names = { "buf" => true }
      result = l.lower(suppress)
      expect(result).to contain_exactly(
        an_instance_of(MIR::TransferMark),
        an_instance_of(MIR::MoveMark)
      )
      expect(result.map(&:name)).to eq(["buf", "buf"])
      expect(emit(result)).to eq("\nbuf_moved = true;")
    end

    it "passes MIR::AllocMark through as the allocation marker" do
      alloc = MIR::AllocMark.new("x", :heap, Type.new(:String))
      result = lowering.lower(alloc)
      expect(result).to be_a(MIR::AllocMark)
      expect(result.name).to eq("x")
      expect(result.alloc).to eq(:heap)
      expect(result.type_info.resolved).to eq(:String)
      expect(emit(result)).to be_nil
    end

    it "translates MIR::Return to MIR::ReturnMark" do
      ret = MIR::Return.new(tok, ["x", "y"])
      result = lowering.lower(ret)
      expect(result).to be_a(MIR::ReturnMark)
      expect(result.escaped_vars).to eq(["x", "y"])
      expect(emit(result)).to be_nil
    end

    it "translates MIR::ReassignCleanup to MIR::ReassignMark" do
      rc = MIR::ReassignCleanup.new(tok, "buf", :heap)
      result = lowering.lower(rc)
      expect(result).to be_a(MIR::ReassignMark)
      expect(result.name).to eq("buf")
    end

  end

  describe "#emit_builtin" do
    it "passes a bare type name through to dupeUnionValue unchanged" do
      mir = lowering.send(
        :emit_builtin,
        :dupeUnionValue,
        [MIR::Ident.new("Value"), MIR::Ident.new("val"), MIR::AllocatorRef.new(:heap)]
      )
      zig = emit(mir)
      expect(zig).to eq("try CheatLib.dupeUnionValue(Value, val, rt.heapAlloc())")
    end
  end

  # =========================================================================
  # Literals
  # =========================================================================

  describe "literals" do
    it "lowers string literal" do
      node = make_lit(:STRING, "hello")
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Lit)
      expect(emit(result)).to eq('"hello"')
    end

    it "escapes string literal special chars" do
      node = make_lit(:STRING, "line\nnext")
      result = lowering.lower(node)
      expect(emit(result)).to eq('"line\\nnext"')
    end

    it "escapes backslash in string literal to two backslashes" do
      node = make_lit(:STRING, "\\")
      result = lowering.lower(node)
      expect(emit(result)).to eq('"\\\\"')
    end

    it "gsub block form: backslash in string not mangled by eql builtin substitution" do
      # Ruby gsub(pattern, string) mangles \\ to \ in the replacement.
      # Using gsub(pattern) { string } avoids this. Regression test.
      # When a string literal containing a backslash is used as an arg to a builtin
      # (like CheatLib.eql), the Zig output must contain "\\\\" (escaped backslash),
      # not "\\"" (escaped double-quote, which is a Zig syntax error).
      backslash_node = make_lit(:STRING, "\\")
      backslash_node.full_type = :String

      id_s = AST::Identifier.new(tok, "s")
      id_s.full_type = :String
      id_i = AST::Identifier.new(tok, "i")
      id_i.full_type = :Int64

      # charAt(s, i) == "\\"
      charat = AST::FuncCall.new(tok, "charAt", [id_s, id_i])
      charat.full_type = :String
      charat.matched_stdlib_def = IntrinsicRegistry.lookup(STD_LIB, "charAt").first
      charat.zig_pattern = charat.matched_stdlib_def.emit.zig
      eq_node = AST::BinaryOp.new(tok, charat, :EQ, backslash_node)
      eq_node.full_type = :Boolean
      eq_node.left.full_type = :String

      l = lowering
      result = l.lower(eq_node)
      zig = emit(result)
      expect(zig).to include('"\\\\"')
      expect(zig).not_to include('"\\"")')
    end

    it "lowers macro print arguments as a structural tuple literal" do
      l = lowering
      left = make_lit(:INT64, 1, full_type: :Int64)
      right = make_lit(:BOOLEAN, true, full_type: :Bool)
      call = AST::FuncCall.new(tok, "print", [left, right])

      result = l.send(:lower_macro_print, call)

      expect(result).to be_a(MIR::Call)
      expect(result.callee).to eq("std.debug.print")
      expect(result.args.last).to be_a(MIR::TupleLiteral)
      expect(emit(result)).to eq('std.debug.print("{d} {}\\n", .{1, true})')
    end

    it "lowers integer literal" do
      node = make_lit(:NUMBER, 42, full_type: :Int64)
      node.coerced_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Lit)
      expect(emit(result)).to eq("42")
    end

    it "lowers float literal" do
      node = make_lit(:NUMBER, 3.14)
      result = lowering.lower(node)
      expect(emit(result)).to eq("3.14")
    end

    it "lowers float literal with integer value" do
      node = make_lit(:NUMBER, 5.0)
      result = lowering.lower(node)
      expect(emit(result)).to eq("5.0")
    end

    it "lowers boolean literal" do
      node = make_lit(:BOOLEAN, true)
      result = lowering.lower(node)
      expect(emit(result)).to eq("true")
    end

    it "lowers nil literal" do
      node = make_lit(:NIL, nil)
      result = lowering.lower(node)
      expect(emit(result)).to eq("null")
    end

    it "lowers i8 literal with cast" do
      node = make_lit(:INT8, 7)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Cast)
      expect(emit(result)).to eq("@as(i8, 7)")
    end

    it "lowers i32 literal with cast" do
      node = make_lit(:INT32, 100)
      result = lowering.lower(node)
      expect(emit(result)).to eq("@as(i32, 100)")
    end

    it "lowers u64 literal with cast" do
      node = make_lit(:UINT64, 999)
      result = lowering.lower(node)
      expect(emit(result)).to eq("@as(u64, 999)")
    end

    it "lowers f32 literal with cast" do
      node = make_lit(:FLOAT32, 2.5)
      result = lowering.lower(node)
      expect(emit(result)).to eq("@as(f32, 2.5)")
    end

    it "lowers INT64 literal" do
      node = make_lit(:INT64, 100)
      result = lowering.lower(node)
      expect(emit(result)).to eq("100")
    end
  end

  # =========================================================================
  # Identifiers
  # =========================================================================

  describe "identifiers" do
    it "lowers simple identifier" do
      node = make_id("count")
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Ident)
      expect(emit(result)).to eq("count")
    end

    it "lowers identifier with bang suffix" do
      node = make_id("push")
      result = lowering.lower(node)
      expect(emit(result)).to eq("push")
    end

    it "lowers identifier with question mark" do
      node = make_id("empty?")
      result = lowering.lower(node)
      expect(emit(result)).to eq("empty")
    end

    it "renames main to clearMain" do
      node = make_id("main")
      result = lowering.lower(node)
      expect(emit(result)).to eq("clearMain")
    end
  end

  # =========================================================================
  # Unary operations
  # =========================================================================

  describe "unary operations" do
    it "lowers NOT" do
      inner = make_lit(:BOOLEAN, true)
      node = AST::UnaryOp.new(tok, :NOT, inner)
      node.full_type = :Boolean
      result = lowering.lower(node)
      expect(result).to be_a(MIR::UnaryOp)
      expect(emit(result)).to eq("!true")
    end

    it "lowers negation" do
      inner = make_lit(:NUMBER, 5.0)
      node = AST::UnaryOp.new(tok, :SUB, inner)
      node.full_type = :Number
      result = lowering.lower(node)
      expect(emit(result)).to eq("-5.0")
    end

    it "rejects tense operations whose annotation plan is missing or inconsistent" do
      fallible = make_id("fallible", full_type: :"!Int64")
      missing_try = AST::UnaryOp.new(tok, :TRY, fallible)
      missing_try.full_type = :Int64
      expect { lowering.lower(missing_try) }.to raise_error(RuntimeError, /TRY lowering requires/)

      invalid_try = AST::UnaryOp.new(tok, :TRY, fallible)
      invalid_try.full_type = :Int64
      invalid_try.tense_plan = TenseOperationPlan.new(
        operation: TenseOperationKind::Try,
        input_type: Type.new(:"!Int64"),
        result_type: Type.new(:Int64),
        backend_form: TenseBackendForm::DirectMap,
      )
      expect { lowering.lower(invalid_try) }.to raise_error(RuntimeError, /unsupported tense backend/)

      optional = make_id("optional", full_type: :"?Int64")
      missing_exists = AST::UnaryOp.new(tok, :EXISTS, optional)
      missing_exists.full_type = :Bool
      expect { lowering.lower(missing_exists) }.to raise_error(RuntimeError, /exists lowering requires/)
    end
  end

  # =========================================================================
  # Binary operations
  # =========================================================================

  describe "binary operations" do
    it "lowers simple addition (float)" do
      left = make_lit(:NUMBER, 1.5)
      right = make_lit(:NUMBER, 2.5)
      node = make_binop(left, :ADD, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::BinOp)
      expect(emit(result)).to eq("(1.5 + 2.5)")
    end

    it "lowers integer addition with checked math" do
      left = make_id("a", full_type: :Int64)
      right = make_id("b", full_type: :Int64)
      node = make_binop(left, :ADD, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RegistryCall)
      expect(result.stdlib_def.emit.borrows).to eq(:all)
      expect(emit(result)).to eq("CheatLib.intAdd(a, b)")
    end

    it "lowers comparison" do
      left = make_id("x")
      right = make_lit(:NUMBER, 10.0)
      node = make_binop(left, :GT, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::BinOp)
      expect(emit(result)).to eq("(x > 10.0)")
    end

    it "lowers bitwise operators directly and casts runtime shift counts" do
      left = make_id("bits", full_type: :Int64)
      right = make_id("amount", full_type: :Int64)

      expect(emit(lowering.lower(make_binop(left, :BIT_AND, right)))).to eq("(bits & amount)")
      expect(emit(lowering.lower(make_binop(left, :BIT_OR, right)))).to eq("(bits | amount)")
      expect(emit(lowering.lower(make_binop(left, :XOR, right)))).to eq("(bits ^ amount)")
      expect(emit(lowering.lower(make_binop(left, :SHL, right)))).to eq("(bits << @intCast(amount))")
      expect(emit(lowering.lower(make_binop(left, :SHR, right)))).to eq("(bits >> @intCast(amount))")
    end

    it "lowers left-optional equality to a nil-safe payload comparison" do
      left = make_id("maybe", full_type: :"?Int64")
      right = make_lit(:INT64, 1, full_type: :Int64)
      node = make_binop(left, :EQ, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::IfOptional)
      expect(emit(result)).to eq("(if (maybe) |__opt_cmp_1| (__opt_cmp_1 == 1) else false)")
    end

    it "lowers right-optional inequality with a true nil fallback" do
      left = make_lit(:INT64, 1, full_type: :Int64)
      right = make_id("maybe", full_type: :"?Int64")
      node = make_binop(left, :NEQ, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::IfOptional)
      expect(emit(result)).to eq("(if (maybe) |__opt_cmp_1| (1 != __opt_cmp_1) else true)")
    end

    it "lowers optional string equality through the string comparison helper" do
      left = make_id("maybe_name", full_type: :"?String")
      right = make_lit(:STRING, "alice", full_type: :String)
      node = make_binop(left, :EQ, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::IfOptional)
      expect(emit(result)).to include("CheatLib.eql(__opt_cmp_1,")
      expect(emit(result)).to end_with(" else false)")
    end

    it "lowers string equality" do
      left = make_id("name", full_type: :String)
      right = make_lit(:STRING, "alice")
      node = make_binop(left, :EQ, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RegistryCall)
      expect(result.stdlib_def.emit.borrows).to eq(:all)
      expect(emit(result)).to include("CheatLib.eql(name,")
    end

    it "lowers string inequality" do
      left = make_id("a", full_type: :String)
      right = make_id("b", full_type: :String)
      node = make_binop(left, :NEQ, right)
      result = lowering.lower(node)
      expect(emit(result)).to include("!CheatLib.eql(a, b)")
    end

    it "lowers wrapping add" do
      left = make_id("a")
      right = make_id("b")
      node = make_binop(left, :WRAP_ADD, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RegistryCall)
      expect(result.stdlib_def.emit.borrows).to eq(:all)
      expect(emit(result)).to eq("CheatLib.wrapAdd(a, b)")
    end

    it "lowers checked mul" do
      left = make_id("a")
      right = make_id("b")
      node = make_binop(left, :CHECK_MUL, right)
      result = lowering.lower(node)
      expect(emit(result)).to eq("CheatLib.checkMul(a, b)")
    end

    it "lowers integer division to @divTrunc" do
      left = make_id("a", full_type: :Int64)
      right = make_id("b", full_type: :Int64)
      node = make_binop(left, :DIV, right)
      result = lowering.lower(node)
      # Routed through the builtin registry (:intDiv) so the :bc target can
      # dispatch to DIV_I64. Zig emission still renders @divTrunc(a, b).
      expect(emit(result)).to include("@divTrunc(a, b)")
    end

    it "lowers signed modulo to @mod" do
      left = make_id("a", full_type: :Int64)
      right = make_id("b", full_type: :Int64)
      node = make_binop(left, :MOD, right)
      result = lowering.lower(node)
      expect(emit(result)).to include("@mod(a, b)")
    end

    it "lowers boolean AND" do
      left = make_lit(:BOOLEAN, true)
      right = make_lit(:BOOLEAN, false)
      node = make_binop(left, :AND, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::BinOp)
      expect(emit(result)).to eq("(true and false)")
    end

    it "keeps boolean RHS pending MIR inside the short-circuit boundary" do
      low = lowering
      left = make_lit(:BOOLEAN, false, full_type: :Boolean)
      right = make_id("rhs", full_type: :Boolean)
      node = make_binop(left, :AND, right)
      original_lower = low.method(:lower)

      low.define_singleton_method(:lower) do |child|
        if child.equal?(right)
          pending = function_state.pending_stmts
          pending << MIR::AllocMark.new("__rhs_tmp", :heap, Type.new(:String))
          pending << MIR::Let.new("__rhs_tmp", MIR::DupeSlice.new(MIR::Lit.new("\"rhs\""), :heap), false, nil, nil)
          MIR::Lit.new("true")
        else
          original_lower.call(child)
        end
      end

      result = low.lower(node)
      expect(result).to be_a(MIR::BinOp)
      expect(result.right).to be_a(MIR::BlockExpr)
      expect(low.flush_pending).to be_empty

      zig = emit(result)
      expect(zig).to include("false and __lazy_")
      expect(zig).to include("break :__lazy_")
    end
  end

  describe "assignment allocator provenance" do
    it "retains a map field's CLEAR value type when replacing it with an empty literal" do
      mir = lower_source_mir(<<~CLEAR)
        UNION Value { Nil, Count: Int64 }
        STRUCT Slot { entries: {String}Value }

        FN main() RETURNS Void ->
          MUTABLE slot = Slot{ entries: {} };
          slot.entries = {};
          RETURN;
        END
      CLEAR

      expect_checker_clean(mir)
      zig = emit(mir)
      expect(zig).to include("CheatLib.StringMap(Value)")
      expect(zig).not_to include("CheatLib.StringMap(f64)")
    end

    it "retains cleanup for an outer rodata String first owned in an IF branch" do
      mir = lower_source_mir(<<~CLEAR)
        FN make() RETURNS String ->
          RETURN "owned" $+ " value";
        END

        FN main() RETURNS Void ->
          MUTABLE output = "";
          IF TRUE THEN
            output = make();
          ELSE
            output = "fallback";
          END
          ASSERT output.length() > 0, "branch result";
          RETURN;
        END
      CLEAR

      expect_checker_clean(mir)
    end

    it "does not reuse a cleanup entry for a same-name primitive sibling binding" do
      mir = lower_source_mir(<<~CLEAR)
        FN choose(flag: Bool) RETURNS Int64 ->
          IF flag THEN
            value = COPY "owned";
            ASSERT value == "owned", "String branch";
          ELSE
            MUTABLE value: Int64 = 1;
            value = 2;
            RETURN value;
          END
          RETURN 0;
        END

        FN main() RETURNS Void ->
          ASSERT choose(FALSE) == 2, "primitive shadow remains a value binding";
          RETURN;
        END
      CLEAR

      errors = MIRChecker.new.check_program!(mir)
      expect(errors).to be_empty

      primitive_allocs = collect_mir_nodes(mir, MIR::AllocMark).select do |node|
        node.name.to_s.start_with?("value_L") && node.type_info&.primitive?
      end
      expect(primitive_allocs).to be_empty
    end

    it "uses declaration identity for same-name branch reassignment cleanup allocators" do
      mir = lower_source_mir(<<~CLEAR)
        FN make() RETURNS String ->
          RETURN "b" $+ "c";
        END

        FN main() RETURNS Void ->
          IF TRUE THEN
            MUTABLE s = "a";
            s = s $+ "x";
          ELSE
            MUTABLE s = make();
            s = s $+ "y";
          END
          RETURN;
        END
      CLEAR

      errors = MIRChecker.new.check_program!(mir)
      expect(errors).to be_empty

      zig = emit(mir)
      expect(zig).to match(/var s: \[\]const u8 = .*rt\.frameAlloc\(\)/)
      expect(zig).to include("CheatLib.cleanup(@TypeOf(s), rt.frameAlloc(), &s)")
      expect(zig).not_to include("CheatLib.cleanup(@TypeOf(s), rt.heapAlloc(), &s)")

      expect(zig).to match(/var s_L\d+: \[\]const u8 = try make\(rt\)/)
      expect(zig).to match(/CheatLib\.cleanup\(@TypeOf\(s_L\d+\), rt\.heapAlloc\(\), &s_L\d+\)/)
    end
  end

  # =========================================================================
  # Field and index access
  # =========================================================================

  describe "field and index access" do
    it "lowers field access" do
      target = make_id("user", full_type: :User)
      node = AST::GetField.new(tok, target, "name")
      node.full_type = :String
      result = lowering.lower(node)
      expect(result).to be_a(MIR::FieldGet)
      expect(emit(result)).to eq("user.name")
    end

    it "falls back to getAt for local dynamic-array index access" do
      target = make_id("items", full_type: :"Int64[]")
      index = make_lit(:NUMBER, 0, full_type: :Int64)
      index.coerced_type = :Int64
      node = AST::GetIndex.new(tok, target, index)
      node.full_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RegistryCall)
      expect(emit(result)).to eq("CheatLib.getAt(items, 0)")
    end

    it "lowers parameter slice index access directly" do
      target = make_id("items", full_type: :"Int64[]")
      index = make_lit(:NUMBER, 0, full_type: :Int64)
      index.coerced_type = :Int64
      node = AST::GetIndex.new(tok, target, index)
      node.full_type = :Int64
      l = lowering
      install_function_context(l, param_names: Set["items"])
      result = l.lower(node)
      expect(result).to be_a(MIR::IndexGet)
      expect(emit(result)).to eq("items[@as(usize, @intCast(0))]")
    end

    it "lowers string length to direct len" do
      target = make_id("items", full_type: :String)
      node = AST::MethodCall.new(tok, target, "length", [])
      node.full_type = :Int64
      node.zig_pattern = "CheatLib.len({0})"
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Cast)
      expect(emit(result)).to eq("@as(i64, @intCast(items.len))")
    end

    it "falls back to CheatLib.len for local dynamic-array length" do
      target = make_id("items", full_type: :"Int64[]")
      node = AST::MethodCall.new(tok, target, "length", [])
      node.full_type = :Int64
      node.zig_pattern = "CheatLib.len({0})"
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RegistryCall)
      expect(emit(result)).to eq("CheatLib.len(items)")
    end

    it "lowers parameter array length via the polymorphic CheatLib.len helper" do
      # Defers to runtime polymorphism: CheatLib.len uses comptime @hasField
      # to dispatch ArrayList (.items.len) vs slice (.len). The lowering does
      # NOT re-derive container shape from "is_param" anymore.
      target = make_id("items", full_type: :"Int64[]")
      node = AST::MethodCall.new(tok, target, "length", [])
      node.full_type = :Int64
      node.zig_pattern = "CheatLib.len({0})"
      l = lowering
      install_function_context(l, param_names: Set["items"])
      result = l.lower(node)
      expect(emit(result)).to eq("CheatLib.len(items)")
    end
  end

  # =========================================================================
  # Type definitions
  # =========================================================================

  describe "type definitions" do
    it "lowers enum definition" do
      node = AST::EnumDef.new(tok, "Direction", [:North, :South, :East, :West], nil)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::EnumDef)
      expect(emit(result)).to eq("const Direction = enum { North, South, East, West };")
    end

    it "lowers simple struct definition" do
      fields = { name: AST::StructField.new(type: :String), age: AST::StructField.new(type: :Int64) }
      node = AST::StructDef.new(tok, "User", fields, nil, nil)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::StructDef)
      zig = emit(result)
      expect(zig).to include("const User = struct {")
      expect(zig).to include("name: []const u8")
      expect(zig).to include("age: i64")
    end

    it "lowers generic struct to FnDef returning anonymous StructDef" do
      fields = { value: AST::StructField.new(type: :T) }
      node = AST::StructDef.new(tok, "Box", fields, nil, ["T"])
      result = lowering.lower(node)
      expect(result).to be_a(MIR::FnDef)
      expect(result.comptime_params).to eq(["comptime T: type"])
      expect(result.ret_type).to eq("type")
      zig = emit(result)
      expect(zig).to include("fn Box(comptime T: type)")
      expect(zig).to include("return struct {")
    end

    it "lowers union definition with unit and payload variants" do
      variants = { Ok: :Int64, Err: :String, Empty: nil }
      node = AST::UnionDef.new(tok, "Result", variants, nil)
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("union(enum)")
      expect(zig).to include("Ok: i64")
      expect(zig).to include("Err: []const u8")
      expect(zig).to include("Empty: void")
    end

    it "selects only public or same-directory package-visible imported type items once" do
      pub_struct = AST::StructDef.new(tok, "PubThing", {}, :pub, nil)
      pkg_enum = AST::EnumDef.new(tok, "PkgThing", [:A], nil)
      private_struct = AST::StructDef.new(tok, "PrivateThing", {}, :private, nil)
      inline_union = AST::UnionDef.new(tok, "Value", { Pair: Schemas::InlineStructVariant.new(fields: {}) }, :pub)
      ast = AST::Program.new(tok, [pub_struct, pkg_enum, private_struct, inline_union])
      type_items = [
        MIR::StructDef.new("PubThing", [], nil, :pub),
        MIR::EnumDef.new("PkgThing", ["A"], nil),
        MIR::StructDef.new("PrivateThing", [], nil, :private),
        MIR::UnionTypeDef.new("Value", [{ name: "Pair", zig_type: "Value_Pair" }], :pub),
        MIR::StructDef.new("Value_Pair", [], nil, :private),
      ]
      mod = ModuleImporter::CompiledModule.new(ast, nil, nil, Dir.pwd, {}, {}, {}, nil, nil, type_items)
      low = lowering

      same_dir_names = low.send(:visible_type_items, mod, same_dir: true).map(&:name)
      second_pass = low.send(:visible_type_items, mod, same_dir: true)
      other_dir_names = lowering.send(:visible_type_items, mod, same_dir: false).map(&:name)

      expect(same_dir_names).to include("PubThing", "PkgThing", "Value", "Value_Pair")
      expect(same_dir_names).not_to include("PrivateThing")
      expect(second_pass).to eq([])
      expect(other_dir_names).to include("PubThing", "Value", "Value_Pair")
      expect(other_dir_names).not_to include("PkgThing")
    end
  end

  # =========================================================================
  # Declarations
  # =========================================================================

  describe "declarations" do
    it "lowers immutable var decl" do
      value = make_lit(:NUMBER, 42, full_type: :Int64)
      value.coerced_type = :Int64
      node = AST::VarDecl.new(tok, "x", nil, value, false)
      node.full_type = :Int64
      node.var_used = true
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Let)
      expect(result.mutable).to eq(false)
      zig = emit(result)
      expect(zig).to include("const x")
      expect(zig).to include("42")
    end

    it "lowers mutable var decl" do
      value = make_lit(:NUMBER, 0, full_type: :Int64)
      value.coerced_type = :Int64
      node = AST::VarDecl.new(tok, "count", nil, value, true)
      node.full_type = :Int64
      node.var_used = true
      node.var_mutated = true
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Let)
      expect(result.mutable).to eq(true)
      zig = emit(result)
      expect(zig).to start_with("var count")
    end

    it "lowers unused const with suppression" do
      value = make_lit(:NUMBER, 1.0)
      node = AST::VarDecl.new(tok, "unused", nil, value, false)
      node.full_type = :Number
      node.var_used = false
      low = lowering
      install_function_context(low)
      result = low.lower(node)
      expect(result.suppression).to eq("_ = unused;")
    end

    it "delegates set declarations with SMOOTH values to expression lowering" do
      delegate = Class.new do
        include MIRLoweringVariables

        attr_reader :lowered_node

        def lower(node)
          @lowered_node = node
          MIR::Ident.new("lowered_smooth")
        end
      end.new
      source = make_id("items", full_type: :"Int64[]")
      stage = AST::DistinctOp.new(tok, make_id("_"))
      smooth = AST::BinaryOp.new(tok, source, :SMOOTH, stage)
      smooth.full_type = Type.new(:"Int64[]", collection: :set)
      node = AST::VarDecl.new(tok, "unique", nil, smooth, false)
      node.full_type = Type.new(:"Int64[]", collection: :set)

      result = delegate.send(:lower_var_decl_init, node, node.full_type, "Set_i64", false, :frame)

      expect(result.name).to eq("lowered_smooth")
      expect(delegate.lowered_node).to equal(smooth)
    end

    it "lowers BindExpr in decl mode" do
      value = make_lit(:STRING, "hello")
      node = AST::BindExpr.new(tok, "greeting", nil, value)
      node.full_type = :String
      node.var_used = true
      node.instance_variable_set(:@mode, :decl)
      def node.mode; @mode; end
      result = lowering.lower(node)
      let = result.is_a?(Array) ? result.find { |item| item.is_a?(MIR::Let) } : result
      expect(let).to be_a(MIR::Let)
      expect(let.name).to eq("greeting")
    end

    it "lowers BindExpr in assign mode" do
      value = make_lit(:NUMBER, 5.0)
      node = AST::BindExpr.new(tok, "x", nil, value)
      node.full_type = :Number
      node.instance_variable_set(:@mode, :assign)
      def node.mode; @mode; end
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Set)
      expect(emit(result)).to eq("x = 5.0;")
    end

    it "lowers BindExpr assign with reassign cleanup" do
      value = make_lit(:STRING, "new")
      node = AST::BindExpr.new(tok, "buf", nil, value)
      node.full_type = :String
      node.instance_variable_set(:@mode, :assign)
      def node.mode; @mode; end
      lifecycle = Semantic::LifecyclePlanner.plan(Type.new(:String), ->(_name) { nil })
      node.instance_variable_set(
        :@reassign_cleanup,
        MIR::ReassignPlan.new(zig_type: "[]const u8", alloc: :heap, lifecycle_plan: lifecycle),
      )
      def node.reassign_cleanup; @reassign_cleanup; end
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ReassignWithCleanup)
      zig = emit(result)
      expect(zig).to include("CheatLib.cleanup")
      expect(zig).to include("buf = __new_buf")
    end

    it "lowers Assignment" do
      target = make_id("x")
      value = make_lit(:NUMBER, 10.0)
      node = AST::Assignment.new(tok, "x", value)
      node.full_type = :Number
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Set)
      expect(emit(result)).to eq("x = 10.0;")
    end
  end

  describe "indexed assignment lowering" do
    it "lowers typed synthetic index targets as direct Set(IndexGet)" do
      target = AST::Identifier.new(tok, "soa_items")
      target.full_type = Type.new(:"Int64[4]")
      index = make_lit(:NUMBER, 2, full_type: :Int64)
      index.coerced_type = :Int64
      value = make_lit(:NUMBER, 9, full_type: :Int64)
      value.coerced_type = :Int64
      get_index = AST::GetIndex.new(tok, target, index)
      node = AST::Assignment.new(tok, get_index, value)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::Set)
      expect(result.target).to be_a(MIR::IndexGet)
      expect(emit(result)).to eq("soa_items[@as(usize, @intCast(2))] = 9;")
    end

    it "uses structural IndexGet assignment for the bytecode backend" do
      low, assignment = compile_first_assignment(<<~CLEAR, target: :bc)
        FN main() RETURNS Void ->
          MUTABLE m: {String}Int64 = {};
          m["a"] = 1_i64;
          RETURN;
        END
      CLEAR

      result = low.lower(assignment)

      expect(result).to be_a(MIR::Set)
      expect(result.target).to be_a(MIR::IndexGet)
      expect(emit(result)).to eq('m["a"] = 1;')
    end

    it "lowers raw fixed-size array writes to native indexed Set with usize cast" do
      low, assignment = compile_first_assignment(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE xs: [4]Int64 = [0_i64, 0_i64, 0_i64, 0_i64];
          xs[1_i64] = 7_i64;
          RETURN;
        END
      CLEAR

      result = low.lower(assignment)

      expect(result).to be_a(MIR::Set)
      expect(result.target).to be_a(MIR::IndexGet)
      expect(result.target.index).to be_a(MIR::Cast)
      expect(emit(result)).to eq("xs[@as(usize, @intCast(1))] = 7;")
    end

    it "lowers string HashMap writes to structured ShardedMapPut" do
      low, assignment = compile_first_assignment(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE m: {String}Int64 = {};
          m["a"] = 1_i64;
          RETURN;
        END
      CLEAR

      result = low.lower(assignment)

      expect(result).to be_a(MIR::ShardedMapPut)
      expect(result.map_kind).to eq(:string_map)
      expect(result.key_type).to be_nil
      expect(result.value_type).to be_nil
      expect(result.template_kind).to eq(IntrinsicTemplateKind::Zig)
      expect(result.target_var).to eq("m")
      expect(result.has_alloc_metadata?).to eq(true)
      expect(result.mutating_receiver_allocator_op?).to eq(true)
      expect(MIR::OwnershipEffect.of(result)).to eq(MIR::OwnershipEffect.none)
    end

    it "carries numeric HashMap key/value Zig types into ShardedMapPut" do
      low, assignment = compile_first_assignment(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE m: {Int64}Float64 = {};
          m[3_i64] = 4.5;
          RETURN;
        END
      CLEAR

      result = low.lower(assignment)

      expect(result).to be_a(MIR::ShardedMapPut)
      expect(result.map_kind).to eq(:numeric_map)
      expect(result.key_type).to eq(Type.new(:Int64))
      expect(result.value_type).to eq(Type.new(:Float64))
    end

    it "uses shard-direct placeholders when lowering inside a shard context" do
      low, assignment = compile_first_assignment(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE m: {String}Int64 = {};
          m["a"] = 1_i64;
          RETURN;
        END
      CLEAR
      low.shard_context = { map: "m", idx: "__sh.idx", key: "__sh.key" }

      result = low.lower(assignment)

      expect(result).to be_a(MIR::ShardedMapPut)
      expect(result.shard_idx).to be_a(MIR::Ident)
      expect(result.shard_key).to be_a(MIR::Ident)
      expect(result.shard_idx.name).to eq("__sh.idx")
      expect(result.shard_key.name).to eq("__sh.key")
      expect(result.template_kind).to eq(IntrinsicTemplateKind::ShardDirectZig)
    end

    it "keeps list writes on the indexed template path with target metadata" do
      low, assignment = compile_first_assignment(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE xs: []Int64 = [];
          xs[0_i64] = 9_i64;
          RETURN;
        END
      CLEAR

      result = low.lower(assignment)

      expect(result).to be_a(MIR::ExprStmt)
      expect(result.expr).to be_a(MIR::IndexedStore)
      expect(result.expr.target_var).to eq("xs")
      expect(emit(result)).to include("CheatLib.setAt(xs, 0, 9)")
    end

    it "falls back to setAt for unknown indexable receiver types" do
      target = make_id("bag", full_type: :Bag)
      index = make_lit(:INT64, 0, full_type: :Int64)
      value = make_lit(:INT64, 42, full_type: :Int64)
      get_index = AST::GetIndex.new(tok, target, index)
      node = AST::Assignment.new(tok, get_index, value)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::ExprStmt)
      expect(emit(result)).to eq("CheatLib.setAt(bag, 0, 42);")
    end

    it "cleans up overwritten list elements that own heap fields before indexed storage" do
      target = make_id("items", full_type: Type.new(:"Point[]", collection: :list))
      index = make_lit(:INT64, 0, full_type: :Int64)
      value = make_id("next_point", full_type: :Point)
      node = AST::Assignment.new(tok, AST::GetIndex.new(tok, target, index), value)
      heap_string = Type.new(:String)
      heap_string.mark_heap_allocated!
      point_schema = Schemas::StructSchema.new(fields: { "name" => heap_string })

      result = lowering(struct_schemas: { Point: point_schema }).lower(node)

      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("CheatLib.cleanupAt(Point, items, rt.frameAlloc(), 0)")
      expect(zig).to include("CheatLib.setAt(items, 0, __tmp_")
      expect(result.body.any? { |stmt| stmt.is_a?(MIR::TransferMark) }).to be true
    end
  end

  describe "BC concurrent pipeline lowering" do
    {
      "count" => ["COUNT _ > 2_i64", MIR::Lit],
      "min" => ["MIN toFloat(_)", MIR::TypeSentinel],
      "max" => ["MAX toFloat(_)", MIR::TypeSentinel],
      "average" => ["AVERAGE toFloat(_)", MIR::FieldGet],
    }.each do |name, (op, expected_node)|
      it "lowers CONCURRENT #{name.upcase} through the BC sequential simulation" do
        low, value = compile_first_binding_value(<<~CLEAR, "out", target: :bc)
          FN main() RETURNS Void ->
            vals = [1_i64, 2_i64, 3_i64, 4_i64];
            out = vals |> CONCURRENT(workers: 2) #{op};
            RETURN;
          END
        CLEAR

        result = low.lower(value)
        nodes = []
        each_mir_node(result) { |node| nodes << node }

        expect(result).to be_a(MIR::Pipeline)
        expect(nodes).to include(a_kind_of(MIR::BlockExpr))
        expect(nodes).to include(a_kind_of(expected_node))
      end
    end

    it "lowers CONCURRENT WHERE OR_ELSE PRUNE through the BC error-sentinel path" do
      low, value = compile_first_binding_value(<<~CLEAR, "out", target: :bc)
        FN maybePositive(x: Float64) RETURNS !Bool ->
          RETURN x > 1.0;
        END

        FN main() RETURNS Void ->
          vals: Float64[] = [1.0, 2.0, 3.0];
          out = vals |> CONCURRENT(workers: 2) WHERE maybePositive(_) OR_ELSE PRUNE;
          RETURN;
        END
      CLEAR

      result = low.lower(value)
      inline_bc_ops = []
      each_mir_node(result) do |node|
        inline_bc_ops << node.op if node.is_a?(MIR::InlineBc)
      end

      expect(result).to be_a(MIR::Pipeline)
      nodes = []
      each_mir_node(result) { |node| nodes << node }
      expect(nodes).to include(a_kind_of(MIR::BlockExpr))
      expect(inline_bc_ops).to include(:is_error)
    end

    it "adds loop restore to BC SHARD producer when the key expression frame-allocates" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n = 4_i64;
          MUTABLE map: {String}@sharded(4) Int64 = {};

          (0..<n) |> SHARD("k:${toString(_)}", map) |> CONCURRENT EACH {
            map[_] = 1_i64;
          };

          RETURN;
        END
      CLEAR
      importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
      result = CompilerFrontend.compile(src, importer: importer, source_dir: Dir.pwd)
      low = lowering(
        struct_schemas: result.struct_schemas,
        enum_schemas: result.enum_schemas,
        union_schemas: result.union_schemas,
        fn_sigs: result.fn_sigs,
        moved_guard_info: result.moved_guard_info,
        importer: importer,
        source_dir: Dir.pwd,
        target: :bc
      )

      program = low.lower_program(result.ast)

      expect_checker_clean(program)
      shard_loop = collect_mir_nodes(program, MIR::ForStmt).find do |loop|
        loop.body.any? { |stmt| stmt.is_a?(MIR::Let) && stmt.name.to_s == "__sh1_key" }
      end
      expect(shard_loop).not_to be_nil
      expect(shard_loop.body).to include(satisfy { |stmt|
        stmt.is_a?(MIR::Let) &&
          stmt.init.is_a?(MIR::MethodCall) &&
          stmt.init.method == "saveLoopMark"
      })
      expect(shard_loop.body).to include(satisfy { |stmt|
        stmt.is_a?(MIR::DeferStmt) &&
          stmt.body.is_a?(MIR::MethodCall) &&
          stmt.body.method == "restoreLoopMark"
      })
    end
  end

  describe "intrinsic receiver allocation lowering" do
    it "hoists frame-returning string intrinsics before direct string length" do
      mir = lower_source_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          line = "SET:12345:payload";
          total = substr(line, 4_i64, 5_i64).length();
          RETURN;
        END
      CLEAR

      expect_checker_clean(mir)
      zig = emit(mir)
      expect(zig).to include("CheatLib.substr")
      expect(zig).to match(/const __tmp_\d+ = .*CheatLib\.substr/)
      expect(zig).to match(/@intCast\(__tmp_\d+\.len\)/)
    end
  end

  # =========================================================================
  # Control flow
  # =========================================================================

  describe "control flow" do
    it "lowers if statement" do
      cond = make_lit(:BOOLEAN, true)
      then_body = make_lit(:NUMBER, 1.0)
      node = AST::IfStatement.new(tok, cond, [then_body], nil, nil, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::IfStmt)
      zig = emit(result)
      expect(zig).to include("if (true)")
      expect(zig).to include("1.0")
    end

    it "lowers if/else statement" do
      cond = make_lit(:BOOLEAN, false)
      then_stmt = make_lit(:NUMBER, 1.0)
      else_stmt = make_lit(:NUMBER, 2.0)
      node = AST::IfStatement.new(tok, cond, [then_stmt], [else_stmt], nil, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("if (false)")
      expect(zig).to include("} else {")
    end

    it "lowers while loop" do
      cond = make_lit(:BOOLEAN, true)
      body_stmt = make_lit(:NUMBER, 1.0)
      node = AST::WhileLoop.new(tok, cond, [body_stmt], nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::WhileStmt)
      expect(result.tight).to be(false)
      zig = emit(result)
      expect(zig).to include("while (true)")
    end

    it "lowers return with value" do
      value = make_lit(:NUMBER, 42, full_type: :Int64)
      value.coerced_type = :Int64
      node = AST::ReturnNode.new(tok, value)
      node.full_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ReturnStmt)
      expect(emit(result)).to eq("return 42;")
    end

    it "lowers bare return" do
      node = AST::ReturnNode.new(tok, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(emit(result)).to eq("return;")
    end

    it "lowers break" do
      node = AST::BreakNode.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::BreakStmt)
      expect(emit(result)).to eq("break;")
    end

    it "lowers continue" do
      node = AST::ContinueNode.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ContinueStmt)
      expect(emit(result)).to eq("continue;")
    end

    it "lowers for-each" do
      coll = make_id("items", full_type: :List)
      body_stmt = make_lit(:NUMBER, 1.0)
      node = AST::ForEach.new(tok, "item", coll, [body_stmt], nil, false)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ForStmt)
      zig = emit(result)
      expect(zig).to include("for")
      expect(zig).to include("|_|")
    end

    it "lowers pass statement" do
      node = AST::PassStmt.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Noop)
    end
  end

  # =========================================================================
  # Match statement
  # =========================================================================

  describe "match statement" do
    it "lowers enum match to SwitchStmt" do
      expr = make_id("dir", full_type: :Direction)

      case_val = AST::GetField.new(tok, make_id("Direction"), "North")
      case_val.full_type = :Direction
      case_body = [make_lit(:NUMBER, 1.0)]

      cases = [AST::MatchCase.new(kind: :eq, value: case_val, body: case_body)]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void

      l = lowering(enum_schemas: { Direction: [:North, :South] })
      result = l.lower(node)
      expect(result).to be_a(MIR::SwitchStmt)
      zig = emit(result)
      expect(zig).to include("switch (dir)")
      expect(zig).to include(".North")
    end

    it "lowers union match to IfChain" do
      expr = make_id("result", full_type: :Result)

      case_val = AST::GetField.new(tok, make_id("Result"), "Ok")
      case_val.full_type = :Result
      case_body = [make_lit(:NUMBER, 1.0)]

      cases = [AST::MatchCase.new(kind: :eq, value: case_val, body: case_body)]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void

      l = lowering(union_schemas: { Result: Schemas::UnionSchema.new(variants: { Ok: :Int64, Err: :String }) })
      result = l.lower(node)
      expect(result).to be_a(MIR::UnionMatchStmt)
      zig = emit(result)
      expect(zig).to include("switch (result)")
      expect(zig).to include(".Ok")
    end

    it "lowers string match to IfChain with strEql" do
      expr = make_id("cmd", full_type: :String)

      case_val = make_lit(:STRING, "quit")
      case_body = [make_lit(:NUMBER, 0, full_type: :Int64)]

      cases = [AST::MatchCase.new(kind: :eq, value: case_val, body: case_body)]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void
      node.string_match = true

      result = lowering.lower(node)
      expect(result).to be_a(MIR::IfChain)
      zig = emit(result)
      expect(zig).to include("CheatLib.strEql")
    end

    it "lowers match with default case" do
      expr = make_id("x", full_type: :Int64)

      case_val = make_lit(:INT64, 1)
      case_body = [make_lit(:STRING, "one")]
      default_body = [make_lit(:STRING, "other")]

      cases = [AST::MatchCase.new(kind: :eq, value: case_val, body: case_body)]
      node = AST::MatchStatement.new(tok, expr, cases, default_body, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::SwitchStmt)
      zig = emit(result)
      expect(zig).to include("else =>")
    end

    it "lowers integer match arms with extra values into a shared switch prong" do
      expr = make_id("x", full_type: :Int64)
      cases = [AST::MatchCase.new(
        kind: :eq,
        value: make_lit(:INT64, 1, full_type: :Int64),
        extra_values: [make_lit(:INT64, 2, full_type: :Int64), make_lit(:INT64, 3, full_type: :Int64)],
        body: [make_lit(:STRING, "small")]
      )]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering.lower(node)

      expect(result).to be_a(MIR::SwitchStmt)
      expect(result.arms.first.patterns).to eq([
        MIR::Lit.new("1"),
        MIR::Lit.new("2"),
        MIR::Lit.new("3"),
      ])
      expect(MIREmitter.new.emit(result)).to include("1, 2, 3 =>")
      expect(result.default_body).to eq([])
    end

    it "adds an empty default for non-exhaustive enum switches" do
      expr = make_id("dir", full_type: :Direction)
      north = AST::GetField.new(tok, make_id("Direction"), "North")
      north.full_type = :Direction
      node = AST::MatchStatement.new(tok, expr, [AST::MatchCase.new(kind: :eq, value: north, body: [make_lit(:NUMBER, 1.0)])], nil, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering(enum_schemas: { Direction: [:North, :South] }).lower(node)

      expect(result).to be_a(MIR::SwitchStmt)
      expect(result.default_body).to eq([])
    end

    it "omits unreachable defaults for exhaustive enum switches" do
      expr = make_id("op", full_type: :Op)
      get = AST::GetField.new(tok, make_id("Op"), "Get")
      get.full_type = :Op
      put = AST::GetField.new(tok, make_id("Op"), "Put")
      put.full_type = :Op
      cases = [
        AST::MatchCase.new(kind: :eq, value: get, body: [make_lit(:NUMBER, 1.0)]),
        AST::MatchCase.new(kind: :eq, value: put, body: [make_lit(:NUMBER, 2.0)]),
      ]
      node = AST::MatchStatement.new(tok, expr, cases, [make_lit(:NUMBER, 3.0)], nil, nil, false, nil)
      node.full_type = :Void

      result = lowering(enum_schemas: { Op: [:Get, :Put] }).lower(node)

      expect(result).to be_a(MIR::SwitchStmt)
      expect(result.default_body).to be_nil
      expect(emit(result)).not_to include("else =>")
    end

    it "lowers expression-mode match to a BlockExpr" do
      expr = make_id("x", full_type: :Int64)
      cases = [AST::MatchCase.new(kind: :eq, value: make_lit(:INT64, 1, full_type: :Int64), body: [make_lit(:INT64, 10, full_type: :Int64)])]
      node = AST::MatchStatement.new(tok, expr, cases, [make_lit(:INT64, 0, full_type: :Int64)], nil, nil, true, nil)
      node.full_type = :Int64
      node.expr_mode = true

      result = lowering.lower(node)

      expect(result).to be_a(MIR::BlockExpr)
      expect(result.body.first).to be_a(MIR::SwitchStmt)
    end

    it "expands multi-variant union binding arms so payload reads match the active tag" do
      expr = make_id("result", full_type: :Result)
      ok = AST::GetField.new(tok, make_id("Result"), "Ok")
      ok.full_type = :Result
      err = AST::GetField.new(tok, make_id("Result"), "Err")
      err.full_type = :Result
      cases = [AST::MatchCase.new(
        kind: :eq,
        value: ok,
        extra_values: [err],
        binding: "payload",
        body: [make_lit(:NUMBER, 1.0)]
      )]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering(union_schemas: { Result: Schemas::UnionSchema.new(variants: { Ok: :Int64, Err: :Int64 }) }).lower(node)

      expect(result).to be_a(MIR::UnionMatchStmt)
      expect(result.arms.length).to eq(2)
      expect(result.arms[0].payload).to start_with("__match_payload_")
      expect(result.arms[0].variant).to eq("Ok")
      expect(result.arms[1].payload).to start_with("__match_payload_")
      expect(result.arms[1].variant).to eq("Err")
      expect(result.arms[0].body.grep(MIR::Let).map(&:name)).to include("payload")
      expect(result.arms[1].body.grep(MIR::Let).map(&:name)).to include("payload")
    end

    it "lowers WHEN guard arms before subject equality dispatch" do
      expr = make_id("x", full_type: :Int64)
      guard = make_lit(:BOOLEAN, true, full_type: :Boolean)
      cases = [AST::MatchCase.new(kind: :when, value: guard, body: [make_lit(:STRING, "guarded")])]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering.lower(node)

      expect(result).to be_a(MIR::IfChain)
      expect(result.branches.first.cond).to be_a(MIR::Lit)
      expect(emit(result.branches.first.cond)).to eq("true")
    end
  end

  # =========================================================================
  # Memory / capability expressions
  # =========================================================================

  describe "memory operations" do
    it "lowers COPY of string" do
      inner = make_id("s", full_type: :String)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = :String
      result = lowering.lower(node)
      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:full_value)
      expect(emit(result)).to include("dupeValue([]const u8, __copy_src")
    end

    it "lowers COPY passthrough for value types as an inline auto-deref expression" do
      inner = make_id("x", full_type: :Int64)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:passthrough)
      expect(emit(result)).to eq("(if (comptime @typeInfo(@TypeOf(x)) == .pointer and @typeInfo(@TypeOf(x)).pointer.size == .one) (x).* else x)")
    end

    it "uses symbol type information when COPY source has not been stamped" do
      inner = AST::Identifier.new(tok, "s")
      inner.symbol = SymbolEntry.new(reg: "s", type: Type.new(:String), mutable: false, storage: :stack)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = Type.new(:String)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:full_value)
      expect(result.zig_type).to eq("[]const u8")
    end

    it "lowers COPY of sync values as full-value dupes" do
      locked_type = Type.new(:Counter, sync: :locked)
      inner = make_id("c", full_type: locked_type)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = locked_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:full_value)
      expect(result.zig_type).to eq("*CheatLib.Locked(Counter)")
      expect(emit(result)).to include("try CheatLib.dupeValue(@TypeOf(c), __copy_src, rt.heapAlloc())")
    end

    it "copies the raw value before creating a reference-counted capability wrapper" do
      raw_type = Type.new(:StringMap)
      source = make_id("values", full_type: raw_type)
      copy = AST::CopyNode.new(tok, source)
      copy.full_type = raw_type
      wrapped_type = Type.new(:StringMap, ownership: :multiowned)
      wrapper = AST::CapabilityWrap.new(tok, copy, :multiowned, nil, nil)
      wrapper.full_type = wrapped_type

      low = lowering
      result = low.send(:with_expected_type, wrapped_type) { low.lower(wrapper) }

      expect(result).to be_a(MIR::CapWrap)
      expect(result.inner).to be_a(MIR::DeepCopy)
      expect(result.inner.zig_type.to_s).not_to include("CheatLib.Rc")
      expect(result.own_fn).to eq("rcCreate")
      expect(emit(result)).not_to include("dupeValue(CheatLib.Rc")
    end

    it "emits cleanup for declarations initialized from COPY of sync values" do
      locked_type = Type.new(:Counter, sync: :locked)
      inner = make_id("src", full_type: locked_type)
      copy = AST::CopyNode.new(tok, inner)
      copy.full_type = locked_type

      node = AST::VarDecl.new(tok, "dst", nil, copy, false)
      node.full_type = locked_type
      node.var_used = true
      node.symbol = SymbolEntry.new(reg: "dst", type: locked_type,
                                    mutable: true, storage: :stack, sync: :locked)

      # CleanupClassifier is the cleanup-recipe authority; lowering inherits
      # from FunctionState current bindings (INV-14). Drive it as the pipeline does
      # rather than the removed destination-synthesis fallback.
      fn = AST::FunctionDef.new(tok, "f", [], nil, :Void, nil, [node],
                                nil, nil, nil, nil, false)
      low = lowering
      low.function_state.current_bindings =
        CleanupClassifier.classify(fn, schema_lookup: ->(_) { nil })

      result = low.lower(node)
      expect(result).to be_a(Array)
      expect(result[0]).to be_a(MIR::AllocMark)
      expect(result[1]).to be_a(MIR::Let)
      expect(result[1].mutable).to be true
      expect(result[1].init).to be_a(MIR::DeepCopy)
      expect(result[1].init.strategy).to eq(:full_value)
      expect(result[2]).to be_a(MIR::Cleanup)
      expect(result[2].cleanup_entry).to include(kind: :uniform, alloc: :heap)
    end

    it "lowers MOVE as identity" do
      inner = make_id("handle", full_type: :Resource)
      node = AST::MoveNode.new(tok, inner)
      node.full_type = :Resource
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Ident)
      expect(emit(result)).to eq("handle")
    end

    it "lowers CLONE of a shared handle to Arc retain" do
      source_type = Type.new(:Box, ownership: :shared)
      inner = make_id("box", full_type: source_type)
      node = AST::CloneNode.new(tok, inner)
      node.full_type = source_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::RcRetain)
      expect(result.func).to eq("arcRetain")
      expect(result.zig_base).to eq("Box")
      expect(emit(result)).to eq("CheatLib.arcRetain(Box, box)")
    end

    it "lowers SHARE of a bare value to Arc creation" do
      inner = make_id("box", full_type: :Box)
      shared_type = Type.new(:Box, ownership: :shared)
      node = AST::ShareNode.new(tok, inner)
      node.full_type = shared_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::CapWrap)
      expect(result.own_fn).to eq("arcCreate")
      expect(result.zig_base).to eq("Box")
      expect(emit(result)).to eq("try CheatLib.arcCreate(Box, rt.heapAlloc(), box)")
    end

    it "lowers SHARE of an existing shared handle to Arc retain" do
      source_type = Type.new(:Box, ownership: :shared)
      inner = make_id("box", full_type: source_type)
      node = AST::ShareNode.new(tok, inner)
      node.full_type = source_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::RcRetain)
      expect(result.func).to eq("arcRetain")
      expect(result.zig_base).to eq("Box")
      expect(emit(result)).to eq("CheatLib.arcRetain(Box, box)")
    end

    it "lowers SHARE of a multiowned handle to Rc-to-Arc promotion" do
      source_type = Type.new(:Box, ownership: :multiowned)
      shared_type = Type.new(:Box, ownership: :shared)
      inner = make_id("box", full_type: source_type)
      node = AST::ShareNode.new(tok, inner)
      node.full_type = shared_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::SharePromote)
      expect(result.zig_base).to eq("Box")
      expect(emit(result)).to include("CheatLib.rcRelease(Box, rt.heapAlloc(), __share_src);")
    end

    it "records cleanup metadata for hoisted SharePromote allocations" do
      source_type = Type.new(:Box, ownership: :multiowned)
      shared_type = Type.new(:Box, ownership: :shared)
      inner = make_id("box", full_type: source_type)
      node = AST::ShareNode.new(tok, inner)
      node.full_type = shared_type

      promote = MIR::SharePromote.new(MIR::Ident.new("box"), "Box", :heap)
      l = lowering
      expect(l.send(:mir_allocates?, promote)).to be true
      entry = l.send(:hoist_cleanup_entry, promote, node)
      expect(entry).to include(kind: :rc, alloc: :heap, zig_type: "CheatLib.Arc(Box)")
    end

    it "lowers CLONE of a multiowned handle to Rc retain" do
      source_type = Type.new(:Box, ownership: :multiowned)
      inner = make_id("box", full_type: source_type)
      node = AST::CloneNode.new(tok, inner)
      node.full_type = source_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::RcRetain)
      expect(result.func).to eq("rcRetain")
      expect(result.zig_base).to eq("Box")
    end

    it "lowers COPY of union" do
      inner = make_id("val", full_type: :Value)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = :Value

      l = lowering(union_schemas: { Value: Schemas::UnionSchema.new(variants: { Num: :Number, Str: :String }) })
      result = l.lower(node)
      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:full_value)
      expect(emit(result)).to include("dupeValue(Value")
    end

    it "lowers COPY of borrowed union using bare union type" do
      borrowed_union = Type.new(:Value)
      borrowed_union.ownership = :borrow
      inner = make_id("val", full_type: borrowed_union)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = :Value

      l = lowering(union_schemas: { Value: Schemas::UnionSchema.new(variants: { Num: :Number, Str: :String }) })
      result = l.lower(node)
      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:full_value)
      expect(result.zig_type).to eq("Value")
      expect(emit(result)).to include("try CheatLib.dupeValue(Value, __copy_src, rt.heapAlloc())")
    end

    it "keeps COPY of a payload-free union constructor allocation-free" do
      target = make_id("Value", full_type: :Value)
      variant = AST::GetField.new(tok, target, "Nil")
      variant.full_type = :Value
      node = AST::CopyNode.new(tok, variant)
      node.full_type = :Value

      result = lowering(
        union_schemas: { Value: Schemas::UnionSchema.new(variants: { "Nil" => nil, "Str" => :String }) }
      ).lower(node)

      expect(result).to be_a(MIR::StructInit)
      expect(emit(result)).to include("Value{ .Nil = {} }")
      expect(emit(result)).not_to include("dupeValue")
    end

  end

  # =========================================================================
  # Struct literals
  # =========================================================================

  describe "struct literals" do
    it "lowers struct literal" do
      name_val = make_lit(:STRING, "alice")
      age_val = make_lit(:NUMBER, 30, full_type: :Int64)
      age_val.coerced_type = :Int64

      node = AST::StructLit.new(tok, "User", { name: name_val, age: age_val }, nil, nil)
      node.full_type = :User

      result = lowering.lower(node)
      expect(result).to be_a(MIR::StructInit)
      zig = emit(result)
      expect(zig).to include("User{")
      expect(zig).to include('.name = "alice"')
      expect(zig).to include(".age = 30")
    end

    it "keeps heap-marked struct literals value-shaped" do
      val = make_lit(:NUMBER, 1.0)
      node = AST::StructLit.new(tok, "Node", { value: val }, :heap, nil)
      node.full_type = :Node

      result = lowering.lower(node)
      expect(result).to be_a(MIR::StructInit)
      zig = emit(result)
      expect(zig).to include("Node{")
      expect(zig).not_to include("create(Node)")
      expect(zig).to include(".value = 1.0")
    end

    it "keeps borrowed list fields in their declared container representation" do
      source = make_id("items", full_type: Type.array_of(:Int64))
      node = AST::StructLit.new(tok, "Window", { "items" => source }, nil, nil)
      node.full_type = :Window
      node.borrowed_field_names = Set["items"]

      result = lowering(struct_schemas: {
        Window: Schemas::StructSchema.new(fields: { "items" => Type.array_of(:Int64) }),
      }).lower(node)

      field_value = MIR.struct_init_field_value(result.fields.first)
      expect(field_value).to eq(MIR::Ident.new("items"))
    end

    it "retains an Rc-backed identifier stored in a struct field" do
      source = make_id("node", full_type: Type.new(:Node, ownership: :multiowned))
      node = AST::StructLit.new(tok, "Wrapper", { "inner" => source }, nil, nil)
      node.full_type = :Wrapper

      low = lowering(struct_schemas: {
        Wrapper: Schemas::StructSchema.new(fields: {
          "inner" => Type.new(:Node, ownership: :multiowned),
        }),
      })
      result = low.lower(node)

      expect(emit(low.function_state.pending_stmts)).to include("rcRetain")
      expect(emit(result)).to include(".inner = __tmp_")
    end
  end

  describe "indirect aggregate field ownership" do
    it "moves recursive union locals when they are boxed into indirect inline-variant fields" do
      src = <<~CLEAR
        UNION Node { Nil, One: String, Pair { left: Node @boxed, right: Node @boxed } }

        FN mk() RETURNS !Node ->
            left = Node{ One: COPY "a" };
            right = Node{ One: COPY "b" };
            RETURN Node.Pair{ left: left, right: right };
        END
      CLEAR
      importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
      result = CompilerFrontend.compile(src, importer: importer, source_dir: Dir.pwd)
      low = lowering(
        struct_schemas: result.struct_schemas,
        enum_schemas: result.enum_schemas,
        union_schemas: result.union_schemas,
        fn_sigs: result.fn_sigs,
        moved_guard_info: result.moved_guard_info,
        importer: importer,
        source_dir: Dir.pwd
      )
      program = low.lower_program(result.ast)
      mk_fn = program.items.find { |item| item.is_a?(MIR::FnDef) && item.name == "mk" }
      hoisted_return = mk_fn.body.find { |stmt| stmt.is_a?(MIR::Let) && stmt.name.to_s.start_with?("__hoist_") }
      block = hoisted_return.init

      expect(block).to be_a(MIR::BlockExpr)
      expect(block.body).to include(
        an_instance_of(MIR::TransferMark).and(have_attributes(name: "left", target: :owned_sink)),
        an_instance_of(MIR::MoveMark).and(have_attributes(name: "left")),
        an_instance_of(MIR::TransferMark).and(have_attributes(name: "right", target: :owned_sink)),
        an_instance_of(MIR::MoveMark).and(have_attributes(name: "right"))
      )
    end
  end

  # =========================================================================
  # String concat
  # =========================================================================

  describe "string concatenation" do
    it "lowers StringConcat" do
      p1 = make_lit(:STRING, "hello ")
      p2 = make_id("name", full_type: :String)
      node = AST::StringConcat.new(tok, [p1, p2])
      node.full_type = :String
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ConcatStr)
      zig = emit(result)
      expect(zig).to include("std.mem.concat")
      expect(zig).to include('"hello "')
      expect(zig).to include("name")
    end
  end

  # =========================================================================
  # Range literal
  # =========================================================================

  describe "range literal" do
    it "lowers exclusive range" do
      s = make_lit(:NUMBER, 0, full_type: :Int64)
      s.coerced_type = :Int64
      e = make_lit(:NUMBER, 10, full_type: :Int64)
      e.coerced_type = :Int64
      node = AST::RangeLit.new(tok, s, e, false)
      node.full_type = Type.new(:"~Int64[]")
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RangeLit)
      zig = emit(result)
      expect(zig).to include("CheatLib.IntRange")
      expect(zig).to include(".start = 0")
      expect(zig).to include(".end = 10")
    end

    it "lowers inclusive range (adds 1 to end)" do
      s = make_lit(:NUMBER, 0, full_type: :Int64)
      s.coerced_type = :Int64
      e = make_lit(:NUMBER, 5, full_type: :Int64)
      e.coerced_type = :Int64
      node = AST::RangeLit.new(tok, s, e, true)
      node.full_type = Type.new(:"~Int64[]")
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("(5 + 1)")
    end
  end

  # =========================================================================
  # Assert and Raise
  # =========================================================================

  describe "assert and raise" do
    it "lowers assert" do
      cond = make_lit(:BOOLEAN, true)
      node = AST::Assert.new(tok, cond, "should be true")
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::AssertStmt)
      expect(emit(result)).to include("CheatLib.assert(true,")
    end

    it "lowers raise" do
      msg = AST::Literal.new(tok, :String, "timed out")
      msg.full_type = :String
      node = AST::Raise.new(tok, :Transient, :Timeout, msg)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      code = emit(result)
      expect(code).to include('setError(.Transient, @intFromEnum(ErrorName.Timeout)')
      expect(code).to include("return error.CheatError")
    end

    it "lowers raise with no message" do
      node = AST::Raise.new(tok, :NotFound, nil, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      code = emit(result)
      # No specific type named -> None id (0) is emitted, message is "".
      expect(code).to include('setError(.NotFound, 0,')
      expect(code).to include("return error.CheatError")
    end
  end

  # =========================================================================
  # Optional unwrap
  # =========================================================================

  describe "optional unwrap" do
    it "lowers optional unwrap" do
      inner = make_id("maybe_val", full_type: :"?Int64")
      node = AST::OptionalUnwrap.new(tok, inner)
      node.full_type = :Int64
      node.tense_plan = TenseOperationPlanner.unwrap(inner.full_type!)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::OptionalUnwrap)
      expect(emit(result)).to eq("maybe_val.?")
    end
  end

  # =========================================================================
  # Block expression
  # =========================================================================

  describe "block expression" do
    it "lowers block expression" do
      body_stmt = make_lit(:NUMBER, 1.0)
      result_expr = make_lit(:NUMBER, 42, full_type: :Int64)
      result_expr.coerced_type = :Int64
      node = AST::BlockExpr.new(tok, [body_stmt], result_expr)
      node.full_type = :Int64

      result = lowering.lower(node)
      expect(result).to be_a(MIR::BlockExpr)
      zig = emit(result)
      expect(zig).to include("__blk_1:")
      expect(zig).to include("break")
    end
  end

  # =========================================================================
  # lower_body
  # =========================================================================

  describe "lower_body" do
    it "lowers array of statements" do
      stmts = [
        make_lit(:NUMBER, 1.0),
        make_lit(:NUMBER, 2.0),
      ]
      result = lowering.lower_body(stmts)
      lits = result.reject { |n| n.is_a?(MIR::Comment) }
      expect(lits.length).to eq(2)
      expect(lits.all? { |n| n.is_a?(MIR::Lit) }).to eq(true)
    end

  end

  # =========================================================================
  # End-to-end: lower then emit
  # =========================================================================

  describe "end-to-end lowering + emission" do
    it "keeps nested boxed union collection copies in the collection layout" do
      mir = lower_source_mir(<<~CLEAR)
        UNION Value {
          Nil,
          List: Value[],
          Pair { car: Value @boxed, cdr: Value @boxed }
        }

        FN main() RETURNS !Void ->
          MUTABLE items: []Value = List[];
          &items.append(Value.Nil);
          MUTABLE slots: []Value = [Value.Nil];
          slots[0_i64] = Value.Pair{
            car: Value.Nil,
            cdr: Value{ List: items }
          };
          RETURN;
        END
      CLEAR

      expect_checker_clean(mir)
      collection_copies = collect_mir_nodes(mir, MIR::DeepCopy).select do |copy|
        collect_mir_nodes(copy.source, MIR::Ident).any? { |ident| ident.name.to_s.start_with?("items") }
      end
      expect(collection_copies).not_to be_empty
      expect(collection_copies).to all(satisfy { |copy| copy.zig_type != "Value" })
    end

    it "keeps nested struct collection copies in the collection layout" do
      mir = lower_source_mir(<<~CLEAR)
        UNION Value { Nil, List: Value[] }
        STRUCT Holder { value: Value }

        FN main() RETURNS !Void ->
          MUTABLE items: []Value = List[];
          &items.append(Value.Nil);
          MUTABLE holders: []Holder = [Holder{ value: Value.Nil }];
          holders[0_i64] = Holder{ value: Value{ List: items } };
          RETURN;
        END
      CLEAR

      expect_checker_clean(mir)
      collection_copies = collect_mir_nodes(mir, MIR::DeepCopy).select do |copy|
        collect_mir_nodes(copy.source, MIR::Ident).any? { |ident| ident.name.to_s.start_with?("items") }
      end
      expect(collection_copies).not_to be_empty
      expect(collection_copies).to all(satisfy { |copy| copy.zig_type != "Value" })
    end

    it "keeps a unit-union fallback borrowed through a nested call and indexed store" do
      mir = lower_source_mir(<<~CLEAR)
        UNION Value { Nil, Count: Int64, Text: String }

        FN getInt(value: Value) RETURNS Int64 ->
          PARTIAL MATCH value START
            Value.Count AS count -> RETURN count;,
            DEFAULT -> RETURN 0_i64;
          END
        END

        FN main() RETURNS !Void ->
          MUTABLE values: []Value = List[];
          MUTABLE ints: []Int64 = [0_i64];
          ints[0_i64] = getInt(values[0_i64] OR_ELSE Value.Nil);
          RETURN;
        END
      CLEAR

      expect_checker_clean(mir)
      expect(emit(mir)).not_to match(/dupeValue\(Value,\s*Value\{ \.Nil/)
    end

    it "does not deep-copy fresh unit union variants into owned sinks" do
      mir = lower_source_mir(<<~CLEAR)
        UNION Value { Nil, Count: Int64 }
        STRUCT Slot { payload: Value }

        FN main() RETURNS !Void ->
          MUTABLE values: []Value = List[];
          &values.append(Value.Nil);
          MUTABLE slot = Slot{ payload: Value.Nil };
          MUTABLE current: Value = Value.Nil;
          current = Value.Nil;
          slot.payload = Value.Nil;
          ASSERT values.length() == 1_i64, "unit variant append";
          RETURN;
        END
      CLEAR

      zig = emit(mir)
      expect(zig).to include("Value{ .Nil = {} }")
      expect(zig).to include("current = Value{ .Nil = {} }")
      expect(zig).to include("slot.payload = Value{ .Nil = {} }")
      expect(zig).not_to match(/dupeValue\(Value,.*\.Nil/)
    end

    it "moves owning lists into local array views without duplicating their backing" do
      mir = lower_source_mir(<<~CLEAR)
        FN hotView(TAKES items: []Int64) RETURNS Int64[] ->
          RETURN GIVE items;
        END
      CLEAR

      zig = emit(mir)
      expect(zig).to include("return items;")
      expect(zig).not_to include("dupeValue")
    end

    it "lowers and emits a var decl with string literal" do
      value = make_lit(:STRING, "world")
      node = AST::VarDecl.new(tok, "greeting", nil, value, false)
      node.full_type = :String
      node.var_used = true
      mir = lowering.lower(node)
      zig = emit(mir)
      expect(zig).to include('const greeting: []const u8 = @as([]const u8, try rt.frameAlloc().dupe(u8, "world"));')
    end

    it "lowers and emits an if with binary condition" do
      left = make_id("x")
      right = make_lit(:NUMBER, 0.0)
      cond = make_binop(left, :GT, right)
      body = make_lit(:NUMBER, 1.0)

      node = AST::IfStatement.new(tok, cond, [body], nil, nil, nil)
      node.full_type = :Void
      mir = lowering.lower(node)
      zig = emit(mir)
      expect(zig).to include("if ((x > 0.0))")
    end
  end

  # =========================================================================
  # Phase 3: FunctionDef
  # =========================================================================

  describe "function definitions" do
    def make_fn(name, params: [], return_type: :Void, body: [], visibility: nil,
                needs_rt: true, can_fail: true, uses_frame: false, uses_alloc: false,
                type_params: [], catch_clauses: nil, default_catch: nil)
      fn = AST::FunctionDef.new(tok, name, params, nil, return_type, nil, body,
                                 catch_clauses, default_catch, visibility, nil, uses_frame)
      fn.full_type = return_type
      fn.needs_rt = needs_rt
      fn.can_fail = can_fail
      fn.uses_alloc = uses_alloc
      fn.type_params = type_params
      fn
    end

    it "lowers simple void function" do
      ret = make_lit(:NIL, nil, full_type: :Void)
      body = [AST::ReturnNode.new(tok, nil).tap { |n| n.full_type = :Void }]
      fn = make_fn("greet", body: body)
      result = lowering.lower(fn)
      expect(result).to be_a(MIR::FnDef)
      expect(result.name).to eq("greet")
      expect(result.visibility).to eq(:private)
      zig = emit(result)
      expect(zig).to include("fn greet(rt: *Runtime)")
      expect(zig).to include("!void")
      expect(zig).to include("return;")
    end

    it "wraps catch-only functions in fallible inner return types even when the body cannot fail" do
      ret = AST::ReturnNode.new(tok, make_lit(:NUMBER, 1, full_type: :Int64))
      ret.full_type = :Int64
      catch_ret = AST::ReturnNode.new(tok, make_lit(:NUMBER, 0, full_type: :Int64))
      catch_ret.full_type = :Int64
      fn = make_fn("recover_int", return_type: :Int64, body: [ret],
                   can_fail: false, catch_clauses: [AST::CatchClause.new(body: [catch_ret])])

      result = lowering.lower(fn)

      expect(result).to be_a(Array)
      expect(result.first.ret_type).to eq("!i64")
    end

    it "lowers pub function" do
      fn = make_fn("hello", visibility: :pub, body: [])
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to start_with("pub fn")
    end

    it "lowers function with params" do
      params = [AST::Param.new(name: "x", type: :Int64, mutable: false),
                AST::Param.new(name: "y", type: :Number, mutable: false)]
      fn = make_fn("add", params: params, return_type: :Number)
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to include("x: i64")
      expect(zig).to include("y: f64")
    end

    it "stack struct param uses anytype — SROA candidate, no const-ptr" do
      # Structs with no heap provenance live on the stack. Zig/LLVM SROAs them
      # into registers. Do NOT pass by *const T — that would prevent SROA.
      params = [AST::Param.new(name: "p", type: :Point, mutable: false)]
      l = lowering(struct_schemas: { Point: Schemas::StructSchema.new(fields: { "x" => :Number, "y" => :Number }) })
      fn = make_fn("sum3", params: params)
      result = l.lower(fn)
      zig = emit(result)
      expect(zig).to include("p: anytype")
      expect(zig).not_to include("*const Point")
    end

    it "includes frame save/restore for value-returning frame functions" do
      fn = make_fn("compute", return_type: :Int64, uses_frame: true)
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to include("saveFrameMark")
      expect(zig).to include("restoreFrameMark")
    end

    it "skips frame mark for frame-string-returning functions (no heap_carry_return)" do
      fn = make_fn("getName", return_type: :String, uses_frame: true)
      result = lowering.lower(fn)
      zig = emit(result)
      # Frame string returns: no mark/restore (result lives in caller's frame region).
      expect(zig).not_to include("saveFrameMark")
      expect(zig).not_to include("restoreFrameMark")
      expect(zig).not_to include("preserveAndRewind")
    end

    it "emits _ = &rt when no frame allocation" do
      fn = make_fn("simple", body: [])
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to include("_ = &rt;")
    end

    it "lowers function without rt when needs_rt=false" do
      fn = make_fn("pure", needs_rt: false, can_fail: false)
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).not_to include("rt: *Runtime")
    end

    it "renames main to clearMain" do
      fn = make_fn("main")
      result = lowering.lower(fn)
      expect(result.name).to eq("clearMain")
    end

    it "emits comptime params for generic functions" do
      fn = make_fn("identity", type_params: ["T"])
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to include("comptime T: type")
    end

    it "renders shared generic type parameters through Type classification" do
      param_type = Type.new(:T, ownership: :shared)
      params = [AST::Param.new(name: "value", type: param_type)]
      fn = make_fn("keep", params: params, return_type: Type.new(:Void), type_params: ["T"])

      result = lowering.lower(fn)
      zig = emit(result)

      expect(zig).to include("comptime T: type")
      expect(zig).to include("value: CheatLib.Arc(T)")
    end

    it "handles mutable scalar param shadows" do
      params = [AST::Param.new(name: "count", type: :Int64, mutable: true)]
      body_stmt = make_id("count")
      fn = make_fn("inc", params: params, body: [body_stmt])
      result = lowering.lower(fn)
      zig = emit(result)
      # Mutable scalar params are passed by pointer so the callee can update
      # the caller's binding (ce525d5a). The shadow unpacks on entry and
      # writes back on exit via a defer.
      expect(zig).to include("_m_count: *i64")
      expect(zig).to include("var count = _m_count.*;")
      expect(zig).to include("_m_count.* = count;")
    end
  end

  describe "fallible sorted lock acquire lowering" do
    it "emits ordered acquire-or-error code with retries, reverse release, and error bubbling" do
      a = make_id("a", full_type: :Counter, sync: :locked)
      b = make_id("b", full_type: :Counter, sync: :write_locked)
      caps = [
        { capability: :EXCLUSIVE, var_node: a, alias: "left", resolved_type: Type.new(:Counter) },
        { capability: :write_locked_read, var_node: b, alias: "right", resolved_type: Type.new(:Counter) }
      ]
      clause = AST::ErrorClause.new(selectors: [], action: AST::ErrorActionKind::Pass, retries: 3, token: nil)
      clause.matched_types = [:LockTimeout]
      clause.bubble_types = [:Deadlock]
      with_node = AST::WithBlock.new(tok, caps, [], nil)
      typed_caps = caps.map { |cap| capability_transition(cap) }

      node = lowering.send(:sorted_lock_acquire, typed_caps, clause, "__with_label", with_node)
      expect(node).to be_a(MIR::SortedLockAcquire)
      expect(node.action).to be_a(MIR::FailureAction)
      expect(node.entries).to all(be_a(MIR::SortedLockAcquireEntry))

      zig = MIREmitter.new.emit(node)

      expect(zig).to include("acquireOrErr")
      expect(zig).to include("readOrErr")
      expect(zig).to include("var __held")
      expect(zig).to include("if (__retry + 1 < 3) continue")
      expect(zig).to include("error.LockTimeout")
      expect(zig).to include("error.Deadlock")
      expect(zig).to include("return error.CheatError")
      expect(zig).to include("defer if (__held")
      expect(zig).to include("const left")
      expect(zig).to include("const right")

      materialization = MIRLoweringCapabilities::WithBindingMaterialization.new(
        bindings: [],
        fallible_clauses: [],
      )
      lowering.send(:materialize_sorted_lock_bindings,
        with_node,
        materialization,
        typed_caps,
        clause,
        "__with_label")

      materialized = materialization.bindings.first
      expect(materialized).to be_a(MIR::SortedLockAcquire)
      expect(MIREmitter.new.emit(materialized)).to include("acquireOrErr")
      expect(materialization.fallible_clauses.map(&:var_name)).to eq(["a", "b"])
    end
  end

  describe "targeted control-flow and ownership lowering" do
    it "lowers atomic compound writes through the mutable scalar parameter cell" do
      target = make_id("c", full_type: :Int64)
      amount = make_lit(:INT64, 3, full_type: :Int64)
      value = AST::BinaryOp.new(tok, target, :ADD, amount)
      node = AST::BindExpr.new(tok, "c", nil, value)
      node.compound_op = :ADD
      node.auto_atomic_op = :fetchAdd
      low = lowering
      install_function_context(low, mutable_scalar_params: Set["c"])

      result = low.lower(node)

      expect(result).to be_a(MIR::ExprStmt)
      expect(result.discard).to be(true)
      expect(emit(result)).to eq("_ = _m_c.*.fetchAdd(3);")
    end

    it "lowers atomic stores without discarding a return value" do
      node = AST::BindExpr.new(tok, "c", nil, make_lit(:INT64, 5, full_type: :Int64))
      node.auto_atomic_op = :store

      result = lowering.lower(node)

      expect(result).to be_a(MIR::ExprStmt)
      expect(result.discard).to be(false)
      expect(emit(result)).to eq("c.*.store(5);")
    end

    it "adds release defers and loop marks to WHILE RESOLVE bindings" do
      link = make_id("weak_node", full_type: :"Node@link")
      cond = AST::ResolveNode.new(tok, link)
      cond.full_type = Type.new(:"?Node@multiowned")
      node = AST::WhileBindLoop.new(tok, cond, "node", tok, [AST::ContinueNode.new(tok)], nil)
      node.mark_per_iter = true
      low = lowering
      install_function_context(low, has_rt: true)

      result = low.lower(node)

      expect(result).to be_a(MIR::WhileStmt)
      expect(result.capture).to eq("node")
      body_zig = result.body.map { |stmt| emit(stmt) }.join("\n")
      expect(emit(result.cond)).to include("CheatLib.weakRcUpgrade")
      expect(body_zig).to include("saveLoopMark")
      expect(body_zig).to include("restoreLoopMark")
      expect(body_zig).not_to include("checkYield")
    end

    it "adds release defers to IF RESOLVE bindings before the then body" do
      link = make_id("weak_node", full_type: :"Node@link")
      cond = AST::ResolveNode.new(tok, link)
      cond.full_type = Type.new(:"?Node@multiowned")
      node = AST::IfBind.new(tok, [AST::Binding.new(expr: cond, name: "node", name_token: tok)], [AST::BreakNode.new(tok)], nil)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::IfBindStmt)
      then_zig = result.then_body.map { |stmt| emit(stmt) }.join("\n")
      expect(emit(result.bindings.first[:expr])).to include("CheatLib.weakRcUpgrade")
      expect(result.then_body[0]).to be_a(MIR::AllocMark)
      expect(result.then_body[0].name).to eq("node")
      expect(result.then_body[1]).to be_a(MIR::Cleanup)
      expect(result.then_body[1].name).to eq("node")
      expect(then_zig).to include("break;")
    end

    it "attributes IF-bind alias field map writes to the captured owner" do
      mir = lower_source_mir(<<~CLEAR)
        STRUCT Env { vars: {String}Int64 }

        FN main() RETURNS Void ->
          MUTABLE pool: [Pool(4)]Env = [];
          id: Id<Env> = &pool.insert(Env{ vars: {} });
          IF pool[id] EXISTS AS env THEN
            env.vars["a"] = 1_i64;
          END
          RETURN;
        END
      CLEAR

      puts = collect_mir_nodes(mir, MIR::ShardedMapPut)

      expect(puts.map(&:target_var)).to include("pool")
      expect(puts.map(&:target_var)).not_to include("env")
    end

    it "stamps frame allocation scopes inside IF-bind bodies" do
      mark = MIR::AllocMark.new("tmp", :frame, Type.new(:String), :iteration)
      if_bind = MIR::IfBindStmt.new([{ expr: MIR::Ident.new("maybe"), capture: "value" }], [mark], nil)

      lowering.send(:stamp_loop_frame_alloc_scopes!, [if_bind], :function)

      expect(mark.scope).to eq(:function)
    end

    it "lowers FOR EACH over maps through keyIterator optional binding" do
      coll = make_id("scores", full_type: :"HashMap<Int64>")
      node = AST::ForEach.new(tok, "name", coll, [AST::ContinueNode.new(tok)], nil, false)
      low = lowering
      install_function_context(low, has_rt: true)

      result = low.lower(node)

      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("var __kit_")
      expect(zig).to include("scores.keyIterator()")
      expect(zig).to include("while (__kit_")
      expect(zig).to include(") |__key_ptr_")
      expect(zig).to include("const name = __key_ptr_")
    end

    it "lowers FOR EACH over bounded streams with deinit and nextOrNull" do
      coll = make_id("stream", full_type: :"~Int64[4]")
      node = AST::ForEach.new(tok, "item", coll, [AST::BreakNode.new(tok)], nil, false)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("defer stream.deinit()")
      expect(zig).to include("while (try stream.nextOrNull()) |item|")
    end

    it "lowers FOR EACH over fixed SOA arrays through indexed get" do
      soa_type = Type.new(:"Point[4]")
      soa_type.mark_soa_layout!
      coll = make_id("points", full_type: soa_type)
      node = AST::ForEach.new(tok, "point", coll, [AST::BreakNode.new(tok)], nil, false)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::ScopeBlock)
      init = result.body.first
      expect(init).to be_a(MIR::Let)
      expect(init.name).to start_with("__soa_idx_")
      loop = result.body[1]
      expect(loop).to be_a(MIR::WhileStmt)
      bind = loop.body.first
      expect(bind).to be_a(MIR::Let)
      expect(bind.name).to eq("point")
      expect(bind.init).to be_a(MIR::MethodCall)
      expect(bind.init.method).to eq("get")
    end

    it "uses ItemsAccess for list parameters in FOR EACH" do
      coll = make_id("items", full_type: :"Int64[]@list")
      node = AST::ForEach.new(tok, "item", coll, [AST::BreakNode.new(tok)], nil, false)
      low = lowering
      install_function_context(low, param_names: Set["items"])

      result = low.lower(node)

      expect(result).to be_a(MIR::ForStmt)
      expect(result.iter).to be_a(MIR::ItemsAccess)
      expect(emit(result)).to include('if (@hasField(@TypeOf(__x), "items")) __x.items else @constCast(__x[0..])')
    end
  end

  # =========================================================================
  # Phase 3: FuncCall / MethodCall
  # =========================================================================

  describe "function calls" do
    it "does not invent ownership cleanup for copy-only union call results" do
      mir = lower_source_mir(<<~CLEAR)
        STRUCT Box { value: Int64 }
        UNION Item { Boxed: Box, Raw: Int64, Empty }

        FN makeItem(i: Int64) RETURNS Item ->
          RETURN Item{ Raw: i };
        END

        FN scoreItem(item: Item) RETURNS Int64 ->
          PARTIAL MATCH item START
            Item.Raw AS v -> RETURN v;,
            DEFAULT -> RETURN 0_i64;
          END
          RETURN 0_i64;
        END

        FN main() RETURNS Void ->
          MUTABLE total = 0_i64;
          MUTABLE i = 0_i64;
          WHILE i < 3_i64 DO
            total = total + scoreItem(makeItem(i));
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR

      expect_checker_clean(mir)
      main = mir.items.find { |item| item.is_a?(MIR::FnDef) && item.name == "clearMain" }
      alloc_names = collect_mir_nodes(main.body, MIR::AllocMark).map(&:name)
      expect(alloc_names).not_to include(a_string_matching(/__tmp/))
    end

    it "treats owned-return calls as allocating even when the result type is scalar-shaped" do
      call = MIR::Call.new("ownedScalar", [], false, true)
      call.result_type = Type.new(:Int64)

      expect(lowering.send(:mir_allocates?, call)).to be(true)
    end

    it "keeps owned provenance for TAKES arguments wrapped in ItemsAccess" do
      list_type = Type.new(:String, collection: :list, location: :heap)
      arg = make_id("initCaps", full_type: list_type)
      sig = FunctionSignature.new(
        params: [AST::Param.new(name: "initCaps", type: list_type, takes: true)],
        return_type: Type.new(:Void),
      )
      lowered_arg = MIR::ItemsAccess.new(MIR::Ident.new("__tmp_1"), true)

      contract = lowering.callable_contract_for_lowered_args(sig, [arg], [lowered_arg])

      operands = T.must(contract).ownership_contract.operands
      expect(operands.map(&:name)).to eq(["__tmp_1"])
      expect(operands.map(&:target_alloc)).to eq([:heap])
    end

    it "lowers simple function call with rt and try" do
      arg = make_lit(:NUMBER, 42, full_type: :Int64)
      arg.coerced_type = :Int64
      node = AST::FuncCall.new(tok, "compute", [arg])
      node.full_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Call)
      zig = emit(result)
      expect(zig).to include("try compute(rt, 42)")
    end

    it "lowers call without rt when fn_sig says needs_rt=false" do
      sig = FunctionSignature.new(params: [], return_type: Type.new(:Int64), needs_rt: false, can_fail: false)
      l = lowering(fn_sigs: { "pure" => sig })
      node = AST::FuncCall.new(tok, "pure", [])
      node.full_type = :Int64
      result = l.lower(node)
      zig = emit(result)
      expect(zig).to eq("pure()")
    end

    it "passes stack struct by value — SROA candidate, no const-ptr" do
      # Structs with no heap provenance live on the stack. Zig/LLVM SROAs them
      # into registers. Do NOT pass by *const T — that would prevent SROA.
      sig = FunctionSignature.new(
        params: [AST::Param.new(name: "p", type: :Point, mutable: false, takes: false)],
        return_type: Type.new(:Int64),
        needs_rt: false,
        can_fail: false
      )
      l = lowering(
        fn_sigs: { "sum3" => sig },
        struct_schemas: { Point: Schemas::StructSchema.new(fields: { "x" => :Int64, "y" => :Int64 }) }
      )
      arg = make_id("point", full_type: :Point)
      node = AST::FuncCall.new(tok, "sum3", [arg])
      node.full_type = :Int64
      result = l.lower(node)
      expect(emit(result)).to eq("sum3(point)")
    end

    it "uses the uniform fallible ABI for function variable calls" do
      arg = make_lit(:NUMBER, 5, full_type: :Int64)
      arg.coerced_type = :Int64
      node = AST::FuncCall.new(tok, "callback", [arg])
      node.full_type = :Int64
      node.fn_var_call = true

      result = lowering.lower(node)

      expect(result).to be_a(MIR::Call)
      expect(result.callee).to eq("try callback")
      expect(result.args.map { |a| emit(a) }).to eq(["rt", "5"])
    end

    it "uses try for fallible function variable calls" do
      arg = make_lit(:NUMBER, 5, full_type: :Int64)
      arg.coerced_type = :Int64
      node = AST::FuncCall.new(tok, "callback", [arg])
      node.full_type = Type.new(:"!Int64")
      node.fn_var_call = true
      node.matched_signature = FunctionSignature.new(
        params: [AST::Param.new(name: "value", type: :Int64)],
        return_type: Type.new(:"!Int64")
      )

      result = lowering.lower(node)

      expect(result).to be_a(MIR::Call)
      expect(result.callee).to eq("try callback")
      expect(result.args.map { |a| emit(a) }).to eq(["rt", "5"])
    end

    it "wraps heap-duped function results in DupeSlice" do
      node = AST::FuncCall.new(tok, "name", [])
      node.full_type = :String
      node.heap_dupe_result = true

      result = lowering.lower(node)

      expect(result).to be_a(MIR::DupeSlice)
      expect(result.alloc).to eq(:heap)
      expect(result.source).to be_a(MIR::Call)
    end

    it "passes mutable scalar arguments by address when the callee requires mutation" do
      arg = make_id("count", full_type: :Int64)
      node = AST::FuncCall.new(tok, "bump", [arg])
      node.full_type = :Void
      sig = FunctionSignature.new(
        params: [AST::Param.new(name: "count", type: Type.new(:Int64), mutable: true)],
        return_type: Type.new(:Void),
        needs_rt: false
      )

      result = lowering(fn_sigs: { "bump" => sig }).lower(node)

      expect(result).to be_a(MIR::Call)
      expect(result.args.last).to be_a(MIR::AddressOf)
      expect(emit(result.args.last)).to eq("&count")
    end

    it "passes generic type args before runtime and value args" do
      arg = make_lit(:NUMBER, 7, full_type: :Int64)
      arg.coerced_type = :Int64
      node = AST::FuncCall.new(tok, "identity", [arg])
      node.full_type = :Int64
      node.generic_type_args = [:Int64]
      sig = FunctionSignature.new(
        params: [AST::Param.new(name: "x", type: Type.new(:Int64))],
        return_type: Type.new(:Int64),
        needs_rt: true
      )

      result = lowering(fn_sigs: { "identity" => sig }).lower(node)

      expect(result).to be_a(MIR::Call)
      expect(result.args.map { |a| emit(a) }).to eq(["i64", "rt", "7"])
    end

    it "lowers method call as UFCS" do
      obj = make_id("user", full_type: :User)
      node = AST::MethodCall.new(tok, obj, "greet", [])
      node.full_type = :String
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Call)
      zig = emit(result)
      expect(zig).to include("try greet(rt, user)")
    end

    it "lowers intrinsic with zig_pattern" do
      arg = make_id("x", full_type: :Int64)
      node = AST::FuncCall.new(tok, "toString", [arg])
      node.full_type = :String
      node.zig_pattern = "try CheatLib.intToString({alloc}, {0})"
      sig = FunctionSignature.new(
        params: [],
        return_type: Type.new(:String),
        intrinsic: true,
        emit: IntrinsicEmit.new(zig: "try CheatLib.intToString({alloc}, {0})", alloc: :frame)
      )
      node.matched_stdlib_def = sig
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RegistryCall)
      zig = emit(result)
      expect(zig).to include("CheatLib.intToString")
      expect(zig).to include("frameAlloc")
    end
  end

  # =========================================================================
  # Phase 3: ListLit / HashLit
  # =========================================================================

  describe "list literals" do
    it "lowers empty list as empty slice" do
      node = AST::ListLit.new(tok, [], nil)
      node.full_type = Type.new(:"Int64[]")
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("i64")
    end

    it "lowers non-empty list as MakeList" do
      items = [make_lit(:NUMBER, 1, full_type: :Int64), make_lit(:NUMBER, 2, full_type: :Int64)]
      items.each { |i| i.coerced_type = :Int64 }
      node = AST::ListLit.new(tok, items, nil)
      node.full_type = Type.new(:"Int64[]")
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("makeList")
    end

    it "wraps non-empty @list literals in declared sync and ownership capabilities" do
      items = [make_lit(:NUMBER, 1, full_type: :Int64), make_lit(:NUMBER, 2, full_type: :Int64)]
      items.each { |i| i.coerced_type = :Int64 }
      node = AST::ListLit.new(tok, items, nil)
      node.full_type = Type.new(:"Int64[]", collection: :list, ownership: :shared, sync: :locked)

      low = lowering
      result = low.send(:with_expected_type, node.full_type) { low.lower(node) }
      zig = emit(result)
      expect(result).to be_a(MIR::CapWrap)
      expect(zig).to include("CheatLib.lockedCreate(std.ArrayListUnmanaged(i64)")
      expect(zig).to include("CheatLib.arcCreate(CheatLib.Locked(std.ArrayListUnmanaged(i64))")
    end
  end

  describe "hash literals" do
    it "lowers empty hash as map_bare" do
      node = AST::HashLit.new(tok, [], :heap)
      node.full_type = :StringMap
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include(".alloc =")
    end
  end

  # =========================================================================
  # Phase 3: Lambda
  # =========================================================================

  describe "lambda literals" do
    it "lowers lambda to LambdaExpr" do
      body = make_lit(:NUMBER, 42, full_type: :Int64)
      body.coerced_type = :Int64
      node = AST::LambdaLit.new(tok, [], nil, body, nil, nil)
      node.full_type = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
      result = lowering.lower(node)
      expect(result).to be_a(MIR::LambdaExpr)
      zig = emit(result)
      expect(zig).to include("struct")
      expect(zig).to include("_lambda_")
      expect(zig).to include("return 42")
    end

    it "normalizes named lambda captures into capture names" do
      body = make_lit(:NUMBER, 42, full_type: :Int64)
      body.coerced_type = :Int64
      capture = AST::Identifier.new(tok, "outer")
      node = AST::LambdaLit.new(tok, [], nil, body, nil, nil)
      node.captures = [capture]
      node.full_type = FunctionSignature.new(params: [], return_type: Type.new(:Int64))

      result = lowering.lower(node)

      expect(result.captures).to eq(["outer"])
    end
  end

  # =========================================================================
  # Phase 3: Escape hatch nodes
  # =========================================================================

  describe "escape hatch nodes" do
    it "lowers ThrowNode" do
      node = AST::ThrowNode.new(tok, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(emit(result)).to include("return error.CheatError")
    end

    it "lowers Cast" do
      inner = make_lit(:NUMBER, 42, full_type: :Int64)
      inner.coerced_type = :Int64
      node = AST::Cast.new(tok, inner, :Int32)
      node.full_type = :Int32
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Cast)
      expect(emit(result)).to eq("@as(i32, 42)")
    end

    it "detects enum casts through Type wrapper payloads" do
      inner = make_lit(:INT64, 1, full_type: :Int64)
      inner.coerced_type = :Int64
      node = AST::Cast.new(tok, inner, Type.new(:"!?Mode"))
      node.full_type = Type.new(:"!?Mode")

      result = lowering(enum_schemas: { Mode: ["Fast", "Slow"] }).lower(node)

      expect(result).to be_a(MIR::Cast)
      expect(result.method).to eq(:enumFromInt)
    end

    it "lowers DieNode" do
      node = AST::DieNode.new(tok, 2)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(emit(result)).to include("std.process.exit(2)")
    end

    it "lowers PassStmt" do
      node = AST::PassStmt.new(tok)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Noop)
    end
  end

  # =========================================================================
  # Phase 4: WithBlock
  # =========================================================================

  describe "WithBlock lowering" do
    it "lowers multiowned capability unwrap" do
      var_node = make_id("counter", full_type: :Counter)
      cap = { var_node: var_node, alias: nil, capability: :multiowned, resolved_type: nil }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void
      attach_capability_plan!(node)

      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("__counter_unwrap")
      expect(zig).to include("ctrl.data.*")
    end

    it "lowers shared capability unwrap" do
      var_node = make_id("counter", full_type: :Counter)
      cap = { var_node: var_node, alias: nil, capability: :shared, resolved_type: nil }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void
      attach_capability_plan!(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("__counter_unwrap")
      expect(zig).to include("ctrl.data.*")
    end

    it "lowers EXCLUSIVE mutex capability with acquire/release" do
      var_node = make_id("counter", full_type: :Counter, sync: :locked)
      resolved = Type.new(:Counter, sync: :locked)
      cap = { var_node: var_node, alias: "c", capability: :EXCLUSIVE, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void
      attach_capability_plan!(node)

      result = lowering.lower(node)
      zig = emit(result)
      guard = zig[/var (__counter_guard_[A-Za-z0-9_]+) =/, 1]
      expect(guard).not_to be_nil
      expect(zig).to include(".acquire()")
      expect(zig).to include("defer #{guard}.release()")
      expect(zig).to include("const c =")
    end

    it "lowers EXCLUSIVE write_locked capability with write()" do
      var_node = make_id("counter", full_type: :Counter, sync: :write_locked)
      resolved = Type.new(:Counter, sync: :write_locked)
      cap = { var_node: var_node, alias: "c", capability: :EXCLUSIVE, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void
      attach_capability_plan!(node)

      result = lowering.lower(node)
      zig = emit(result)
      guard = zig[/var (__counter_guard_[A-Za-z0-9_]+) =/, 1]
      expect(guard).not_to be_nil
      expect(zig).to include(".write()")
      expect(zig).to include("defer #{guard}.release()")
    end

    it "lowers write_locked_read capability with read()" do
      var_node = make_id("counter", full_type: :Counter, sync: :write_locked)
      resolved = Type.new(:Counter, sync: :write_locked)
      cap = { var_node: var_node, alias: "c", capability: :write_locked_read, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void
      attach_capability_plan!(node)

      result = lowering.lower(node)
      zig = emit(result)
      guard = zig[/var (__counter_guard_[A-Za-z0-9_]+) =/, 1]
      expect(guard).not_to be_nil
      expect(zig).to include(".read()")
      expect(zig).to include("defer #{guard}.release()")
    end

	    it "lowers BORROWED capability" do
	      var_node = make_id("data", full_type: :Data)
	      cap = { var_node: var_node, alias: "d", capability: :BORROWED, resolved_type: nil }
	      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
	      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void
      attach_capability_plan!(node)

      result = lowering.lower(node)
	      zig = emit(result)
	      expect(zig).to include("const d = data")
	    end

	    it "dereferences borrowed list parameters at the pointer-shaped ABI boundary" do
	      array_type = Type.array_of(:Int64)
	      var_node = make_id("data", full_type: array_type)
	      symbol = SymbolEntry.new(reg: "data", type: array_type, mutable: false, storage: :stack)
	      symbol.is_param = true
	      var_node.symbol = symbol
	      cap = { var_node: var_node, alias: "ref", capability: :BORROWED, resolved_type: array_type }
	      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
	      body_lit.coerced_type = :Int64
	      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
	      node.full_type = :Void
	      attach_capability_plan!(node)

	      result = lowering.lower(node)
	      zig = emit(result)
	      expect(zig).to include("const ref = data.*;")
	    end

	    it "lowers RESTRICT capability" do
	      var_node = make_id("buf", full_type: :Buffer)
	      resolved = Type.new(:Buffer)
	      cap = { var_node: var_node, alias: "b", capability: :RESTRICT, alias_mutable: false, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void
      attach_capability_plan!(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("const b = buf")
    end

    it "lowers RESTRICT mutable capability with pointer" do
      var_node = make_id("buf", full_type: :Buffer)
      resolved = Type.new(:Buffer)
      cap = { var_node: var_node, alias: "b", capability: :RESTRICT, alias_mutable: true, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void
      attach_capability_plan!(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("const b = &buf")
    end

    it "lowers empty WithBlock" do
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [], [body_lit], nil)
      node.full_type = :Void
      attach_capability_plan!(node)

      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      expect(result.body).not_to be_empty
    end
  end

  # =========================================================================
  # Phase 4: DoBlock
  # =========================================================================

  describe "DoBlock lowering" do
    it "lowers single-branch DoBlock with WaitGroup" do
      body_lit = make_lit(:NUMBER, 42, full_type: :Int64)
      body_lit.coerced_type = :Int64
      branch = AST::DoBranch.new(
        body: [body_lit],
        capture_analysis: nil,
        pinned: false,
        stack_size: nil,
        computed_stack_tier: nil,
      )
      node = AST::DoBlock.new(tok, [branch])
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::DoBlock)
      expect(result.code).to be_a(MIR::DoBlockPlan)
      expect(result.code.branches.first).to be_a(MIR::DoBranchPlan)
      zig = emit(result)
      expect(zig).to include("WaitGroup")
      expect(zig).to include(".add(1)")
      expect(zig).to include(".wait()")
      expect(zig).to include("__DoBranchCtx")
      expect(zig).to include("fn run(")
      expect(zig).to include("&__do0_ctx0")
    end

    it "lowers multi-branch DoBlock" do
      lit1 = make_lit(:NUMBER, 1, full_type: :Int64)
      lit1.coerced_type = :Int64
      lit2 = make_lit(:NUMBER, 2, full_type: :Int64)
      lit2.coerced_type = :Int64
      branches = [
        AST::DoBranch.new(body: [lit1], capture_analysis: nil, pinned: false, stack_size: nil, computed_stack_tier: nil),
        AST::DoBranch.new(body: [lit2], capture_analysis: nil, pinned: true, stack_size: nil, computed_stack_tier: nil),
      ]
      node = AST::DoBlock.new(tok, branches)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("__DoBranchCtx")
      # Per-spawn add(1) replaces upfront add(N); errdefer guards partial-spawn failures.
      expect(zig).to include(".add(1)")
      expect(zig).not_to include(".add(2)")
      expect(zig).to include("errdefer")
      # Pinned branch uses submitSpawn, unpinned uses spawnBest
      expect(zig).to include("spawnBest")
      expect(zig).to include("submitSpawn")
      expect(zig).to include("&__do0_ctx0")
      expect(zig).to include("&__do0_ctx1")
    end

    it "lowers DoBlock with captures" do
      body_id = make_id("x", full_type: :Int64)
      captures_hash = { "x" => :Int64 }
      analysis = capture_analysis(captures: captures_hash)
      branch = AST::DoBranch.new(
        body: [body_id],
        capture_analysis: analysis,
        pinned: false,
        stack_size: nil,
        computed_stack_tier: nil,
      )
      node = AST::DoBlock.new(tok, [branch])
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      # Same pattern as BG: @TypeOf for the field type, direct value
      # init, no deref in body. Replaces the previous *const T + &name
      # + ctx.x.* triplet that diverged from BG codegen.
      expect(zig).to include("x: @TypeOf(x)")
      expect(zig).to include(".x = x")
    end

    it "merges nested BG capture analysis into the DoBlock context" do
      nested_body = make_id("inner", full_type: :Int64)
      nested_analysis = capture_analysis(
        captures: { "inner" => :Int64 },
        capture_symbols: {},
        close_plans: {},
        pointer_captures: Set.new,
        string_captures: Set.new,
        resource_captures: Set.new
      )
      nested_bg = AST::BgBlock.new(tok, [nested_body], nil, nil, nil, nil, nil, nil)
      nested_bg.full_type = :"~Void"
      nested_bg.capture_analysis = nested_analysis

      branch_analysis = capture_analysis(
        captures: {},
        capture_symbols: {},
        close_plans: {},
        pointer_captures: Set.new,
        string_captures: Set.new,
        resource_captures: Set.new
      )
      branch = AST::DoBranch.new(
        body: [nested_bg],
        capture_analysis: branch_analysis,
        pinned: false,
        stack_size: nil,
        computed_stack_tier: nil,
      )
      node = AST::DoBlock.new(tok, [branch])
      node.full_type = :Void

      zig = emit(lowering.lower(node))
      expect(zig).to include("inner: @TypeOf(inner)")
      expect(zig).to include(".inner = inner")
      expect(zig).to match(/(?:_ = try __discard_bg_\d+\.next\(\);|const __tmp_\d+ = try __discard_bg_\d+\.next\(\);\s+_ = __tmp_\d+;)/)
      expect(zig).to include(".next()")
    end

    it "flattens array-lowered DoBlock body declarations" do
      locked_type = Type.new(:Counter, sync: :locked)
      inner = make_id("src", full_type: locked_type)
      copy = AST::CopyNode.new(tok, inner)
      copy.full_type = locked_type
      decl = AST::VarDecl.new(tok, "dst", nil, copy, false)
      decl.full_type = locked_type
      decl.var_used = true
      decl.symbol = SymbolEntry.new(reg: "dst", type: locked_type,
                                    mutable: true, storage: :stack, sync: :locked)
      branch = AST::DoBranch.new(
        body: [decl],
        capture_analysis: nil,
        pinned: false,
        stack_size: nil,
        computed_stack_tier: nil,
      )
      node = AST::DoBlock.new(tok, [branch])
      node.full_type = :Void

      # Cleanup recipe inherited from the classifier (INV-14), as the pipeline
      # wires it -- not the removed destination-synthesis fallback.
      fn = AST::FunctionDef.new(tok, "f", [], nil, :Void, nil, [decl],
                                nil, nil, nil, nil, false)
      low = lowering
      low.function_state.current_bindings =
        CleanupClassifier.classify(fn, schema_lookup: ->(_) { nil })

      zig = emit(low.lower(node))
      expect(zig).to include("blk_copy_")
      expect(zig).to include("try CheatLib.dupeValue")
      expect(zig).to include("defer CheatLib.cleanup(@TypeOf(dst), __rt.heapAlloc(), &dst)")
    end

    it "lowers DoBlock with stack tier" do
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      branch = AST::DoBranch.new(
        body: [body_lit],
        capture_analysis: nil,
        pinned: false,
        stack_size: nil,
        computed_stack_tier: :large,
      )
      node = AST::DoBlock.new(tok, [branch])
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("stack_size = .Large")
    end
  end

  # =========================================================================
  # Phase 4: BgBlock
  # =========================================================================

  describe "BgBlock lowering" do
    it "lowers void BgBlock with promise spawn" do
      body_lit = make_lit(:NUMBER, 42, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::BgBlock.new(tok, [body_lit], nil, nil, nil, nil, nil, nil)
      node.full_type = :"~Void"

      result = lowering.lower(node)
      expect(result).to be_a(MIR::BgBlock)
      expect(result.code).to be_a(MIR::BgStackfulPlan)
      zig = emit(result)
      expect(zig).to include("__BgCtx")
      expect(zig).to include(".spawn(")
      expect(zig).to include("fn run(")
      expect(zig).to include("submitSpawn")
      expect(zig).to include(".profile_dispatch = 1")
      expect(zig).not_to include("spawnBest")
    end

    it "lowers BgBlock with captures" do
      body_id = make_id("x", full_type: :Int64)
      captures_hash = { "x" => :Int64 }
      analysis = capture_analysis(
        captures: captures_hash,
        capture_symbols: {},
        close_plans: {},
        pointer_captures: Set.new(["x"]),
        string_captures: Set.new,
        resource_captures: Set.new
      )
      node = AST::BgBlock.new(tok, [body_id], nil, nil, nil, nil, nil, nil)
      node.full_type = :"~Void"
      node.capture_analysis = analysis

      result = lowering.lower(node)
      zig = emit(result)
      # Pointer captures (HashMap, @pool, @sharded:locked, ...) flow as
      # `*T` into the fiber context so writes inside the fiber land on
      # the outer instance. Without this the fiber operates on a value
      # copy and per-shard locks become independent mutexes -- writes
      # never appear to outer readers (regressed examples/graphdb).
      expect(zig).to include("x: @TypeOf(&x)")
      expect(zig).to include(".x = &x")
    end

    it "keeps nested BG pointer capture initializers pointed at rewritten outer refs" do
      body_id = make_id("x", full_type: :Int64)
      analysis = capture_analysis(
        captures: { "x" => :Int64 },
        capture_symbols: {},
        close_plans: {},
        pointer_captures: Set["x"],
        string_captures: Set.new,
        resource_captures: Set.new
      )
      node = AST::BgBlock.new(tok, [body_id], nil, nil, nil, nil, nil, nil)
      node.full_type = :"~Void"
      node.capture_analysis = analysis
      low = lowering
      low.capture_state.do_capture_map = { "x" => "__ctx_outer.x" }

      zig = emit(low.lower(node))

      expect(zig).to include("x: @TypeOf(&__ctx_outer.x)")
      expect(zig).to include(".x = &__ctx_outer.x")
    ensure
      low&.capture_state&.do_capture_map = nil
    end

    it "lowers pinned BgBlock with submitSpawn" do
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::BgBlock.new(tok, [body_lit], nil, nil, true, nil, nil, nil)
      node.full_type = :"~Void"

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("submitSpawn")
      expect(zig).not_to include("spawnBest")
    end

    it "lowers BgBlock with arena mode" do
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::BgBlock.new(tok, [body_lit], nil, nil, nil, nil, true, nil)
      node.full_type = :"~Void"

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("arena_mode = true")
    end

    it "lowers BgBlock with stack tier" do
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::BgBlock.new(tok, [body_lit], nil, nil, nil, nil, nil, nil)
      node.full_type = :"~Void"
      node.computed_stack_tier = :large

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("stack_size = .Large")
    end

    it "flattens ThenChain in BgBlock body" do
      step1 = make_lit(:NUMBER, 1, full_type: :Int64)
      step1.coerced_type = :Int64
      step2 = make_lit(:NUMBER, 2, full_type: :Int64)
      step2.coerced_type = :Int64
      chain = AST::ThenChain.new(tok, [
        AST::ThenStep.new(expr: step1, binding: "a"),
        AST::ThenStep.new(expr: step2, binding: nil),
      ])
      chain.full_type = :Int64
      node = AST::BgBlock.new(tok, [chain], nil, nil, nil, nil, nil, nil)
      node.full_type = :"~Void"

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("const a = 1")
    end
  end

  # =========================================================================
  # Phase 4: BgStreamBlock + Yield
  # =========================================================================

  describe "BgStreamBlock lowering" do
    it "lowers basic stream generator" do
      yield_expr = make_lit(:NUMBER, 42, full_type: :Int64)
      yield_expr.coerced_type = :Int64
      yield_node = AST::YieldExpr.new(tok, yield_expr)
      yield_node.full_type = :Void
      node = AST::BgStreamBlock.new(tok, [yield_node], nil, nil)
      node.full_type = :"~?Void[]"

      result = lowering.lower(node)
      expect(result).to be_a(MIR::BgBlock)
      expect(result.code).to be_a(MIR::BgStreamPlan)
      zig = emit(result)
      expect(zig).to include("__SgCtx")
      expect(zig).to include("spawnNew")
      expect(zig).to include(".close()")
      expect(zig).to include(".push(")
    end

    it "refuses unsafe BG STREAM captures with ownership-specific guidance" do
      node = AST::BgStreamBlock.new(tok, [], nil, nil)
      node.full_type = :"~?Int64[]"
      node.capture_analysis = capture_analysis(
        captures: { "items" => Type.new(:"Int64[]@list") },
        strategies: {
          "items" => CaptureStrategy::Refuse.new(
            reason: :list_borrow_without_transfer,
            owner_name: "items"
          )
        }
      )

      expect { lowering.lower(node) }
        .to raise_error(/BG block captures values.*'items' is @list.*GIVE.*COPY/m)
    end

    it "lowers finite BG STREAM to an eager block for the bytecode backend" do
      yield_expr = make_lit(:INT64, 1, full_type: :Int64)
      yield_node = AST::YieldExpr.new(tok, yield_expr)
      yield_node.full_type = :Void
      node = AST::BgStreamBlock.new(tok, [yield_node], nil, nil)
      node.full_type = :"~?Int64[]"

      result = lowering(target: :bc).lower(node)

      expect(result).to be_a(MIR::BlockExpr)
      expect(result.body.first).to be_a(MIR::Let)
      expect(result.body.first.init).to be_a(MIR::MakeList)
      expect(result.body.last).to be_a(MIR::BreakStmt)
    end

    it "lowers infinite BG STREAM to StreamSpawn for the bytecode backend" do
      yield_expr = make_lit(:INT64, 1, full_type: :Int64)
      yield_node = AST::YieldExpr.new(tok, yield_expr)
      yield_node.full_type = :Void
      node = AST::BgStreamBlock.new(tok, [yield_node], nil, nil)
      node.full_type = :"~Int64[INF]"
      node.capture_analysis = capture_analysis(captures: { "seed" => :Int64 })

      result = lowering(target: :bc).lower(node)

      expect(result).to be_a(MIR::StreamSpawn)
      expect(result.captures).to eq({ "seed" => :Int64 })
    end
  end

  # =========================================================================
  # Phase 4: YieldExpr (standalone)
  # =========================================================================

  describe "YieldExpr lowering" do
    it "lowers yield outside stream context" do
      expr = make_lit(:NUMBER, 7, full_type: :Int64)
      expr.coerced_type = :Int64
      node = AST::YieldExpr.new(tok, expr)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::MethodCall)
      zig = emit(result)
      expect(zig).to include("try __stream_local.push(7)")
    end
  end

  # =========================================================================
  # Phase 4: NextExpr
  # =========================================================================

  describe "NextExpr lowering" do
    it "rejects scalar NEXT when annotation did not publish its operation plan" do
      inner = make_id("promise", full_type: :"~Int64")
      node = AST::NextExpr.new(tok, inner)
      node.full_type = :Int64

      expect { lowering.lower(node) }.to raise_error(
        RuntimeError,
        /scalar NEXT lowering requires its annotation-produced TenseOperationPlan/,
      )
    end

    it "lowers NEXT expression" do
      inner = make_id("promise", full_type: :"~Int64")
      node = AST::NextExpr.new(tok, inner)
      node.full_type = :Int64
      node.tense_plan = TenseOperationPlanner.next_value(Type.new(:"~Int64"))

      result = lowering.lower(node)
      expect(result).to be_a(MIR::MethodCall)
      zig = emit(result)
      expect(zig).to include("try promise.next()")
    end

    it "temps non-identifier stream receivers before NEXT" do
      source = AST::StaticCall.new(tok, "Streams", "source", [])
      source.full_type = Type.new(:"~Int64[INF]")
      source.zig_pattern = "makeStream()"
      source_sig = FunctionSignature.new(
        params: [],
        return_type: source.full_type!,
        intrinsic: true,
        emit: IntrinsicEmit.new(zig: "makeStream()")
      )
      source.matched_stdlib_def = source_sig
      node = AST::NextExpr.new(tok, source)
      node.full_type = Type.new(:Int64)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::BlockExpr)
      expect(result.label).to start_with("__next_recv_")
      temp = result.body.first
      expect(temp).to be_a(MIR::Let)
      expect(temp.init).to be_a(MIR::RegistryCall)
      expect(result.body.last).to be_a(MIR::BreakStmt)
      expect(result.result_type).to eq(Type.new(:Int64))
    end
  end

  # =========================================================================
  # Phase 4: StaticCall
  # =========================================================================

  describe "StaticCall lowering" do
    it "lowers static call with pattern substitution" do
      arg = make_lit(:NUMBER, 10, full_type: :Int64)
      arg.coerced_type = :Int64
      node = AST::StaticCall.new(tok, "Math", "sqrt", [arg])
      node.full_type = :Number
      node.zig_pattern = "std.math.sqrt({0})"
      sig = FunctionSignature.new(
        params: [],
        return_type: Type.new(:Number),
        intrinsic: true,
        emit: IntrinsicEmit.new(zig: "std.math.sqrt({0})")
      )
      node.matched_stdlib_def = sig

      result = lowering.lower(node)
      expect(result).to be_a(MIR::RegistryCall)
      zig = emit(result)
      expect(zig).to eq("std.math.sqrt(10)")
    end

    it "lowers static call with multiple args" do
      arg0 = make_lit(:NUMBER, 1, full_type: :Int64)
      arg0.coerced_type = :Int64
      arg1 = make_lit(:NUMBER, 2, full_type: :Int64)
      arg1.coerced_type = :Int64
      node = AST::StaticCall.new(tok, "Math", "max", [arg0, arg1])
      node.full_type = :Number
      node.zig_pattern = "std.math.max({0}, {1})"
      sig = FunctionSignature.new(
        params: [],
        return_type: Type.new(:Number),
        intrinsic: true,
        emit: IntrinsicEmit.new(zig: "std.math.max({0}, {1})")
      )
      node.matched_stdlib_def = sig

      result = lowering.lower(node)
      expect(result).to be_a(MIR::RegistryCall)
      zig = emit(result)
      expect(zig).to eq("std.math.max(1, 2)")
    end

    it "rejects static calls without matched stdlib metadata" do
      node = AST::StaticCall.new(tok, "Math", "missing", [])
      node.full_type = :Number

      expect { lowering.send(:lower_static_call, node) }
        .to raise_error(/lower_static_call: missing stdlib signature for AST::StaticCall/)
    end
  end

  # =========================================================================
  # Phase 4: Or* error chains
  # =========================================================================

  describe "Or* error chain lowering" do
    it "lowers OrElseRaise to a structural error value" do
      node = AST::OrElseRaise.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::FieldGet)
      expect(emit(result)).to eq("error.OrElseRaise")
    end

    it "lowers OrElseBreak to BreakStmt" do
      node = AST::OrElseBreak.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::BreakStmt)
      expect(emit(result)).to eq("break;")
    end

    it "lowers OrElsePass to a structural undefined default" do
      node = AST::OrElsePass.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::DefaultValue)
      expect(emit(result)).to eq("undefined")
    end

    it "lowers OrElsePrune to a structural undefined default" do
      node = AST::OrElsePrune.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::DefaultValue)
      expect(emit(result)).to eq("undefined")
    end

    it "lowers OrElseExit with message (pure message override)" do
      # New unified OR_ELSE EXIT: 4-arg (token, kind, error_name, message).
      # Pure "msg" form passes nil kind + nil error_name; lowering
      # inherits both from rt.__error and only updates message.
      msg = make_lit(:STRING, "fatal", full_type: :String)
      node = AST::OrElseExit.new(tok, nil, nil, msg)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("rt.__error.message")
      expect(zig).to include("return error.CheatError")
      # No kind / error_name writes because both were nil.
      expect(zig).not_to include("rt.__error.kind =")
      expect(zig).not_to include("rt.__error.error_name =")
    end

    it "lowers OrElseExit Kind,Type,msg (full override) with direct field writes" do
      msg = make_lit(:STRING, "bad", full_type: :String)
      node = AST::OrElseExit.new(tok, :Input, "ParseErr", msg)
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("rt.__error.kind = .Input")
      expect(zig).to include("rt.__error.error_name = @intFromEnum(ErrorName.ParseErr)")
      expect(zig).to include("rt.__error.message")
      expect(zig).to include("return error.CheatError")
    end

    it "lowers OrElseExit Kind (kind-only) with type cleared to 0" do
      node = AST::OrElseExit.new(tok, :Input, nil, nil)
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("rt.__error.kind = .Input")
      # Kind-without-type clears the stale type explicitly.
      expect(zig).to include("rt.__error.error_name = 0")
    end

    it "builds bytecode OR_ELSE EXIT reassign metadata" do
      facts = MIRLoweringExpressions::OrElseExitFacts.new(
        kind: "Input",
        error_name: nil,
        name_id: 9,
        clear_type: true,
        has_message: true,
        line: 44,
      )
      message = MIR::Lit.new("\"bad\"")

      result = lowering.send(:or_else_exit_bc_reassign, facts, message)

      expect(result).to be_a(MIR::OrElseExitBcRewrite)
      expect(result.kind).to eq("Input")
      expect(result.name_id).to eq(9)
      expect(result.clear_type).to eq(true)
      expect(result.has_message).to eq(true)
      expect(result.line).to eq(44)
      expect(result.message).to eq(message)
    end

    it "lowers OR_ELSE EXIT on fallible expressions to a catch block that rewrites error context" do
      call = AST::FuncCall.new(tok, "parse", [])
      call.full_type = :Int64
      call.error_union_type = Type.new(:"!Int64")
      call.can_fail = true
      exit = AST::OrElseExit.new(tok, :Input, "ParseErr", make_lit(:STRING, "bad", full_type: :String))
      node = AST::BinaryOp.new(tok, call, :OR_ELSE, exit)
      node.full_type = :Int64
      stamp_or_else_plan(node)

      result = lowering.lower(node)
      zig = emit(result)

      expect(result).to be_a(MIR::TryCatch)
      expect(zig).to include("catch |__exit_err|")
      expect(zig).to include("rt.__error.kind = .Input")
      expect(zig).to include("ErrorName.ParseErr")
      expect(zig).to include("return __exit_err")
    end

    it "lowers OR_ELSE fallback to error catch and optional orelse based on left type" do
      fallible = AST::FuncCall.new(tok, "fallible", [])
      fallible.full_type = :Int64
      fallible.error_union_type = Type.new(:"!Int64")
      fallback = make_lit(:INT64, 0, full_type: :Int64)
      error_node = AST::BinaryOp.new(tok, fallible, :OR_ELSE, fallback)
      error_node.full_type = :Int64
      stamp_or_else_plan(error_node)

      maybe = make_id("maybe", full_type: :"?Int64")
      optional_node = AST::BinaryOp.new(tok, maybe, :OR_ELSE, fallback)
      optional_node.full_type = :Int64
      stamp_or_else_plan(optional_node)

      expect(lowering.lower(error_node)).to be_a(MIR::TryCatch)
      expect(lowering.lower(optional_node)).to be_a(MIR::Orelse)
    end

    it "rejects OR_ELSE lowering without its annotation plan" do
      optional = make_id("maybe", full_type: :"?Int64")
      fallback = make_lit(:INT64, 0, full_type: :Int64)
      node = AST::BinaryOp.new(tok, optional, :OR_ELSE, fallback)
      node.full_type = :Int64

      expect { lowering.lower(node) }.to raise_error(RuntimeError, /OR_ELSE lowering requires/)
    end

    it "uses structural OR_ELSE PASS defaults instead of Zig-spelled literals" do
      string_call = AST::FuncCall.new(tok, "fallible_string", [])
      string_call.full_type = Type.new(:"!String")
      string_default = lowering.send(:or_else_pass_fallback, string_call)

      list_call = AST::FuncCall.new(tok, "fallible_list", [])
      list_call.full_type = Type.new(:"!Int64[]", collection: :list)
      list_default = lowering.send(:or_else_pass_fallback, list_call)

      int_call = AST::FuncCall.new(tok, "fallible_int", [])
      int_call.full_type = Type.new(:"!Int64")
      int_default = lowering.send(:or_else_pass_fallback, int_call)

      expect(string_default).to be_a(MIR::DefaultValue)
      expect(T.cast(string_default, MIR::DefaultValue).kind).to eq(:string_empty)
      expect(list_default).to be_a(MIR::DefaultValue)
      expect(T.cast(list_default, MIR::DefaultValue).kind).to eq(:collection_empty)
      expect(int_default).to be_a(MIR::DefaultValue)
      expect(T.cast(int_default, MIR::DefaultValue).kind).to eq(:undefined)
      expect([string_default, list_default, int_default].any? { |node| node.is_a?(MIR::Lit) }).to be(false)
    end

    it "materializes owned OR_ELSE PASS results before stdlib TAKES argument verification" do
      mir = lower_source_mir(<<~CLEAR)
        FN inner() RETURNS !String ->
          MUTABLE v: String = ""; v = v $+ "x";
          RETURN v;
        END

        FN run() RETURNS !Void ->
          MUTABLE outer: []String = [];
          &outer.append(inner() OR_ELSE PASS);
          RETURN;
        END
      CLEAR

      expect_checker_clean(mir)
      consuming_call = collect_mir_nodes(mir, MIR::RegistryCall).find do |call|
        call.ownership_contract.owned_operand_names.any?
      end
      expect(consuming_call).not_to be_nil
      consumed = T.must(consuming_call).ownership_contract.owned_operand_names
      expect(consumed.length).to eq(1)
      expect(consumed.first).to match(/\A__tmp_\d+\z/)
      expect(T.must(consuming_call).args[1].expr).to be_a(MIR::Ident)
    end

    it "lowers OR_ELSE BREAK catch fallback as a structural break expression" do
      fallible = AST::FuncCall.new(tok, "fallible", [])
      fallible.full_type = :Int64
      fallible.error_union_type = Type.new(:"!Int64")
      fallible.can_fail = true
      node = AST::BinaryOp.new(tok, fallible, :OR_ELSE, AST::OrElseBreak.new(tok))
      node.full_type = :Int64
      stamp_or_else_plan(node)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::TryCatch)
      expect(result.catch_body).to be_a(MIR::BreakExpr)
      expect(emit(result)).to eq("(fallible(rt) catch break)")
    end
  end

  # =========================================================================
  # Phase 4: TestBlock
  # =========================================================================

  describe "TestBlock lowering" do
    it "lowers basic test block with WHEN and TEST THAT" do
      body_lit = make_lit(:BOOLEAN, true, full_type: :Boolean)
      assert_node = AST::Assert.new(tok, body_lit, nil)
      assert_node.full_type = :Void
      test_that = AST::TestThat.new(tok, "works", [assert_node])
      when_block = AST::WhenBlock.new(tok, "given input", [], [test_that], [])
      node = AST::TestBlock.new(tok, "MyTest", [], [when_block])
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(Array)
      expect(result.first).to be_a(MIR::TestDef)
      zig = result.map { |t| emit(t) }.join("\n")
      expect(zig).to include('test "MyTest: given input: works"')
      expect(zig).to include("Runtime.init(allocator")
      expect(zig).to include("__rt_box.wireAllocator()")
    end

    it "lowers test block with setup code" do
      setup_lit = make_lit(:NUMBER, 0, full_type: :Int64)
      setup_lit.coerced_type = :Int64
      body_lit = make_lit(:BOOLEAN, true, full_type: :Boolean)
      assert_node = AST::Assert.new(tok, body_lit, nil)
      assert_node.full_type = :Void
      test_that = AST::TestThat.new(tok, "passes", [assert_node])
      when_block = AST::WhenBlock.new(tok, "setup", [], [test_that], [])
      node = AST::TestBlock.new(tok, "WithSetup", [setup_lit], [when_block])
      node.full_type = :Void

      result = lowering.lower(node)
      zig = result.map { |t| emit(t) }.join("\n")
      expect(zig).to include('test "WithSetup: setup: passes"')
    end
  end

  # =========================================================================
  # Phase 4: AssertRaises
  # =========================================================================

  describe "AssertRaises lowering" do
    it "lowers assert raises with kind" do
      expr = make_lit(:BOOLEAN, true, full_type: :Boolean)
      node = AST::AssertRaises.new(tok, :Runtime, nil, expr)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::AssertRaisesCheck)
      zig = emit(result)
      expect(zig).to include("ASSERT_RAISES")
      expect(zig).to include("matchesKind(.Runtime)")
    end

    it "lowers assert raises with kind and error name" do
      expr = make_lit(:BOOLEAN, true, full_type: :Boolean)
      node = AST::AssertRaises.new(tok, :Type, "NotFound", expr)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("matchesKind(.Type)")
      expect(zig).to include('matchesName(@intFromEnum(ErrorName.NotFound))')
    end
  end

  # =========================================================================
  # Phase 4: RequireNode
  # =========================================================================

  describe "RequireNode lowering" do
    it "lowers package require to MIR::Import" do
      node = AST::RequireNode.new(tok, "math", "math", :package)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::Import)
      zig = emit(result)
      expect(zig).to include('@import("math.zig")')
    end

    it "raises on local require when no importer available" do
      node = AST::RequireNode.new(tok, "utils.clear", nil, :local)
      node.full_type = :Void

      expect { lowering.lower(node) }.to raise_error(/no importer available/)
    end

    it "lowers local require to visible type items plus a structural module namespace" do
      imported_fn_ast = AST::FunctionDef.new(tok, "helper_value", [], nil, :Void, nil, [], nil, nil, :pub, nil, false)
      imported_fn_ast.needs_rt = false
      imported_fn_ast.can_fail = false
      imported_main_ast = AST::FunctionDef.new(tok, "main", [], nil, :Void, nil, [], nil, nil, :pub, nil, false)
      imported_main_ast.needs_rt = false
      imported_main_ast.can_fail = false
      imported_ast = AST::Program.new(tok, [
        AST::StructDef.new(tok, "PublicType", {}, :pub, nil),
        imported_fn_ast,
        imported_main_ast,
      ])
      imported_type = MIR::StructDef.new("PublicType", [], nil, :pub)
      imported_mod = ModuleImporter::CompiledModule.new(
        imported_ast,
        nil,
        nil,
        Dir.pwd,
        {},
        {},
        {},
        nil,
        nil,
        [imported_type],
      )
      importer = ModuleImporter.new(base_dir: Dir.pwd)
      importer.define_singleton_method(:compile_file) { |_path, caller_dir:| imported_mod }
      node = AST::RequireNode.new(tok, "helper.clear", "helper", :local)

      low = lowering(importer: importer, source_dir: Dir.pwd)
      result = low.lower(node)

      expect(result).to include(imported_type)
      namespace = result.find { |item| item.is_a?(MIR::ModuleNamespace) }
      expect(namespace.name).to eq("helper")
      expect(namespace.items).to include(an_object_having_attributes(name: "helper_value"))
      expect(namespace.items).not_to include(an_object_having_attributes(name: "main"))
      expect(low.send(:program_state).fn_sigs).to include("helper_value")
      expect(low.send(:program_state).fn_sigs).not_to include("main")
      expect(emit(namespace)).to include("const helper = struct")
      expect(emit(namespace)).not_to include("clearMain")
    end

    it "keeps hidden implementation declarations inside imported module namespaces" do
      public_fn_ast = AST::FunctionDef.new(tok, "public_value", [], nil, :Void, nil, [], nil, nil, :pub, nil, false)
      public_fn_ast.needs_rt = false
      public_fn_ast.can_fail = false
      private_fn_ast = AST::FunctionDef.new(tok, "private_helper", [], nil, :Void, nil, [], nil, nil, :private, nil, false)
      private_fn_ast.needs_rt = false
      private_fn_ast.can_fail = false
      imported_ast = AST::Program.new(tok, [
        AST::StructDef.new(tok, "PublicType", {}, :pub, nil),
        AST::StructDef.new(tok, "HiddenState", {}, :private, nil),
        public_fn_ast,
        private_fn_ast,
      ])
      public_type = MIR::StructDef.new("PublicType", [], nil, :pub)
      hidden_type = MIR::StructDef.new("HiddenState", [], nil, nil)
      imported_mod = ModuleImporter::CompiledModule.new(
        imported_ast,
        nil,
        nil,
        File.join(Dir.pwd, "dep"),
        {},
        {},
        {},
        nil,
        nil,
        [public_type, hidden_type],
      )
      importer = ModuleImporter.new(base_dir: Dir.pwd)
      importer.define_singleton_method(:compile_file) { |_path, caller_dir:| imported_mod }
      node = AST::RequireNode.new(tok, "dep/helper.clear", "helper", :local)

      low = lowering(importer: importer, source_dir: Dir.pwd)
      result = low.lower(node)

      expect(result).to include(public_type)
      expect(result).not_to include(hidden_type)
      namespace = result.find { |item| item.is_a?(MIR::ModuleNamespace) }
      expect(namespace.items).to include(an_object_having_attributes(name: "HiddenState"))
      expect(namespace.items).to include(an_object_having_attributes(name: "private_helper"))
      expect(namespace.items).to include(an_object_having_attributes(name: "public_value"))
    end

    it "emits a repeated local require module only once" do
      imported_fn = MIR::FnDef.new(
        "helper_value",
        [],
        "i64",
        [MIR::ReturnStmt.new(MIR::Lit.new("7"))],
        :pub, false, nil
      )
      imported_mod = ModuleImporter::CompiledModule.new(
        AST::Program.new(tok, []),
        nil,
        nil,
        Dir.pwd,
        {},
        {},
        {},
        nil,
        [imported_fn],
        [],
      )
      importer = ModuleImporter.new(base_dir: Dir.pwd)
      importer.define_singleton_method(:compile_file) { |_path, caller_dir:| imported_mod }
      low = lowering(importer: importer, source_dir: Dir.pwd)

      first = low.lower(AST::RequireNode.new(tok, "grid.clear", "grid", :local))
      second = low.lower(AST::RequireNode.new(tok, "grid.clear", "grid", :local))

      expect(first).to include(an_instance_of(MIR::ModuleNamespace))
      expect(second).to eq([])
    end

    it "falls back to a structural namespace for BC local require when no helper functions exist" do
      imported_mod = ModuleImporter::CompiledModule.new(
        nil,
        nil,
        nil,
        Dir.pwd,
        {},
        {},
        {},
        nil,
        [],
        [],
      )
      importer = ModuleImporter.new(base_dir: Dir.pwd)
      importer.define_singleton_method(:compile_file) { |_path, caller_dir:| imported_mod }

      result = lowering(importer: importer, source_dir: Dir.pwd, target: :bc)
        .lower(AST::RequireNode.new(tok, "empty.clear", "empty", :local))

      expect(result).to contain_exactly(an_instance_of(MIR::ModuleNamespace))
    end

    it "reconstructs imported module items from AST without nesting requires" do
      private_fn = AST::FunctionDef.new(tok, "private_helper", [], nil, :Void, nil, [], nil, nil, :private, nil, false)
      private_fn.needs_rt = false
      private_fn.can_fail = false
      imported_ast = AST::Program.new(tok, [
        private_fn,
        AST::RequireNode.new(tok, "math", "math", :package),
        AST::ExternFnDecl.new(tok, "puts", [], Type.new(:Void), "c", nil),
        make_lit(:NUMBER, 1),
      ])
      imported_mod = ModuleImporter::CompiledModule.new(
        imported_ast,
        nil,
        nil,
        Dir.pwd,
        {},
        {},
        {},
        nil,
        nil,
        nil,
      )

      items = lowering.send(:imported_module_items, imported_mod)

      expect(items).not_to include(an_object_having_attributes(alias_name: "math", module_path: "math.zig"))
      expect(items).to include(an_object_having_attributes(alias_name: "c", module_path: "c.zig"))
      expect(items).to include(an_object_having_attributes(name: "private_helper"))
    end

    it "filters already-lowered dependency namespaces from imported module bodies" do
      dependency = MIR::ModuleNamespace.new("types", [
        MIR::FnDef.new("getStr", [], "void", [], :pub, false, nil),
      ])
      helper = MIR::FnDef.new("debugPause", [], "void", [], :pub, false, nil)
      imported_mod = ModuleImporter::CompiledModule.new(
        nil,
        nil,
        nil,
        Dir.pwd,
        {},
        {},
        {},
        nil,
        [dependency, helper],
        [],
      )

      items = lowering.send(:imported_module_items, imported_mod)

      expect(items).to contain_exactly(helper)
    end

    it "hoists imported module requires as dependency items" do
      imported_ast = AST::Program.new(tok, [
        AST::RequireNode.new(tok, "math", "math", :package),
      ])
      imported_mod = ModuleImporter::CompiledModule.new(
        imported_ast,
        nil,
        nil,
        Dir.pwd,
        {},
        {},
        {},
        nil,
        nil,
        nil,
      )

      items = lowering.send(:imported_module_dependency_items, imported_mod)

      expect(items).to include(an_object_having_attributes(alias_name: "math", module_path: "math.zig"))
    end

    it "filters imported type items and BC helper items defensively" do
      public_struct = AST::StructDef.new(tok, "PublicType", {}, :pub, nil)
      struct_item = MIR::StructDef.new("PublicType", [], nil, :pub)
      mixed_type_mod = ModuleImporter::CompiledModule.new(
        AST::Program.new(tok, [public_struct]),
        nil,
        nil,
        Dir.pwd,
        {},
        {},
        {},
        nil,
        nil,
        [Object.new, MIR::Lit.new("1"), struct_item],
      )
      nil_type_mod = ModuleImporter::CompiledModule.new(
        AST::Program.new(tok, [public_struct]),
        nil,
        nil,
        Dir.pwd,
        {},
        {},
        {},
        nil,
        nil,
        nil,
      )
      no_ast_mod = ModuleImporter::CompiledModule.new(nil, nil, nil, Dir.pwd, {}, {}, {}, nil, nil, nil)
      orphan_fn = MIR::FnDef.new("orphan", [], "void", [], :pub, false, nil)
      ast_without_fns_mod = ModuleImporter::CompiledModule.new(
        AST::Program.new(tok, [public_struct]),
        nil,
        nil,
        Dir.pwd,
        {},
        {},
        {},
        nil,
        nil,
        nil,
      )

      expect(lowering.send(:visible_type_items, nil_type_mod)).to eq([])
      expect(lowering.send(:visible_type_items, mixed_type_mod)).to eq([struct_item])
      expect(lowering.send(:imported_module_items, no_ast_mod)).to eq([])
      expect(lowering.send(:imported_bc_helper_fns, no_ast_mod, [struct_item, orphan_fn])).to eq([orphan_fn])
      expect(lowering.send(:imported_bc_helper_fns, ast_without_fns_mod, [])).to eq([])
    end
  end

  # =========================================================================
  # Phase 4: StubDecl, BenchmarkStmt, SmashStmt, ProfileStmt
  # =========================================================================

  describe "test framework helpers" do
    it "lowers StubDecl :returns to MIR::Let" do
      node = AST::StubDecl.new(tok, "getData", :returns, make_lit(:NUMBER, 42))
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Let)
      expect(result.name).to eq("__stub_getData")
    end

    it "lowers BenchmarkStmt to Comment" do
      node = AST::BenchmarkStmt.new(tok, make_lit(:NUMBER, 1), 1000)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Comment)
    end

    it "lowers SmashStmt to Comment" do
      node = AST::SmashStmt.new(tok, make_lit(:NUMBER, 1))
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Comment)
    end

    it "lowers ProfileStmt to Comment" do
      node = AST::ProfileStmt.new(tok, make_lit(:NUMBER, 1))
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Comment)
    end
  end

  # =========================================================================
  # Phase 4: ThenChain error
  # =========================================================================

  describe "ThenChain" do
    it "raises when encountered directly" do
      node = AST::ThenChain.new(tok, [])
      node.full_type = :Void
      expect { lowering.lower(node) }.to raise_error(/ThenChain should be flattened/)
    end
  end

  # =========================================================================
  # Phase 5: Program node
  # =========================================================================

  describe "Program lowering" do
    it "lowers empty program with standard imports" do
      prog = run_mir_frontend("")
      result = lowering.lower(prog)
      expect(result).to be_a(MIR::Program)
      zig = emit(result)
      expect(zig).to include('@import("std")')
      expect(zig).to include('@import("runtime/runtime-header.zig")')
      expect(zig).to include("CheatLib")
      expect(zig).to include("Runtime")
      expect(zig).to include("EbrContext")
    end

    it "lowers program with statements and source line comments" do
      prog = run_mir_frontend("ENUM Color { Red, Blue }")
      result = lowering.lower(prog)
      zig = emit(result)
      expect(zig).to include("// CLR:1")
      expect(zig).to include("Color")
    end

    it "includes safety import when requested" do
      prog = run_mir_frontend("")
      result = lowering.lower_program(prog, needs_safety: true)
      zig = emit(result)
      expect(zig).to include('@import("runtime/../lib/safety.zig")')
    end

    it "includes USE_C_ALLOCATOR when requested" do
      prog = run_mir_frontend("")
      result = lowering.lower_program(prog, use_c_allocator: true)
      zig = emit(result)
      expect(zig).to include("USE_C_ALLOCATOR")
    end
  end

  describe "source fixture MIR lowering corpus" do
    fixture_expectations = {
      "transpile-tests/253_while_bind.clear" => {
        description: "WHILE bind and RESOLVE traversal",
        required_patterns: [/while \(items\.pop\(\)\) \|v\|/, /CheatLib\.weakRcUpgrade/, /CheatLib\.cleanup\([^,]+,\s*rt\.heapAlloc\(\),\s*&__tmp_/]
      },
      "transpile-tests/305_observable_collect.clear" => {
        description: "observable COLLECT wait/destroy cleanup",
        # wait+destroy lives in CheatLib.cleanup's observable arm now; the
        # codegen contract is "binding cleanup routes through CheatLib.cleanup
        # with heapAlloc, calling running.next() in the body."
        required_patterns: [/CheatLib\.cleanup\([^,]+,\s*rt\.heapAlloc\(\),\s*&running\)/, /try running\.next\(\)/]
      },
      "transpile-tests/306_observable_default.clear" => {
        description: "inline observable aggregate COLLECT accumulator ownership",
        required_patterns: [
          /const __collect_acc_\d+/,
          /CheatLib\.cleanup\(@TypeOf\(__collect_acc_\d+\), rt\.heapAlloc\(\), &__collect_acc_\d+\)/
        ]
      },
      "transpile-tests/329_versioned_snapshot_mutable.clear" => {
        description: "versioned mutable snapshot update conflict handling",
        required_patterns: [/\.update\(rt, rt\.heapAlloc\(\)/, /MvccConflict/]
      },
      "transpile-tests/337_atomic_basic_ops.clear" => {
        description: "primitive atomic load/store/fetch operations",
        required_patterns: [/\.load\(\)/, /\.store\(/, /\.fetchAdd\(/, /\.fetchSub\(/]
      },
      "transpile-tests/342_atomic_ptr_read.clear" => {
        description: "atomic pointer snapshot read guards",
        required_patterns: [/\.read\(rt\)/, /\.release\(\)/]
      },
      "transpile-tests/349_polymorphic_transaction_acceptance.clear" => {
        description: "polymorphic lock and snapshot dispatch",
        required_patterns: [/acquire\(\)/, /\.update\(rt, rt\.heapAlloc\(\)/, /@hasField/]
      }
    }

    fixture_expectations.each do |path, expectation|
      it "lowers #{expectation[:description]} fixture to checker-clean MIR" do
        mir = lower_fixture_mir(path)
        expect_checker_clean(mir)

        zig = emit(mir)
        expectation[:required_patterns].each do |pattern|
          expect(zig).to match(pattern)
        end
      end
    end

    it "keeps nested concurrent pipeline sources checker-clean" do
      mir = lower_fixture_mir("examples/parallel_du/du.clear")
      expect_checker_clean(mir)

      zig = emit(mir)
      expect(zig).to include("concurrentListSelect")
      expect(zig).to match(/CheatLib\.cleanup\([^,]+,\s*rt\.frameAlloc\(\),\s*&pipe_src_list\)/)
    end

  end

  # =========================================================================
  # Phase 5: SMOOTH (pipeline) operator
  # =========================================================================

  describe "SMOOTH pipeline lowering" do
    it "lowers simple pipe x |> f to function call" do
      lhs = make_lit(:NUMBER, 42, full_type: :Number)
      lhs.coerced_type = nil
      rhs = AST::Identifier.new(tok, "double")
      rhs.full_type = :Number

      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("double")
      expect(zig).to include("42")
    end

    it "lowers pipe with args x |> f(y) to f(x, y)" do
      lhs = make_lit(:NUMBER, 10, full_type: :Number)
      lhs.coerced_type = nil
      arg = make_lit(:NUMBER, 20, full_type: :Number)
      arg.coerced_type = nil
      rhs = AST::FuncCall.new(tok, "add", [arg])
      rhs.full_type = :Number

      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("add")
      expect(zig).to include("10")
      expect(zig).to include("20")
    end

    it "lowers RECOVER directly to TryCatch without legacy pipeline fallback" do
      lhs = AST::FuncCall.new(tok, "fallible", [])
      lhs.full_type = :Int64
      lhs.error_union_type = Type.new(:"!Int64")
      lhs.can_fail = true
      rhs = AST::RecoverOp.new(tok, make_lit(:INT64, 0, full_type: :Int64))
      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Int64

      result = lowering.lower(node)

      expect(result).to be_a(MIR::TryCatch)
      expect(result.expr).to be_a(MIR::Call)
      expect(result.expr.callee).to eq("fallible")
      expect(result.catch_body).to be_a(MIR::Lit)
      expect(emit(result)).to eq("(fallible(rt) catch 0)")
    end

    it "lowers BatchWindowOp through structural MIR instead of the legacy pipeline host" do
      mir = lower_fixture_mir("transpile-tests/243_batch_window.clear")

      expect(collect_mir_nodes(mir, MIR::BatchWindowPush)).not_to be_empty
      expect(collect_mir_nodes(mir, MIR::BatchWindowFlush)).not_to be_empty
      expect(MIR.const_defined?(:InlineZig, false)).to be(false)

      zig = emit(mir)
      expect(zig).to include("CheatLib.BatchWindow(i64).init")
      expect(zig).to include(".freeBatch(")
    end

    it "lowers non-mutual THUNK recursion through structural MIR instead of opaque Zig" do
      mir = lower_fixture_mir("transpile-tests/526_non_mutual_thunk_trampoline.clear")

      thunk_nodes = collect_mir_nodes(mir, MIR::ThunkTrampoline)
      expect(thunk_nodes.length).to eq(1)
      thunk = thunk_nodes.fetch(0)
      expect(thunk.fn_name).to eq("sum_down")
      expect(thunk.return_type.zig_type).to eq("i64")
      expect(thunk.base_cases.length).to eq(1)
      expect(MIREmitter.new.emit(thunk.base_cases.first.fetch(:value))).to eq("0")
      expect(MIREmitter.new.emit(thunk.combine_lhs)).to eq("current.n")
      expect(thunk.combine_op).to eq(:ADD)
      expect(thunk.recurse_arg_inits.length).to eq(1)
      expect(thunk.recurse_arg_inits.first).to be_a(MIR::ThunkFrameInit)
      expect(MIREmitter.new.emit(thunk.recurse_arg_inits.first.value)).to include("current.n")
      expect(thunk.yield_policy).to eq(:check)
      expect(MIR.const_defined?(:InlineZig, false)).to be(false)
    end

    it "lowers mutual THUNK recursion through structural MIR instead of opaque Zig" do
      mir = lower_fixture_mir("transpile-tests/525_mutual_thunk_trampoline.clear")

      thunk_nodes = collect_mir_nodes(mir, MIR::MutualThunkTrampoline)
      expect(thunk_nodes.map(&:fn_name)).to contain_exactly("is_even", "is_odd")
      thunk_nodes.each do |thunk|
        expect(thunk.variants.map { |v| v.fetch(:name) }).to contain_exactly("is_even", "is_odd")
        expect(thunk.initial_variant).to eq(thunk.fn_name)
        expect(thunk.initial_fields.map(&:field_name)).to eq(["n"])
        expect(MIREmitter.new.emit(thunk.initial_fields.first.value)).to eq("n")
        expect(thunk.yield_policy).to eq(:check)
      end

      even = thunk_nodes.find { |n| n.fn_name == "is_even" }
      expect(even).not_to be_nil
      even_arm = even.arms.find { |a| a.fetch(:variant_name) == "is_even" }
      expect(even_arm).not_to be_nil
      expect(MIREmitter.new.emit(even_arm.fetch(:base_cases).first.fetch(:value))).to eq("true")
      expect(even_arm.fetch(:target_variant)).to eq("is_odd")
      expect(MIREmitter.new.emit(even_arm.fetch(:target_arg_inits).first.value)).to include("f.n")

      odd = thunk_nodes.find { |n| n.fn_name == "is_odd" }
      expect(odd).not_to be_nil
      odd_arm = odd.arms.find { |a| a.fetch(:variant_name) == "is_odd" }
      expect(odd_arm).not_to be_nil
      expect(MIREmitter.new.emit(odd_arm.fetch(:base_cases).first.fetch(:value))).to eq("false")
      expect(odd_arm.fetch(:target_variant)).to eq("is_even")
      expect(MIREmitter.new.emit(odd_arm.fetch(:target_arg_inits).first.value)).to include("f.n")

      expect(MIR.const_defined?(:InlineZig, false)).to be(false)
    end

    it "collects named observables by calling next directly" do
      lhs = make_id("running", full_type: :"~Int64@observable")
      rhs = AST::CollectOp.new(tok)
      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Int64

      result = lowering.lower(node)

      expect(result).to be_a(MIR::MethodCall)
      expect(result.method).to eq("next")
      expect(emit(result)).to eq("try running.next()")
    end

    it "collects inline collection observables through materializeNext and destroys the accumulator" do
      lhs = AST::FuncCall.new(tok, "makeDistinct", [])
      lhs.full_type = Type.new(:"~Int64[]", collection: :set, observable: true, observable_terminal: :distinct)
      rhs = AST::CollectOp.new(tok)
      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = Type.new(:"Int64[]@list")

      result = lowering.lower(node)
      zig = emit(result)

      expect(result).to be_a(MIR::BlockExpr)
      expect(zig).to include("materializeNext(rt.frameAlloc())")
      expect(zig).to include("CheatLib.cleanup(@TypeOf(__collect_acc_1), rt.heapAlloc(), &__collect_acc_1)")
    end

    it "raises on unhandled SMOOTH RHS" do
      lhs = make_lit(:NUMBER, 1, full_type: :Number)
      rhs = make_lit(:NUMBER, 2, full_type: :Number) # Literal is not a valid pipe target

      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Number

      expect { lowering.lower(node) }.to raise_error(/unhandled SMOOTH/)
    end
  end

  # =========================================================================
  # Phase 5: OR_ELSE error chain
  # =========================================================================

  describe "OR_ELSE error chain lowering" do
    def make_error_expr(name)
      id = make_id(name, full_type: :"!Number")
      # Simulate error union type
      allow(id).to receive(:can_fail).and_return(true)
      id
    end

    it "lowers OR_ELSE RAISE with error to try" do
      left = make_error_expr("getData")
      right = AST::OrElseRaise.new(tok)
      node = AST::BinaryOp.new(tok, left, :OR_ELSE, right)
      node.full_type = :Number
      stamp_or_else_plan(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("try")
      expect(zig).to include("getData")
    end

    it "lowers OR_ELSE RAISE with an optional-only value to passthrough" do
      left = make_id("x", full_type: :"?Number")
      right = AST::OrElseRaise.new(tok)
      node = AST::BinaryOp.new(tok, left, :OR_ELSE, right)
      node.full_type = :"?Number"
      stamp_or_else_plan(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to eq("x")
    end

    it "lowers OR_ELSE PASS with error to catch undefined" do
      left = make_error_expr("getData")
      right = AST::OrElsePass.new(tok)
      node = AST::BinaryOp.new(tok, left, :OR_ELSE, right)
      node.full_type = :Number
      stamp_or_else_plan(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("catch undefined")
    end

    it "lowers OR_ELSE BREAK with error to catch break" do
      left = make_error_expr("getData")
      right = AST::OrElseBreak.new(tok)
      node = AST::BinaryOp.new(tok, left, :OR_ELSE, right)
      node.full_type = :Number
      stamp_or_else_plan(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("catch break")
    end

    it "lowers OR_ELSE EXIT with error to catch + setError" do
      left = make_error_expr("getData")
      msg = make_lit(:STRING, "failed", full_type: :String)
      right = AST::OrElseExit.new(tok, msg)
      node = AST::BinaryOp.new(tok, left, :OR_ELSE, right)
      node.full_type = :Number
      stamp_or_else_plan(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("__exit_err")
      expect(zig).to include("return __exit_err")
    end

    it "lowers error union with default fallback to catch" do
      left = make_error_expr("getData")
      right = make_lit(:NUMBER, 0, full_type: :Number)
      right.coerced_type = nil
      node = AST::BinaryOp.new(tok, left, :OR_ELSE, right)
      node.full_type = :Number
      stamp_or_else_plan(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("catch")
      expect(zig).to include("0")
    end

    it "lowers optional with fallback to orelse" do
      left = make_id("maybe", full_type: :"?Number")
      right = make_lit(:NUMBER, 99, full_type: :Number)
      right.coerced_type = nil
      node = AST::BinaryOp.new(tok, left, :OR_ELSE, right)
      node.full_type = :Number
      stamp_or_else_plan(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("orelse")
      expect(zig).to include("99")
    end

    it "lowers OR_ELSE PRUNE with error to catch undefined" do
      left = make_error_expr("getData")
      right = AST::OrElsePrune.new(tok)
      node = AST::BinaryOp.new(tok, left, :OR_ELSE, right)
      node.full_type = :Number
      stamp_or_else_plan(node)

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("catch undefined")
    end

    context "lazy fallback scoping (descend + lower_scoped)" do
      # The fallback expression is evaluated lazily. Any allocations done
      # while lowering it must NOT escape to outer FunctionState pending statements -- they
      # belong to the orelse/catch fallback branch and must only run when
      # that branch is actually taken. AST::BinaryOp#lazy_fields declares
      # :right as lazy when op == :OR_ELSE; descend() wraps the right
      # side in MIR::BlockExpr containing the scoped pending stmts.
      it "wraps an allocating fallback (struct lit with heap field) in BlockExpr" do
        # Allocating fallback: a StructLit whose String field gets a
        # CopyNode-wrapped rodata literal. Lowering the field invokes
        # hoist_alloc which pushes a `Let __tmp = DeepCopy(...)` into
        # FunctionState pending statements. With lazy scoping that hoisted Let must land
        # inside the MIR::BlockExpr wrapping the fallback, NOT in outer
        # FunctionState pending statements.
        left = make_id("opt_node", full_type: :"?Node")
        lit  = make_lit(:STRING, "?", full_type: Type.new(:String, location: :rodata))
        copy = AST::CopyNode.new(tok, lit)
        copy.full_type = Type.new(:String, location: :heap)
        struct_lit = AST::StructLit.new(tok, "Node", { "label" => copy })
        struct_lit.full_type = :Node

        node = AST::BinaryOp.new(tok, left, :OR_ELSE, struct_lit)
        node.full_type = :Node
        stamp_or_else_plan(node)

        l = lowering(struct_schemas: { Node: Schemas::StructSchema.new(fields: { "label" => Type.new(:String) }) })
        result = l.lower(node)
        expect(l.function_state.pending_stmts).to be_empty
        expect(result).to be_a(MIR::Orelse)
        expect(result.fallback).to be_a(MIR::BlockExpr)
        expect(result.fallback.body.any? { |stmt| stmt.is_a?(MIR::AllocMark) }).to be true
        expect(result.fallback.body.last).to be_a(MIR::BreakStmt)
      end

      it "leaves a non-allocating fallback unwrapped" do
        # Pure rodata fallback, no allocations -> no BlockExpr wrapping.
        left  = make_id("opt_str", full_type: :"?String")
        right = make_lit(:STRING, "default", full_type: Type.new(:String, location: :rodata))

        node = AST::BinaryOp.new(tok, left, :OR_ELSE, right)
        node.full_type = :String
        stamp_or_else_plan(node)

        l = lowering
        result = l.lower(node)
        expect(result).to be_a(MIR::Orelse)
        expect(result.fallback).not_to be_a(MIR::BlockExpr)
      end
    end
  end
end

RSpec.describe "MIRLowering allocation cleanup classification" do
  let(:tok) { Lexer::Token.new(:KEYWORD, "test", 1, 1) }

  def lowering(**opts)
    schema_lookup = opts[:schema_lookup] || lambda do |name|
      opts.fetch(:struct_schemas, {})[name.to_sym] ||
        opts.fetch(:enum_schemas, {})[name.to_sym] ||
        opts.fetch(:union_schemas, {})[name.to_sym]
    end
    opts[:lifecycle_registry] ||= spec_lifecycle_registry(schema_lookup: schema_lookup)
    MIRLowering.new(input: MIRLoweringInput.new(**opts))
  end

  def typed_node(type)
    AST::Identifier.new(tok, "value").tap { |node| node.full_type = type }
  end

  it "treats every owned MIR allocation node as cleanup-relevant" do
    l = lowering

    expect(l.send(:mir_allocates?, MIR::DupeSlice.new(MIR::Ident.new("s"), :heap))).to be(true)
    expect(l.send(:mir_allocates?, MIR::DupeSlice.new(MIR::Ident.new("s"), :frame))).to be(true)
    expect(l.send(:mir_allocates?, MIR::AllocSlice.new("i64", MIR::Lit.new("4"), :heap))).to be(true)
    expect(l.send(:mir_allocates?, MIR::AllocSlice.new("i64", MIR::Lit.new("4"), :frame))).to be(true)
    expect(l.send(:mir_allocates?, MIR::HeapCreate.new("Node", MIR::StructInit.new("Node", []), :frame, nil))).to be(true)
  end

  it "recurses through casts when deciding whether an expression allocates" do
    l = lowering
    heap_copy = MIR::DeepCopy.new(MIR::Ident.new("s"), nil, nil, :string, :heap)
    frame_copy = MIR::DeepCopy.new(MIR::Ident.new("s"), nil, nil, :string, :frame)

    expect(l.send(:mir_allocates?, MIR::Cast.new(heap_copy, "[]const u8", :as))).to be(true)
    expect(l.send(:mir_allocates?, MIR::Cast.new(frame_copy, "[]const u8", :as))).to be(true)
  end

  it "classifies direct allocation cleanup entries by allocation shape" do
    l = lowering

    expect(l.send(:hoist_cleanup_entry, MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), nil)).to include(kind: :heap_string)
    expect(l.send(:hoist_cleanup_entry, MIR::ConcatStr.new([MIR::Ident.new("a"), MIR::Ident.new("b")], :heap, "rt"), nil)).to include(kind: :heap_string)
    expect(l.send(:hoist_cleanup_entry, MIR::AllocSlice.new("i64", MIR::Lit.new("4"), :heap), nil)).to include(kind: :uniform, elem_zig_type: "i64")
    expect(l.send(:hoist_cleanup_entry, MIR::MakeList.new("i64", [MIR::Lit.new("1")], :heap), nil)).to include(kind: :uniform, zig_type: "std.ArrayListUnmanaged(i64)")
    expect(l.send(:hoist_cleanup_entry, MIR::HeapCreate.new("Node", MIR::StructInit.new("Node", []), :heap, nil), nil)).to include(kind: :uniform, zig_type: "Node")
    expect(l.send(:hoist_cleanup_entry, MIR::ContainerInit.new("std.ArrayListUnmanaged(i64)", :array_list_empty, :heap, nil), nil)).to include(kind: :uniform)
  end

  it "classifies pipeline cleanup entries through their owned result" do
    l = lowering
    ast_node = typed_node(Type.new(:String))
    inner = MIR::DupeSlice.new(MIR::Ident.new("s"), :heap)
    pipeline = MIR::Pipeline.new(ast_node, inner, nil, nil, nil, nil)

    expect(l.send(:mir_allocates?, pipeline)).to be(true)
    expect(l.send(:hoist_cleanup_entry, pipeline, ast_node)).to include(kind: :heap_string)
  end

  it "classifies DeepCopy cleanup entries uniformly via :full_value (slice and value)" do
    l = lowering

    expect(l.send(:hoist_cleanup_entry, MIR::DeepCopy.new(MIR::Ident.new("xs"), "[]i64", "i64", :full_value, :heap), nil)).to include(kind: :uniform, zig_type: "[]i64")
    expect(l.send(:hoist_cleanup_entry, MIR::DeepCopy.new(MIR::Ident.new("xs"), "[]Value", "Value", :full_value, :heap), nil)).to include(kind: :uniform, zig_type: "[]Value")
    expect(l.send(:hoist_cleanup_entry, MIR::DeepCopy.new(MIR::Ident.new("v"), "Value", nil, :full_value, :heap), nil)).to include(kind: :uniform, zig_type: "Value")
    expect(l.send(:hoist_cleanup_entry, MIR::DeepCopy.new(MIR::Ident.new("s"), "[]const u8", nil, :full_value, :heap), nil)).to include(kind: :uniform, zig_type: "[]const u8")
  end

  it "raises when a heap DeepCopy uses a strategy other than :full_value" do
    expect {
      lowering.send(:hoist_cleanup_entry, MIR::DeepCopy.new(MIR::Ident.new("x"), nil, nil, :unknown_strategy, :heap), nil)
    }.to raise_error(/unexpected DeepCopy strategy :unknown_strategy/)
  end

  it "raises when rc_cleanup_entry's ast_node carries no Type" do
    expect {
      lowering.send(:rc_cleanup_entry, nil, source: "test")
    }.to raise_error(/RC hoist cleanup: missing type info/)
  end

  it "classifies capability wrappers and share promotion cleanup entries" do
    l = lowering

    locked = MIR::CapWrap.new(MIR::Ident.new("box"), "Box", :sync_only, "lockedCreate", "CheatLib.Locked(Box)", nil, :heap)
    rw_locked = MIR::CapWrap.new(MIR::Ident.new("box"), "Box", :sync_only, "rwLockedCreate", "CheatLib.RwLocked(Box)", nil, :heap)
    owned = MIR::CapWrap.new(MIR::Ident.new("box"), "Box", :own_only, nil, nil, "arcCreate", :heap)
    passthrough = MIR::CapWrap.new(MIR::Ident.new("box"), "Box", :passthrough, nil, nil, nil, :heap)
    shared_node = typed_node(Type.new(:Box, ownership: :shared))

    expect(l.send(:hoist_cleanup_entry, locked, nil)).to include(kind: :uniform, zig_type: "CheatLib.Locked(Box)")
    expect(l.send(:hoist_cleanup_entry, rw_locked, nil)).to include(kind: :uniform, zig_type: "CheatLib.RwLocked(Box)")
    expect(l.send(:hoist_cleanup_entry, owned, shared_node)).to include(kind: :rc, zig_type: "CheatLib.Arc(Box)")
    expect(l.send(:hoist_cleanup_entry, passthrough, nil)).to be_nil
    expect(l.send(:hoist_cleanup_entry, MIR::SharePromote.new(MIR::Ident.new("box"), "Box", :heap), shared_node)).to include(kind: :rc, zig_type: "CheatLib.Arc(Box)")
  end

  it "delegates cleanup classification through Cast wrappers" do
    l = lowering
    inner = MIR::DeepCopy.new(MIR::Ident.new("s"), "[]const u8", nil, :full_value, :heap)

    expect(l.send(:hoist_cleanup_entry, MIR::Cast.new(inner, "[]const u8", :as), nil)).to include(kind: :uniform, zig_type: "[]const u8")
  end

  it "lowers default fixed-array literals structurally" do
    l = lowering
    node = AST::DefaultArrayLit.new(tok, Type.array_of(:Int64, capacity: 2), :stack)

    result = l.lower(node)

    expect(result).to be_a(MIR::ArrayDefaultInit)
    expect(result.elem_type).to eq("i64")
    expect(result.count).to eq("2")
    expect(result.default_value).to eq(MIR::Lit.new("0"))
    expect(result.alloc).to eq(:frame)
    expect(result.ownership_effect.produces_owned).to be(false)
    expect(result.result_type.resolved).to eq(:"Int64[2]")
  end

  it "lowers default fixed-array values for supported primitive element types" do
    l = lowering

    expect(l.lower(AST::DefaultArrayLit.new(tok, Type.array_of(:Float64, capacity: 2), :stack)).default_value)
      .to eq(MIR::Lit.new("0.0"))
    expect(l.lower(AST::DefaultArrayLit.new(tok, Type.array_of(:String, capacity: 2), :stack)).default_value)
      .to eq(MIR::Lit.new("\"\""))
    expect(l.lower(AST::DefaultArrayLit.new(tok, Type.array_of(:Bool, capacity: 2), :stack)).default_value)
      .to eq(MIR::Lit.new("false"))
  end

  it "rejects default fixed-array literals without integer capacity or supported element type" do
    l = lowering

    expect {
      l.lower(AST::DefaultArrayLit.new(tok, Type.array_of(:Int64), :stack))
    }.to raise_error(/integer capacity/)

    expect {
      l.lower(AST::DefaultArrayLit.new(tok, Type.array_of(:Widget, capacity: 2), :stack))
    }.to raise_error(/unsupported fixed-array default element type/)
  end

  it "keeps final void FSM assignment steps as statements" do
    l = lowering
    target = AST::Identifier.new(tok, "slot")
    target.full_type = Type.new(:Int64)
    value = AST::Literal.new(tok, :INT64, 1, nil)
    value.full_type = Type.new(:Int64)
    assignment = AST::Assignment.new(tok, target, value)
    assignment.full_type = Type.new(:Void)

    body = l.send(:lower_step_stmts, [assignment], no_result: false, ctx_id: 3)

    expect(body.length).to eq(1)
    expect(body.first).to be_a(MIR::Set)
    expect(body.first.target).to eq(MIR::Ident.new("slot"))
  end

  it "wraps bound THEN steps as MIR lets" do
    l = lowering
    expr = AST::Literal.new(tok, :INT64, 1, nil)
    expr.full_type = Type.new(:Int64)
    step = AST::ThenStep.new(expr: expr, binding: "saved")

    wrapped = l.send(:wrap_step_as_stmt, step, MIR::Lit.new("1"))

    expect(wrapped).to be_a(MIR::Let)
    expect(wrapped.name).to eq("saved")
  end

  it "unwraps cast and try nodes when recording FSM result transfers" do
    l = lowering
    entry = CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: false })
    l.function_state.current_bindings = { "owned" => entry }
    l.function_state.fn_name_rename_map = {}
    l.function_state.guarded_cleanup_names = {}
    ast = AST::Identifier.new(tok, "owned")
    ast.full_type = Type.new(:String)
    mir = MIR::Cast.new(MIR::TryExpr.new(MIR::Ident.new("owned")), "[]const u8", :as)

    facts = l.send(:fsm_result_transfer_facts, mir, ast)

    expect(facts.map { |fact| [fact.name, fact.target_alloc, fact.move_guarded] })
      .to eq([["owned", :heap, true]])
    expect(entry.has_moved_guard?).to eq(true)
    expect(l.function_state.guarded_cleanup_names).to include("owned" => true)
  end

  it "guards renamed FSM result cleanups and records consumed owned fields" do
    l = lowering
    cleanup = CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: false })
    l.function_state.fn_name_rename_map = { "owned" => "owned_renamed" }
    l.function_state.guarded_cleanup_names = {}

    l.send(
      :guard_fsm_result_cleanup!,
      [MIR::Cleanup.new("owned", cleanup)],
      [MIR::FsmResultTransferFact.new(name: "owned_renamed", target_alloc: :heap, move_guarded: true)],
    )

    expect(cleanup.has_moved_guard?).to eq(true)
    expect(l.function_state.guarded_cleanup_names).to include("owned_renamed" => true)

    binding = CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: false })
    l.function_state.current_bindings = { "owned" => binding }
    l.function_state.guarded_cleanup_names = { "owned_renamed" => true }
    owned = AST::Identifier.new(tok, "owned")
    owned.full_type = Type.new(:String)
    ast = AST::StructLit.new(tok, "Box", { "value" => owned }, :heap, [])
    ast.full_type = Type.new(:Box)

    facts = l.send(:fsm_result_transfer_facts, MIR::Lit.new("box"), ast)

    expect(facts.map { |fact| [fact.name, fact.target_alloc, fact.move_guarded] })
      .to eq([["owned_renamed", :heap, true]])
  end


  it "requires annotation plans before lowering tense navigation" do
    l = lowering
    target = AST::Identifier.new(tok, "future")
    target.full_type = Type.new("~Int64")
    navigation = AST::TenseNavigation.new(tok, target, "~")
    member = AST::GetField.new(tok, navigation, "value")

    expect {
      l.send(:lower_tense_navigation, member, navigation) { |_receiver| MIR::Lit.new("1") }
    }.to raise_error(/requires its annotation-produced TenseOperationPlan/)
  end

  it "derives resource cleanup entries from the annotation lifecycle plan" do
    l = lowering
    close_plan = Schemas::ResourceClosePlan.method("close")
    lifecycle = Semantic::LifecyclePlan.new(
      type_key: "Handle",
      drop_strategy: :resource_close,
      copy_strategy: :forbidden,
      resource_close_plan: close_plan,
    )

    entry = l.send(:tense_map_cleanup_entry, Type.new(:Handle), lifecycle)
    expect(entry.kind).to eq(:resource)
    expect(entry.resource_close_plan).to equal(close_plan)
    expect(entry.lifecycle_plan).to equal(lifecycle)
  end
end
