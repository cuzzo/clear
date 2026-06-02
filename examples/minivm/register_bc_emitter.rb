# frozen_string_literal: true

require "set"
require_relative "../../src/mir/mir"
require_relative "../../src/ast/error_registry"
require_relative "register_opcode_layout"
require_relative "register_pipeline"

class RegisterBcEmitter
  class Unsupported < StandardError; end

  MiniVM::Register::OpcodeSpec::OPCODES.each do |op|
    const_set(op.name, op.code)
  end

  ARG_I = 0
  ARG_F = 1
  ARG_S = 2

  RET_VOID = 0
  RET_I = 1
  RET_F = 2
  RET_S = 3

  N_TIMESTAMP_MS = 0
  N_RANDOM = 1
  N_RANDOM_INT = 2
  N_INT_TO_STRING = 3
  N_STRING_LENGTH = 4
  N_STRING_STARTS_WITH = 5
  N_STRING_CONTAINS = 6
  N_STRING_CHAR_AT = 7
  N_STRING_SUBSTR = 8
  N_STRING_TO_NUMBER_OR = 9
  N_FLOAT_TO_INT = 10
  N_INT_TO_FLOAT = 11
  N_STRING_REPLACE = 12
  N_STRING_LOWERCASE = 13
  N_STRING_UPPERCASE = 14
  N_READ_LINE = 15
  N_FRAME_PEAK_BYTES = 16
  N_STRING_CODEPOINT_COUNT = 17
  N_FILE_READ = 18
  N_FILE_WRITE = 19
  N_STRING_INDEX_OF = 20
  N_THREAD_COUNT = 21
  N_CURRENT_MEMORY_KB = 22

  MAIN_NAMES = %w[main clearMain cheatMain].freeze

  Result = Struct.new(:ops, :consts, :source_lines, :source_columns, :var_names, keyword_init: true)

  # Per-function list of bindings. Each binding is one `(source_line,
  # kind, virt, name)` row -- the `source_line` is the CLEAR line at
  # which the binding becomes live. We deliberately track the source
  # line (not the bytecode IP) because the optimizer pass can fold or
  # remove instructions, shifting IPs after the names table is built;
  # source lines are stable. Multiple bindings can share a physical
  # register over a function's lifetime (linear-scan reuse) -- the
  # runtime snapshot picks the binding whose `source_line` is the
  # largest still strictly less than the current pause line, which is
  # byebug's "visible after assignment completes" semantic. Only
  # serialized to disk + read by the runner in --debug mode.
  Binding = Struct.new(:source_line, :source_column, :end_source_line, :kind, :virt, :name, :type_name, keyword_init: true)
  VarNamesByFunction = Struct.new(:entry_ip, :bindings, keyword_init: true)

  def initialize(frontend_result, source: nil, importer: nil)
    @frontend_result = frontend_result
    @source = source
    @importer = importer
    @ops = []
    @op_source_lines = []
    @op_source_columns = []
    @current_source_line = 0
    @current_source_column = 0
    @consts = []
    # Per-function virtual register name maps. Populated during
    # compile_function via record_var_name. Combined post-pipeline with
    # the allocator's virtual -> physical mapping in `compile()` to
    # produce a per-function `VarNamesByFunction` (keyed by physical
    # register index). Result is exposed on `Result.var_names`; bc_run.rb
    # serializes it to disk only when invoked in --debug mode.
    # Per-function ordered list of bindings (one entry per recorded
    # `(kind, virt, name)` site). See `Binding` above for the shape and
    # the rationale for keeping multiple bindings per phys reg.
    @bindings_in_function = []
    @function_var_names = {}
    @next_ireg = 0
    @next_freg = 0
    @next_sreg = 0
    @next_vreg = 0
    @ireg_by_name = {}
    @freg_by_name = {}
    @sreg_by_name = {}
    @vreg_by_name = {}
    @vkind_by_name = {}
    @value_by_name = {}
    @callable_by_name = {}
    @tag_type_by_name = {}
    @enum_variants = {}
    @union_variants = {}
    @struct_fields = {}
    @tag_context_type = nil
    @return_type = :i64
    @functions_by_name = {}
    @function_entries = {}
    @function_frame_sizes = {}
    @function_patches = []
    @compiled_functions = {}
    @inline_return = nil
    @loop_continue_target = nil
    @loop_break_patches = nil
    @loop_continue_patches = nil
    # Loom-mode groundwork (not yet active). The bc emitter records
    # every shared-memory event (read/write/lock-acquire/release/etc.)
    # so a future deterministic-replay scheduler can enumerate
    # interleavings. The recording is structural: it consumes the
    # value-kinds we already track and adds nothing to the runtime.
    @shared_events = []
    @bg_dispatch_points = []
    # Default: top-level scalar BGs spawn real fibers; nested /
    # FSM-eligible / suspend / non-scalar-capture bodies still inline.
    # CLEAR_REGISTER_BG_MODE=inline forces the all-inline fallback.
    @bg_mode = ENV["CLEAR_REGISTER_BG_MODE"] == "inline" ? :inline : :fiber
    @current_function_name = nil
  end

  attr_reader :shared_events, :bg_dispatch_points

  # Record a shared-memory event seen during compilation. Categories:
  #   :read         -- field/atomic load
  #   :write        -- field/atomic store
  #   :acquire      -- lock acquire (WITH EXCLUSIVE / SHARED)
  #   :release      -- lock release
  #   :snapshot     -- versioned snapshot read pin
  #   :transaction  -- versioned snapshot mutable txn
  # `binding` is the user-visible name; `kind` is the primary value-
  # kind (`:locked_struct`, `:atomic_primitive`, etc.); `caps` is
  # the ownership/sync pair pulled from the binding's value hash
  # (`{ownership: :arc, sync: :locked}` etc.). Stored in compile
  # order; consumed by --concurrency-report and (future) the loom
  # scheduler.
  def record_shared_event(category, binding, kind, caps: nil)
    @shared_events << {
      function: @current_function_name,
      category: category,
      binding: binding.to_s,
      kind: kind,
      caps: caps,
      line: @current_source_line,
    }
  end

  # Pull the caps tuple from a value hash, with sensible defaults
  # for non-cap-wrapped kinds (atomic primitive, etc.).
  def caps_for_value(value)
    return value[:caps] if value && value[:caps]
    case (value && value[:kind])
    when :rc_struct           then { ownership: :rc, sync: :none }
    when :arc_struct          then { ownership: :arc, sync: :none }
    when :locked_struct       then { ownership: :none, sync: :locked }
    when :write_locked_struct then { ownership: :none, sync: :write_locked }
    when :local_struct        then { ownership: :local, sync: :none }
    when :versioned_struct    then { ownership: :none, sync: :versioned }
    when :atomic_ptr_struct   then { ownership: :none, sync: :atomic_ptr }
    when :atomic_primitive    then { ownership: :none, sync: :atomic_primitive }
    else nil
    end
  end

  def compile(program)
    functions = program.items.select { |item| item.is_a?(MIR::FnDef) }
    @functions_by_name = functions.to_h { |fn| [fn.name.to_s, fn] }
    # Cross-file FN bodies: imported modules' FnDefs are visible to
    # the local file via REQUIRE. Pull them in so calls like
    # `makePoint(...)` (from a REQUIREd helper) resolve to a known
    # FnDef and the bc emitter can inline / patch the call. The
    # imported FNs share the same opcode space and dispatch as local
    # ones; cleanup, allocators, and lifetimes are unaffected.
    # Cross-file FN bodies: imported modules' FnDefs are visible to
    # the local file via REQUIRE. Pull them in so calls like
    # `helper.makePoint(...)` or `helper.addPub(...)` resolve to a
    # known FnDef and the bc emitter can either inline or patch the
    # call. Only pull in FNs that the local program actually
    # references (qualified `<alias>.<fn>` calls), so we don't force
    # compilation of unused helpers that may use unsupported
    # features.
    @cross_file_alias = {}  # qualified name -> bare name
    if @importer
      referenced = collect_qualified_calls(program.items)
      @importer.module_cache.each do |abs_path, mod|
        next unless mod.respond_to?(:mir_items) && mod.mir_items
        alias_name = File.basename(abs_path, ".cht")
        mod.mir_items.each do |item|
          next unless item.is_a?(MIR::FnDef)
          qualified = "#{alias_name}.#{item.name}"
          next unless referenced.include?(qualified)
          @functions_by_name[item.name.to_s] ||= item
          @functions_by_name[qualified] ||= item
          @cross_file_alias[qualified] = item.name.to_s
        end
      end
    end
    @function_source_lines = collect_function_source_lines(@frontend_result&.ast)
    collect_type_defs(program.items)

    main = functions.find { |fn| MAIN_NAMES.include?(fn.name.to_s) }
    raise Unsupported, "register emitter requires a main function" unless main

    compile_function(main)
    emit(HALT)
    loop do
      missing = @function_patches.map(&:last).uniq.reject do |name|
        # A qualified callee `<alias>.<fn>` is satisfied either by an
        # entry under that exact name or by an entry under the bare
        # FN name (cross-file FNs compile under their bare name).
        @function_entries.key?(name) || @function_entries.key?(@cross_file_alias[name].to_s)
      end
      break if missing.empty?

      missing.each do |name|
        function = @functions_by_name[name]
        raise Unsupported, "register emitter could not resolve helper #{name.inspect}" unless function

        compile_function(function)
        # Cross-file FNs compile under their bare name; mirror the
        # entry under the qualified name so the patcher's lookup
        # (which uses the call site's verbatim callee text) hits.
        if (bare = @cross_file_alias[name]) && @function_entries.key?(bare)
          @function_entries[name] = @function_entries[bare]
          @function_frame_sizes[name] = @function_frame_sizes[bare] if @function_frame_sizes.key?(bare)
        end
        emit(HALT)
      end
    end
    patch_function_calls
    pipeline_result = MiniVM::Register::Pipeline.new.run_with_lines(@ops, @op_source_lines, @op_source_columns)
    var_names = build_physical_name_table(pipeline_result.segment_mappings)
    Result.new(
      ops: pipeline_result.ops,
      consts: @consts,
      source_lines: pipeline_result.source_lines,
      source_columns: pipeline_result.source_columns,
      var_names: var_names
    )
  end

  # Joins the emitter's virtual->name maps (per function) with the
  # allocator's virtual->physical maps (per segment entry) to produce
  # `[VarNamesByFunction]`, where `i`/`f`/`s` are now keyed by physical
  # register index. Functions whose entry_ip the allocator did not
  # process (dead code) are dropped. Always cheap; the per-segment
  # join is O(N) in the number of named virtual registers per function.
  # Resolve each `Binding` in each function to a `(funcEntryIp,
  # entryIp, kind, phys, name)` row. Multiple bindings can resolve to
  # the same `(kind, phys)` -- intentional. The runtime snapshot
  # picks the binding with the largest `entryIp <= currentIp`, which
  # is the variable name actually visible at the pause site.
  def build_physical_name_table(segment_mappings)
    return [] unless segment_mappings

    out = []
    @function_var_names.each_value do |fv|
      mapping = segment_mappings[fv.entry_ip]
      next unless mapping

      bindings_out = []
      fv.bindings.each do |b|
        kind_map = mapping[b.kind]
        next unless kind_map
        phys = kind_map[[b.kind, b.virt]]
        next unless phys

        bindings_out << Binding.new(
          source_line: b.source_line,
          source_column: b.source_column,
          end_source_line: -1,
          kind: b.kind,
          virt: phys,
          name: b.name,
          type_name: b.type_name
        )
      end
      next if bindings_out.empty?

      # Compute each binding's end_source_line: the last line where
      # the binding's name still resolves. With linear-scan reuse,
      # multiple bindings share `(kind, phys)`; we set each binding's
      # end_source_line to the *next* binding's source_line. Pause-at-
      # line-N happens before line N executes, so the previous name
      # is still semantically valid AT line N (the slot transitions
      # only after the assignment runs). The last binding in a slot
      # keeps `end_source_line = -1`, the sentinel meaning "lives
      # until the function returns".
      bindings_out.group_by { |b| [b.kind, b.virt] }.each_value do |group|
        sorted = group.sort_by(&:source_line)
        sorted.each_cons(2) do |earlier, later|
          earlier.end_source_line = later.source_line
        end
      end

      out << VarNamesByFunction.new(entry_ip: fv.entry_ip, bindings: bindings_out)
    end
    out
  end

  def serialize_const(value)
    return "F:#{value[1]}" if value.is_a?(Array) && value[0] == :f64
    return "S:#{value.bytesize}:#{value}" if value.is_a?(String)

    "I:#{value}"
  end

  private

  def compile_function(function)
    return if @compiled_functions[function.name.to_s]

    @compiled_functions[function.name.to_s] = true
    saved_function_name = @current_function_name
    saved_fn = @current_fn
    @current_fn = function
    @current_function_name = function.name.to_s
    saved_iregs = @ireg_by_name
    saved_fregs = @freg_by_name
    saved_sregs = @sreg_by_name
    saved_vregs = @vreg_by_name
    saved_vkinds = @vkind_by_name
    saved_values = @value_by_name
    saved_callables = @callable_by_name
    saved_tag_types = @tag_type_by_name
    saved_return_type = @return_type
    saved_next_ireg = @next_ireg
    saved_next_freg = @next_freg
    saved_next_sreg = @next_sreg
    saved_next_vreg = @next_vreg

    @ireg_by_name = {}
    @freg_by_name = {}
    @sreg_by_name = {}
    @vreg_by_name = {}
    @vkind_by_name = {}
    @value_by_name = {}
    @callable_by_name = {}
    @tag_type_by_name = {}
    @next_ireg = 0
    @next_freg = 0
    @next_sreg = 0
    @next_vreg = 0
    @return_type = normalize_type(function.ret_type)
    @function_entries[function.name.to_s] = @ops.length
    saved_source_line = @current_source_line
    @current_source_line = @function_source_lines&.fetch(function.name.to_s, 0) || 0
    saved_var_names = @bindings_in_function
    @bindings_in_function = []
    bind_function_params(function)
    semantic_body(function.body).each do |stmt|
      compile_stmt(stmt)
    end
    @function_frame_sizes[function.name.to_s] = [@next_ireg, @next_freg]
    @function_var_names[function.name.to_s] = VarNamesByFunction.new(
      entry_ip: @function_entries[function.name.to_s],
      bindings: @bindings_in_function
    )
  ensure
    @ireg_by_name = saved_iregs
    @freg_by_name = saved_fregs
    @sreg_by_name = saved_sregs
    @vreg_by_name = saved_vregs
    @vkind_by_name = saved_vkinds
    @value_by_name = saved_values
    @callable_by_name = saved_callables
    @tag_type_by_name = saved_tag_types
    @return_type = saved_return_type
    @next_ireg = saved_next_ireg
    @next_freg = saved_next_freg
    @next_sreg = saved_next_sreg
    @next_vreg = saved_next_vreg
    @current_source_line = saved_source_line if defined?(saved_source_line)
    @bindings_in_function = saved_var_names if defined?(saved_var_names)
    @current_function_name = saved_function_name if defined?(saved_function_name)
    @current_fn = saved_fn if defined?(saved_fn)
  end

  # Records a (kind, virtual_reg) -> name binding. Called from the same
  # spots that populate `@*reg_by_name`. Compiler-synthesized temps that
  # bypass the by_name maps (e.g. fresh_zero_ireg) get no entry, which
  # is the right behavior -- they have no user-visible name.
  def record_var_name(kind, virtual_reg, name, type_name = nil)
    return unless name && !name.empty?
    # Stamp the current CLEAR source line so the runtime snapshot can
    # tell which name is visible at a given pause line. Source lines
    # are stable across the optimizer (which can fold/remove ops);
    # bytecode IPs are not.
    #
    # `type_name` is the user-facing CLEAR type ("Int64", "Float64",
    # "String", "Bool", or nil for params where we haven't resolved
    # it). Stored alongside so `:p NAME` / `:info` can render values
    # in their declared type ("x: Int64 = 10" instead of "x = 10").
    @bindings_in_function << Binding.new(
      source_line: @current_source_line,
      source_column: @current_source_column,
      end_source_line: -1,
      kind: kind,
      virt: virtual_reg,
      name: name.to_s,
      type_name: type_name
    )
  end

  # Walks the AST::Program for top-level `AST::FunctionDef` nodes and
  # builds `name -> token.line`. Used by `compile_function` to stamp each
  # emitted opcode with the function's start line so VM crash messages
  # can say "vm.cht:142 in fn fib" instead of just "ip=387". Per-statement
  # granularity would require threading source-line through MIR; for now
  # function-level is the cheapest meaningful upgrade.
  def collect_function_source_lines(ast)
    return {} unless ast && ast.respond_to?(:statements)

    out = {}
    ast.statements.each do |stmt|
      next unless stmt.respond_to?(:token) && stmt.token.respond_to?(:line)
      next unless stmt.respond_to?(:name) && stmt.respond_to?(:body)
      name = stmt.name.to_s
      line = stmt.token.line
      out[name] = line
      # MIR lowering renames the user's `main` to `clearMain` (see MAIN_NAMES).
      # Mirror the alias so compile_function can still find the source line
      # by the renamed identifier.
      out["clearMain"] = line if name == "main"
      out["cheatMain"] = line if name == "main"
    end
    out
  end

  def bind_function_params(function)
    # MUTABLE container params (HashMap<UserUnion>, UserUnion[]@list,
    # etc.) are erased to `anytype` at MIR-lowering time so the same
    # function can take callers from different sites. Recover the
    # original type from the FunctionSignature stored on the frontend
    # result so we can pick the right register kind here.
    fn_sig = lookup_fn_sig(function.name)
    sig_params = fn_sig.respond_to?(:params) ? (fn_sig.params || []) : []
    callable_params(function).each_with_index do |param, _idx|
      effective_zig_type = param.zig_type
      if effective_zig_type.to_s == "anytype"
        # Match by stripped name (`_m_<x>` -> `<x>`).
        stripped = param.name.to_s.sub(/\A_m_/, "")
        sig_param = sig_params.find { |sp| sp[:name].to_s == stripped }
        if sig_param && sig_param[:type].respond_to?(:zig_type)
          effective_zig_type = sig_param[:type].zig_type
        end
      end
      case normalize_type(effective_zig_type)
      when :i64, :bool
        reg = fresh_ireg
        @ireg_by_name[param.name.to_s] = reg
        type_name = (normalize_type(param.zig_type) == :bool) ? "Bool" : "Int64"
        record_var_name(:i, reg, param.name.to_s, type_name)
        if (enum_type = enum_type_name(param.zig_type))
          @tag_type_by_name[param.name.to_s] = enum_type
        end
      when :f64
        reg = fresh_freg
        @freg_by_name[param.name.to_s] = reg
        record_var_name(:f, reg, param.name.to_s, "Float64")
      when :string
        reg = fresh_sreg
        @sreg_by_name[param.name.to_s] = reg
        record_var_name(:s, reg, param.name.to_s, "String")
      else
        list_type = list_value_type(effective_zig_type)
        vmap_info  = value_string_map_type?(effective_zig_type)
        vlist_info = value_list_type?(effective_zig_type)
        if list_type
          @vreg_by_name[param.name.to_s] = fresh_vreg
          @vkind_by_name[param.name.to_s] = list_type
        elsif vmap_info
          @vreg_by_name[param.name.to_s] = fresh_vreg
          @vkind_by_name[param.name.to_s] = :value_string_map
          @value_map_variants ||= {}
          @value_map_variants[param.name.to_s] = { union_name: vmap_info[:union_name], variants: vmap_info[:variants] }
        elsif vlist_info
          @vreg_by_name[param.name.to_s] = fresh_vreg
          @vkind_by_name[param.name.to_s] = :value_list
          @value_list_variants ||= {}
          @value_list_variants[param.name.to_s] = { union_name: vlist_info[:union_name], variants: vlist_info[:variants] }
        elsif int64_string_map_type?(effective_zig_type)
          @vreg_by_name[param.name.to_s] = fresh_vreg
          @vkind_by_name[param.name.to_s] = :int_map
        elsif numeric_int64_map_type?(effective_zig_type)
          @vreg_by_name[param.name.to_s] = fresh_vreg
          @vkind_by_name[param.name.to_s] = :numeric_int_map
        elsif numeric_float64_map_type?(effective_zig_type)
          @vreg_by_name[param.name.to_s] = fresh_vreg
          @vkind_by_name[param.name.to_s] = :numeric_f64_map
        elsif (struct_map_type = string_struct_map_type?(effective_zig_type))
          @value_by_name[param.name.to_s] = compile_struct_map_init(struct_map_type)
        elsif effective_zig_type.to_s.match?(/\A(?:CheatLib\.)?(?:Sharded)?Pool\(/)
          # Pool params: placeholder binding -- the inline-call path
          # overrides @pool_info with the caller's actual pool when
          # the call site is compiled.
          @vkind_by_name[param.name.to_s] = :pool
        else
          raise Unsupported, "register emitter only supports Int64, Float64 and list helper params in this tranche"
        end
      end
    end
  end

  # Look up a fn signature by FnDef name. The MIR lowering strips the
  # `!` from fn names, so try the bare name and the `!` variant. Also
  # handle the `clearMain` <-> `main` rename.
  def lookup_fn_sig(name)
    return nil unless @frontend_result.respond_to?(:fn_sigs)
    sigs = @frontend_result.fn_sigs
    candidates = [name.to_s, name.to_s + "!", name.to_s.sub(/\AclearMain\z/, "main")]
    candidates.each do |c|
      sig = sigs[c]
      return sig if sig
    end
    nil
  end

  def callable_params(function)
    function.params.reject do |param|
      ["rt", "_rt"].include?(param.name.to_s) && param.zig_type.to_s.include?("Runtime")
    end
  end

  def semantic_body(body)
    body.reject do |stmt|
      stmt.is_a?(MIR::Comment) ||
        stmt.is_a?(MIR::Suppress) ||
        quota_setter?(stmt) ||
        runtime_yield_check?(stmt) ||
        runtime_loop_mark?(stmt) ||
        runtime_loop_mark_restore?(stmt)
    end
  end

  def quota_setter?(stmt)
    stmt.is_a?(MIR::ExprStmt) &&
      stmt.expr.is_a?(MIR::Call) &&
      stmt.expr.callee.to_s == "@setEvalBranchQuota"
  end

  # `@reentrant` / `@nonReentrant` decorate every fn with a
  # safety.StackGuard prologue:
  #     `_guard = try safety.StackGuard.enter(@src);`
  #     `_guard.push();`
  #     `defer _guard.pop();`
  # The guard is a runtime reentrancy detector that has no analogue
  # in the bc VM (which is single-threaded with its own stack frames),
  # so all three statements compile to nothing.
  def reentrant_guard_stmt?(stmt)
    case stmt
    when MIR::Let
      stmt.name.to_s == "_guard" &&
        stmt.init.is_a?(MIR::TryExpr) &&
        stmt.init.expr.is_a?(MIR::Call) &&
        stmt.init.expr.callee.to_s == "safety.StackGuard.enter"
    when MIR::ExprStmt
      (stmt.expr.is_a?(MIR::MethodCall) &&
        stmt.expr.receiver.is_a?(MIR::Ident) &&
        stmt.expr.receiver.name.to_s == "_guard" &&
        %w[push pop].include?(stmt.expr.method.to_s)) ||
      # @nonReentrant: bare `safety.enterDepth()` / `safety.exitDepth()`
      (stmt.expr.is_a?(MIR::Call) &&
        stmt.expr.callee.to_s.start_with?("safety."))
    when MIR::DeferStmt
      (stmt.body.is_a?(MIR::MethodCall) &&
        stmt.body.receiver.is_a?(MIR::Ident) &&
        stmt.body.receiver.name.to_s == "_guard" &&
        stmt.body.method.to_s == "pop") ||
      # `defer safety.exitDepth();` from @nonReentrant fns.
      (stmt.body.is_a?(MIR::Call) &&
        stmt.body.callee.to_s.start_with?("safety."))
    else
      false
    end
  end

  def runtime_yield_check?(stmt)
    stmt.is_a?(MIR::ExprStmt) &&
      stmt.expr.is_a?(MIR::MethodCall) &&
      stmt.expr.receiver.is_a?(MIR::Ident) &&
      stmt.expr.receiver.name.to_s == "rt" &&
      stmt.expr.method.to_s == "checkYield"
  end

  def runtime_loop_mark?(stmt)
    stmt.is_a?(MIR::Let) &&
      stmt.name.to_s.start_with?("__loop_mark_") &&
      stmt.init.is_a?(MIR::MethodCall) &&
      stmt.init.receiver.is_a?(MIR::Ident) &&
      stmt.init.receiver.name.to_s == "rt" &&
      stmt.init.method.to_s == "saveLoopMark"
  end

  def runtime_loop_mark_restore?(stmt)
    stmt.is_a?(MIR::DeferStmt) &&
      stmt.body.is_a?(MIR::MethodCall) &&
      stmt.body.receiver.is_a?(MIR::Ident) &&
      stmt.body.receiver.name.to_s == "rt" &&
      stmt.body.method.to_s == "restoreLoopMark"
  end

  def compile_stmt(stmt)
    # Per-statement source-line override: MIR::Stmt nodes are stamped by
    # `lower_body` in mir_lowering.rb with the originating AST stmt's
    # token line. Falls back to the function-level line set in
    # compile_function when the MIR node was synthesized (no AST origin).
    saved_line = @current_source_line
    saved_col  = @current_source_column
    if stmt.respond_to?(:source_line) && stmt.source_line
      @current_source_line = stmt.source_line
      @current_source_column = stmt.respond_to?(:source_column) ? (stmt.source_column || 0) : 0
    end
    result = compile_stmt_inner(stmt)
    @current_source_line = saved_line
    @current_source_column = saved_col
    result
  end

  def compile_stmt_inner(stmt)
    return nil if reentrant_guard_stmt?(stmt)

    case stmt
    when MIR::Comment, MIR::Suppress, MIR::Noop
      nil
    when MIR::FrameSave, MIR::FrameRestore, MIR::AllocMark, MIR::Cleanup, MIR::ErrCleanup, MIR::ErrDeferStmt,
         MIR::ReturnMark, MIR::MoveMark, MIR::ReassignMark, MIR::TransferMark, MIR::FieldCleanupMark,
         MIR::OwnedCreate, MIR::OwnedDestroy, MIR::OwnedTransfer, MIR::OwnedBorrow, MIR::OwnedStore, MIR::OwnedReturn
      nil
    when MIR::CatchWrapper
      compile_catch_wrapper(stmt)
    when MIR::ScopeBlock
      compile_scope_block(stmt)
    when MIR::Let
      compile_let(stmt)
    when MIR::Set
      compile_set(stmt)
    when MIR::ReassignWithCleanup
      compile_reassign_with_cleanup(stmt)
    when MIR::IfStmt
      compile_if(stmt)
    when MIR::IfChain
      compile_if_chain(stmt)
    when MIR::WhileStmt
      compile_while(stmt)
    when MIR::ContinueStmt
      compile_continue(stmt)
    when MIR::BreakStmt
      compile_break(stmt)
    when MIR::SwitchStmt
      compile_switch(stmt)
    when MIR::ReturnStmt
      compile_return(stmt)
    when MIR::InlineBc
      compile_inline_bc_stmt(stmt)
    when MIR::InlineZig
      compile_inline_zig_stmt(stmt)
    when MIR::Call
      compile_call_stmt(stmt)
    when MIR::DeferStmt
      compile_defer_stmt(stmt)
    when MIR::ShardedMapPut
      compile_sharded_map_put(stmt)
    when MIR::IndexInsert
      compile_index_insert(stmt)
    when MIR::ExprStmt
      compile_expr_stmt(stmt)
    when MIR::ForStmt
      compile_for_stmt(stmt)
    when MIR::Pipeline
      # Migrated pipeline operators carry the lowered shape (ForStmt
      # over range / list / etc.) in `inner`. Pass through.
      compile_stmt(stmt.inner)
    when MIR::Sort
      compile_sort(stmt)
    when MIR::IfBindStmt
      compile_if_bind_stmt(stmt)
    when MIR::SnapshotRead
      compile_snapshot_read(stmt)
    when MIR::SnapshotTransaction
      compile_snapshot_transaction(stmt)
    when MIR::SnapshotMultiTxn
      compile_snapshot_multi_txn(stmt)
    when MIR::WithMatchDispatch
      compile_with_match_dispatch(stmt)
    when MIR::PolymorphicMutate, MIR::PolymorphicMutateFlow
      compile_polymorphic_mutate(stmt)
    when MIR::StructDef, MIR::EnumDef, MIR::UnionTypeDef
      # Type-definition forms appear when the language drops them
      # inline (rare; usually flattened to module level). The bc
      # emitter already collected types in collect_type_defs; it's
      # safe to no-op them at stmt time.
      nil
    when MIR::BlockExpr
      # Side-effect-only BlockExpr in stmt position (a WITH wrapper
      # that doesn't break a value). A fallible WITH lowers here, not
      # to ScopeBlock, so it needs the same lock-release/escape drain.
      with_lock_scope { semantic_body(stmt.body || []).each { |child| compile_stmt(child) } }
    when MIR::MethodCall
      # Bare-statement form (`NEXT p;` / `q.next();`) -- route through
      # the ExprStmt path so the same dispatch handles it.
      compile_expr_stmt(MIR::ExprStmt.new(stmt, false))
    when MIR::TryExpr
      # `call() OR RAISE;` at statement position (result discarded).
      # Compile the inner call, then propagate if it raised.
      compile_try_stmt(stmt)
    when MIR::TryCatch
      # `call() OR { ... };` at statement position -- run the catch
      # body if the call raised (ECLR first), else fall through.
      compile_try_catch_stmt(stmt)
    when MIR::AssertStmt
      compile_assert_stmt(stmt)
    else
      raise Unsupported, "register emitter does not support #{stmt.class.name} yet"
    end
  end

  def compile_assert_stmt(stmt)
    cond = compile_bool_expr(stmt.cond)
    emit(JF, cond, 0)
    fail_patch = @ops.length - 1
    emit(JMP, 0)
    pass_patch = @ops.length - 1
    @ops[fail_patch] = @ops.length
    emit(HALT)
    @ops[pass_patch] = @ops.length
  end

  def compile_defer_stmt(stmt)
    body = stmt.body
    return nil if body.is_a?(MIR::Call) && body.callee.to_s.match?(/\A(?:CheatLib\.)?(?:rcRelease|arcRelease|weakRcRelease|weakArcRelease)\z/)

    # WITH EXCLUSIVE lock-release write-back: `defer { *_m_c = c }`.
    # In the bc field-decomposed cap-struct model the WITH body
    # mutated the shared field regs in place (caller and callee
    # alias the same value identity -- see compile_struct_arg /
    # anytype_arg_type), so the write-back through the by-pointer
    # param is redundant. Single-threaded VM: the lock itself is a
    # no-op. Any non-write-back defer body still raises.
    return nil if with_release_writeback?(body)

    raise Unsupported, "register emitter does not support MIR::DeferStmt yet"
  end

  def with_release_writeback?(body)
    return false unless body.is_a?(MIR::ScopeBlock)

    stmts = semantic_body(body.body || [])
    !stmts.empty? && stmts.all? { |s| s.is_a?(MIR::Set) && s.target.is_a?(MIR::Deref) }
  end

  # Lower `MIR::ForStmt iter=ListItems(<list>) capture=<name> body=...`
  # to a length-bounded WHILE that binds the capture to the indexed
  # element on each iteration. This is the iteration shape pipelines
  # (REDUCE/SUM/SELECT/WHERE/EACH/...) lower into; without ForStmt
  # support the bc emitter can't run any of them.
  def compile_for_stmt(stmt)
    iter = stmt.iter
    # Pipeline-host lowerings sometimes wrap the iter in AddressOf for
    # MUTABLE pointer-passing; unwrap. ItemsAccess is the safe-deref
    # wrapper around list locals (`*xs.items` style); unwrap too.
    loop do
      if iter.is_a?(MIR::AddressOf)
        iter = iter.expr
      elsif iter.is_a?(MIR::ItemsAccess)
        iter = iter.expr
      else
        break
      end
    end
    if iter.is_a?(MIR::Ident) && @vkind_by_name[iter.name.to_s] == :struct_list
      return compile_struct_list_for_stmt(iter.name.to_s, stmt)
    end
    if iter.is_a?(MIR::Ident) && @vkind_by_name[iter.name.to_s] == :pool
      return compile_pool_for_stmt(iter.name.to_s, stmt)
    end
    if iter.is_a?(MIR::FieldGet) &&
       iter.field.to_s == "slots" &&
       iter.object.is_a?(MIR::Ident) &&
       @vkind_by_name[iter.object.name.to_s] == :pool
      return compile_pool_slots_for_stmt(iter.object.name.to_s, stmt)
    end
    if iter.is_a?(MIR::IterRange)
      return compile_iter_range_for_stmt(iter, stmt)
    end
    # Bare list Ident as iter (e.g. fixed-size array `FOR e IN x DO`)
    # is equivalent to `ListItems(x)`.
    if iter.is_a?(MIR::Ident) && @vreg_by_name.key?(iter.name.to_s)
      iter = MIR::ListItems.new(iter)
    end
    unless iter.is_a?(MIR::ListItems)
      raise Unsupported, "register emitter only supports ForStmt over ListItems / IterRange / struct_list in this tranche"
    end

    # Resolve the list to (kind, reg). Local Idents look up directly;
    # non-Ident sources (e.g. `raw |> split(",") |> SELECT ...` where
    # the iter is the split result) compile through compile_value_expr
    # to produce a list-shaped value bound to a fresh vreg.
    if iter.list.is_a?(MIR::Ident) && @vkind_by_name[iter.list.name.to_s] == :struct_list
      return compile_struct_list_for_stmt(iter.list.name.to_s, stmt)
    end
    if iter.list.is_a?(MIR::Ident) && @vreg_by_name.key?(iter.list.name.to_s)
      list_name = iter.list.name.to_s
      list_kind = @vkind_by_name.fetch(list_name)
      list_reg = @vreg_by_name.fetch(list_name)
    else
      value = compile_value_expr(iter.list)
      unless value && %i[int_list f64_list string_list value_list].include?(value[:kind])
        raise Unsupported, "register emitter expected list-producing iter for ForStmt, got #{value.inspect[0..80]}"
      end
      list_name = "__for_iter_#{@ops.length}"
      list_kind = value[:kind]
      list_reg = value[:reg]
      @vreg_by_name[list_name] = list_reg
      @vkind_by_name[list_name] = list_kind
      if list_kind == :value_list && value[:variant_map]
        @value_list_variants ||= {}
        @value_list_variants[list_name] = { union_name: value[:union_name], variants: value[:variant_map] }
      end
    end
    capture = stmt.capture.to_s.sub(/\A\*+/, "")
    raise Unsupported, "register emitter expected a capture for ForStmt" if capture.empty?

    len_reg = fresh_ireg
    len_op = case list_kind
             when :int_list then LLEN
             when :f64_list then LFLEN
             when :string_list then LSLEN
             when :value_list then LVLEN
             else raise Unsupported, "register emitter cannot iterate list kind #{list_kind.inspect} yet"
             end
    emit(len_op, len_reg, list_reg)

    i_reg = fresh_ireg
    emit(ICONST, i_reg, add_const(0))

    one_reg = fresh_ireg
    emit(ICONST, one_reg, add_const(1))

    loop_start = @ops.length
    cond_reg = fresh_ireg
    emit(ILT, cond_reg, i_reg, len_reg)
    emit(JF, cond_reg, 0)
    exit_target_idx = @ops.length - 1

    saved_continue = @loop_continue_target
    saved_breaks = @loop_break_patches
    saved_continue_patches = @loop_continue_patches
    @loop_continue_target = :deferred_for_update
    @loop_break_patches = []
    @loop_continue_patches = []

    saved_iregs = @ireg_by_name.dup
    saved_fregs = @freg_by_name.dup
    saved_sregs = @sreg_by_name.dup
    saved_values = @value_by_name.dup
    saved_vkinds = @vkind_by_name.dup

    case list_kind
    when :int_list
      cap_reg = fresh_ireg
      emit(LGETI, cap_reg, list_reg, i_reg)
      @ireg_by_name[capture] = cap_reg
    when :f64_list
      cap_reg = fresh_freg
      emit(LFGET, cap_reg, list_reg, i_reg)
      @freg_by_name[capture] = cap_reg
    when :string_list
      cap_reg = fresh_sreg
      emit(LSGET, cap_reg, list_reg, i_reg)
      @sreg_by_name[capture] = cap_reg
    when :value_list
      list_info = (@value_list_variants || {})[list_name]
      raise Unsupported, "register emitter lost variant map for value list #{list_name.inspect}" unless list_info
      variant_map = list_info[:variants]
      union_name = list_info[:union_name]

      raw_tag = fresh_ireg
      emit(LVGETTAG, raw_tag, list_reg, i_reg)
      tag_reg = translate_rv_tag_to_user_position(raw_tag, variant_map, union_name)
      payloads = {}
      variant_map.each do |variant_name, info|
        case info[:kind]
        when :int
          reg = fresh_ireg
          emit(LVGETI, reg, list_reg, i_reg)
          payloads[variant_name] = reg
        when :float
          reg = fresh_freg
          emit(LVGETF, reg, list_reg, i_reg)
          payloads[variant_name] = reg
        when :string
          reg = fresh_sreg
          emit(LVGETS, reg, list_reg, i_reg)
          payloads[variant_name] = reg
        end
      end
      @value_by_name[capture] = {
        kind: :union,
        type: union_name,
        tag: nil,
        tag_reg: tag_reg,
        payloads: payloads,
      }
    end

    semantic_body(stmt.body || []).each { |child| compile_stmt(child) }

    continue_target = @ops.length
    @loop_continue_patches.each { |idx| @ops[idx] = continue_target }
    new_i = fresh_ireg
    emit(IADD, new_i, i_reg, one_reg)
    emit(IMOV, i_reg, new_i)
    emit(JMP, loop_start)
    @loop_break_patches.each { |idx| @ops[idx] = @ops.length }
    @ops[exit_target_idx] = @ops.length
  ensure
    @ireg_by_name = saved_iregs if saved_iregs
    @freg_by_name = saved_fregs if saved_fregs
    @sreg_by_name = saved_sregs if saved_sregs
    @value_by_name = saved_values if saved_values
    @vkind_by_name = saved_vkinds if saved_vkinds
    @loop_continue_target = saved_continue if defined?(saved_continue)
    @loop_break_patches = saved_breaks if defined?(saved_breaks)
    @loop_continue_patches = saved_continue_patches if defined?(saved_continue_patches)
  end

  # ExprStmt with a discardable side-effecting MethodCall. The
  # map-literal sugar `{"k": v}` lowers to a build-block whose body
  # has `__hm.put(rt.heapAlloc(), key, value)` ExprStmts; recognizing
  # those here lets compile_value_block_expr walk the body cleanly.
  def compile_expr_stmt(stmt)
    expr = stmt.expr
    if expr.is_a?(MIR::MethodCall) && expr.receiver.is_a?(MIR::Ident) &&
       expr.method.to_s == "put" && @vkind_by_name[expr.receiver.name.to_s] == :int_map
      args = expr.args || []
      # CLEAR's hashmap put lowering passes leading allocator args
      # (one or two `rt.heapAlloc()` calls); key+value are the last
      # two. The bytecode VM's MPUTI/MPUTIR ignores allocator args
      # because the slot owns its own storage.
      raise Unsupported, "register emitter expected at least 2 args for hashmap put" unless args.length >= 2
      key_expr = args[-2]
      value_expr = args[-1]
      map_reg = @vreg_by_name.fetch(expr.receiver.name.to_s)
      key_kind, key_operand = map_string_key_operand(key_expr)
      value_reg = compile_i64_expr(value_expr)
      if key_kind == :literal
        emit(MPUTI, map_reg, key_operand, value_reg)
      else
        emit(MPUTIR, map_reg, key_operand, value_reg)
      end
      return
    end

    if expr.is_a?(MIR::MethodCall) && expr.receiver.is_a?(MIR::Ident) &&
       expr.method.to_s == "next"
      # NEXT on a void-payload BG promise (side-effect-only body).
      # The body has already run synchronously at the BG site; NEXT
      # is a no-op.
      name = resolve_ctx_name(expr.receiver.name)
      promise = (@bg_promise_bindings || {})[name]
      if promise && promise.fetch(:payload_kind) == :void
        # Real fiber: NEXT must join (force the fiber to run to
        # completion). Inline body already ran; NEXT is a no-op.
        if promise[:fiber]
          dst = fresh_ireg
          emit(FNEXTI, dst, promise.fetch(:reg))
        end
        return
      end
    end

    if expr.is_a?(MIR::MethodCall) &&
       %w[store fetchAdd fetchSub].include?(expr.method.to_s) &&
       (atomic_target = atomic_receiver_ident(expr.receiver))
      # Atomic mutation on a scalar binding. Single-threaded VM:
      # equivalent to plain assignment / += / -=.
      val = (expr.args || []).reject { |a| a.is_a?(MIR::AllocatorRef) }.first
      raise Unsupported, "register emitter expected one value arg for #{expr.method}" unless val
      method = expr.method.to_s
      name = atomic_target.name.to_s
      record_shared_event(:write, name, :atomic_primitive,
                          caps: { ownership: :none, sync: :atomic_primitive })
      if @ireg_by_name.key?(name)
        v = compile_i64_expr(val); dst = @ireg_by_name[name]
        case method
        when "store"     then emit(IMOV, dst, v)
        when "fetchAdd"  then emit(IADD, dst, dst, v)
        when "fetchSub"  then emit(ISUB, dst, dst, v)
        end
        return
      elsif @freg_by_name.key?(name)
        v = compile_f64_expr(val); dst = @freg_by_name[name]
        case method
        when "store"     then emit(FMOV, dst, v)
        end
        return
      end
    end

    if set_error_stmt?(stmt)
      # RAISE -> `rt.setError(kind, name, msg, line)`. Emit ERAISE
      # (sets VM error state). The following `RETURN error.CheatError`
      # becomes EGUARD. See docs/agents/register-error-union.md.
      compile_set_error(expr)
      return
    end

    if expr.is_a?(MIR::MethodCall) && expr.receiver.is_a?(MIR::Ident) && runtime_arg?(expr.receiver)
      # `rt.checkYield()`, `rt.freeSnapshot()`, etc. are runtime hooks
      # the bc VM has no analogue for -- no-op.
      return
    end

    if expr.is_a?(MIR::MethodCall) && expr.receiver.is_a?(MIR::Ident) &&
       expr.method.to_s == "insert" && (@set_views || {})[expr.receiver.name.to_s]
      raw_args = expr.args || []
      value_args = raw_args.reject { |a| a.is_a?(MIR::AllocatorRef) }
      raise Unsupported, "register emitter expected exactly 1 value arg for set insert" unless value_args.length == 1
      name = expr.receiver.name.to_s
      kind = @vkind_by_name[name]
      if kind == :int_map
        compile_set_insert_string(name, value_args.first)
      else
        compile_set_insert_numeric(name, value_args.first)
      end
      return
    end

    if expr.is_a?(MIR::MethodCall) && expr.receiver.is_a?(MIR::Ident) &&
       expr.method.to_s == "append" && @vkind_by_name.key?(expr.receiver.name.to_s)
      # Pipeline-lowered list append: `res_list.append(allocator, val)`.
      # Strip the leading AllocatorRef args; the bytecode VM owns the
      # list's storage so it ignores allocator hints.
      raw_args = expr.args || []
      value_args = raw_args.reject { |a| a.is_a?(MIR::AllocatorRef) }
      raise Unsupported, "register emitter expected exactly 1 value arg for list append" unless value_args.length == 1
      list_name = expr.receiver.name.to_s
      list_kind = @vkind_by_name.fetch(list_name)
      if list_kind == :struct_list
        compile_struct_list_append(list_name, value_args.first)
        return
      end
      list_reg = @vreg_by_name.fetch(list_name)
      case list_kind
      when :int_list
        emit(LAPPENDI, list_reg, compile_i64_expr(value_args.first))
      when :f64_list
        emit(LFAPPEND, list_reg, compile_f64_expr(value_args.first))
      when :string_list
        emit(LSAPPEND, list_reg, compile_string_expr(value_args.first))
      else
        raise Unsupported, "register emitter does not support .append() on #{list_kind.inspect}"
      end
      return
    end

    # InlineBc / InlineZig as bare ExprStmt (e.g. `pool.remove(id);`,
    # `sleep(ms);`) -- delegate to the stmt-shaped dispatch.
    if expr.is_a?(MIR::InlineBc) || expr.is_a?(MIR::InlineZig)
      return compile_inline_bc_stmt(expr)
    end

    # `try expr;` / `call() OR RAISE;` as an ExprStmt -- compile the
    # inner (result discarded), then propagate if it raised.
    if expr.is_a?(MIR::TryExpr)
      return compile_try_stmt(expr)
    end

    # Bare Call discarding the result. Routes through compile_call_stmt.
    if expr.is_a?(MIR::Call)
      return compile_call_stmt(expr)
    end

    raise Unsupported, "register emitter does not support ExprStmt of #{expr.class.name} yet"
  end

  # Scope guarding the lock-release/fallible-escape stacks: emit
  # LOCKREL for cells acquired within, and patch fallible-acquire
  # escape JUMPs to land past the releases. Both ScopeBlock (non-
  # fallible WITH) and stmt-position BlockExpr (fallible WITH) use it.
  def with_lock_scope
    @with_lock_releases ||= []
    @with_fallible_escapes ||= []
    saved = @with_lock_releases.length
    saved_esc = @with_fallible_escapes.length
    yield
    while @with_lock_releases.length > saved
      emit(LOCKREL, @with_lock_releases.pop)
    end
    while @with_fallible_escapes.length > saved_esc
      @ops[@with_fallible_escapes.pop] = @ops.length
    end
  end

  def compile_scope_block(stmt)
    with_lock_scope { semantic_body(stmt.body || []).each { |child| compile_stmt(child) } }
  end

  # Port of the stack VM's emit_fallible_lock_dispatch (bc_emitter.rb):
  # ON LockTimeout / RETRY acquire. LOCKACQ writes 1 (acquired) or 0
  # (timed out) into a reg; 0 falls into the retry/ON-action path, which
  # ends in an escape JUMP patched by compile_scope_block to land past
  # the LOCKREL. The acquired path registers the cell for release.
  def emit_fallible_lock_dispatch(fc, cell_reg)
    retries = fc.retries
    retry_reg = nil
    retry_top = nil
    if retries
      retry_reg = fresh_ireg
      emit(ICONST, retry_reg, add_const(0))
      retry_top = @ops.length
    end
    tmo = fresh_ireg
    emit(ICONST, tmo, add_const(100))
    res = fresh_ireg
    emit(LOCKACQ, res, cell_reg, tmo)
    emit(JF, res, 0)
    to_err = @ops.length - 1
    emit(JMP, 0)
    to_ok = @ops.length - 1
    @ops[to_err] = @ops.length
    if retries
      one = fresh_ireg
      emit(ICONST, one, add_const(1))
      nxt = fresh_ireg
      emit(IADD, nxt, retry_reg, one)
      lim = fresh_ireg
      emit(ICONST, lim, add_const(retries.to_i))
      lt = fresh_ireg
      emit(ILT, lt, nxt, lim)
      emit(JF, lt, 0)
      giveup = @ops.length - 1
      emit(IADD, retry_reg, retry_reg, one)
      emit(JMP, retry_top)
      @ops[giveup] = @ops.length
    end
    if fc.action_kind == :block
      semantic_body(fc.action_mir || []).each { |s| compile_stmt(s) }
    end
    emit(JMP, 0)
    @with_fallible_escapes ||= []
    @with_fallible_escapes << (@ops.length - 1)
    @ops[to_ok] = @ops.length
    @with_lock_releases << cell_reg
  end

  # The single cell-backed field's value-index reg, if `src` is a
  # single-i64-field @shared:locked struct (R6.2b). nil otherwise.
  def cell_backed_field_cell(src)
    fields = src && src[:fields]
    return nil unless fields && fields.size == 1
    fields.values.first[:cell]
  end

  def compile_return(stmt)
    if returns_cheat_error?(stmt)
      # `RETURN error.CheatError` -- preceding ERAISE set the VM error
      # state. Real frame: EGUARD pops it. Inlined: jump to inline
      # exit (unconditional -- this IS the error-return path; errored
      # is set; no value MOV).
      if @inline_return
        emit(JMP, 0)
        @inline_return.fetch(:patches) << (@ops.length - 1)
      else
        emit(EGUARD)
      end
      return
    end

    return compile_inline_return(stmt) if @inline_return

    unless stmt.value
      emit(HALT)
      return
    end

    case @return_type
    when :i64
      reg = compile_i64_expr(stmt.value)
      emit(IRET, reg)
    when :bool
      reg = compile_bool_expr(stmt.value)
      emit(IRET, reg)
    when :f64
      reg = compile_f64_expr(stmt.value)
      emit(FRET, reg)
    when :string
      reg = compile_string_expr(stmt.value)
      emit(SRET, reg)
    else
      raise Unsupported, "register emitter only supports Int64 and Float64 returns in Tranche 5"
    end
  end

  def compile_let(stmt)
    if stmt.init.is_a?(MIR::StructInit) && (struct_type = struct_list_map_type?(stmt.annotation))
      bind_value(stmt.name.to_s, compile_struct_list_map_init(struct_type))
      return
    end

    value = compile_value_expr(stmt.init)
    if value
      bind_value(stmt.name.to_s, value)
      return
    end

    begin
      # Alias the binding to the init's vreg when it's safe:
      # - non-Ident init produces a fresh vreg owned by no one else, so
      #   alias is always safe (saves a redundant MOV after ICONST/IADD/etc.).
      # - Ident init is shared with the source binding; alias only when
      #   alias_safe is set by lowering AND the binding is immutable.
      can_alias =
        if stmt.init.is_a?(MIR::Ident)
          stmt.alias_safe && !stmt.mutable
        else
          true
        end
      case binding_type(stmt)
      when :i64
        src = compile_i64_expr(stmt.init)
        if can_alias
          dst = src
        else
          dst = fresh_ireg
          emit(IMOV, dst, src)
        end
        @ireg_by_name[stmt.name.to_s] = dst; record_var_name(:i, dst, stmt.name.to_s, "Int64")
        if (enum_type = enum_binding_type(stmt))
          @tag_type_by_name[stmt.name.to_s] = enum_type
        end
      when :bool
        src = compile_bool_expr(stmt.init)
        if can_alias
          dst = src
        else
          dst = fresh_ireg
          emit(IMOV, dst, src)
        end
        @ireg_by_name[stmt.name.to_s] = dst; record_var_name(:i, dst, stmt.name.to_s, "Bool")
      when :f64
        src = compile_f64_expr(stmt.init)
        if can_alias
          dst = src
        else
          dst = fresh_freg
          emit(FMOV, dst, src)
        end
        @freg_by_name[stmt.name.to_s] = dst; record_var_name(:f, dst, stmt.name.to_s, "Float64")
      when :string
        src = compile_string_expr(stmt.init)
        if can_alias
          dst = src
        else
          dst = fresh_sreg
          emit(SMOV, dst, src)
        end
        @sreg_by_name[stmt.name.to_s] = dst; record_var_name(:s, dst, stmt.name.to_s, "String")
      else
        if stmt.init.is_a?(MIR::RangeLit)
          raise Unsupported, "register emitter does not yet lower RangeLit-as-value (used by stream pipelines like `~Int64[] = 0..<n`); needs the pipeline lowering work to be useful"
        end
        raise Unsupported, "register emitter only supports Int64 and Float64 locals in Tranche 5 (got #{stmt.init.class.name.split('::').last})"
      end
    rescue Unsupported
      return if unused_suppressed_local?(stmt)

      raise
    end
  end

  def unused_suppressed_local?(stmt)
    return false if stmt.mutable

    stmt.suppression.to_s.include?("_ = #{stmt.name};")
  end

  def compile_set(stmt)
    return compile_field_set(stmt.target, stmt.value) if stmt.target.is_a?(MIR::FieldGet)
    return compile_index_set(stmt.target, stmt.value) if stmt.target.is_a?(MIR::IndexGet)

    unless stmt.target.is_a?(MIR::Ident)
      raise Unsupported, "register emitter only supports assignment to local Int64/Float64 bindings or scalar struct fields in this tranche"
    end

    name = stmt.target.name.to_s
    if @ireg_by_name.key?(name)
      dst = @ireg_by_name[name]
      src = compile_i64_expr(stmt.value)
      emit(IMOV, dst, src) unless dst == src
    elsif @freg_by_name.key?(name)
      dst = @freg_by_name[name]
      src = compile_f64_expr(stmt.value)
      emit(FMOV, dst, src) unless dst == src
    elsif @sreg_by_name.key?(name)
      dst = @sreg_by_name[name]
      src = compile_string_expr(stmt.value)
      emit(SMOV, dst, src) unless dst == src
    elsif @value_by_name.key?(name)
      value = compile_value_expr(stmt.value)
      unless value && value.fetch(:kind) == @value_by_name[name].fetch(:kind)
        raise Unsupported, "register emitter expected value assignment for #{name.inspect}"
      end
      if value[:kind] == :struct
        assign_struct_value_to_binding(name, value)
      else
        @value_by_name[name] = value
      end
    else
      raise Unsupported, "register emitter cannot assign unknown local #{name.inspect}"
    end
  end

  def assign_struct_value_to_binding(name, src)
    dst = @value_by_name.fetch(name)
    dst_fields = dst.fetch(:fields)
    src.fetch(:fields).each do |fname, sfield|
      dfield = dst_fields[fname.to_s] || dst_fields[fname.to_sym]
      raise Unsupported, "register emitter missing destination field #{fname.inspect} for #{name.inspect}" unless dfield

      case dfield.fetch(:type)
      when :i64, :bool
        emit(IMOV, dfield.fetch(:reg), sfield.fetch(:reg)) unless dfield.fetch(:reg) == sfield.fetch(:reg)
      when :f64
        emit(FMOV, dfield.fetch(:reg), sfield.fetch(:reg)) unless dfield.fetch(:reg) == sfield.fetch(:reg)
      when :string
        emit(SMOV, dfield.fetch(:reg), sfield.fetch(:reg)) unless dfield.fetch(:reg) == sfield.fetch(:reg)
      else
        if list_handle_type?(dfield.fetch(:type))
          dst_fields[fname.to_s] = sfield
        else
          raise Unsupported, "register emitter only supports scalar/list-handle struct reassignment fields in this tranche"
        end
      end
    end
  end

  def compile_reassign_with_cleanup(stmt)
    name = stmt.name.to_s
    if @ireg_by_name.key?(name)
      src = compile_i64_expr(stmt.value)
      dst = @ireg_by_name.fetch(name)
      emit(IMOV, dst, src) unless dst == src
    elsif @freg_by_name.key?(name)
      src = compile_f64_expr(stmt.value)
      dst = @freg_by_name.fetch(name)
      emit(FMOV, dst, src) unless dst == src
    elsif @sreg_by_name.key?(name)
      src = compile_string_expr(stmt.value)
      dst = @sreg_by_name.fetch(name)
      emit(SMOV, dst, src) unless dst == src
    else
      raise Unsupported, "register emitter cannot reassign unknown local #{name.inspect}"
    end
  end

  def compile_field_set(target, value)
    unless target.object.is_a?(MIR::Ident)
      raise Unsupported, "register emitter only supports assignment to local struct fields in this tranche"
    end

    object = @value_by_name[target.object.name.to_s]
    capability_struct_kinds = %i[struct rc_struct arc_struct locked_struct write_locked_struct local_struct versioned_struct atomic_ptr_struct]
    unless object && capability_struct_kinds.include?(object.fetch(:kind))
      raise Unsupported, "register emitter cannot assign field on unknown struct #{target.object.name.inspect}"
    end

    # Loom groundwork: a field write through a cap-wrapped binding
    # is a shared-memory write event. If the binding is a WITH-block
    # alias for a cap-wrapped source, attribute the event to the
    # underlying source instead.
    cap_kinds = %i[locked_struct write_locked_struct rc_struct arc_struct versioned_struct atomic_ptr_struct]
    if cap_kinds.include?(object[:kind])
      record_shared_event(:write, target.object.name, object[:kind], caps: caps_for_value(object))
    elsif (alias_src = (@cap_alias_source || {})[target.object.name.to_s])
      record_shared_event(:write, alias_src[:name], alias_src[:kind], caps: alias_src[:caps])
    end

    field = ensure_struct_field_loaded(object, target.field.to_s)
    raise Unsupported, "register emitter does not know struct field #{target.field.inspect}" unless field
    object[:dirty_fields][target.field.to_s] = true if object[:dirty_fields]

    if (cell = field[:cell])
      raise Unsupported, "register emitter only supports i64 shared store cells" unless field.fetch(:type) == :i64
      emit(SCELLSETI, cell, compile_i64_expr(value))
      return
    end

    field_type = field.fetch(:type)
    dst = field.fetch(:reg)
    unless dst.is_a?(Integer)
      raise Unsupported, "register emitter only supports scalar struct field assignment in this tranche"
    end

    case field_type
    when :i64
      src = compile_i64_expr(value)
      emit(IMOV, dst, src) unless dst == src
    when :f64
      src = compile_f64_expr(value)
      emit(FMOV, dst, src) unless dst == src
    else
      raise Unsupported, "register emitter only supports Int64 and Float64 struct field assignment in this tranche"
    end
    nil
  end

  def compile_index_set(target, value)
    if target.object.is_a?(MIR::Ident) && @value_by_name[target.object.name.to_s]&.fetch(:kind, nil) == :struct_map
      compile_struct_map_set(target, value)
      return
    end

    # `<struct_list>[i] = <struct_view>` / `<pool>[i] = <struct_view>`
    # -- write the struct's per-field regs back into the matching
    # parallel arrays at index i. Same shape for both; pool's alive
    # flags array isn't touched here (set/clear is via insert/remove).
    if target.object.is_a?(MIR::Ident) &&
       %i[struct_list pool].include?(@vkind_by_name[target.object.name.to_s])
      list_name = target.object.name.to_s
      list_kind = @vkind_by_name[list_name]
      info = (list_kind == :pool ? (@pool_info || {}) : (@struct_list_info || {}))[list_name]
      raise Unsupported, "register emitter lost #{list_kind} info for #{list_name.inspect}" unless info

      src = compile_value_expr(value)
      raise Unsupported, "register emitter expected struct value for struct_list[i] = ..., got #{src.inspect[0..80]}" unless src && src[:kind] == :struct
      idx_reg = compile_i64_expr(target.index)
      lazy = src[:lazy_struct_list]
      same_lazy_slot = lazy && lazy[:list_name] == list_name && lazy[:idx_reg] == idx_reg
      dirty_filter = src[:dirty_fields] if src[:dirty_fields] && (!src[:dirty_fields].empty? || same_lazy_slot)
      info[:fields].each do |fname, finfo|
        next if dirty_filter && !dirty_filter[fname.to_s]

        field = ensure_struct_field_loaded(src, fname.to_s)
        raise Unsupported, "register emitter missing field #{fname.inspect} in struct_list[i] assignment source" unless field
        case finfo[:kind]
        when :int_list    then emit(LSETI, finfo[:reg], idx_reg, field[:reg])
        when :f64_list    then emit(LFSET, finfo[:reg], idx_reg, field[:reg])
        when :string_list then emit(LSSET, finfo[:reg], idx_reg, field[:reg])
        end
      end
      return
    end

    if target.object.is_a?(MIR::Ident) && @vreg_by_name.key?(target.object.name.to_s)
      reg = @vreg_by_name.fetch(target.object.name.to_s)
      case @vkind_by_name.fetch(target.object.name.to_s)
      when :int_map
        key_kind, key_operand = map_string_key_operand(target.index)
        value_reg = compile_i64_expr(value)
        if key_kind == :literal
          emit(MPUTI, reg, key_operand, value_reg)
        else
          emit(MPUTIR, reg, key_operand, value_reg)
        end
      when :numeric_int_map
        key_reg = compile_i64_expr(target.index)
        value_reg = compile_i64_expr(value)
        emit(NMPUTI, reg, key_reg, value_reg)
      when :numeric_f64_map
        key_reg = compile_i64_expr(target.index)
        value_reg = compile_f64_expr(value)
        emit(NMPUTF, reg, key_reg, value_reg)
      when :int_list
        index_reg = compile_i64_expr(target.index)
        value_reg = compile_i64_expr(value)
        emit(LSETI, reg, index_reg, value_reg)
      when :f64_list
        index_reg = compile_i64_expr(target.index)
        value_reg = compile_f64_expr(value)
        emit(LFSET, reg, index_reg, value_reg)
      when :value_string_map
        compile_value_map_set(target, value, reg)
      else
        raise Unsupported, "register emitter only supports Int64 maps and Int64/Float64 list index assignment in this tranche"
      end
      return
    end

    raise Unsupported, "register emitter only supports local Int64 maps and Int64/Float64 list index assignment in this tranche"
  end

  # `valueList.append(Value{Variant: payload})` -- analogous to
  # compile_value_map_set but for the list opcode family.
  def compile_value_list_append(list_ident, value, list_reg)
    list_info = (@value_list_variants || {}).fetch(list_ident.name.to_s) do
      raise Unsupported, "register emitter lost variant map for value list #{list_ident.name.inspect}"
    end
    variant_map = list_info[:variants]

    variant_name, info = extract_value_variant_for_append(value, variant_map)
    case info[:kind]
    when :nil
      emit(LVAPPNIL, list_reg)
    when :int
      payload_reg = compile_i64_expr(extract_value_payload(value))
      emit(LVAPPI, list_reg, payload_reg)
    when :float
      payload_reg = compile_f64_expr(extract_value_payload(value))
      emit(LVAPPF, list_reg, payload_reg)
    when :string
      payload_reg = compile_string_expr(extract_value_payload(value))
      emit(LVAPPS, list_reg, payload_reg)
    end
  end

  def extract_value_variant_for_append(value, variant_map)
    case value
    when MIR::StructInit
      field = (value.fields || []).first
      raise Unsupported, "register emitter expected a tag field in StructInit for value list append" unless field
      vname = field.fetch(:name).to_s
      info = variant_map[vname]
      raise Unsupported, "register emitter does not recognize variant #{vname.inspect} on value list" unless info
      [vname, info]
    when MIR::FieldGet
      # Value.Nil-style nullary variant access.
      vname = value.field.to_s
      info = variant_map[vname]
      raise Unsupported, "register emitter does not recognize variant #{vname.inspect} on value list" unless info
      raise Unsupported, "register emitter expected nullary variant for FieldGet append (got #{vname.inspect})" unless info[:kind] == :nil
      [vname, info]
    else
      raise Unsupported, "register emitter only supports struct-literal or .Variant RHS for Value[]@list append"
    end
  end

  def extract_value_payload(value)
    case value
    when MIR::StructInit then (value.fields || []).first.fetch(:value)
    else value
    end
  end

  # Lower `valueMap[key] = Value{Variant: payload}` to a per-variant
  # VMPUT_* op. The variant name resolves to one of RegisterValue's
  # variant tags via the variant_map captured at container declaration.
  def compile_value_map_set(target, value, map_reg)
    map_info = (@value_map_variants || {}).fetch(target.object.name.to_s) do
      raise Unsupported, "register emitter lost variant map for value map #{target.object.name.inspect}"
    end
    variant_map = map_info[:variants]
    unless value.is_a?(MIR::StructInit)
      raise Unsupported, "register emitter only supports struct-literal RHS for HashMap<UserUnion> stores in Phase 1"
    end

    field = (value.fields || []).first
    unless field
      raise Unsupported, "register emitter expected a tag field in StructInit for value map store"
    end
    variant_name = field.fetch(:name).to_s
    info = variant_map[variant_name]
    unless info
      raise Unsupported, "register emitter does not recognize variant #{variant_name.inspect} on value map (tag fits {Nil, Int64, Float64, String} only)"
    end

    key_kind, key_operand = map_string_key_operand(target.index)
    is_lit = key_kind == :literal
    case info[:kind]
    when :nil
      emit(is_lit ? VMPUTNIL : VMPUTNILR, map_reg, key_operand)
    when :int
      payload_reg = compile_i64_expr(field.fetch(:value))
      emit(is_lit ? VMPUTI : VMPUTIR, map_reg, key_operand, payload_reg)
    when :float
      payload_reg = compile_f64_expr(field.fetch(:value))
      emit(is_lit ? VMPUTF : VMPUTFR, map_reg, key_operand, payload_reg)
    when :string
      payload_reg = compile_string_expr(field.fetch(:value))
      emit(is_lit ? VMPUTS : VMPUTSR, map_reg, key_operand, payload_reg)
    end
  end

  def compile_if(stmt)
    cond = compile_bool_expr(stmt.cond)
    emit(JF, cond, 0)
    false_target_idx = @ops.length - 1

    semantic_body(stmt.then_body || []).each { |child| compile_stmt(child) }

    if stmt.else_body && !stmt.else_body.empty?
      emit(JMP, 0)
      end_target_idx = @ops.length - 1
      @ops[false_target_idx] = @ops.length
      semantic_body(stmt.else_body).each { |child| compile_stmt(child) }
      @ops[end_target_idx] = @ops.length
    else
      @ops[false_target_idx] = @ops.length
    end
  end

  def compile_while(stmt)
    if stmt.capture
      raise Unsupported, "register emitter only supports plain WHILE loops in Tranche 4"
    end

    loop_start = @ops.length
    cond = compile_bool_expr(stmt.cond)
    emit(JF, cond, 0)
    exit_target_idx = @ops.length - 1

    saved_continue = @loop_continue_target
    saved_breaks = @loop_break_patches
    saved_continue_patches = @loop_continue_patches
    @loop_continue_target = stmt.update ? :deferred_while_update : loop_start
    @loop_break_patches = []
    @loop_continue_patches = []

    semantic_body(stmt.body || []).each { |child| compile_stmt(child) }
    continue_target = @ops.length
    (@loop_continue_patches || []).each { |idx| @ops[idx] = continue_target }
    compile_stmt(stmt.update) if stmt.update

    emit(JMP, loop_start)
    (@loop_break_patches || []).each { |idx| @ops[idx] = @ops.length }
    @ops[exit_target_idx] = @ops.length
  ensure
    @loop_continue_target = saved_continue
    @loop_break_patches = saved_breaks
    @loop_continue_patches = saved_continue_patches
  end

  def compile_continue(_stmt)
    raise Unsupported, "register emitter cannot compile CONTINUE outside a loop" unless @loop_continue_target

    if @loop_continue_target == :deferred_while_update || @loop_continue_target == :deferred_for_update
      emit(JMP, 0)
      @loop_continue_patches << (@ops.length - 1)
    else
      emit(JMP, @loop_continue_target)
    end
  end

  def compile_break(stmt)
    if stmt.value
      raise Unsupported, "register emitter only supports value-less BREAK in loops"
    end
    raise Unsupported, "register emitter cannot compile BREAK outside a loop" unless @loop_break_patches

    emit(JMP, 0)
    @loop_break_patches << (@ops.length - 1)
  end

  def compile_if_chain(stmt)
    end_patches = []

    stmt.branches.each do |branch|
      cond = compile_bool_expr(branch.fetch(:cond))
      emit(JF, cond, 0)
      next_target_idx = @ops.length - 1
      semantic_body(branch.fetch(:body) || []).each { |child| compile_stmt(child) }
      emit(JMP, 0)
      end_patches << (@ops.length - 1)
      @ops[next_target_idx] = @ops.length
    end

    semantic_body(stmt.default_body || []).each { |child| compile_stmt(child) }
    end_patches.each { |idx| @ops[idx] = @ops.length }
  end

  def compile_switch(stmt)
    subject_reg, tag_type = compile_tag_subject(stmt.subject)
    end_patches = []

    stmt.arms.each do |arm|
      pattern = arm.fetch(:pattern).to_s.delete_prefix(".")
      pattern_reg = tag_type ? compile_tag_const(tag_type, pattern) : compile_i64_expr(MIR::Lit.new(pattern))
      cond = fresh_ireg
      emit(IEQ, cond, subject_reg, pattern_reg)
      emit(JF, cond, 0)
      next_target_idx = @ops.length - 1
      semantic_body(arm.fetch(:body) || []).each { |child| compile_stmt(child) }
      emit(JMP, 0)
      end_patches << (@ops.length - 1)
      @ops[next_target_idx] = @ops.length
    end

    semantic_body(stmt.default_body || []).each { |child| compile_stmt(child) }
    end_patches.each { |idx| @ops[idx] = @ops.length }
  end

  def compile_inline_return(stmt)
    case @inline_return.fetch(:type)
    when :void
      nil
    when :i64
      src = compile_i64_expr(stmt.value)
      emit(IMOV, @inline_return.fetch(:reg), src) unless src == @inline_return.fetch(:reg)
    when :f64
      src = compile_f64_expr(stmt.value)
      emit(FMOV, @inline_return.fetch(:reg), src) unless src == @inline_return.fetch(:reg)
    when :string
      src = compile_string_expr(stmt.value)
      emit(SMOV, @inline_return.fetch(:reg), src) unless src == @inline_return.fetch(:reg)
    when :int_list, :f64_list
      value = compile_value_expr(stmt.value)
      unless value && value.fetch(:kind) == @inline_return.fetch(:type)
        raise Unsupported, "register emitter expected #{@inline_return.fetch(:type)} return"
      end
      @inline_return[:value] = value
    when Array
      expected_kind, expected_name = @inline_return.fetch(:type)
      cap_struct_kinds = %i[struct rc_struct arc_struct locked_struct write_locked_struct local_struct versioned_struct atomic_ptr_struct]
      unless %i[struct union].include?(expected_kind) || cap_struct_kinds.include?(expected_kind)
        raise Unsupported, "register emitter does not support #{@inline_return.fetch(:type).inspect} helper returns in this tranche"
      end

      value = compile_value_expr(stmt.value)
      # Cap-wrapped scalar structs share the field-decomposed layout,
      # so any of the cap-struct kinds is interchangeable with :struct
      # for inline-return matching. The expected kind from the fn sig
      # determines the binding's kind on the caller side.
      if value && cap_struct_kinds.include?(expected_kind) && cap_struct_kinds.include?(value[:kind])
        value = { kind: expected_kind, type: value[:type], fields: value[:fields] }
      end
      unless value && value.fetch(:kind) == expected_kind && value.fetch(:type) == expected_name
        raise Unsupported, "register emitter expected #{expected_kind} return #{expected_name.inspect}"
      end
      if expected_kind == :union && @inline_return[:value]
        copy_union_value_into(@inline_return.fetch(:value), value)
      else
        @inline_return[:value] = value
      end
    else
      raise Unsupported, "register emitter only supports Int64, Float64 and String helper returns in this tranche"
    end

    emit(JMP, 0)
    @inline_return.fetch(:patches) << (@ops.length - 1)
  end

  def compile_call_stmt(stmt)
    return compile_debug_print(stmt) if stmt.callee.to_s == "std.debug.print"
    # safety.* runtime helpers (StackGuard already elided by
    # reentrant_guard_stmt? in Tranche 9, but the @nonReentrant
    # variants land as bare Calls on `safety.enterDepth` /
    # `safety.exitDepth`). The bc VM has no analogous reentrancy
    # tracking, so they're no-ops.
    return nil if stmt.callee.to_s.start_with?("safety.")

    function = @functions_by_name[stmt.callee.to_s]
    raise Unsupported, "register emitter does not support external call #{stmt.callee.inspect} yet" unless function

    return_type = normalize_type(function.ret_type)
    compile_inline_function(function, return_type, compile_call_args(stmt.callee, function, stmt.args || []))
    nil
  end

  def compile_inline_bc_stmt(stmt)
    return compile_inline_zig_stmt(stmt) if stmt.is_a?(MIR::InlineZig)

    case stmt.op
    when :append, :insert, :push
      args = stmt.args || []
      receiver_is_plain_vreg = args[0].is_a?(MIR::Ident) && @vreg_by_name.key?(resolve_ctx_name(args[0].name))
      if args.length >= 2 && !receiver_is_plain_vreg && (handle = compile_list_handle_expr(args[0]))
        case handle.fetch(:kind)
        when :int_list_handle
          emit(IHAPPEND, handle.fetch(:reg), compile_i64_expr(args[1]))
        when :string_list_handle
          emit(SHAPPEND, handle.fetch(:reg), compile_string_expr(args[1]))
        end
        return
      end
      if args.length >= 2 && !args[0].is_a?(MIR::Ident)
        receiver_value = compile_value_expr(args[0])
        if receiver_value && receiver_value[:kind] == :struct_list
          append_struct_to_fields(receiver_value.fetch(:fields), receiver_value.fetch(:type), args[1])
          return
        end
      end

      unless args.length >= 2 && args[0].is_a?(MIR::Ident)
        raise Unsupported, "register emitter only supports local list append in this tranche"
      end
      list_name = args[0].name.to_s
      list_kind = @vkind_by_name[list_name]
      if list_kind == :struct_list
        compile_struct_list_append(list_name, args[1])
      elsif list_kind == :pool
        compile_pool_insert(list_name, args[1])
      elsif list_kind == :int_map && (@set_views || {})[list_name]
        # @set with String elements -> int_map (StringMap<Int64>) of
        # presence flags (always 1).
        compile_set_insert_string(list_name, args[1])
      elsif list_kind == :numeric_int_map && (@set_views || {})[list_name]
        # @set with Int64 elements -> numeric_int_map.
        compile_set_insert_numeric(list_name, args[1])
      else
        list_reg = @vreg_by_name.fetch(list_name) do
          raise Unsupported, "register emitter does not know list #{args[0].name.inspect}"
        end
        case list_kind
        when :int_list
          value_reg = compile_i64_expr(args[1])
          emit(LAPPENDI, list_reg, value_reg)
        when :f64_list
          value_reg = compile_f64_expr(args[1])
          emit(LFAPPEND, list_reg, value_reg)
        when :string_list
          value_reg = compile_string_expr(args[1])
          emit(LSAPPEND, list_reg, value_reg)
        when :value_list
          compile_value_list_append(args[0], args[1], list_reg)
        else
          raise Unsupported, "register emitter only supports Int64, Float64, String, and Value list append in this tranche"
        end
      end
    when :assert
      compile_bool_expr((stmt.args || []).first)
    when :writeFile
      args = stmt.args || []
      raise Unsupported, "register emitter expected 2 args for writeFile" unless args.length == 2
      path = compile_string_expr(args[0])
      content = compile_string_expr(args[1])
      emit_ncall(RET_VOID, 0, N_FILE_WRITE, [[ARG_S, path], [ARG_S, content]])
    when :delete
      args = stmt.args || []
      unless args.length >= 2 && args[0].is_a?(MIR::Ident)
        raise Unsupported, "register emitter only supports local HashMap<Int64> delete in this tranche"
      end
      kind = @vkind_by_name.fetch(args[0].name.to_s, nil)
      unless [:int_map, :numeric_int_map].include?(kind)
        raise Unsupported, "register emitter only supports HashMap<Int64> delete in this tranche"
      end

      map_reg = map_register_for(args[0])
      if kind == :numeric_int_map
        key_reg = compile_i64_expr(args[1])
        emit(NMDELETE, map_reg, key_reg)
      else
        key_idx = map_string_key_const(args[1])
        emit(MDELETE, map_reg, key_idx)
      end
    when :sleep
      # The bc VM has no clock; treat sleep as a no-op. Tests that
      # observe wall-clock behavior remain pending separately.
      nil
    when :reserve
      # The register VM lists grow on mutation; reserve only affects
      # capacity/perf on the Zig backend and is semantically a no-op here.
      nil
    when :remove
      args = stmt.args || []
      unless args.length >= 2 && args[0].is_a?(MIR::Ident)
        raise Unsupported, "register emitter only supports local pool/HashMap remove in this tranche"
      end
      target_name = args[0].name.to_s
      target_kind = @vkind_by_name[target_name]
      if target_kind == :pool
        compile_pool_remove(target_name, args[1])
      elsif (@set_views || {})[target_name]
        compile_set_remove(target_name, args[1], target_kind)
      else
        raise Unsupported, "register emitter does not support remove on #{target_kind.inspect}"
      end
    when :or_exit
      compile_or_exit(stmt)
    else
      raise Unsupported, "register emitter does not support MIR::InlineBc stmt #{stmt.op.inspect} yet"
    end
  end

  # `pool.insert(T{...})` -- decompose the struct into per-field
  # appends, push 1 onto alive, return the slot index as the ID.
  # Slots are append-only (no freelist); a removed slot stays in
  # place but with alive[slot]=0.
  def compile_pool_insert(pool_name, value_expr)
    info = (@pool_info || {})[pool_name]
    raise Unsupported, "register emitter lost pool info for #{pool_name.inspect}" unless info

    src = compile_value_expr(value_expr)
    raise Unsupported, "register emitter expected struct value for pool.insert, got #{src.inspect[0..80]}" unless src && src[:kind] == :struct
    raise Unsupported, "register emitter pool.insert type mismatch (got #{src[:type].inspect}, expected #{info[:type].inspect})" unless src[:type] == info[:type]

    # Capture the slot index BEFORE appending (length of alive array
    # before the alive=1 push). This is the ID returned to the user.
    id_reg = fresh_ireg
    emit(LLEN, id_reg, info[:alive_reg])

    info[:fields].each do |fname, finfo|
      field = src[:fields][fname.to_s] || src[:fields][fname]
      raise Unsupported, "register emitter missing field #{fname.inspect} in pool.insert source" unless field
      case finfo[:kind]
      when :int_list    then emit(LAPPENDI, finfo[:reg], field[:reg])
      when :f64_list    then emit(LFAPPEND, finfo[:reg], field[:reg])
      when :string_list then emit(LSAPPEND, finfo[:reg], field[:reg])
      end
    end
    one = fresh_ireg
    emit(ICONST, one, add_const(1))
    emit(LAPPENDI, info[:alive_reg], one)
    id_reg
  end

  # `pool.length()` -- count of alive flags (sum of the alive list,
  # since each entry is 0 or 1). Uses a small loop.
  def compile_pool_length(pool_name)
    info = (@pool_info || {})[pool_name]
    raise Unsupported, "register emitter lost pool info for #{pool_name.inspect}" unless info

    total = fresh_ireg
    emit(ICONST, total, add_const(0))
    len = fresh_ireg
    emit(LLEN, len, info[:alive_reg])
    i = fresh_ireg
    emit(ICONST, i, add_const(0))
    one = fresh_ireg
    emit(ICONST, one, add_const(1))

    loop_start = @ops.length
    cond = fresh_ireg
    emit(ILT, cond, i, len)
    emit(JF, cond, 0)
    exit_idx = @ops.length - 1

    flag = fresh_ireg
    emit(LGETI, flag, info[:alive_reg], i)
    emit(IADD, total, total, flag)
    emit(IADD, i, i, one)
    emit(JMP, loop_start)
    @ops[exit_idx] = @ops.length
    total
  end

  # `map.keys()` -- snapshot the map's keys into a fresh list slot.
  # MKEYS / NMKEYS handle the dispatch; the runtime arm calls
  # `map.keys()` on the underlying CLEAR HashMap, which returns a
  # `T[]@list` (ArrayList) post hotfix/keys-values-list-type-mismatch.
  def compile_map_keys(map_name)
    kind = @vkind_by_name[map_name]
    map_reg = @vreg_by_name.fetch(map_name)
    list_reg = fresh_vreg
    case kind
    when :int_map
      emit(MKEYS, list_reg, map_reg)
      { kind: :string_list, reg: list_reg }
    when :numeric_int_map
      emit(NMKEYS, list_reg, map_reg)
      { kind: :int_list, reg: list_reg }
    else
      raise Unsupported, "register emitter does not support .keys() on #{kind.inspect}"
    end
  end

  def compile_map_values(map_name)
    kind = @vkind_by_name[map_name]
    map_reg = @vreg_by_name.fetch(map_name)
    list_reg = fresh_vreg
    case kind
    when :int_map
      emit(MVALUES, list_reg, map_reg)
      { kind: :int_list, reg: list_reg }
    when :numeric_int_map
      emit(NMVALUES, list_reg, map_reg)
      { kind: :int_list, reg: list_reg }
    else
      raise Unsupported, "register emitter does not support .values() on #{kind.inspect}"
    end
  end

  # `set.contains?(elem)` -- read the underlying map's slot via OR
  # 0 fallback; non-zero means present. (Sets store 1 on insert.)
  def compile_set_contains(set_name, key_expr, kind)
    map_reg = @vreg_by_name.fetch(set_name)
    dst = fresh_ireg
    fallback_reg = fresh_ireg
    emit(ICONST, fallback_reg, add_const(0))
    if kind == :numeric_int_map
      key_reg = compile_i64_expr(key_expr)
      emit(NMGETI, dst, map_reg, key_reg, fallback_reg)
    else
      key_kind, key_operand = map_string_key_operand(key_expr)
      if key_kind == :literal
        emit(MGETI, dst, map_reg, key_operand, fallback_reg)
      else
        emit(MGETIR, dst, map_reg, key_operand, fallback_reg)
      end
    end
    dst
  end

  # `map.contains?(key)` for a plain HashMap -- routes through the
  # same get-or-0 path; presence-test is value-vs-0.
  def compile_map_contains(map_name, key_expr, kind)
    compile_set_contains(map_name, key_expr, kind)
  end

  # `set.insert(elem)` for a string-keyed @set -- record presence
  # by writing 1 to the underlying StringMap.
  def compile_set_insert_string(set_name, key_expr)
    map_reg = @vreg_by_name.fetch(set_name)
    key_kind, key_operand = map_string_key_operand(key_expr)
    one = fresh_ireg
    emit(ICONST, one, add_const(1))
    if key_kind == :literal
      emit(MPUTI, map_reg, key_operand, one)
    else
      emit(MPUTIR, map_reg, key_operand, one)
    end
  end

  # `set.insert(elem)` for an integer-keyed @set.
  def compile_set_insert_numeric(set_name, key_expr)
    map_reg = @vreg_by_name.fetch(set_name)
    key_reg = compile_i64_expr(key_expr)
    one = fresh_ireg
    emit(ICONST, one, add_const(1))
    emit(NMPUTI, map_reg, key_reg, one)
  end

  # `set.remove(elem)` -- delete from the underlying map.
  def compile_set_remove(set_name, key_expr, kind)
    map_reg = @vreg_by_name.fetch(set_name)
    if kind == :numeric_int_map
      key_reg = compile_i64_expr(key_expr)
      emit(NMDELETE, map_reg, key_reg)
    else
      key_idx = map_string_key_const(key_expr)
      emit(MDELETE, map_reg, key_idx)
    end
  end

  # `pool.remove(id)` -- alive[id] = 0. The pool keeps the slot
  # in place so other live IDs stay valid; the alive flag is the
  # sole "is this slot live?" signal for get/length/FIND/EACH.
  def compile_pool_remove(pool_name, id_expr)
    info = (@pool_info || {})[pool_name]
    raise Unsupported, "register emitter lost pool info for #{pool_name.inspect}" unless info
    id_reg = compile_i64_expr(id_expr)
    zero = fresh_ireg
    emit(ICONST, zero, add_const(0))
    emit(LSETI, info[:alive_reg], id_reg, zero)
  end

  def compile_inline_zig_stmt(stmt)
    code = stmt.code.to_s

    # WITH EXCLUSIVE/SHARED block: the lowering emits an InlineZig
    # blob that acquires/releases the lock and binds the inner
    # const. The bytecode VM is single-threaded, so the
    # acquire/release are no-ops -- we just mirror the binding.
    # Pull the bound name from the `const <name> = ...get();` line
    # and the source container from stdlib_def.borrows; the
    # acquire/release pattern is fixed (always present, always
    # the same shape) so we don't actually parse the Zig
    # semantically -- we look up two names and bind a new view.
    if stmt.reason.to_s == "with_block_bindings"
      compile_with_block_bindings(stmt)
      return
    end

    if (match = code.match(/\Atry\s+([A-Za-z_][A-Za-z0-9_]*)\.append\(\{alloc\},\s*(.+)\)\z/))
      list_reg = @vreg_by_name.fetch(match[1]) do
        raise Unsupported, "register emitter does not know list #{match[1].inspect}"
      end
      case @vkind_by_name.fetch(match[1])
      when :int_list
        value_reg = compile_i64_inline_zig_operand(match[2])
        emit(LAPPENDI, list_reg, value_reg)
      when :f64_list
        value_reg = compile_f64_inline_zig_operand(match[2])
        emit(LFAPPEND, list_reg, value_reg)
      else
        raise Unsupported, "register emitter only supports Int64 and Float64 list append in this tranche"
      end
      return
    end

    raise Unsupported, "register emitter does not support MIR::InlineZig stmt #{stmt.reason.inspect} yet"
  end

  # `WITH EXCLUSIVE c AS inner { ... }` emits an InlineZig that
  # acquires `c.acquire()`, defers release, then binds
  # `const inner = guard.get()`. We extract the source container
  # name (from stdlib_def.borrows) and the bound name (regex on the
  # code text -- the shape is fixed by the lowering) and bind
  # `inner` as a struct view of the underlying fields. No actual
  # locking happens because the bc VM is single-threaded.
  # `WITH SNAPSHOT cell AS alias { ... }` on a @versioned cell. The
  # lowering emits a MIR::SnapshotRead that, in the Zig backend,
  # would acquire an EBR-pinned read guard on the cell. The bc VM
  # is single-threaded with no concurrent writers, so the snapshot
  # is just an alias to the underlying struct view.
  def compile_snapshot_read(stmt)
    cell_name = extract_cell_name(stmt.cell_unwrap.to_s)
    raise Unsupported, "register emitter could not extract cell name from SnapshotRead" unless cell_name
    src = @value_by_name[cell_name]
    raise Unsupported, "register emitter does not know cell #{cell_name.inspect}" unless src

    record_shared_event(:snapshot, cell_name, src[:kind], caps: caps_for_value(src))
    @value_by_name[stmt.alias_zig.to_s] = { kind: :struct, type: src[:type], fields: src[:fields] }
  end

  # The SnapshotRead's `cell_unwrap` is a long Zig comptime ladder
  # that mentions the source variable several times. Pull the name
  # out without invoking a Zig parser -- the first @TypeOf(<name>)
  # occurrence is the cell.
  def extract_cell_name(zig_text)
    m = zig_text.match(/@TypeOf\(([A-Za-z_][A-Za-z0-9_]*)\)/)
    m && m[1]
  end

  # `WITH SNAPSHOT cell AS MUTABLE alias { body }` on a @versioned
  # cell. The Zig backend wraps body in a closure that reruns on
  # MvccConflict; the bc VM is single-threaded with no concurrent
  # writers, so it always succeeds on the first try. Bind the alias
  # to the cell's underlying struct view and inline the body.
  def compile_snapshot_transaction(stmt)
    cell_name = extract_cell_name(stmt.cell_unwrap.to_s)
    raise Unsupported, "register emitter could not extract cell name from SnapshotTransaction" unless cell_name
    src = @value_by_name[cell_name]
    raise Unsupported, "register emitter does not know cell #{cell_name.inspect}" unless src

    record_shared_event(:transaction, cell_name, src[:kind], caps: caps_for_value(src))
    saved = @value_by_name.dup
    @value_by_name[stmt.alias_zig.to_s] = { kind: :struct, type: src[:type], fields: src[:fields] }
    semantic_body(stmt.body || []).each { |s| compile_stmt(s) }
  ensure
    @value_by_name = saved if defined?(saved) && saved
  end

  # `WITH SNAPSHOT a AS MUTABLE va, b AS MUTABLE vb, ... { body }`.
  # Same single-threaded equivalence as SnapshotTransaction: bind
  # each alias to its cell's underlying struct view and inline.
  def compile_snapshot_multi_txn(stmt)
    saved = @value_by_name.dup
    # cells_tuple is `.{ <name1>, <name2>, ... }`; pull the bare
    # cell names in order. alias_decls binds each as
    # `const <alias> = views[<i>]; _ = &<alias>;` -- pair them up.
    tuple = stmt.cells_tuple.to_s
    inner = tuple[/\.\{([^}]*)\}/, 1] || ""
    cells = inner.scan(/[A-Za-z_][A-Za-z0-9_]*/)
    aliases = stmt.alias_decls.to_s
                  .scan(/const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*views\[(\d+)\]/)
                  .map { |name, idx| [idx.to_i, name] }
                  .sort_by(&:first)
                  .map(&:last)
    aliases.zip(cells).each do |alias_name, cell|
      next unless alias_name && cell && (src = @value_by_name[cell])
      @value_by_name[alias_name] = { kind: :struct, type: src[:type], fields: src[:fields] }
    end
    semantic_body(stmt.body || []).each { |s| compile_stmt(s) }
  ensure
    @value_by_name = saved if defined?(saved) && saved
  end

  # `WITH cell AS va MATCH WHEN VERSIONED -> {...} WHEN LOCKED -> {...}`.
  # The Zig backend wraps each arm in a comptime if/elif so only one
  # arm is reachable at runtime. The bc VM has no comptime; it picks
  # the arm whose family matches the cell's binding kind and inlines
  # that arm only.
  def compile_with_match_dispatch(stmt)
    cell_name = extract_cell_name(stmt.cell_zig.to_s) || stmt.cell_zig.to_s.strip
    src = @value_by_name[cell_name]
    raise Unsupported, "register emitter does not know WITH MATCH cell #{cell_name.inspect}" unless src

    family = case src[:kind]
             when :versioned_struct then :VERSIONED
             when :atomic_ptr_struct then :ATOMIC
             when :locked_struct    then :LOCKED
             when :write_locked_struct then :WRITE_LOCKED
             when :rc_struct, :arc_struct then :SHARED
             when :local_struct     then :LOCAL
             else nil
             end
    arm = stmt.arms.find { |a| a[:family].to_s.upcase == family.to_s.upcase } if family
    arm ||= stmt.arms.find { |a| %w[LOCKED VERSIONED].include?(a[:family].to_s.upcase) }
    raise Unsupported, "register emitter found no matching WITH MATCH arm for #{family.inspect}" unless arm

    saved = @value_by_name.dup
    # The arm's prelude binds the user's alias from the cell. Reuse
    # the cell's struct view directly (single-threaded equivalence).
    alias_name = extract_with_match_alias(arm[:prelude_zig].to_s)
    if alias_name
      @value_by_name[alias_name] = { kind: :struct, type: src[:type], fields: src[:fields] }
    end
    semantic_body(arm[:body] || []).each { |s| compile_stmt(s) }
  ensure
    @value_by_name = saved if defined?(saved) && saved
  end

  # `WITH POLYMORPHIC c AS x [GUARD cond] { body } [ON GuardFail
  # gfail]`. Single-threaded bc VM: the lock/family wrapper is a
  # no-op; `x` is a view of cap-struct `c` (shared field regs). All
  # control fields are structured MIR (body / guard_cond /
  # guard_fail_body); only the simple `&c` / `x` identifiers come
  # from the *_zig fields -- no Zig logic is parsed.
  def compile_polymorphic_mutate(stmt)
    cell_name = extract_cell_name(stmt.cell_zig.to_s) ||
                stmt.cell_zig.to_s.strip.delete_prefix("&").strip
    src = @value_by_name[cell_name]
    unless src
      raise Unsupported, "register emitter does not know WITH POLYMORPHIC cell #{cell_name.inspect}"
    end

    alias_name = stmt.alias_zig.to_s.strip
    saved = @value_by_name.dup
    @value_by_name[alias_name] = { kind: :struct, type: src[:type], fields: src[:fields] }

    guard = stmt.respond_to?(:guard_cond) ? stmt.guard_cond : nil
    if guard
      cond = compile_bool_expr(guard)
      emit(JF, cond, 0)
      jf = @ops.length - 1
      semantic_body(stmt.body || []).each { |s| compile_stmt(s) }
      emit(JMP, 0)
      jend = @ops.length - 1
      @ops[jf] = @ops.length
      semantic_body(stmt.guard_fail_body || []).each { |s| compile_stmt(s) }
      @ops[jend] = @ops.length
    else
      semantic_body(stmt.body || []).each { |s| compile_stmt(s) }
    end
  ensure
    @value_by_name = saved if defined?(saved) && saved
  end

  # The arm's prelude declares an internal Guard local (`var __va_*`)
  # and then aliases the user's name as `const <alias> = guard.get();`.
  # Prefer the `.get()` line; that's the user-visible binding.
  def extract_with_match_alias(zig_text)
    m = zig_text.match(/const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*[A-Za-z_][A-Za-z0-9_]*\.get\(\);/)
    return m[1] if m

    m = zig_text.match(/(?:var|const)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=/)
    m && m[1]
  end

  def compile_with_block_bindings(stmt)
    borrows = stmt.stdlib_def&.emit&.borrows
    raise Unsupported, "register emitter expected borrows on with_block_bindings" unless borrows.is_a?(Array) && borrows.first
    src_name = borrows.first.to_s
    src = @value_by_name[src_name]
    code = stmt.code.to_s
    bound_names = extract_with_block_bound_names(code)
    if @vreg_by_name.key?(src_name) && %i[int_list string_list].include?(@vkind_by_name[src_name])
      bound_names.each do |bound|
        @vreg_by_name[bound] = @vreg_by_name.fetch(src_name)
        @vkind_by_name[bound] = @vkind_by_name.fetch(src_name)
        @borrowed_list_aliases ||= {}
        @borrowed_list_aliases[bound] = true
      end
      return
    end

    unless src && %i[locked_struct write_locked_struct rc_struct arc_struct struct].include?(src[:kind])
      raise Unsupported, "register emitter does not know with-block source #{src_name.inspect} (kind=#{src && src[:kind]})"
    end

    # Loom groundwork: a WITH block whose source has a sync cap
    # (locked / write_locked) is an acquire+release pair. With
    # caps in the value hash we now also catch @shared:locked
    # (kind=:arc_struct, sync=:locked) which the old kind-only
    # check missed.
    src_caps = caps_for_value(src)
    if src_caps && %i[locked write_locked].include?(src_caps[:sync])
      record_shared_event(:acquire, src_name, src[:kind], caps: src_caps)
      fallible = stmt.stdlib_def&.emit&.fallible_clauses || []
      cell_reg = cell_backed_field_cell(src)
      if cell_reg
        @with_lock_releases ||= []
        fc = fallible.find { |c| c.var_name.to_s == src_name }
        if fc
          emit_fallible_lock_dispatch(fc, cell_reg)
        else
          tmo = fresh_ireg
          emit(ICONST, tmo, add_const(30000))
          emit(LOCKACQ, fresh_ireg, cell_reg, tmo)
          @with_lock_releases << cell_reg
        end
      end
    end

    # Each `const <name> = ...get();` line introduces a binding for
    # an EXCLUSIVE/SHARED block. Bare `WITH pt { ... }` on a cap-
    # wrapped value emits `const <name> = pt.ctrl.data.*;` (a deref
    # of the Rc/Arc inner) -- match both shapes.
    #
    # Loom groundwork: stash the cap-source binding name on the
    # alias so later field reads / writes can be attributed back to
    # the underlying cap-wrapped binding. The alias itself is a
    # plain :struct view; the back-pointer lives on a side map
    # (@cap_alias_source) so existing :struct dispatch is unchanged.
    @cap_alias_source ||= {}
    cap_kind = src[:kind]
    alias_caps = src_caps
    code.scan(/^\s*const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*[A-Za-z_][A-Za-z0-9_]*\.get\(\);/) do |m|
      bound = m[0]
      @value_by_name[bound] = { kind: :struct, type: src[:type], fields: src[:fields] }
      @cap_alias_source[bound] = { name: src_name, kind: cap_kind, caps: alias_caps }
    end
    code.scan(/^\s*const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*[A-Za-z_][A-Za-z0-9_]*\.ctrl\.data\.\*;/) do |m|
      bound = m[0]
      @value_by_name[bound] = { kind: :struct, type: src[:type], fields: src[:fields] }
      @cap_alias_source[bound] = { name: src_name, kind: cap_kind, caps: alias_caps }
    end
  end

  def extract_with_block_bound_names(code)
    names = []
    code.scan(/^\s*const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=/) do |m|
      name = m[0]
      names << name unless name.start_with?("__")
    end
    names
  end

  def compile_i64_expr(expr)
    case expr
    when MIR::Lit
      value = parse_i64_literal(expr.value)
      reg = fresh_ireg
      emit(ICONST, reg, add_const(value))
      reg
    when MIR::Ident
      if expr.name.to_s.start_with?(".") && @tag_context_type
        return compile_tag_const(@tag_context_type, expr.name.to_s.delete_prefix("."))
      end

      @ireg_by_name.fetch(resolve_ctx_name(expr.name)) do
        raise Unsupported, "register emitter does not know local #{expr.name.inspect}"
      end
    when MIR::FieldGet
      compile_i64_field_get(expr)
    when MIR::IndexGet
      compile_i64_index_get(expr)
    when MIR::InlineBc
      compile_i64_inline_bc(expr)
    when MIR::InlineZig
      compile_i64_inline_zig(expr)
    when MIR::BinOp
      compile_i64_binop(expr)
    when MIR::UnaryOp
      compile_i64_unary(expr)
    when MIR::Cast
      compile_i64_cast(expr)
    when MIR::OptionalUnwrap
      compile_i64_expr(expr.expr)
    when MIR::DeepCopy
      compile_i64_expr(expr.source)
    when MIR::Deref, MIR::AddressOf
      # &x / *x for a MUTABLE/by-pointer scalar arg. The bc VM passes
      # scalars by register value (mutation is shared when the callee
      # is inlined); unwrap to the inner value.
      compile_i64_expr(expr.expr)
    when MIR::BlockExpr
      compile_i64_block_expr(expr)
    when MIR::Pipeline
      compile_i64_expr(expr.inner)
    when MIR::TryExpr
      # `try expr` / OR RAISE. Compile inner (its call emitted), then
      # EGUARD: if the callee raised, propagate (return-from-fn).
      compile_try_expr(compile_i64_expr(expr.expr))
    when MIR::TryCatch
      compile_i64_try_catch(expr)
    when MIR::Orelse
      compile_i64_orelse(expr)
    when MIR::ShardedMapGet
      compile_i64_sharded_map_get(expr, fallback_reg: nil)
    when MIR::ListLength
      compile_i64_length(expr.expr)
    when MIR::Call
      return compile_active_tag(expr) if active_tag_call?(expr)

      compile_call(expr, :i64)
    when MIR::MethodCall
      compile_bg_promise_next(expr, :i64) ||
        compile_atomic_method(expr, :i64) ||
        (raise Unsupported, "register emitter does not support MethodCall #{expr.method.inspect} for i64")
    else
      raise Unsupported, "register emitter does not support #{expr.class.name} i64 expressions yet"
    end
  end

  def compile_f64_expr(expr)
    case expr
    when MIR::Lit
      value = parse_f64_literal(expr.value)
      reg = fresh_freg
      emit(FCONST, reg, add_const([:f64, value]))
      reg
    when MIR::Ident
      @freg_by_name.fetch(resolve_ctx_name(expr.name)) do
        raise Unsupported, "register emitter does not know Float64 local #{expr.name.inspect}"
      end
    when MIR::FieldGet
      compile_f64_field_get(expr)
    when MIR::BinOp
      compile_f64_binop(expr)
    when MIR::UnaryOp
      compile_f64_unary(expr)
    when MIR::Cast
      compile_f64_cast(expr)
    when MIR::InlineBc
      compile_f64_inline_bc(expr)
    when MIR::BlockExpr
      compile_f64_block_expr(expr)
    when MIR::Pipeline
      compile_f64_expr(expr.inner)
    when MIR::TryExpr
      compile_try_expr(compile_f64_expr(expr.expr))
    when MIR::TryCatch
      compile_f64_try_catch(expr)
    when MIR::DeepCopy
      compile_f64_expr(expr.source)
    when MIR::Deref, MIR::AddressOf
      compile_f64_expr(expr.expr)
    when MIR::Orelse
      compile_f64_orelse(expr)
    when MIR::ShardedMapGet
      if numeric_f64_map_target?(expr.target)
        fallback = fresh_freg
        emit(FCONST, fallback, add_const([:f64, 0.0]))
        compile_f64_sharded_map_get(expr, fallback_reg: fallback)
      else
        raise Unsupported, "register emitter does not support Float64 map get for #{expr.target.inspect}"
      end
    when MIR::IndexGet
      compile_f64_index_get(expr)
    when MIR::Call
      compile_call(expr, :f64)
    when MIR::MethodCall
      compile_bg_promise_next(expr, :f64) ||
        compile_atomic_method(expr, :f64) ||
        (raise Unsupported, "register emitter does not support MethodCall #{expr.method.inspect} for f64")
    else
      raise Unsupported, "register emitter does not support #{expr.class.name} f64 expressions yet"
    end
  end

  def compile_string_expr(expr)
    case expr
    when MIR::Lit
      text = expr.value.to_s
      unless text.start_with?('"') && text.end_with?('"')
        raise Unsupported, "register emitter only supports string literals in string expressions in this tranche"
      end

      reg = fresh_sreg
      emit(SCONST, reg, add_const(unescape_string(text[1...-1])))
      reg
    when MIR::Ident
      @sreg_by_name.fetch(resolve_ctx_name(expr.name)) do
        raise Unsupported, "register emitter does not know String local #{expr.name.inspect}"
      end
    when MIR::ConcatStr
      compile_string_concat_parts(expr.parts || [])
    when MIR::DupeSlice
      compile_string_expr(expr.source)
    when MIR::DeepCopy
      compile_string_expr(expr.source)
    when MIR::HeapCreate
      compile_string_expr(expr.init)
    when MIR::Deref, MIR::AddressOf
      compile_string_expr(expr.expr)
    when MIR::BinOp
      unless expr.op.to_s == "+"
        raise Unsupported, "register emitter does not support string operator #{expr.op.inspect} yet"
      end

      left = compile_string_expr(expr.left)
      right = compile_string_expr(expr.right)
      dst = fresh_sreg
      emit(SCONCAT, dst, left, right)
      dst
    when MIR::Cast
      compile_string_expr(expr.expr)
    when MIR::InlineBc
      compile_string_inline_bc(expr)
    when MIR::InlineZig
      compile_string_inline_zig(expr)
    when MIR::TryExpr
      compile_try_expr(compile_string_expr(expr.expr))
    when MIR::TryCatch
      compile_string_try_catch(expr)
    when MIR::FieldGet
      compile_string_field_get(expr)
    when MIR::IndexGet
      compile_string_index_get(expr)
    when MIR::Call
      compile_call(expr, :string)
    when MIR::MethodCall
      compile_bg_promise_next(expr, :string) ||
        (raise Unsupported, "register emitter does not support MethodCall #{expr.method.inspect} for string")
    else
      raise Unsupported, "register emitter does not support #{expr.class.name} string expressions yet"
    end
  end

  # `readLine!` and friends lower to MIR::InlineZig with a `try
  # CheatLib.<name>(...)` template. The register VM doesn't (and
  # shouldn't) evaluate Zig text -- we recognize the small set of
  # stdlib intrinsics by their template and dispatch to a native
  # bytecode op.
  def compile_string_inline_zig(expr)
    code = expr.code.to_s
    if code.match?(/\Atry CheatLib\.readLine\(/)
      return emit_string_ncall(N_READ_LINE, [])
    end
    raise Unsupported, "register emitter does not support InlineZig string expression #{code.inspect} yet"
  end

  # `expr OR fallback` lowers to MIR::TryCatch with a fallback branch.
  # When both arms produce a String, the result is whichever side
  # succeeded. We compile the body into the shared destination and
  # emit a guarded jump that overwrites with the fallback on error.
  # The register VM today doesn't propagate errors through string
  # ops -- the underlying ops (`SCONST`, `SCONCAT`, `N_*` natives)
  # raise on failure -- so the fallback path is reachable only when
  # a string-producing native explicitly signals "no value" via an
  # empty result. For `readLine!`, EOF returns "" which the caller
  # can match against; keeping the OR fallback as a no-op preserves
  # source compatibility without expanding the bytecode contract.
  def compile_string_try_catch(expr)
    compile_string_expr(expr.body)
  end

  def compile_string_inline_bc(expr)
    args = expr.args || []
    case expr.op
    when :toString
      unless args.length == 1
        raise Unsupported, "register emitter expected one operand for toString"
      end

      src = compile_i64_expr(args[0])
      return emit_string_ncall(N_INT_TO_STRING, [[ARG_I, src]])
    when :charAt
      unless args.length == 2
        raise Unsupported, "register emitter expected two operands for charAt"
      end

      str = compile_string_expr(args[0])
      idx = compile_i64_expr(args[1])
      return emit_string_ncall(N_STRING_CHAR_AT, [[ARG_S, str], [ARG_I, idx]])
    when :substr
      unless args.length == 3
        raise Unsupported, "register emitter expected three operands for substr"
      end

      str = compile_string_expr(args[0])
      start = compile_i64_expr(args[1])
      len = compile_i64_expr(args[2])
      return emit_string_ncall(N_STRING_SUBSTR, [[ARG_S, str], [ARG_I, start], [ARG_I, len]])
    when :replace
      unless args.length == 3
        raise Unsupported, "register emitter expected three operands for replace"
      end

      str = compile_string_expr(args[0])
      old = compile_string_expr(args[1])
      replacement = compile_string_expr(args[2])
      return emit_string_ncall(N_STRING_REPLACE, [[ARG_S, str], [ARG_S, old], [ARG_S, replacement]])
    when :lowercase, :downcase
      unless args.length == 1
        raise Unsupported, "register emitter expected one operand for #{expr.op}"
      end

      str = compile_string_expr(args[0])
      return emit_string_ncall(N_STRING_LOWERCASE, [[ARG_S, str]])
    when :uppercase, :upcase
      unless args.length == 1
        raise Unsupported, "register emitter expected one operand for #{expr.op}"
      end

      str = compile_string_expr(args[0])
      return emit_string_ncall(N_STRING_UPPERCASE, [[ARG_S, str]])
    when :readFile
      unless args.length == 1
        raise Unsupported, "register emitter expected one operand for readFile"
      end
      path = compile_string_expr(args[0])
      return emit_string_ncall(N_FILE_READ, [[ARG_S, path]])
    when :getAt
      receiver_is_plain_vreg = args[0].is_a?(MIR::Ident) && @vreg_by_name.key?(resolve_ctx_name(args[0].name))
      if args.length >= 2 && !receiver_is_plain_vreg && (handle = compile_list_handle_expr(args[0], :string_list_handle))
        dst = fresh_sreg
        emit(SHGET, dst, handle.fetch(:reg), compile_i64_expr(args[1]))
        return dst
      end

      unless args.length >= 2 && args[0].is_a?(MIR::Ident)
        raise Unsupported, "register emitter only supports local String list getAt in this tranche"
      end
      list_reg = @vreg_by_name.fetch(args[0].name.to_s) do
        raise Unsupported, "register emitter does not know list #{args[0].name.inspect}"
      end
      unless @vkind_by_name.fetch(args[0].name.to_s) == :string_list
        raise Unsupported, "register emitter expected String list #{args[0].name.inspect}"
      end
      index_reg = compile_i64_expr(args[1])
      dst = fresh_sreg
      emit(LSGET, dst, list_reg, index_reg)
      return dst
    when :join
      unless args.length == 2 && args[0].is_a?(MIR::Ident)
        raise Unsupported, "register emitter only supports local String list join in this tranche"
      end
      list_reg = @vreg_by_name.fetch(args[0].name.to_s) do
        raise Unsupported, "register emitter does not know list #{args[0].name.inspect}"
      end
      unless @vkind_by_name.fetch(args[0].name.to_s) == :string_list
        raise Unsupported, "register emitter expected String list #{args[0].name.inspect}"
      end
      sep_reg = compile_string_expr(args[1])
      dst = fresh_sreg
      emit(LSJOIN, dst, list_reg, sep_reg)
      return dst
    else
      raise Unsupported, "register emitter does not support MIR::InlineBc string op #{expr.op.inspect} yet"
    end
  end

  def compile_i64_length(expr)
    plain_vreg_length = expr.is_a?(MIR::Ident) && @vreg_by_name.key?(resolve_ctx_name(expr.name))
    if !plain_vreg_length && (handle = compile_list_handle_expr(expr))
      dst = fresh_ireg
      case handle.fetch(:kind)
      when :int_list_handle then emit(IHLEN, dst, handle.fetch(:reg))
      when :borrowed_int_list_handle then emit(LLEN, dst, handle.fetch(:reg))
      when :string_list_handle then emit(SHLEN, dst, handle.fetch(:reg))
      when :borrowed_string_list_handle then emit(LSLEN, dst, handle.fetch(:reg))
      end
      return dst
    end

    if expr.is_a?(MIR::Ident)
      name = expr.name.to_s
      dst = fresh_ireg
      if @vkind_by_name[name] == :pool
        return compile_pool_length(name)
      elsif @sreg_by_name.key?(name)
        emit_ncall(RET_I, dst, N_STRING_LENGTH, [[ARG_S, @sreg_by_name.fetch(name)]])
        return dst
      elsif (info = (@struct_list_info || {})[name])
        first = info[:fields].values.first
        op = case first[:kind]
             when :int_list then LLEN
             when :f64_list then LFLEN
             when :string_list then LSLEN
             when :handle_list then LLEN
             when :int_handle_values then IHLEN
             when :string_handle_values then SHLEN
             end
        emit(op, dst, first[:reg])
        return dst
      elsif @vreg_by_name.key?(name)
        opcode = case @vkind_by_name.fetch(name)
                 when :f64_list then LFLEN
                 when :string_list then LSLEN
                 when :value_list then LVLEN
                 when :int_map then MLEN
                 when :numeric_int_map then NMLEN
                 else LLEN
                 end
        emit(opcode, dst, @vreg_by_name.fetch(name))
        return dst
      end
    end

    if string_expr?(expr)
      src = compile_string_expr(expr)
      return emit_i64_ncall(N_STRING_LENGTH, [[ARG_S, src]])
    end

    raise Unsupported, "register emitter only supports String and local list/map length in this tranche"
  end

  def compile_string_concat_parts(parts)
    if parts.empty?
      reg = fresh_sreg
      emit(SCONST, reg, add_const(""))
      return reg
    end

    current = compile_string_expr(parts.first)
    parts.drop(1).each do |part|
      right = compile_string_expr(part)
      dst = fresh_sreg
      emit(SCONCAT, dst, current, right)
      current = dst
    end
    current
  end

  def compile_bool_expr(expr)
    case expr
    when MIR::BinOp
      return compile_bool_and(expr) if expr.op.to_s == "and"
      return compile_bool_or(expr) if expr.op.to_s == "or"

      if f64_expr?(expr.left) || f64_expr?(expr.right)
        compile_f64_compare(expr)
      elsif string_expr?(expr.left) || string_expr?(expr.right)
        compile_string_compare(expr)
      else
        compile_i64_compare(expr)
      end
    else
      compile_i64_expr(expr)
    end
  end

  def compile_bool_and(expr)
    left = compile_bool_expr(expr.left)
    zero = fresh_ireg
    dst = fresh_ireg
    emit(ICONST, zero, add_const(0))
    emit(IMOV, dst, zero)
    emit(JF, left, 0)
    end_patch = @ops.length - 1
    right = compile_bool_expr(expr.right)
    emit(IMOV, dst, right)
    @ops[end_patch] = @ops.length
    dst
  end

  def compile_bool_or(expr)
    left = compile_bool_expr(expr.left)
    dst = fresh_ireg
    emit(IMOV, dst, left)
    emit(JF, left, 0)
    false_patch = @ops.length - 1
    emit(JMP, 0)
    end_patch = @ops.length - 1
    @ops[false_patch] = @ops.length
    right = compile_bool_expr(expr.right)
    emit(IMOV, dst, right)
    @ops[end_patch] = @ops.length
    dst
  end

  def compile_i64_compare(expr)
    opcode = case expr.op
             when "<" then ILT
             when ">" then IGT
             when "==" then IEQ
             when "!=" then INEQ
             when "<=" then ILTE
             when ">=" then IGTE
             else
               raise Unsupported, "register emitter does not support comparison #{expr.op.inspect} yet"
             end

    tag_type = tag_expr_type(expr.left) || tag_expr_type(expr.right)
    left = with_tag_context(tag_type) { compile_i64_expr(expr.left) }
    right = with_tag_context(tag_type) { compile_i64_expr(expr.right) }
    dst = fresh_ireg
    emit(opcode, dst, left, right)
    dst
  end

  def compile_f64_compare(expr)
    opcode = case expr.op
             when "<" then FLT
             when ">" then FGT
             when "==" then FEQ
             when "!=" then FNEQ
             when "<=" then FLTE
             when ">=" then FGTE
             else
               raise Unsupported, "register emitter does not support f64 comparison #{expr.op.inspect} yet"
             end

    left = compile_f64_expr(expr.left)
    right = compile_f64_expr(expr.right)
    dst = fresh_ireg
    emit(opcode, dst, left, right)
    dst
  end

  def compile_string_compare(expr)
    unless expr.op.to_s == "=="
      raise Unsupported, "register emitter does not support string comparison #{expr.op.inspect} yet"
    end

    left = compile_string_expr(expr.left)
    right = compile_string_expr(expr.right)
    dst = fresh_ireg
    emit(SEQ, dst, left, right)
    dst
  end

  def compile_f64_binop(expr)
    opcode = case expr.op
             when "+" then FADD
             when "-" then FSUB
             when "*" then FMUL
             when "/" then FDIV
             else
               raise Unsupported, "register emitter does not support f64 operator #{expr.op.inspect} yet"
             end

    left = compile_f64_expr(expr.left)
    right = compile_f64_expr(expr.right)
    dst = fresh_freg
    emit(opcode, dst, left, right)
    dst
  end

  def compile_i64_binop(expr)
    return compile_i64_compare(expr) if %w[< > == != <= >=].include?(expr.op.to_s)

    opcode = case expr.op
             when "+" then IADD
             when "-" then ISUB
             when "*" then IMUL
             when "/" then IDIV
             when "MOD" then IMOD
             else
               raise Unsupported, "register emitter does not support i64 operator #{expr.op.inspect} yet"
             end

    left = compile_i64_expr(expr.left)
    right = compile_i64_expr(expr.right)
    dst = fresh_ireg
    emit(opcode, dst, left, right)
    dst
  end

  def compile_i64_unary(expr)
    if expr.op.to_s == "!"
      value = compile_bool_expr(expr.operand)
      zero = fresh_ireg
      emit(ICONST, zero, add_const(0))
      dst = fresh_ireg
      emit(IEQ, dst, value, zero)
      return dst
    end

    unless expr.op.to_s == "-"
      raise Unsupported, "register emitter does not support i64 unary operator #{expr.op.inspect} yet"
    end

    zero = fresh_ireg
    emit(ICONST, zero, add_const(0))
    value = compile_i64_expr(expr.operand)
    dst = fresh_ireg
    emit(ISUB, dst, zero, value)
    dst
  end

  def compile_f64_unary(expr)
    unless expr.op.to_s == "-"
      raise Unsupported, "register emitter does not support f64 unary operator #{expr.op.inspect} yet"
    end

    zero = fresh_freg
    emit(FCONST, zero, add_const([:f64, 0.0]))
    value = compile_f64_expr(expr.operand)
    dst = fresh_freg
    emit(FSUB, dst, zero, value)
    dst
  end

  def compile_i64_block_expr(expr)
    compile_block_expr(expr, :i64)
  end

  def compile_f64_block_expr(expr)
    compile_block_expr(expr, :f64)
  end

  def compile_block_expr(expr, type)
    if expr.body.length == 1
      stmt = expr.body.first
      return compile_if_block_expr(stmt, type) if stmt.is_a?(MIR::IfStmt)
      return compile_switch_block_expr(stmt, type) if stmt.is_a?(MIR::SwitchStmt)
    end

    # Pipeline-shape: walk the body, then extract the BreakStmt's
    # value as the block result. Reduce/Sum/Map-style pipelines lower
    # to `Let acc = init; ForStmt(...){ Set acc = ...; }; break acc`.
    if expr.body.any? { |s| s.is_a?(MIR::BreakStmt) }
      semantic_body(expr.body).each do |stmt|
        if stmt.is_a?(MIR::BreakStmt)
          case type
          when :i64 then return compile_i64_expr(stmt.value)
          when :f64 then return compile_f64_expr(stmt.value)
          when :string then return compile_string_expr(stmt.value)
          else raise Unsupported, "register emitter does not support BlockExpr result type #{type.inspect}"
          end
        end
        compile_stmt(stmt)
      end
    end

    raise Unsupported, "register emitter only supports simple IF/MATCH block expressions in this tranche"
  end

  def compile_if_block_expr(stmt, type)
    unless stmt.then_body&.length == 1 && stmt.then_body.first.is_a?(MIR::BreakStmt) &&
           stmt.else_body&.length == 1 && stmt.else_body.first.is_a?(MIR::BreakStmt)
      raise Unsupported, "register emitter only supports IF block expressions with direct branch values"
    end

    dst = type == :f64 ? fresh_freg : fresh_ireg
    cond = compile_bool_expr(stmt.cond)
    emit(JF, cond, 0)
    false_target_idx = @ops.length - 1

    then_value = stmt.then_body.first.value
    then_reg = type == :f64 ? compile_f64_expr(then_value) : compile_i64_expr(then_value)
    emit(type == :f64 ? FMOV : IMOV, dst, then_reg) unless dst == then_reg
    emit(JMP, 0)
    end_target_idx = @ops.length - 1

    @ops[false_target_idx] = @ops.length
    else_value = stmt.else_body.first.value
    else_reg = type == :f64 ? compile_f64_expr(else_value) : compile_i64_expr(else_value)
    emit(type == :f64 ? FMOV : IMOV, dst, else_reg) unless dst == else_reg
    @ops[end_target_idx] = @ops.length
    dst
  end

  def compile_switch_block_expr(stmt, type)
    dst = type == :f64 ? fresh_freg : fresh_ireg
    subject = compile_i64_expr(stmt.subject)
    end_patches = []

    stmt.arms.each do |arm|
      pattern = arm.fetch(:pattern)
      body = arm.fetch(:body) || []
      unless body.length == 1 && body.first.is_a?(MIR::BreakStmt)
        raise Unsupported, "register emitter only supports MATCH expression arms with direct values"
      end

      pattern_reg = compile_i64_expr(MIR::Lit.new(pattern.to_s))
      cond = fresh_ireg
      emit(IEQ, cond, subject, pattern_reg)
      emit(JF, cond, 0)
      next_target_idx = @ops.length - 1
      value_reg = type == :f64 ? compile_f64_expr(body.first.value) : compile_i64_expr(body.first.value)
      emit(type == :f64 ? FMOV : IMOV, dst, value_reg) unless dst == value_reg
      emit(JMP, 0)
      end_patches << (@ops.length - 1)
      @ops[next_target_idx] = @ops.length
    end

    default_body = stmt.default_body || []
    unless default_body.length == 1 && default_body.first.is_a?(MIR::BreakStmt)
      raise Unsupported, "register emitter only supports MATCH expression default with direct value"
    end

    default_reg = type == :f64 ? compile_f64_expr(default_body.first.value) : compile_i64_expr(default_body.first.value)
    emit(type == :f64 ? FMOV : IMOV, dst, default_reg) unless dst == default_reg
    end_patches.each { |idx| @ops[idx] = @ops.length }
    dst
  end

  def compile_i64_cast(expr)
    method = expr.method.to_sym
    case method
    when :as, :intCast
      compile_i64_expr(expr.expr)
    else
      raise Unsupported, "register emitter does not support i64 cast method #{expr.method.inspect} yet"
    end
  end

  def compile_f64_cast(expr)
    method = expr.method.to_sym
    case method
    when :as
      inferred_expr_type(expr.expr) == :i64 ? int_to_f64(expr.expr) : compile_f64_expr(expr.expr)
    when :floatFromInt
      int_to_f64(expr.expr)
    else
      raise Unsupported, "register emitter does not support f64 cast method #{expr.method.inspect} yet"
    end
  end

  def int_to_f64(expr)
    if expr.is_a?(MIR::Lit)
      reg = fresh_freg
      emit(FCONST, reg, add_const([:f64, parse_i64_literal(expr.value).to_f]))
      return reg
    elsif expr.is_a?(MIR::Cast)
      return int_to_f64(expr.expr)
    end

    value = compile_i64_expr(expr)
    emit_f64_ncall(N_INT_TO_FLOAT, [[ARG_I, value]])
  end

  def compile_call(expr, expected_type)
    callable = callable_call(expr)
    return compile_callable_call(expr, callable, expected_type) if callable

    function = @functions_by_name[expr.callee.to_s]
    raise Unsupported, "register emitter does not support external call #{expr.callee.inspect} yet" unless function

    return_type = normalize_type(function.ret_type)
    # Bool is represented as i64 (0/1) in the bc VM, so a function
    # returning Bool can satisfy an i64-expecting call site.
    return_type = :i64 if return_type == :bool && expected_type == :i64
    unless return_type == expected_type
      raise Unsupported, "register emitter expected #{expected_type} return from #{expr.callee.inspect}, got #{return_type}"
    end

    compiled_args = compile_call_args(expr.callee, function, expr.args || [])
    return compile_inline_function(function, return_type, compiled_args) if return_type == :string || compiled_args.any? { |_name, type, _reg| type == :callable || list_register_type?(type) || union_register_type?(type) || value_register_type?(type) || type == :pool }

    case return_type
    when :i64
      dst = fresh_ireg
      emit_function_call(ICALL, dst, expr.callee.to_s, compiled_args)
      dst
    when :f64
      dst = fresh_freg
      emit_function_call(FCALL, dst, expr.callee.to_s, compiled_args)
      dst
    else
      raise Unsupported, "register emitter only supports Int64, Float64 and inlined String helper returns"
    end
  end

  def callable_call(expr)
    callee = expr.callee.to_s
    return nil unless callee.start_with?("try ")

    @callable_by_name[callee.delete_prefix("try ").strip]
  end

  def compile_callable_call(expr, callable, expected_type)
    args = (expr.args || []).dup
    args.shift if args.first && runtime_arg?(args.first)

    case callable.fetch(:kind)
    when :fn_ref
      function = @functions_by_name.fetch(callable.fetch(:name))
      return_type = normalize_type(function.ret_type)
      unless return_type == expected_type
        raise Unsupported, "register emitter expected #{expected_type} return from callable #{callable.fetch(:name).inspect}, got #{return_type}"
      end

      compiled_args = compile_call_args(callable.fetch(:name), function, args)
      dst = expected_type == :f64 ? fresh_freg : fresh_ireg
      emit_function_call(expected_type == :f64 ? FCALL : ICALL, dst, callable.fetch(:name), compiled_args)
      dst
    when :lambda
      function = callable.fetch(:fn_def)
      return_type = normalize_type(function.ret_type)
      unless return_type == expected_type
        raise Unsupported, "register emitter expected #{expected_type} return from lambda, got #{return_type}"
      end

      with_callable_captures(callable) do
        compiled_args = compile_call_args(function.name || "<lambda>", function, args)
        compile_inline_function(function, return_type, compiled_args)
      end
    else
      raise Unsupported, "register emitter does not support callable kind #{callable.fetch(:kind).inspect}"
    end
  end

  def with_callable_captures(callable)
    saved_iregs = @ireg_by_name
    saved_fregs = @freg_by_name
    saved_sregs = @sreg_by_name
    @ireg_by_name = saved_iregs.dup
    @freg_by_name = saved_fregs.dup
    @sreg_by_name = saved_sregs.dup
    callable.fetch(:captures, {}).each do |name, capture|
      case capture.fetch(:type)
      when :i64
        @ireg_by_name[name] = capture.fetch(:reg)
        record_var_name(:i, capture.fetch(:reg), name)
      when :f64
        @freg_by_name[name] = capture.fetch(:reg)
        record_var_name(:f, capture.fetch(:reg), name)
      when :string
        @sreg_by_name[name] = capture.fetch(:reg)
        record_var_name(:s, capture.fetch(:reg), name)
      else
        raise Unsupported, "register emitter only supports Int64 and Float64 lambda captures in this tranche"
      end
    end
    yield
  ensure
    @ireg_by_name = saved_iregs
    @freg_by_name = saved_fregs
    @sreg_by_name = saved_sregs
  end

  def compile_i64_try_catch(expr)
    compile_scalar_try_catch(expr, :i64)
  end

  def compile_f64_try_catch(expr)
    compile_scalar_try_catch(expr, :f64)
  end

  def compile_f64_orelse(expr)
    if expr.expr.is_a?(MIR::ShardedMapGet) && numeric_f64_map_target?(expr.expr.target)
      fallback_reg = compile_f64_expr(expr.fallback)
      return compile_f64_sharded_map_get(expr.expr, fallback_reg: fallback_reg)
    end

    if expr.expr.is_a?(MIR::InlineBc) && expr.expr.op == :toNumber
      args = expr.expr.args || []
      unless args.length == 1
        raise Unsupported, "register emitter expected one operand for toNumber"
      end

      str = compile_string_expr(args[0])
      fallback = compile_f64_expr(expr.fallback)
      return emit_f64_ncall(N_STRING_TO_NUMBER_OR, [[ARG_S, str], [ARG_F, fallback]])
    end

    raise Unsupported, "register emitter only supports OR fallback for toNumber and HashMap<Int64, Float64> get in Float64 expressions in this tranche"
  end

  def compile_f64_sharded_map_get(expr, fallback_reg:)
    dst = fresh_freg
    map_reg = map_register_for(expr.target)
    key_reg = compile_i64_expr(expr.key)
    emit(NMGETF, dst, map_reg, key_reg, fallback_reg)
    dst
  end

  # A propagating catch_body re-raises rather than producing a
  # fallback value: OR EXIT (InlineBc :or_exit) or a bare
  # RETURN error.CheatError. Distinct from a value-fallback catch.
  def propagating_catch?(cb)
    return false unless cb.is_a?(MIR::ScopeBlock)

    semantic_body(cb.body || []).any? do |s|
      returns_cheat_error?(s) ||
        (s.is_a?(MIR::ExprStmt) && s.expr.is_a?(MIR::InlineBc) && s.expr.op == :or_exit)
    end
  end

  def compile_scalar_try_catch(expr, type)
    # Additive dynamic path for propagating catches (OR EXIT / re-
    # raise). The static heuristic below is left intact for ordinary
    # value-fallback callers (no regression).
    if propagating_catch?(expr.catch_body)
      resreg = type == :f64 ? compile_f64_expr(expr.expr) : compile_i64_expr(expr.expr)
      e = fresh_ireg
      emit(EFLAG, e)
      emit(JF, e, 0)
      done = @ops.length - 1
      semantic_body(expr.catch_body.body || []).each { |s| compile_stmt(s) }
      @ops[done] = @ops.length
      return resreg
    end

    unless expr.expr.is_a?(MIR::Call)
      raise Unsupported, "register emitter only supports OR fallback around helper calls in this tranche"
    end

    function = @functions_by_name[expr.expr.callee.to_s]
    raise Unsupported, "register emitter does not support external fallible call #{expr.expr.callee.inspect} yet" unless function

    if function_always_raises?(function)
      return type == :f64 ? compile_f64_expr(expr.catch_body) : compile_i64_expr(expr.catch_body)
    end

    if function_has_unsupported_raise?(function)
      raise Unsupported, "register emitter only supports statically successful or statically raising scalar OR helpers in this tranche"
    end

    type == :f64 ? compile_f64_expr(expr.expr) : compile_i64_expr(expr.expr)
  end

  def function_always_raises?(function)
    body = semantic_body(function.body)
    body.length == 1 && raise_scope_block?(body.first)
  end

  def function_has_unsupported_raise?(function)
    semantic_body(function.body).any? do |stmt|
      raise_scope_block?(stmt) || returns_cheat_error?(stmt)
    end
  end

  def raise_scope_block?(stmt)
    return false unless stmt.is_a?(MIR::ScopeBlock)

    body = semantic_body(stmt.body || [])
    body.any? { |child| set_error_stmt?(child) } &&
      body.any? { |child| returns_cheat_error?(child) }
  end

  def set_error_stmt?(stmt)
    stmt.is_a?(MIR::ExprStmt) &&
      stmt.expr.is_a?(MIR::MethodCall) &&
      stmt.expr.receiver.is_a?(MIR::Ident) &&
      stmt.expr.receiver.name.to_s == "rt" &&
      stmt.expr.method.to_s == "setError"
  end

  def returns_cheat_error?(stmt)
    stmt.is_a?(MIR::ReturnStmt) &&
      stmt.value.is_a?(MIR::Ident) &&
      stmt.value.name.to_s == "error.CheatError"
  end

  # ErrorKind ids -- fixed enum, must match zig/runtime/runtime.zig
  # `ErrorKind` and AST::ERROR_KINDS order.
  ERROR_KIND_IDS = {
    "Transient" => 0, "Input" => 1, "System" => 2, "NotFound" => 3,
    "Permission" => 4, "Canceled" => 5, "Unknown" => 6
  }.freeze

  def error_kind_id(node)
    unless node.is_a?(MIR::Ident)
      raise Unsupported, "register emitter expected error-kind ident, got #{node.class.name}"
    end

    name = node.name.to_s.sub(/\A\./, "")
    ERROR_KIND_IDS.fetch(name) do
      raise Unsupported, "register emitter unknown error kind #{name.inspect}"
    end
  end

  # Resolve an ErrorName type symbol/string to its per-program u32 id
  # via the same registry the Zig backend's @intFromEnum uses.
  def error_name_id(type_name)
    sym = type_name.to_s.to_sym
    AST.id_of_type(sym) ||
      (raise Unsupported, "register emitter unknown error type #{type_name.inspect}")
  end

  def string_lit_text(lit)
    text = lit.is_a?(MIR::Lit) ? lit.value.to_s : lit.to_s
    return unescape_string(text[1...-1]) if text.start_with?('"') && text.end_with?('"')

    text
  end

  # RAISE -> `rt.setError(kind, @intFromEnum(ErrorName.T)|0, msg, line)`.
  def compile_set_error(expr)
    args = expr.args || []
    unless args.length >= 4
      raise Unsupported, "register emitter expected 4 args for rt.setError"
    end

    kind_id = error_kind_id(args[0])
    name_arg = args[1]
    name_id =
      if name_arg.is_a?(MIR::Ident) && name_arg.name.to_s =~ /ErrorName\.(\w+)/
        error_name_id(Regexp.last_match(1))
      else
        0
      end
    msg = args[2].is_a?(MIR::Lit) ? string_lit_text(args[2]) : ""
    line = args[3].is_a?(MIR::Lit) ? parse_i64_literal(args[3].value) : 0
    emit(ERAISE, add_const(kind_id), add_const(name_id), add_const(msg), add_const(line))
  end

  # Propagate the error one level out, context-aware:
  # - real frame (non-inlined): EGUARD pops the frame.
  # - inlined fn: jump to the inline exit (errored stays set; the
  #   inline site's caller handles it). Frame-pop would corrupt the
  #   enclosing real frame, since inlined code has no frame.
  def emit_err_propagate
    if @inline_return
      t = fresh_ireg
      emit(EFLAG, t)
      emit(JF, t, 0)
      skip = @ops.length - 1
      emit(JMP, 0)
      @inline_return.fetch(:patches) << (@ops.length - 1)
      @ops[skip] = @ops.length
    else
      emit(EGUARD)
    end
  end

  # OR EXIT: structured partial rewrite of the active error
  # (InlineBc :or_exit from lower_or_exit's :bc branch). Unset fields
  # inherit the error set by the failing call; errored stays set so
  # the following RETURN error.CheatError propagates.
  def compile_or_exit(stmt)
    meta = stmt.stdlib_def || {}
    mask = 0
    kind_c = add_const(0)
    name_c = add_const(0)
    msg_c = add_const("")
    if meta[:kind]
      kind_c = add_const(ERROR_KIND_IDS.fetch(meta[:kind].to_s))
      mask |= 1
    end
    if meta[:name_id]
      name_c = add_const(meta[:name_id].to_i)
      mask |= 2
    elsif meta[:clear_type]
      name_c = add_const(0)
      mask |= 2
    end
    if meta[:has_message]
      msg_arg = (stmt.args || []).first
      unless msg_arg.is_a?(MIR::Lit)
        raise Unsupported, "register emitter OR EXIT supports literal messages in this commit"
      end
      msg_c = add_const(string_lit_text(msg_arg))
      mask |= 4
    end
    line_c = add_const(meta.fetch(:line, 0).to_i)
    mask |= 8
    emit(EREWRITE, kind_c, name_c, msg_c, line_c, add_const(mask))
  end

  # OR RAISE: inner already compiled (its call emitted); propagate if
  # the callee set the error state.
  def compile_try_expr(inner_reg)
    emit_err_propagate
    inner_reg
  end

  # `call() OR RAISE;` at statement position -- compile the inner
  # (value discarded), then propagate if it raised.
  def compile_try_stmt(try_expr)
    compile_expr_stmt(MIR::ExprStmt.new(try_expr.expr, false))
    emit_err_propagate
  end

  # `call() OR { ...catch... };` at statement position. Compile the
  # call (value discarded); if it raised, ECLR and run the catch
  # body; else skip the catch.
  def compile_try_catch_stmt(stmt)
    compile_expr_stmt(MIR::ExprStmt.new(stmt.expr, false))
    e = fresh_ireg
    emit(EFLAG, e)
    emit(JF, e, 0)
    skip = @ops.length - 1
    emit(ECLR)
    cb = stmt.catch_body
    if cb.is_a?(MIR::ScopeBlock)
      semantic_body(cb.body || []).each { |c| compile_stmt(c) }
    elsif or_pass_sentinel?(cb)
      # OR PASS: error suppressed; ECLR above is the whole handler.
      nil
    elsif cb
      compile_stmt(cb)
    end
    @ops[skip] = @ops.length
  end

  # OR PASS lowers the catch body to `MIR::Ident("undefined")`
  # (Zig `catch undefined`). It means "swallow the error"; the
  # preceding ECLR is the entire handler -- nothing to emit.
  def or_pass_sentinel?(node)
    node.is_a?(MIR::Ident) && node.name.to_s == "undefined"
  end

  # Wrapper fn whose body is a single MIR::CatchWrapper. Calls
  # __<fn>_body(rt, params...); on success returns its value; on error
  # dispatches by clause_meta (kinds/types OR, narrowed by
  # filter_types/filter_messages), else DEFAULT, else propagate.
  # Uses clause_bodies/clause_meta only -- never the Zig `code`.
  # Int64/Bool/Float64/String returns. String/Bool wrappers are
  # inlined (no frame); propagation is inline-aware (see
  # emit_err_propagate / register-error-union.md).
  def compile_catch_wrapper(stmt)
    rk = @return_type
    unless %i[i64 bool f64 string].include?(rk)
      raise Unsupported, "register emitter CatchWrapper return type #{rk.inspect} unsupported"
    end

    inner = "__#{@current_fn.name}_body"
    unless @functions_by_name.key?(inner)
      raise Unsupported, "register emitter CatchWrapper inner body #{inner.inspect} not found"
    end

    call_args = [MIR::Ident.new("rt")] +
                callable_params(@current_fn).map { |p| MIR::Ident.new(p.name) }
    call = MIR::Call.new(inner, call_args, false, nil)
    resreg = case rk
             when :i64, :bool then compile_i64_expr(call)
             when :f64        then compile_f64_expr(call)
             when :string     then compile_string_expr(call)
             end

    eflag = fresh_ireg
    emit(EFLAG, eflag)
    emit(JF, eflag, 0)
    succ_patch = @ops.length - 1

    meta = stmt.clause_meta || []
    bodies = stmt.clause_bodies || []
    zero = fresh_ireg
    emit(ICONST, zero, add_const(0))
    meta.each_with_index do |cm, i|
      kinds = cm[:kinds] || []
      types = cm[:types] || []
      ftypes = cm[:filter_types] || []
      fmsgs = cm[:filter_messages] || []

      # primary = (any kind matches) OR (any type matches), as a
      # nonzero count. No JT opcode -> accumulate with IADD and
      # compare > 0 with IGT.
      pcount = fresh_ireg
      emit(IMOV, pcount, zero)
      (kinds.map { |k| [EMATCHK, ERROR_KIND_IDS.fetch(k.to_s)] } +
       types.map { |t| [EMATCHN, error_name_id(t)] }).each do |op, cst|
        m = fresh_ireg
        emit(op, m, add_const(cst))
        emit(IADD, pcount, pcount, m)
      end
      matched = fresh_ireg
      if kinds.empty? && types.empty?
        emit(ICONST, matched, add_const(1))
      else
        emit(IGT, matched, pcount, zero)
      end

      unless ftypes.empty? && fmsgs.empty?
        fcount = fresh_ireg
        emit(IMOV, fcount, zero)
        ftypes.each do |t|
          m = fresh_ireg
          emit(EMATCHN, m, add_const(error_name_id(t)))
          emit(IADD, fcount, fcount, m)
        end
        fmsgs.each do |lit|
          m = fresh_ireg
          emit(EMATCHM, m, add_const(string_lit_text(lit)))
          emit(IADD, fcount, fcount, m)
        end
        fok = fresh_ireg
        emit(IGT, fok, fcount, zero)
        emit(IMUL, matched, matched, fok)
      end

      emit(JF, matched, 0)
      skip = @ops.length - 1
      emit(ECLR)
      semantic_body(bodies[i] || []).each { |c| compile_stmt(c) }
      @ops[skip] = @ops.length
    end

    if stmt.has_default
      emit(ECLR)
      semantic_body(bodies[meta.length] || []).each { |c| compile_stmt(c) }
    else
      emit_err_propagate
    end

    @ops[succ_patch] = @ops.length
    emit_return_reg(resreg)
  end

  # Return `reg` per the current return type, inline-aware: real
  # frame -> IRET/FRET/SRET; inlined -> MOV into the inline result
  # reg + JMP to the inline exit (recorded in :patches).
  def emit_return_reg(reg)
    if @inline_return
      tgt = @inline_return.fetch(:reg)
      case @return_type
      when :i64, :bool then emit(IMOV, tgt, reg) unless reg == tgt
      when :f64        then emit(FMOV, tgt, reg) unless reg == tgt
      when :string     then emit(SMOV, tgt, reg) unless reg == tgt
      end
      emit(JMP, 0)
      @inline_return.fetch(:patches) << (@ops.length - 1)
    else
      case @return_type
      when :i64, :bool then emit(IRET, reg)
      when :f64        then emit(FRET, reg)
      when :string     then emit(SRET, reg)
      end
    end
  end

  def compile_call_args(callee, function, args)
    params = callable_params(function)
    args = args.drop(1) if args.length == params.length + 1 && runtime_arg?(args.first)
    if args.length != params.length
      raise Unsupported, "register emitter expected #{params.length} args for #{callee.inspect}"
    end

    fn_sig = lookup_fn_sig(function.name)
    sig_params = fn_sig.respond_to?(:params) ? (fn_sig.params || []) : []
    params.zip(args).map do |param, arg|
      effective_zig_type = param.zig_type
      if effective_zig_type.to_s == "anytype"
        stripped = param.name.to_s.sub(/\A_m_/, "")
        sig_param = sig_params.find { |sp| sp[:name].to_s == stripped }
        if sig_param && sig_param[:type].respond_to?(:zig_type)
          effective_zig_type = sig_param[:type].zig_type
        end
      end

      type = if callable_param?(param)
               :callable
             elsif list_value_type(effective_zig_type)
               list_value_type(effective_zig_type)
             elsif value_string_map_type?(effective_zig_type)
               :value_string_map
             elsif value_list_type?(effective_zig_type)
               :value_list
             elsif int64_string_map_type?(effective_zig_type)
               :int_map
             elsif numeric_int64_map_type?(effective_zig_type)
               :numeric_int_map
             elsif numeric_float64_map_type?(effective_zig_type)
               :numeric_f64_map
             elsif (struct_map_type = string_struct_map_type?(effective_zig_type))
               [:struct_map, struct_map_type]
             elsif effective_zig_type.to_s.match?(/\A(?:CheatLib\.)?(?:Sharded)?Pool\(/)
               :pool
             else
               union_arg_type(param.zig_type) || struct_arg_type(param.zig_type) || anytype_arg_type(param, arg) || normalize_type(param.zig_type)
             end
      reg = case type
            when :callable then compile_callable_arg(arg)
            when :i64 then compile_i64_expr(arg)
            when :f64 then compile_f64_expr(arg)
            when :string then compile_string_expr(arg)
            when :int_list, :f64_list, :string_list then compile_list_arg(arg, type)
            when :value_string_map, :value_list then compile_value_container_arg(arg, type)
            when :int_map, :numeric_int_map, :numeric_f64_map then compile_value_container_arg(arg, type)
            when Array
              if type.first == :struct_map
                compile_struct_map_arg(arg, type.last)
              elsif type.first == :union
                compile_union_arg(arg, type.last)
              elsif type.first == :struct
                compile_struct_arg(arg, type.last)
              else
                raise Unsupported, "register emitter does not support helper param type #{type.inspect}"
              end
            when :pool then compile_pool_arg(arg)
            else
              raise Unsupported, "register emitter only supports Int64, Float64, String and list helper params in this tranche"
            end
      [param.name.to_s, type, reg]
    end
  end

  # Pass a pool to a helper. The caller's pool binding is the
  # authoritative one; the callee shares the same per-field regs.
  def compile_pool_arg(arg)
    arg = arg.expr if arg.is_a?(MIR::AddressOf)
    raise Unsupported, "register emitter expected an Ident pool arg" unless arg.is_a?(MIR::Ident)
    info = (@pool_info || {})[arg.name.to_s]
    raise Unsupported, "register emitter does not know pool arg #{arg.name.inspect}" unless info
    info
  end

  # Pass a value-typed container (HashMap<UserUnion> or
  # UserUnion[]@list) to a helper FN. Both caller and callee share
  # the same vmap/vlist slot index, so the call effectively borrows
  # the slot for the callee's lifetime. The caller's variant_map info
  # must already be in @value_map_variants / @value_list_variants
  # since the container was bound there at declaration.
  def compile_value_container_arg(arg, expected_type)
    # MUTABLE container args show up as `AddressOf(Ident(...))` in
    # MIR; the call passes a pointer to the slot. The bytecode VM's
    # slot model already passes by slot-index, so we can ignore the
    # AddressOf wrapper.
    arg = arg.expr if arg.is_a?(MIR::AddressOf)
    unless arg.is_a?(MIR::Ident)
      raise Unsupported, "register emitter only supports local value containers as helper args"
    end

    name = arg.name.to_s
    actual = @vkind_by_name.fetch(name) do
      raise Unsupported, "register emitter does not know value container #{name.inspect}"
    end
    unless actual == expected_type
      raise Unsupported, "register emitter expected #{expected_type.inspect} arg, got #{actual.inspect}"
    end
    @vreg_by_name.fetch(name)
  end

  def compile_list_arg(arg, expected_type)
    arg = arg.expr if arg.is_a?(MIR::ItemsAccess)
    arg = arg.expr if arg.is_a?(MIR::AddressOf)
    unless arg.is_a?(MIR::Ident)
      raise Unsupported, "register emitter only supports local list args in this tranche"
    end

    name = arg.name.to_s
    actual_type = @vkind_by_name.fetch(name) do
      raise Unsupported, "register emitter does not know list #{arg.name.inspect}"
    end
    unless actual_type == expected_type
      raise Unsupported, "register emitter expected #{expected_type} list arg #{arg.name.inspect}, got #{actual_type}"
    end

    @vreg_by_name.fetch(name)
  end

  def compile_union_arg(arg, expected_type)
    value = if arg.is_a?(MIR::Ident)
              @value_by_name[arg.name.to_s]
            else
              compile_value_expr(arg)
            end
    unless value && value.fetch(:kind) == :union
      raise Unsupported, "register emitter expected union arg #{expected_type.inspect}"
    end
    unless value.fetch(:type) == expected_type
      raise Unsupported, "register emitter expected union arg #{expected_type.inspect}, got #{value.fetch(:type).inspect}"
    end

    value
  end

  def compile_struct_map_arg(arg, expected_type)
    arg = arg.expr if arg.is_a?(MIR::AddressOf)
    value = if arg.is_a?(MIR::Ident)
              @value_by_name[arg.name.to_s]
            else
              compile_value_expr(arg)
            end
    unless value && value.fetch(:kind) == :struct_map && value.fetch(:type) == expected_type
      raise Unsupported, "register emitter expected HashMap<#{expected_type}> arg"
    end

    value
  end

  def compile_struct_arg(arg, expected_type)
    inner = unwrap_to_ident(arg)
    value = if inner.is_a?(MIR::Ident)
              @value_by_name[inner.name.to_s]
            else
              compile_value_expr(arg)
            end
    valid_kinds = [:struct, :rc_struct, :arc_struct, :locked_struct, :write_locked_struct, :local_struct, :versioned_struct, :atomic_ptr_struct]
    unless value && valid_kinds.include?(value.fetch(:kind))
      raise Unsupported, "register emitter expected struct arg #{expected_type.inspect}"
    end
    unless value.fetch(:type) == expected_type
      raise Unsupported, "register emitter expected struct arg #{expected_type.inspect}, got #{value.fetch(:type).inspect}"
    end

    value
  end

  def runtime_arg?(arg)
    return false unless arg.is_a?(MIR::Ident)
    name = arg.name.to_s
    # Also recognize FSM/BG context-bound runtime handles (__rt_bgN,
    # __rt_fsmN). The lowering binds these in BG/FSM ctx structs as
    # the receiving fiber's runtime; the bc VM is single-threaded
    # and uses one runtime, so they're equivalent to "rt".
    name == "rt" || name == "_rt" || name.start_with?("__rt_")
  end

  def callable_param?(param)
    param.zig_type.to_s.include?("fn(")
  end

  def compile_callable_arg(arg)
    value = compile_value_expr(arg)
    unless value && [:fn_ref, :lambda].include?(value.fetch(:kind))
      raise Unsupported, "register emitter only supports direct function/lambda callable args in this tranche"
    end

    value
  end

  def compile_inline_function(function, return_type, compiled_args)
    inline_value = nil
    result_reg = case return_type
                 when :f64 then fresh_freg
                 when :i64 then fresh_ireg
                 when :string then fresh_sreg
                 when :void then nil
                 when :int_list, :f64_list then nil
                 when Array
                   if return_type.first == :union
                     inline_value = allocate_union_storage(return_type.last)
                     nil
                   elsif %i[struct rc_struct arc_struct locked_struct write_locked_struct local_struct versioned_struct atomic_ptr_struct].include?(return_type.first)
                     nil
                   else
                     raise Unsupported, "register emitter does not support #{return_type.inspect} helper returns in this tranche"
                   end
                 else
                   raise Unsupported, "register emitter only supports Int64, Float64, String and Void helper returns"
                 end
    saved_iregs = @ireg_by_name
    saved_fregs = @freg_by_name
    saved_sregs = @sreg_by_name
    saved_vregs = @vreg_by_name
    saved_vkinds = @vkind_by_name
    saved_values = @value_by_name
    saved_callables = @callable_by_name
    saved_tag_types = @tag_type_by_name
    saved_return_type = @return_type
    saved_inline_return = @inline_return
    saved_inline_fn = @current_fn
    @current_fn = function
    saved_borrowed_list_aliases = @borrowed_list_aliases

    @ireg_by_name = saved_iregs.dup
    @freg_by_name = saved_fregs.dup
    @sreg_by_name = saved_sregs.dup
    @vreg_by_name = saved_vregs.dup
    @vkind_by_name = saved_vkinds.dup
    @value_by_name = saved_values.dup
    @callable_by_name = saved_callables.dup
    @tag_type_by_name = saved_tag_types.dup
    @borrowed_list_aliases = saved_borrowed_list_aliases ? saved_borrowed_list_aliases.dup : {}
    saved_value_map_variants = @value_map_variants ? @value_map_variants.dup : {}
    saved_value_list_variants = @value_list_variants ? @value_list_variants.dup : {}
    @value_map_variants = saved_value_map_variants.dup
    @value_list_variants = saved_value_list_variants.dup
    compiled_args.each do |name, type, reg|
      case type
      when :i64
        @ireg_by_name[name] = reg
        record_var_name(:i, reg, name)
      when :f64
        @freg_by_name[name] = reg
        record_var_name(:f, reg, name)
      when :string
        @sreg_by_name[name] = reg
        record_var_name(:s, reg, name)
      when :int_list, :f64_list, :string_list, :int_map, :numeric_int_map, :numeric_f64_map
        @vreg_by_name[name] = reg
        @vkind_by_name[name] = type
      when :value_string_map, :value_list
        @vreg_by_name[name] = reg
        @vkind_by_name[name] = type
        # Re-derive the variant_map for the callee param's type. The
        # callee's MIR FnDef has the param's `anytype` zig_type; the
        # original union type is on the FunctionSignature.
        sig = lookup_fn_sig(function.name)
        if sig.respond_to?(:params)
          stripped = name.sub(/\A_m_/, "")
          sp = sig.params.find { |x| x[:name].to_s == stripped }
          if sp && sp[:type].respond_to?(:zig_type)
            zt = sp[:type].zig_type
            info = type == :value_string_map ? value_string_map_type?(zt) : value_list_type?(zt)
            if info
              if type == :value_string_map
                @value_map_variants[name] = { union_name: info[:union_name], variants: info[:variants] }
              else
                @value_list_variants[name] = { union_name: info[:union_name], variants: info[:variants] }
              end
            end
          end
        end
      when :callable then @callable_by_name[name] = reg
      when :pool
        @vkind_by_name[name] = :pool
        @pool_info ||= {}
        @pool_info[name] = reg
      when Array
        @value_by_name[name] = reg if type.first == :struct_map ||
                                       type.first == :union ||
                                       %i[struct rc_struct arc_struct locked_struct write_locked_struct local_struct versioned_struct atomic_ptr_struct].include?(type.first)
      end
    end

    @return_type = return_type
    @inline_return = { type: return_type, reg: result_reg, value: inline_value, patches: [] }
    semantic_body(function.body).each { |stmt| compile_stmt(stmt) }
    @inline_return.fetch(:patches).each { |idx| @ops[idx] = @ops.length }
    value_register_type?(return_type) || union_register_type?(return_type) || list_register_type?(return_type) ? @inline_return.fetch(:value) : result_reg
  ensure
    @value_map_variants = saved_value_map_variants if defined?(saved_value_map_variants) && saved_value_map_variants
    @value_list_variants = saved_value_list_variants if defined?(saved_value_list_variants) && saved_value_list_variants
    @ireg_by_name = saved_iregs
    @freg_by_name = saved_fregs
    @sreg_by_name = saved_sregs
    @vreg_by_name = saved_vregs
    @vkind_by_name = saved_vkinds
    @value_by_name = saved_values
    @callable_by_name = saved_callables
    @tag_type_by_name = saved_tag_types
    @borrowed_list_aliases = saved_borrowed_list_aliases
    @return_type = saved_return_type
    @inline_return = saved_inline_return
    @current_fn = saved_inline_fn if defined?(saved_inline_fn)
  end

  def emit_function_call(opcode, dst, callee, compiled_args)
    if compiled_args.any? { |_name, type, _reg| type == :callable || list_register_type?(type) || union_register_type?(type) || value_register_type?(type) }
      raise Unsupported, "register emitter cannot pass callable/list/union/struct args to non-inlined helper #{callee.inspect}"
    end

    patch_idx = @ops.length + 2
    frame_i_idx = @ops.length + 4
    frame_f_idx = @ops.length + 5
    emit(opcode, dst, 0, compiled_args.length, 0, 0)
    compiled_args.each do |_name, _type, reg|
      emit(arg_kind(_type), reg)
    end
    @function_patches << [patch_idx, frame_i_idx, frame_f_idx, callee]
  end

  def emit_i64_ncall(native_id, args)
    dst = fresh_ireg
    emit_ncall(RET_I, dst, native_id, args)
    dst
  end

  def emit_f64_ncall(native_id, args)
    dst = fresh_freg
    emit_ncall(RET_F, dst, native_id, args)
    dst
  end

  def emit_string_ncall(native_id, args)
    dst = fresh_sreg
    emit_ncall(RET_S, dst, native_id, args)
    dst
  end

  def emit_ncall(ret_kind, dst, native_id, args)
    emit(NCALL, ret_kind, dst, native_id, args.length)
    args.each do |kind, reg|
      emit(kind, reg)
    end
  end

  def arg_kind(type)
    case type
    when :f64 then ARG_F
    when :string then ARG_S
    else ARG_I
    end
  end

  def list_register_type?(type)
    type == :int_list || type == :f64_list || type == :string_list || type == :value_list || type == :value_string_map
  end

  def list_handle_type?(type)
    type == :int_list_handle || type == :string_list_handle ||
      type == :borrowed_int_list_handle || type == :borrowed_string_list_handle
  end

  def list_handle_value?(value)
    value && %i[int_list_handle string_list_handle borrowed_int_list_handle borrowed_string_list_handle].include?(value[:kind])
  end

  def compatible_list_handle_kind?(kind, expected_type)
    return true if expected_type.nil? || kind == expected_type
    (expected_type == :int_list_handle && kind == :borrowed_int_list_handle) ||
      (expected_type == :string_list_handle && kind == :borrowed_string_list_handle)
  end

  def union_register_type?(type)
    type.is_a?(Array) && type.first == :union
  end

  def value_register_type?(type)
    return false unless type.is_a?(Array)
    %i[struct rc_struct arc_struct locked_struct write_locked_struct local_struct versioned_struct atomic_ptr_struct].include?(type.first)
  end

  def patch_function_calls
    @function_patches.each do |idx, frame_i_idx, frame_f_idx, callee|
      entry = @function_entries[callee]
      raise Unsupported, "register emitter could not resolve helper #{callee.inspect}" unless entry
      i_frame, f_frame = @function_frame_sizes.fetch(callee) do
        raise Unsupported, "register emitter missing frame size for helper #{callee.inspect}"
      end

      @ops[idx] = entry
      @ops[frame_i_idx] = i_frame
      @ops[frame_f_idx] = f_frame
    end
  end

  def compile_value_expr(expr)
    case expr
    when MIR::Cast
      compile_value_expr(expr.expr)
    when MIR::MakeList
      compile_list_value(expr.elem_type, expr.items || [])
    when MIR::ArrayInit
      compile_array_init_value(expr)
    when MIR::CapWrap
      compile_cap_wrap_value(expr)
    when MIR::RcRetain
      compile_rc_retain_value(expr)
    when MIR::RcDowngrade
      compile_rc_downgrade_value(expr)
    when MIR::WeakUpgrade
      compile_weak_upgrade_value(expr)
    when MIR::BgBlock
      compile_bg_block_value(expr)
    when MIR::FnRef
      { kind: :fn_ref, name: expr.name.to_s }
    when MIR::LambdaExpr
      compile_lambda_value(expr)
    when MIR::StructInit
      # `{"key": value}` map-literal sugar lowers to a StructInit of
      # CheatLib.StringMap(...) -- recognize that here so the
      # blockexpr-builder pattern (`Let __hm = StructInit; __hm.put(...);
      # break __hm`) can produce a known map kind without falling through
      # to the struct path that doesn't know StringMap.
      type_text = expr.zig_type.to_s
      if int64_string_map_type?(type_text)
        reg = fresh_vreg
        emit(MNEW, reg)
        next_value = { kind: :int_map, reg: reg }
        next_value
      elsif (vinfo = value_string_map_type?(type_text))
        reg = fresh_vreg
        emit(VMNEW, reg)
        { kind: :value_string_map, reg: reg, union_name: vinfo[:union_name], variant_map: vinfo[:variants] }
      else
        compile_struct_init_value(expr)
      end
    when MIR::ContainerInit
      compile_container_init_value(expr)
    when MIR::DeepCopy
      value = compile_value_expr(expr.source)
      clone_value(value) if value
    when MIR::Deref
      compile_value_expr(expr.expr)
    when MIR::HeapCreate
      compile_value_expr(expr.init)
    when MIR::BlockExpr
      return nil unless value_block_expr?(expr)

      compile_value_block_expr(expr)
    when MIR::Pipeline
      # CONCURRENT(workers: N) and other migrated pipeline operators
      # carry the lowered (sequential) body in `inner`. Single-threaded
      # bc VM runs it sequentially -- behavior matches the concurrent
      # path for pure-data SELECT/WHERE/REDUCE; ordering effects from
      # actual fiber concurrency are out of scope here.
      compile_value_expr(expr.inner)
    when MIR::ShardedMapGet
      compile_struct_list_map_get(expr)
    when MIR::RangeLit
      # `0..<n` / `0..=n` as a value (e.g. `~Int64[] = 0..<n` for a
      # bounded stream pipeline). Materialize it eagerly into an
      # int_list via a tight loop. Used by stream pipelines whose
      # source is a range; the downstream pipeline ForStmt consumes
      # the list normally.
      compile_range_to_int_list(expr)
    when MIR::ItemsAccess
      # ItemsAccess is a safe-deref wrapper over a list expression.
      # The bc emitter treats lists as direct vregs, so the wrapper
      # is transparent.
      compile_value_expr(expr.expr)
    when MIR::TryExpr
      # `try expr` / OR RAISE -- compile inner, then EGUARD propagate.
      r = compile_value_expr(expr.expr)
      emit(EGUARD)
      r
    when MIR::TryCatch
      if propagating_catch?(expr.catch_body)
        r = compile_value_expr(expr.expr)
        e = fresh_ireg
        emit(EFLAG, e)
        emit(JF, e, 0)
        done = @ops.length - 1
        semantic_body(expr.catch_body.body || []).each { |s| compile_stmt(s) }
        @ops[done] = @ops.length
        r
      else
        # OR PASS / value fallback: use the protected value. (OR PASS
        # on a raised error yields undefined in Zig; the supported
        # bc cases don't dynamically raise at this site.)
        compile_value_expr(expr.expr)
      end
    when MIR::Call
      compile_value_call(expr)
    when MIR::Orelse
      compile_value_orelse(expr)
    when MIR::InlineBc
      compile_value_inline_bc(expr)
    when MIR::Ident
      name = resolve_ctx_name(expr.name)
      if @vreg_by_name.key?(name)
        kind = @vkind_by_name.fetch(name)
        result = { kind: kind, reg: @vreg_by_name.fetch(name) }
        # For value containers, propagate the variant info so the
        # binding can re-use the same MATCH dispatch machinery.
        if kind == :value_string_map && (info = (@value_map_variants || {})[name])
          result[:union_name] = info[:union_name]
          result[:variant_map] = info[:variants]
        elsif kind == :value_list && (info = (@value_list_variants || {})[name])
          result[:union_name] = info[:union_name]
          result[:variant_map] = info[:variants]
        end
        return result
      end

      if @vkind_by_name[name] == :struct_list
        info = (@struct_list_info || {})[name]
        return { kind: :struct_list, type: info[:type], fields: info[:fields] } if info
      end

      value = @value_by_name[name]
      clone_value(value) if value
    when MIR::FieldGet
      compile_enum_variant_value(expr) || compile_struct_field_value(expr)
    when MIR::IndexGet
      # `<struct_list>[i]` / `<pool>[i]` -- materialize the per-index
      # struct view so a Let can bind it (e.g. CONCURRENT EACH /
      # pool EACH iterating by index).
      if (list_name = index_get_list_name(expr.object))
        kind = @vkind_by_name[list_name]
        if kind == :struct_list
          return compile_struct_list_index_get(list_name, expr.index)
        elsif kind == :pool
          return compile_pool_index_get(list_name, expr.index)
        end
      end
      object_value = if expr.object.is_a?(MIR::ListItems)
                       compile_value_expr(expr.object.list)
                     else
                       compile_value_expr(expr.object)
                     end
      if object_value && object_value[:kind] == :struct_list
        return compile_struct_list_value_index_get(object_value, expr.index)
      end
      nil
    end
  end

  # `FOR x IN pool DO ... END` -- iterate alive slots only. The loop
  # walks the alive flags array; on a dead slot it skips the body.
  def compile_pool_for_stmt(pool_name, stmt)
    info = (@pool_info || {})[pool_name]
    raise Unsupported, "register emitter lost pool info for #{pool_name.inspect}" unless info
    capture = stmt.capture.to_s.sub(/\A\*+/, "")
    raise Unsupported, "register emitter expected a capture for ForStmt over @pool" if capture.empty?

    len_reg = fresh_ireg
    emit(LLEN, len_reg, info[:alive_reg])
    i_reg = fresh_ireg
    emit(ICONST, i_reg, add_const(0))
    one_reg = fresh_ireg
    emit(ICONST, one_reg, add_const(1))

    loop_start = @ops.length
    cond_reg = fresh_ireg
    emit(ILT, cond_reg, i_reg, len_reg)
    emit(JF, cond_reg, 0)
    exit_target_idx = @ops.length - 1

    saved_continue = @loop_continue_target
    saved_breaks = @loop_break_patches
    saved_continue_patches = @loop_continue_patches
    @loop_continue_target = :deferred_for_update
    @loop_break_patches = []
    @loop_continue_patches = []
    saved_iregs = @ireg_by_name.dup
    saved_fregs = @freg_by_name.dup
    saved_sregs = @sreg_by_name.dup
    saved_values = @value_by_name.dup
    saved_vkinds = @vkind_by_name.dup

    # Skip dead slots: if alive[i] == 0, jump to update.
    alive_reg = fresh_ireg
    emit(LGETI, alive_reg, info[:alive_reg], i_reg)
    emit(JF, alive_reg, 0)
    skip_idx = @ops.length - 1

    # Bind the capture to the per-index struct view (with alive_reg).
    fields = {}
    info[:fields].each do |fname, finfo|
      case finfo[:kind]
      when :int_list
        r = fresh_ireg
        emit(LGETI, r, finfo[:reg], i_reg)
        fields[fname] = { type: :i64, reg: r }
      when :f64_list
        r = fresh_freg
        emit(LFGET, r, finfo[:reg], i_reg)
        fields[fname] = { type: :f64, reg: r }
      when :string_list
        r = fresh_sreg
        emit(LSGET, r, finfo[:reg], i_reg)
        fields[fname] = { type: :string, reg: r }
      when :handle_list
        r = fresh_ireg
        emit(LGETI, r, finfo[:reg], i_reg)
        fields[fname] = { type: finfo[:type], reg: r }
      end
    end
    @value_by_name[capture] = { kind: :struct, type: info[:type], fields: fields, alive_reg: alive_reg }
    @ireg_by_name[capture] = alive_reg

    semantic_body(stmt.body || []).each { |child| compile_stmt(child) }

    continue_target = @ops.length
    @loop_continue_patches.each { |idx| @ops[idx] = continue_target }
    @ops[skip_idx] = continue_target
    new_i = fresh_ireg
    emit(IADD, new_i, i_reg, one_reg)
    emit(IMOV, i_reg, new_i)
    emit(JMP, loop_start)
    @loop_break_patches.each { |idx| @ops[idx] = @ops.length }
    @ops[exit_target_idx] = @ops.length
  ensure
    @ireg_by_name = saved_iregs if saved_iregs
    @freg_by_name = saved_fregs if saved_fregs
    @sreg_by_name = saved_sregs if saved_sregs
    @value_by_name = saved_values if saved_values
    @vkind_by_name = saved_vkinds if saved_vkinds
    @loop_continue_target = saved_continue if defined?(saved_continue)
    @loop_break_patches = saved_breaks if defined?(saved_breaks)
    @loop_continue_patches = saved_continue_patches if defined?(saved_continue_patches)
  end

  # Lowered pool iteration sometimes appears as:
  #   FOR *slot IN pool.slots DO
  #     IF !slot.alive THEN CONTINUE; END
  #     item = slot.value;
  #     ...
  #   END
  # Preserve that shape by binding the capture to a synthetic pool-slot
  # value with `.alive` and `.value` fields backed by the pool's
  # parallel arrays.
  def compile_pool_slots_for_stmt(pool_name, stmt)
    info = (@pool_info || {})[pool_name]
    raise Unsupported, "register emitter lost pool info for #{pool_name.inspect}" unless info
    capture = stmt.capture.to_s.sub(/\A\*+/, "")
    raise Unsupported, "register emitter expected a capture for ForStmt over pool.slots" if capture.empty?

    len_reg = fresh_ireg
    emit(LLEN, len_reg, info[:alive_reg])
    i_reg = fresh_ireg
    emit(ICONST, i_reg, add_const(0))
    one_reg = fresh_ireg
    emit(ICONST, one_reg, add_const(1))

    loop_start = @ops.length
    cond_reg = fresh_ireg
    emit(ILT, cond_reg, i_reg, len_reg)
    emit(JF, cond_reg, 0)
    exit_target_idx = @ops.length - 1

    saved_continue = @loop_continue_target
    saved_breaks = @loop_break_patches
    saved_continue_patches = @loop_continue_patches
    @loop_continue_target = :deferred_for_update
    @loop_break_patches = []
    @loop_continue_patches = []
    saved_iregs = @ireg_by_name.dup
    saved_fregs = @freg_by_name.dup
    saved_sregs = @sreg_by_name.dup
    saved_values = @value_by_name.dup
    saved_vkinds = @vkind_by_name.dup

    alive_reg = fresh_ireg
    emit(LGETI, alive_reg, info[:alive_reg], i_reg)
    @value_by_name[capture] = {
      kind: :pool_slot,
      alive_reg: alive_reg,
      value: pool_struct_value_at(info, i_reg),
    }
    @ireg_by_name[capture] = alive_reg

    semantic_body(stmt.body || []).each { |child| compile_stmt(child) }

    continue_target = @ops.length
    @loop_continue_patches.each { |idx| @ops[idx] = continue_target }
    new_i = fresh_ireg
    emit(IADD, new_i, i_reg, one_reg)
    emit(IMOV, i_reg, new_i)
    emit(JMP, loop_start)
    @loop_break_patches.each { |idx| @ops[idx] = @ops.length }
    @ops[exit_target_idx] = @ops.length
  ensure
    @ireg_by_name = saved_iregs if saved_iregs
    @freg_by_name = saved_fregs if saved_fregs
    @sreg_by_name = saved_sregs if saved_sregs
    @value_by_name = saved_values if saved_values
    @vkind_by_name = saved_vkinds if saved_vkinds
    @loop_continue_target = saved_continue if defined?(saved_continue)
    @loop_break_patches = saved_breaks if defined?(saved_breaks)
    @loop_continue_patches = saved_continue_patches if defined?(saved_continue_patches)
  end

  def pool_struct_value_at(info, idx_reg)
    fields = {}
    info[:fields].each do |fname, finfo|
      case finfo[:kind]
      when :int_list
        r = fresh_ireg
        emit(LGETI, r, finfo[:reg], idx_reg)
        fields[fname] = { type: :i64, reg: r }
      when :f64_list
        r = fresh_freg
        emit(LFGET, r, finfo[:reg], idx_reg)
        fields[fname] = { type: :f64, reg: r }
      when :string_list
        r = fresh_sreg
        emit(LSGET, r, finfo[:reg], idx_reg)
        fields[fname] = { type: :string, reg: r }
      when :handle_list
        r = fresh_ireg
        emit(LGETI, r, finfo[:reg], idx_reg)
        fields[fname] = { type: finfo[:type], reg: r }
      end
    end
    { kind: :struct, type: info[:type], fields: fields }
  end

  # `<pool>[i]` -- read the struct view at slot i, plus the alive
  # flag. The body of `pool |> EACH` (and similar) typically does
  # `IF item == nil CONTINUE` then mutates the struct view, so the
  # binding needs both: a struct view for field access, and an
  # i64 reg for the nil comparison.
  def compile_pool_index_get(pool_name, idx_expr)
    info = (@pool_info || {})[pool_name]
    raise Unsupported, "register emitter lost pool info for #{pool_name.inspect}" unless info
    idx_reg = compile_i64_expr(idx_expr)
    alive_reg = fresh_ireg
    emit(LGETI, alive_reg, info[:alive_reg], idx_reg)
    fields = {}
    info[:fields].each do |fname, finfo|
      case finfo[:kind]
      when :int_list
        reg = fresh_ireg
        emit(LGETI, reg, finfo[:reg], idx_reg)
        fields[fname] = { type: :i64, reg: reg }
      when :f64_list
        reg = fresh_freg
        emit(LFGET, reg, finfo[:reg], idx_reg)
        fields[fname] = { type: :f64, reg: reg }
      when :string_list
        reg = fresh_sreg
        emit(LSGET, reg, finfo[:reg], idx_reg)
        fields[fname] = { type: :string, reg: reg }
      when :handle_list
        reg = fresh_ireg
        emit(LGETI, reg, finfo[:reg], idx_reg)
        fields[fname] = { type: finfo[:type], reg: reg }
      end
    end
    { kind: :struct, type: info[:type], fields: fields, alive_reg: alive_reg }
  end

  # `valueList[i]` (InlineBc op=:getAt) -- typical read path for
  # UserUnion[]@list. Returns nil when the list isn't a value_list,
  # so compile_value_expr falls through to the scalar typed-list paths.
  def compile_value_inline_bc(expr)
    if expr.op == :split
      args = expr.args || []
      raise Unsupported, "register emitter expected 2 args for split" unless args.length == 2
      src_reg = compile_string_expr(args[0])
      sep_reg = compile_string_expr(args[1])
      reg = fresh_vreg
      emit(LSSPLIT, reg, src_reg, sep_reg)
      return { kind: :string_list, reg: reg }
    end
    if expr.op == :keys
      args = expr.args || []
      return nil unless args.length == 1 && args[0].is_a?(MIR::Ident)
      return compile_map_keys(args[0].name.to_s)
    end
    if expr.op == :values
      args = expr.args || []
      return nil unless args.length == 1 && args[0].is_a?(MIR::Ident)
      return compile_map_values(args[0].name.to_s)
    end
    if expr.op == :get
      args = expr.args || []
      if args.length == 2 && args[0].is_a?(MIR::Ident) && @vkind_by_name[args[0].name.to_s] == :pool
        return compile_pool_index_get(args[0].name.to_s, args[1])
      end
    end
    return nil unless expr.op == :getAt
    args = expr.args || []
    return nil unless args.length >= 2 && args[0].is_a?(MIR::Ident)
    list_name = args[0].name.to_s
    if @vkind_by_name[list_name] == :struct_list
      return compile_struct_list_index_get(list_name, args[1])
    end
    return nil unless @vkind_by_name[list_name] == :value_list
    list_info = (@value_list_variants || {})[list_name]
    return nil unless list_info
    variant_map = list_info[:variants]
    union_name = list_info[:union_name]

    list_reg = @vreg_by_name.fetch(list_name)
    idx_reg = compile_i64_expr(args[1])

    raw_tag = fresh_ireg
    emit(LVGETTAG, raw_tag, list_reg, idx_reg)
    tag_reg = translate_rv_tag_to_user_position(raw_tag, variant_map, union_name)

    payloads = {}
    variant_map.each do |variant_name, info|
      case info[:kind]
      when :int
        reg = fresh_ireg
        emit(LVGETI, reg, list_reg, idx_reg)
        payloads[variant_name] = reg
      when :float
        reg = fresh_freg
        emit(LVGETF, reg, list_reg, idx_reg)
        payloads[variant_name] = reg
      when :string
        reg = fresh_sreg
        emit(LVGETS, reg, list_reg, idx_reg)
        payloads[variant_name] = reg
      end
    end

    {
      kind: :union,
      type: union_name,
      tag: nil,
      tag_reg: tag_reg,
      payloads: payloads,
    }
  end

  # `valueMap[k] OR Value.<TagName>` -- the typical read path for
  # HashMap<UserUnion>. Emits VMGETTAG with the fallback variant's tag
  # id, then VMGETI/F/S for each non-Nil variant the union exposes.
  # The result is a synthetic union local that downstream MATCH arms
  # destructure exactly like a non-container Value local.
  def compile_value_orelse(expr)
    if (struct_value = compile_struct_map_orelse(expr))
      return struct_value
    end

    inner = expr.expr
    return nil unless inner.is_a?(MIR::ShardedMapGet) && inner.target.is_a?(MIR::Ident)
    map_name = inner.target.name.to_s
    return nil unless @vkind_by_name[map_name] == :value_string_map
    map_info = (@value_map_variants || {})[map_name]
    return nil unless map_info
    variant_map = map_info[:variants]
    union_name = map_info[:union_name]

    fallback_variant = extract_fallback_variant(expr.fallback)
    miss_info = variant_map[fallback_variant]
    unless miss_info && miss_info[:kind] == :nil
      raise Unsupported, "register emitter only supports `... OR <Union>.<NilVariant>` fallback for HashMap<UserUnion> reads in Phase 1 (got #{fallback_variant.inspect})"
    end

    map_reg = @vreg_by_name.fetch(map_name)
    key_kind, key_operand = map_string_key_operand(inner.key)
    is_lit = key_kind == :literal

    # VMGETTAG writes RegisterValue's tag id (0=Nil, 1=Int64Val,
    # 2=Number, 3=Str) which doesn't line up with the user union's
    # variant-position id that the bc emitter's MATCH lowering
    # compares against. Translate raw RV tag -> user variant position
    # via an inline IEQ chain so the synthesized union local looks
    # identical to a non-container Value local.
    raw_tag = fresh_ireg
    miss_reg = fresh_ireg
    emit(ICONST, miss_reg, add_const(miss_info[:tag_id]))
    emit(is_lit ? VMGETTAG : VMGETTAGR, raw_tag, map_reg, key_operand, miss_reg)
    tag_reg = translate_rv_tag_to_user_position(raw_tag, variant_map, union_name)

    payloads = {}
    variant_map.each do |variant_name, info|
      case info[:kind]
      when :int
        reg = fresh_ireg
        emit(is_lit ? VMGETI : VMGETIR, reg, map_reg, key_operand)
        payloads[variant_name] = reg
      when :float
        reg = fresh_freg
        emit(is_lit ? VMGETF : VMGETFR, reg, map_reg, key_operand)
        payloads[variant_name] = reg
      when :string
        reg = fresh_sreg
        emit(is_lit ? VMGETS : VMGETSR, reg, map_reg, key_operand)
        payloads[variant_name] = reg
      end
    end

    {
      kind: :union,
      type: union_name,
      tag: nil,
      tag_reg: tag_reg,
      payloads: payloads,
    }
  end

  # Map raw_tag (RegisterValue position) to the user union's
  # variant position via an IEQ chain. The variant_map gives us
  # the (rv_tag_id, user_position) pairs. We emit:
  #   tmp_match = IEQ raw, rv0_const → if 1 sets user_pos = user0
  #   ...
  # implemented as: user_pos = sum(IEQ(raw, rvN) * userN). For
  # well-formed input only one IEQ matches so the sum equals the
  # right user position.
  def translate_rv_tag_to_user_position(raw_tag, variant_map, union_name)
    variants = @union_variants[union_name] || []
    user_pos_for_variant = variants.each_with_index.to_h do |variant, idx|
      vname = variant.is_a?(Hash) ? variant[:name].to_s : variant.to_s
      [vname, idx]
    end

    user_tag = fresh_ireg
    emit(ICONST, user_tag, add_const(0))
    variant_map.each do |variant_name, info|
      user_pos = user_pos_for_variant.fetch(variant_name)
      next if user_pos == 0  # default value already 0
      eq_reg = fresh_ireg
      const_reg = fresh_ireg
      emit(ICONST, const_reg, add_const(info[:tag_id]))
      emit(IEQ, eq_reg, raw_tag, const_reg)
      pos_reg = fresh_ireg
      emit(ICONST, pos_reg, add_const(user_pos))
      contrib = fresh_ireg
      emit(IMUL, contrib, eq_reg, pos_reg)
      sum = fresh_ireg
      emit(IADD, sum, user_tag, contrib)
      user_tag = sum
    end
    user_tag
  end

  # `FOR i IN 0..<n DO body END` -- iterate a bare integer range
  # without materializing it. Used by lazy-range pipelines.
  def compile_iter_range_for_stmt(iter, stmt)
    capture = stmt.capture.to_s.sub(/\A\*+/, "")
    raise Unsupported, "register emitter expected a capture for IterRange ForStmt" if capture.empty?

    end_reg = compile_i64_expr(iter.end_val)
    one_reg = fresh_ireg
    emit(ICONST, one_reg, add_const(1))
    i_reg = fresh_ireg
    start_src = compile_i64_expr(iter.start)
    emit(IMOV, i_reg, start_src)

    loop_start = @ops.length
    cond_reg = fresh_ireg
    emit(ILT, cond_reg, i_reg, end_reg)
    emit(JF, cond_reg, 0)
    exit_target_idx = @ops.length - 1

    saved_continue = @loop_continue_target
    saved_breaks = @loop_break_patches
    saved_continue_patches = @loop_continue_patches
    @loop_continue_target = :deferred_for_update
    @loop_break_patches = []
    @loop_continue_patches = []
    saved_iregs = @ireg_by_name.dup

    @ireg_by_name[capture] = i_reg
    semantic_body(stmt.body || []).each { |child| compile_stmt(child) }

    continue_target = @ops.length
    @loop_continue_patches.each { |idx| @ops[idx] = continue_target }
    new_i = fresh_ireg
    emit(IADD, new_i, i_reg, one_reg)
    emit(IMOV, i_reg, new_i)
    emit(JMP, loop_start)
    @loop_break_patches.each { |idx| @ops[idx] = @ops.length }
    @ops[exit_target_idx] = @ops.length
  ensure
    @ireg_by_name = saved_iregs if saved_iregs
    @loop_continue_target = saved_continue if defined?(saved_continue)
    @loop_break_patches = saved_breaks if defined?(saved_breaks)
    @loop_continue_patches = saved_continue_patches if defined?(saved_continue_patches)
  end

  def compile_struct_list_for_stmt(list_name, stmt)
    info = (@struct_list_info || {})[list_name]
    raise Unsupported, "register emitter lost struct_list info for #{list_name.inspect}" unless info
    capture = stmt.capture.to_s.sub(/\A\*+/, "")
    raise Unsupported, "register emitter expected a capture for ForStmt" if capture.empty?

    # Iterate by index over the first field's array; all parallel
    # arrays share the same length by construction.
    first_field = info[:fields].values.first
    raise Unsupported, "register emitter cannot iterate empty struct_list #{list_name.inspect}" unless first_field
    len_op = case first_field[:kind]
             when :int_list then LLEN
             when :f64_list then LFLEN
             when :string_list then LSLEN
             when :handle_list then LLEN
             when :int_handle_values then IHLEN
             when :string_handle_values then SHLEN
             end
    len_reg = fresh_ireg
    emit(len_op, len_reg, first_field[:reg])

    i_reg = fresh_ireg
    emit(ICONST, i_reg, add_const(0))
    one_reg = fresh_ireg
    emit(ICONST, one_reg, add_const(1))

    loop_start = @ops.length
    cond_reg = fresh_ireg
    emit(ILT, cond_reg, i_reg, len_reg)
    emit(JF, cond_reg, 0)
    exit_target_idx = @ops.length - 1

    saved_continue = @loop_continue_target
    saved_breaks = @loop_break_patches
    saved_continue_patches = @loop_continue_patches
    @loop_continue_target = :deferred_for_update
    @loop_break_patches = []
    @loop_continue_patches = []
    saved_iregs = @ireg_by_name.dup
    saved_fregs = @freg_by_name.dup
    saved_sregs = @sreg_by_name.dup
    saved_values = @value_by_name.dup
    saved_vkinds = @vkind_by_name.dup

    fields = {}
    info[:fields].each do |fname, finfo|
      case finfo[:kind]
      when :int_list
        r = fresh_ireg
        emit(LGETI, r, finfo[:reg], i_reg)
        fields[fname] = { type: :i64, reg: r }
      when :f64_list
        r = fresh_freg
        emit(LFGET, r, finfo[:reg], i_reg)
        fields[fname] = { type: :f64, reg: r }
      when :string_list
        r = fresh_sreg
        emit(LSGET, r, finfo[:reg], i_reg)
        fields[fname] = { type: :string, reg: r }
      end
    end
    dirty_fields = {}
    @value_by_name[capture] = { kind: :struct, type: info[:type], fields: fields, dirty_fields: dirty_fields }

    semantic_body(stmt.body || []).each { |child| compile_stmt(child) }

    continue_target = @ops.length
    @loop_continue_patches.each { |idx| @ops[idx] = continue_target }
    write_struct_list_fields_back(info[:fields], fields, i_reg, dirty_fields: dirty_fields)
    new_i = fresh_ireg
    emit(IADD, new_i, i_reg, one_reg)
    emit(IMOV, i_reg, new_i)
    emit(JMP, loop_start)
    @loop_break_patches.each { |idx| @ops[idx] = @ops.length }
    @ops[exit_target_idx] = @ops.length
  ensure
    @ireg_by_name = saved_iregs if saved_iregs
    @freg_by_name = saved_fregs if saved_fregs
    @sreg_by_name = saved_sregs if saved_sregs
    @value_by_name = saved_values if saved_values
    @vkind_by_name = saved_vkinds if saved_vkinds
    @loop_continue_target = saved_continue if defined?(saved_continue)
    @loop_break_patches = saved_breaks if defined?(saved_breaks)
    @loop_continue_patches = saved_continue_patches if defined?(saved_continue_patches)
  end

  def write_struct_list_fields_back(target_fields, source_fields, idx_reg, dirty_fields: nil)
    target_fields.each do |fname, finfo|
      next if dirty_fields && !dirty_fields[fname.to_s]

      field = source_fields[fname.to_s] || source_fields[fname]
      next unless field

      case finfo[:kind]
      when :int_list
        emit(LSETI, finfo[:reg], idx_reg, field.fetch(:reg))
      when :f64_list
        emit(LFSET, finfo[:reg], idx_reg, field.fetch(:reg))
      when :string_list
        emit(LSSET, finfo[:reg], idx_reg, field.fetch(:reg))
      end
    end
  end

  # `<struct_list>.append(<struct value>)` -- decomposes the source
  # struct's per-field regs and appends each into the corresponding
  # parallel array. Source can be any value-tracked struct: an Ident
  # bound by ForStmt iter, a literal StructInit, or a clone produced
  # by compile_value_expr. The bc emitter never materializes a single
  # contiguous struct value in memory; the field-decomposed layout
  # is always our authoritative form.
  def compile_struct_list_append(list_name, source_expr)
    info = (@struct_list_info || {})[list_name]
    raise Unsupported, "register emitter lost struct_list info for #{list_name.inspect}" unless info

    append_struct_to_fields(info.fetch(:fields), info.fetch(:type), source_expr)
  end

  def append_struct_to_fields(fields, type_name, source_expr)
    value = compile_value_expr(source_expr)
    cap_struct_kinds = %i[struct rc_struct arc_struct locked_struct write_locked_struct local_struct versioned_struct atomic_ptr_struct]
    unless value && value.is_a?(Hash) && cap_struct_kinds.include?(value[:kind])
      raise Unsupported, "register emitter expected a struct value for struct_list append, got #{value.inspect[0..80]}"
    end
    unless value[:type] == type_name
      raise Unsupported, "register emitter struct_list append type mismatch: expected #{type_name.inspect}, got #{value[:type].inspect}"
    end

    fields.each do |fname, finfo|
      field = ensure_struct_field_loaded(value, fname.to_s)
      raise Unsupported, "register emitter missing field #{fname.inspect} in append source" unless field
      case finfo[:kind]
      when :int_list    then emit(LAPPENDI, finfo[:reg], field[:reg])
      when :f64_list    then emit(LFAPPEND, finfo[:reg], field[:reg])
      when :string_list then emit(LSAPPEND, finfo[:reg], field[:reg])
      when :handle_list then emit(LAPPENDI, finfo[:reg], field[:reg])
      end
    end
  end

  # Read `<struct_list>[i]` -- returns a synthetic struct value
  # whose field regs are loaded from the parallel arrays at index i.
  # Same shape compile_struct_init_value returns, so downstream
  # FieldGet works without changes.
  def compile_struct_list_index_get(list_name, idx_expr)
    info = (@struct_list_info || {})[list_name]
    raise Unsupported, "register emitter lost struct_list info for #{list_name.inspect}" unless info
    compile_struct_list_value_index_get({ type: info[:type], fields: info[:fields], element_kind: info[:element_kind], list_name: list_name }, idx_expr)
  end

  def compile_struct_list_value_index_get(info, idx_expr)
    idx_reg = compile_i64_expr(idx_expr)
    fields = {}
    {
      kind: info[:element_kind] || :struct,
      type: info[:type],
      fields: fields,
      lazy_struct_list: { fields: info[:fields], idx_reg: idx_reg, list_name: info[:list_name] },
      dirty_fields: {},
    }
  end

  def ensure_struct_field_loaded(value, fname)
    fields = value.fetch(:fields)
    return fields[fname] if fields.key?(fname)
    return fields[fname.to_sym] if fields.key?(fname.to_sym)

    lazy = value[:lazy_struct_list]
    return nil unless lazy

    finfo = lazy.fetch(:fields)[fname] || lazy.fetch(:fields)[fname.to_sym]
    return nil unless finfo

    idx_reg = lazy.fetch(:idx_reg)
    field = case finfo[:kind]
            when :int_list
              reg = fresh_ireg
              emit(LGETI, reg, finfo[:reg], idx_reg)
              { type: :i64, reg: reg }
            when :f64_list
              reg = fresh_freg
              emit(LFGET, reg, finfo[:reg], idx_reg)
              { type: :f64, reg: reg }
            when :string_list
              reg = fresh_sreg
              emit(LSGET, reg, finfo[:reg], idx_reg)
              { type: :string, reg: reg }
            when :handle_list
              reg = fresh_ireg
              emit(LGETI, reg, finfo[:reg], idx_reg)
              { type: finfo[:type], reg: reg }
            when :int_handle_values
              reg = fresh_ireg
              emit(IHGET, reg, finfo[:reg], idx_reg)
              { type: :i64, reg: reg }
            when :string_handle_values
              reg = fresh_sreg
              emit(SHGET, reg, finfo[:reg], idx_reg)
              { type: :string, reg: reg }
            end
    fields[fname] = field if field
    field
  end

  def index_get_list_name(object)
    if object.is_a?(MIR::Ident)
      object.name.to_s
    elsif object.is_a?(MIR::ListItems) && object.list.is_a?(MIR::Ident)
      object.list.name.to_s
    end
  end

  def list_like_value?(value)
    %i[int_list f64_list string_list struct_list].include?(value[:kind])
  end

  def clone_list_value(value)
    case value[:kind]
    when :int_list, :f64_list, :string_list
      clone_scalar_list_value(value)
    when :struct_list
      clone_struct_list_value(value)
    end
  end

  def clone_scalar_list_value(value)
    src_reg = value.fetch(:reg)
    kind = value.fetch(:kind)
    dst_reg = fresh_vreg
    new_op, len_op, get_op, append_op, fresh_fn = case kind
      when :int_list
        [LNEW, LLEN, LGETI, LAPPENDI, :fresh_ireg]
      when :f64_list
        [LFNEW, LFLEN, LFGET, LFAPPEND, :fresh_freg]
      when :string_list
        [LSNEW, LSLEN, LSGET, LSAPPEND, :fresh_sreg]
      end
    emit(new_op, dst_reg)
    emit_clone_loop(src_reg, dst_reg, len_op, get_op, append_op, fresh_fn)
    { kind: kind, reg: dst_reg }
  end

  def clone_struct_list_value(value)
    fields = value.fetch(:fields)
    cloned_fields = {}
    fields.each do |fname, finfo|
      cloned = clone_scalar_list_value(finfo)
      cloned_fields[fname] = finfo.merge(reg: cloned.fetch(:reg))
    end
    { kind: :struct_list, type: value.fetch(:type), fields: cloned_fields, element_kind: value[:element_kind] }
  end

  def emit_clone_loop(src_reg, dst_reg, len_op, get_op, append_op, fresh_fn)
    len_reg = fresh_ireg
    emit(len_op, len_reg, src_reg)
    i_reg = fresh_ireg
    emit(ICONST, i_reg, add_const(0))
    one_reg = fresh_ireg
    emit(ICONST, one_reg, add_const(1))

    loop_start = @ops.length
    cond = fresh_ireg
    emit(ILT, cond, i_reg, len_reg)
    emit(JF, cond, 0)
    exit_patch = @ops.length - 1

    val = send(fresh_fn)
    emit(get_op, val, src_reg, i_reg)
    emit(append_op, dst_reg, val)
    next_i = fresh_ireg
    emit(IADD, next_i, i_reg, one_reg)
    emit(IMOV, i_reg, next_i)
    emit(JMP, loop_start)
    @ops[exit_patch] = @ops.length
  end

  def compile_sort(node)
    target = sort_target_value(node.items_expr)
    raise Unsupported, "register emitter only supports ORDER_BY over list values in this tranche" unless target

    case target.fetch(:kind)
    when :int_list
      compile_scalar_list_sort(target.fetch(:reg), :int_list, node)
    when :f64_list
      compile_scalar_list_sort(target.fetch(:reg), :f64_list, node)
    when :struct_list
      compile_struct_list_sort(target, node)
    else
      raise Unsupported, "register emitter does not support ORDER_BY over #{target.fetch(:kind).inspect}"
    end
  end

  def sort_target_value(expr)
    expr = expr.object while expr.is_a?(MIR::FieldGet) && expr.field.to_s == "items"
    compile_value_expr(expr)
  end

  def compile_scalar_list_sort(list_reg, kind, node)
    len_op, get_op, set_op, fresh_fn, bind_map = case kind
      when :int_list
        [LLEN, LGETI, LSETI, :fresh_ireg, @ireg_by_name]
      when :f64_list
        [LFLEN, LFGET, LFSET, :fresh_freg, @freg_by_name]
      end
    compile_sort_loop(len_op, list_reg) do |j_reg, next_j_reg, swap_end|
      a = send(fresh_fn)
      b = send(fresh_fn)
      emit(get_op, a, list_reg, next_j_reg)
      emit(get_op, b, list_reg, j_reg)
      bind_map["a"] = a
      bind_map["b"] = b
      cond = compile_bool_expr(MIR::BinOp.new("<", node.key_a, node.key_b))
      emit(JF, cond, 0)
      swap_end << (@ops.length - 1)
      emit(set_op, list_reg, j_reg, a)
      emit(set_op, list_reg, next_j_reg, b)
    end
  end

  def compile_struct_list_sort(value, node)
    fields = value.fetch(:fields)
    first = fields.values.first
    raise Unsupported, "register emitter cannot sort empty struct_list" unless first

    len_op = case first[:kind]
             when :int_list then LLEN
             when :f64_list then LFLEN
             when :string_list then LSLEN
             when :handle_list then LLEN
             end
    compile_sort_loop(len_op, first.fetch(:reg)) do |j_reg, next_j_reg, swap_end|
      a_fields = load_struct_fields_at(fields, next_j_reg)
      b_fields = load_struct_fields_at(fields, j_reg)
      @value_by_name["a"] = { kind: :struct, type: value.fetch(:type), fields: a_fields }
      @value_by_name["b"] = { kind: :struct, type: value.fetch(:type), fields: b_fields }
      cond = compile_bool_expr(MIR::BinOp.new("<", node.key_a, node.key_b))
      emit(JF, cond, 0)
      swap_end << (@ops.length - 1)
      store_struct_fields_at(fields, j_reg, a_fields)
      store_struct_fields_at(fields, next_j_reg, b_fields)
    end
  end

  def compile_sort_loop(len_op, len_source_reg)
    saved_iregs = @ireg_by_name.dup
    saved_fregs = @freg_by_name.dup
    saved_sregs = @sreg_by_name.dup
    saved_values = @value_by_name.dup

    len_reg = fresh_ireg
    emit(len_op, len_reg, len_source_reg)
    one_reg = fresh_ireg
    emit(ICONST, one_reg, add_const(1))
    last_reg = fresh_ireg
    emit(ISUB, last_reg, len_reg, one_reg)

    i_reg = fresh_ireg
    emit(ICONST, i_reg, add_const(0))
    outer_start = @ops.length
    outer_cond = fresh_ireg
    emit(ILT, outer_cond, i_reg, len_reg)
    emit(JF, outer_cond, 0)
    outer_exit = @ops.length - 1

    j_reg = fresh_ireg
    emit(ICONST, j_reg, add_const(0))
    inner_start = @ops.length
    inner_cond = fresh_ireg
    emit(ILT, inner_cond, j_reg, last_reg)
    emit(JF, inner_cond, 0)
    inner_exit = @ops.length - 1

    next_j = fresh_ireg
    emit(IADD, next_j, j_reg, one_reg)
    swap_end = []
    yield(j_reg, next_j, swap_end)
    swap_end.each { |idx| @ops[idx] = @ops.length }
    emit(IMOV, j_reg, next_j)
    emit(JMP, inner_start)
    @ops[inner_exit] = @ops.length

    next_i = fresh_ireg
    emit(IADD, next_i, i_reg, one_reg)
    emit(IMOV, i_reg, next_i)
    emit(JMP, outer_start)
    @ops[outer_exit] = @ops.length
  ensure
    @ireg_by_name = saved_iregs if saved_iregs
    @freg_by_name = saved_fregs if saved_fregs
    @sreg_by_name = saved_sregs if saved_sregs
    @value_by_name = saved_values if saved_values
  end

  def load_struct_fields_at(fields, idx_reg)
    loaded = {}
    fields.each do |fname, finfo|
      case finfo[:kind]
      when :int_list
        reg = fresh_ireg
        emit(LGETI, reg, finfo[:reg], idx_reg)
        loaded[fname] = { type: :i64, reg: reg }
      when :f64_list
        reg = fresh_freg
        emit(LFGET, reg, finfo[:reg], idx_reg)
        loaded[fname] = { type: :f64, reg: reg }
      when :string_list
        reg = fresh_sreg
        emit(LSGET, reg, finfo[:reg], idx_reg)
        loaded[fname] = { type: :string, reg: reg }
      when :handle_list
        reg = fresh_ireg
        emit(LGETI, reg, finfo[:reg], idx_reg)
        loaded[fname] = { type: finfo[:type], reg: reg }
      when :int_handle_values
        reg = fresh_ireg
        emit(IHGET, reg, finfo[:reg], idx_reg)
        loaded[fname] = { type: :i64, reg: reg }
      when :string_handle_values
        reg = fresh_sreg
        emit(SHGET, reg, finfo[:reg], idx_reg)
        loaded[fname] = { type: :string, reg: reg }
      end
    end
    loaded
  end

  def store_struct_fields_at(fields, idx_reg, values)
    fields.each do |fname, finfo|
      field = values.fetch(fname)
      case finfo[:kind]
      when :int_list then emit(LSETI, finfo[:reg], idx_reg, field.fetch(:reg))
      when :f64_list then emit(LFSET, finfo[:reg], idx_reg, field.fetch(:reg))
      when :string_list then emit(LSSET, finfo[:reg], idx_reg, field.fetch(:reg))
      when :handle_list then emit(LSETI, finfo[:reg], idx_reg, field.fetch(:reg))
      end
    end
  end

  def extract_fallback_variant(node)
    case node
    when MIR::StructInit
      (node.fields || []).first&.fetch(:name)&.to_s
    when MIR::FieldGet
      node.field.to_s
    when MIR::Ident
      # Could be a Value.X reference -- the field syntax in CLEAR.
      name = node.name.to_s
      name.split(".").last
    end
  end

  def compile_value_call(expr)
    if expr.callee.to_s == "CheatLib.makeList"
      args = expr.args || []
      source = args[2]
      value = compile_value_expr(source)
      return clone_list_value(value) if value && list_like_value?(value)
    end

    function = @functions_by_name[expr.callee.to_s]
    return nil unless function

    return_type = list_value_type(function.ret_type) || value_type(function.ret_type)
    return nil unless value_register_type?(return_type) || union_register_type?(return_type) || list_register_type?(return_type)

    compiled_args = compile_call_args(expr.callee, function, expr.args || [])
    compile_inline_function(function, return_type, compiled_args)
  end

  def compile_value_block_expr(expr)
    semantic_body(expr.body || []).each do |stmt|
      return compile_value_expr(stmt.value) if stmt.is_a?(MIR::BreakStmt)

      compile_stmt(stmt)
    end

    nil
  end

  def value_block_expr?(expr)
    # The simple case: BreakStmt's value is a value-producing expr we
    # can recognize statically (StructInit, ContainerInit, fn-returning-
    # struct Call, etc.).
    return true if (expr.body || []).any? do |stmt|
      stmt.is_a?(MIR::BreakStmt) && value_expr_candidate?(stmt.value)
    end

    # The map-literal-builder pattern: BreakStmt's value is an Ident
    # whose binding (an earlier Let in the same block) IS a value-
    # producing init. We can't see the binding in @value_by_name yet
    # because the body hasn't run, so peek at the prior Let's init.
    body = expr.body || []
    body.each_with_index do |stmt, i|
      next unless stmt.is_a?(MIR::BreakStmt) && stmt.value.is_a?(MIR::Ident)
      let = body[0...i].reverse.find { |s| s.is_a?(MIR::Let) && s.name.to_s == stmt.value.name.to_s }
      return true if let && value_expr_candidate?(let.init)
      return true if let && let.init.is_a?(MIR::StructInit) &&
                     (int64_string_map_type?(let.init.zig_type.to_s) ||
                      value_string_map_type?(let.init.zig_type.to_s) ||
                      struct_list_map_type?(let.annotation))
    end
    false
  end

  def value_expr_candidate?(expr)
    case expr
    when MIR::StructInit, MIR::ContainerInit, MIR::MakeList, MIR::FnRef, MIR::LambdaExpr
      true
    when MIR::Call
      return true if expr.callee.to_s == "CheatLib.makeList"

      function = @functions_by_name[expr.callee.to_s]
      return_type = function && (list_value_type(function.ret_type) || value_type(function.ret_type))
      return_type && (value_register_type?(return_type) || union_register_type?(return_type) || list_register_type?(return_type))
    when MIR::Ident
        @value_by_name.key?(expr.name.to_s) ||
        @vreg_by_name.key?(expr.name.to_s) ||
        @vkind_by_name[expr.name.to_s] == :struct_list
    when MIR::DeepCopy
      value_expr_candidate?(expr.source)
    when MIR::Cast, MIR::Deref
      value_expr_candidate?(expr.expr)
    else
      false
    end
  end

  def compile_lambda_value(expr)
    captures = {}
    (expr.captures || []).each do |capture|
      name = capture.to_s
      if @ireg_by_name.key?(name)
        captures[name] = { type: :i64, reg: @ireg_by_name.fetch(name) }
      elsif @freg_by_name.key?(name)
        captures[name] = { type: :f64, reg: @freg_by_name.fetch(name) }
      elsif @sreg_by_name.key?(name)
        captures[name] = { type: :string, reg: @sreg_by_name.fetch(name) }
      else
        raise Unsupported, "register emitter only supports scalar lambda capture #{name.inspect} in this tranche"
      end
    end

    { kind: :lambda, fn_def: expr.fn_def, captures: captures }
  end

  # `[item1, item2, ...]` lowers to MIR::ArrayInit. For scalar
  # element types (i64/f64/string) it's equivalent to compile_list_value.
  # For struct elements we use field-decomposition: each struct field
  # becomes its own typed list (parallel arrays). The synthetic
  # struct_list value carries the field-name -> (vreg, type) map so
  # `arr[i].field` and `FOR x IN arr DO ... x.field END` can read
  # from the right per-field array.
  #
  # Compared to compiled CLEAR's array-of-struct layout, this is a
  # storage shape difference -- the OBSERVED behavior matches for
  # field reads, length, and iteration; per-field cleanup is
  # equivalent because each field's @list cleanup runs the same
  # variant cleanup as compiled CLEAR's struct-element cleanup.
  def compile_array_init_value(expr)
    elem_type_text = expr.elem_type.to_s
    items = expr.items || []
    case normalize_type(elem_type_text)
    when :i64
      compile_list_value("i64", items)
    when :f64
      compile_list_value("f64", items)
    when :string
      compile_list_value("[]const u8", items)
    else
      compile_struct_array_init(elem_type_text, items)
    end
  end

  # `BG { body }` -- the bytecode VM runs the body synchronously and
  # treats the resulting Promise as just the body's value. Faithful
  # for tests where the BG body is pure compute (no shared mutable
  # state observed by the parent through fiber-concurrent ordering);
  # tests that depend on actual fiber concurrency need the full
  # spawn path (deferred work).
  # Inside a synchronously-inlined BG body, captures are renamed to
  # `__ctx_<id>.<name>` (the FSM context field path). Strip the
  # prefix so register lookups find the outer-scope binding.
  def resolve_ctx_name(name)
    text = name.to_s
    return text unless @bg_ctx_prefixes && !@bg_ctx_prefixes.empty?
    @bg_ctx_prefixes.each do |pfx|
      if text.start_with?(pfx) && (idx = text.index(".")) && idx > pfx.length - 1
        # Strip "__ctx_<id>." -> "<name>"
        rest = text[idx + 1..]
        return rest if rest && !rest.empty?
      end
    end
    text
  end

  # NEXT lowers to `MethodCall(receiver, "next", [])`. In the
  # single-threaded bc VM the BG body has been inlined synchronously
  # and the binding is aliased to the underlying scalar reg, so NEXT
  # is just an Ident-equivalent lookup.
  # `c.load()` / `c.store(v)` / `c.fetchAdd(n)` / `c.fetchSub(n)`
  # on an `@shared:atomic` scalar. Single-threaded VM: the atomic
  # wrapper has no observable behavior; load = read, store/fetchAdd
  # = mutate. `fetchAdd` returns the old value -- but the bc VM's
  # tests use it for the side effect, so returning the new value
  # is also fine for the tests we have.
  # `@shared:atomic` is lowered as Arc<Atomic<T>>, so an atomic op's
  # receiver arrives wrapped in MIR::Deref (the `.ctrl.data.*` unwrap),
  # not as a bare Ident. Peel any Deref layers to recover the binding
  # Ident; return nil if it does not bottom out at an Ident.
  def atomic_receiver_ident(node)
    node = node.expr while node.is_a?(MIR::Deref)
    node.is_a?(MIR::Ident) ? node : nil
  end

  def compile_atomic_method(expr, type)
    return nil unless expr.is_a?(MIR::MethodCall)
    recv = atomic_receiver_ident(expr.receiver)
    return nil unless recv
    name = recv.name.to_s
    case expr.method.to_s
    when "load"
      record_shared_event(:read, name, :atomic_primitive,
                          caps: { ownership: :none, sync: :atomic_primitive })
      case type
      when :i64    then return @ireg_by_name[name]
      when :f64    then return @freg_by_name[name]
      when :string then return @sreg_by_name[name]
      end
    end
    nil
  end

  def compile_bg_promise_next(expr, type)
    return nil unless expr.is_a?(MIR::MethodCall)
    return nil unless expr.method.to_s == "next"
    return nil unless expr.receiver.is_a?(MIR::Ident)

    name = resolve_ctx_name(expr.receiver.name)

    if (stream = (@bg_stream_bindings || {})[name])
      return nil unless stream.fetch(:payload_kind) == type

      list_reg = stream.fetch(:reg)
      cursor_reg = stream.fetch(:cursor_reg)
      dst = case type
            when :i64    then fresh_ireg
            when :f64    then fresh_freg
            when :string then fresh_sreg
            end
      op = case type
           when :i64    then LGETI
           when :f64    then LFGET
           when :string then LSGET
           end
      emit(op, dst, list_reg, cursor_reg)
      one_reg = fresh_ireg
      emit(ICONST, one_reg, add_const(1))
      emit(IADD, cursor_reg, cursor_reg, one_reg)
      return dst
    end

    promise = (@bg_promise_bindings || {})[name]
    return nil unless promise
    return nil unless promise.fetch(:payload_kind) == type

    if promise[:fiber]
      fut = promise.fetch(:reg)
      case type
      when :i64, :bool
        dst = fresh_ireg; emit(FNEXTI, dst, fut); return dst
      when :f64
        dst = fresh_freg; emit(FNEXTF, dst, fut); return dst
      when :string
        dst = fresh_sreg; emit(FNEXTS, dst, fut); return dst
      end
    end

    case type
    when :i64    then @ireg_by_name.fetch(name)
    when :f64    then @freg_by_name.fetch(name)
    when :string then @sreg_by_name.fetch(name)
    end
  end

  def compile_bg_block_value(expr)
    body = expr.run_body || []
    raise Unsupported, "register emitter requires structured run_body for BgBlock" if body.empty?

    # Loom groundwork: every BG site is a potential dispatch point
    # where the body can run on another thread. Recording the site
    # lets a future scheduler enumerate which interleavings to try.
    @bg_dispatch_points << {
      function: @current_function_name,
      line: @current_source_line,
      capture_count: (expr.captures || {}).length,
    }

    if @bg_mode == :defer
      # Reserved for the future deterministic-replay scheduler. The
      # body is captured as a schedulable unit instead of being
      # inlined. No bc emitter today drives this path.
      raise Unsupported, "register emitter :defer BG mode is reserved for future loom-mode integration"
    end

    if @bg_mode == :fiber && expr.fsm_structure.nil? && !bg_body_has_suspend?(body) &&
       (@bg_ctx_prefixes.nil? || @bg_ctx_prefixes.empty?)
      caps = (expr.captures || {})
      cap_kind = lambda do |t|
        return :other unless t.respond_to?(:raw)
        return :other if %i[list_collection? array? map? set_collection? pool?]
                           .any? { |m| t.respond_to?(m) && t.send(m) } &&
                         !(t.respond_to?(:string?) && t.string?)
        return :string if t.respond_to?(:string?) && t.string?
        case t.raw.to_s
        when "Int64", "Bool" then :i64
        when "Float64" then :f64
        else :other
        end
      end
      tail = body.last
      result_tail = bg_body_result_value(tail)
      pk = result_tail ? inferred_expr_type(result_tail) : :other
      pk = :i64 if pk == :bool
      void_body = !result_tail || pk == :void
      kinds = caps.transform_values { |t| cap_kind.call(t) }
      # A cell-backed @shared:locked struct capture (R6.2b) shares by
      # value-id: the cell index marshals as an i64, sharedCells is
      # already by-ref, so the fiber mutates the same cell. The body
      # reaches it via @value_by_name, not a scalar reg.
      caps.each_key do |n|
        kinds[n] = :cell if kinds[n] == :other && cell_backed_field_cell(@value_by_name[n])
      end
      if !%i[i64 f64 string].include?(pk) && result_tail.is_a?(MIR::Ident)
        bare = result_tail.name.to_s.split(".").last
        pk = kinds[bare] if kinds.key?(bare)
      end
      name_map = { i64: @ireg_by_name, f64: @freg_by_name, string: @sreg_by_name }
      push_op = { i64: CAPPUSHI, f64: CAPPUSHF, string: CAPPUSHS, cell: CAPPUSHI }
      cap_op  = { i64: CAPGETI, f64: CAPGETF, string: CAPGETS, cell: CAPGETI }
      if ([:i64, :f64, :string].include?(pk) || void_body) && kinds.values.all? { |k| %i[i64 f64 string cell].include?(k) }
        outer = caps.keys.map do |n|
          k = kinds[n]
          reg = k == :cell ? cell_backed_field_cell(@value_by_name[n]) : name_map[k].fetch(n)
          [n, k, reg]
        end
        emit(JMP, 0)
        over_patch = @ops.length - 1
        entry_ip = @ops.length
        saved = outer.map { |n, k, _| [n, k, k == :cell ? @value_by_name[n] : name_map[k][n]] }
        saved_pfx = @bg_ctx_prefixes
        @bg_ctx_prefixes = (saved_pfx ? saved_pfx.dup : []).push("__ctx_")
        outer.each_with_index do |(n, k, _), i|
          if k == :cell
            r = fresh_ireg
            emit(CAPGETI, r, add_const(i))
            cv = @value_by_name[n]
            fname = cv[:fields].keys.first
            @value_by_name[n] = { kind: cv[:kind], type: cv[:type], caps: cv[:caps],
                                  fields: { fname => { type: :i64, cell: r } } }
          else
            r = (k == :i64 ? fresh_ireg : k == :f64 ? fresh_freg : fresh_sreg)
            emit(cap_op[k], r, add_const(i))
            name_map[k][n] = r
          end
        end
        if void_body
          body.each { |s| compile_stmt(s) }
          z = fresh_ireg
          emit(ICONST, z, add_const(0))
          emit(IRET, z)
        else
          body[0...-1].each { |s| compile_stmt(s) }
          ret_expr = T.must(result_tail)
          ret = pk == :i64 ? compile_i64_expr(ret_expr) : pk == :f64 ? compile_f64_expr(ret_expr) : compile_string_expr(ret_expr)
          emit(pk == :i64 ? IRET : pk == :f64 ? FRET : SRET, ret)
        end
        @bg_ctx_prefixes = saved_pfx
        saved.each do |n, k, v|
          if k == :cell
            @value_by_name[n] = v
          elsif v.nil?
            name_map[k].delete(n)
          else
            name_map[k][n] = v
          end
        end
        @ops[over_patch] = @ops.length
        emit(CAPNEW)
        outer.each { |_, k, r| emit(push_op[k], r) }
        fid = fresh_ireg
        emit(BGSPAWN, fid, entry_ip, 0)
        return { kind: :bg_promise, payload_kind: void_body ? :void : pk, reg: fid, fiber: true }
      end
    end

    # The lowering rewrites captured variable references inside the
    # BG body to `__ctx_<id>.<name>` (the FSM context field path).
    # Synchronous inlining maps those back to the outer-scope name.
    saved_prefixes = @bg_ctx_prefixes
    @bg_ctx_prefixes = (saved_prefixes ? saved_prefixes.dup : []).push("__ctx_")

    last = body.last
    result_tail = bg_body_result_value(last)

    if !result_tail
      # Side-effect-only BG body (no value). Run every stmt as a
      # statement; NEXT on the resulting promise is a no-op.
      body.each { |s| compile_stmt(s) }
      return { kind: :bg_promise, payload_kind: :void, reg: nil }
    end

    # Compile priors first so reg lookups (e.g. an Ident-shaped tail
    # referring to a Let earlier in the body) resolve. Then infer
    # the tail's type from the now-populated bindings and compile
    # via the matching scalar emitter.
    body[0...-1].each { |s| compile_stmt(s) }
    type = inferred_expr_type(result_tail)
    case type
    when :i64, :bool
      reg = compile_i64_expr(result_tail)
      { kind: :bg_promise, payload_kind: :i64, reg: reg }
    when :f64
      reg = compile_f64_expr(result_tail)
      { kind: :bg_promise, payload_kind: :f64, reg: reg }
    when :string
      reg = compile_string_expr(result_tail)
      { kind: :bg_promise, payload_kind: :string, reg: reg }
    when :void
      # Tail is an expression with no value (e.g. sleep). Run it
      # as a stmt; the promise carries no payload.
      compile_stmt(T.must(last))
      { kind: :bg_promise, payload_kind: :void, reg: nil }
    else
      raise Unsupported, "register emitter does not yet support BG body returning #{type.inspect}"
    end
  ensure
    @bg_ctx_prefixes = saved_prefixes
  end

  # A BG body's last statement determines the Promise's payload type.
  # An expression-shaped last statement (Lit, Call, BinOp, ...) gives
  # the value; anything else (assignments, ScopeBlocks, IfStmts that
  # don't break with a value) is side-effect-only and yields ~Void.
  # A nested BG or a NEXT anywhere makes the body FSM-eligible
  # (suspend points); the plain :fiber region cannot model that.
  def bg_body_has_suspend?(node)
    case node
    when MIR::BgBlock then true
    when MIR::MethodCall then node.method.to_s == "next" ||
        bg_body_has_suspend?(node.receiver) ||
        (node.args || []).any? { |a| bg_body_has_suspend?(a) }
    when Array then node.any? { |n| bg_body_has_suspend?(n) }
    else
      node.is_a?(Struct) && node.class.name.to_s.start_with?("MIR::") &&
        node.members.any? { |m| bg_body_has_suspend?(node[m]) }
    end
  end

  def bg_body_tail_is_expr?(last)
    !!bg_body_result_value(last)
  end

  def bg_body_result_value(last)
    return nil unless last
    if last.is_a?(MIR::Set) && bg_inner_result_target?(last.target)
      return last.value
    end
    case last
    when MIR::Lit, MIR::Ident, MIR::BinOp, MIR::UnaryOp, MIR::Call, MIR::MethodCall,
         MIR::FieldGet, MIR::IndexGet, MIR::Cast, MIR::InlineBc, MIR::Pipeline,
         MIR::TryExpr, MIR::TryCatch, MIR::Orelse, MIR::ConcatStr, MIR::DeepCopy,
         MIR::Deref, MIR::OptionalUnwrap, MIR::BlockExpr
      last
    else
      nil
    end
  end

  def bg_inner_result_target?(target)
    return false unless target.is_a?(MIR::FieldGet) && target.field.to_s == "result"
    inner = target.object
    inner.is_a?(MIR::FieldGet) && inner.field.to_s == "inner"
  end

  # `Counter{ value: 42 } @multiowned` / `... @shared` on a scalar
  # struct. The MIR wraps the StructInit in a MIR::CapWrap with
  # own_fn = "rcCreate" / "arcCreate". Compiled CLEAR allocates a
  # heap-backed Rc(T) / Arc(T) control block; the bytecode VM uses
  # field-decomposed scalar registers + a virtual refcount tracked
  # in the bc emitter alone (no allocation).
  #
  # Faithfulness: the testing-allocator "no leaks" check is vacuous
  # here because we don't allocate any of T on the heap. Field
  # reads, `n2 = n` clones, and scope-exit cleanup all observe the
  # same semantics as compiled CLEAR for scalar-fielded structs.
  # When fields contain heap-owned data (Strings), we'll need to
  # respect the refcount before tearing down those fields.
  def compile_cap_wrap_value(expr)
    inner = expr.inner
    # Atomic primitive: `@shared:atomic` on Int64/Float64/String wraps
    # a scalar, not a struct. Single-threaded VM has nothing atomic
    # to honor; the wrapped primitive is observably equivalent to the
    # raw value, so just compile the inner and pass it through.
    if expr.sync_fn.to_s == "atomicCreate" || expr.sync_fn.to_s == "atomicValueCreate"
      kind = inferred_expr_type(inner)
      reg = case kind
            when :i64, :bool then compile_i64_expr(inner)
            when :f64        then compile_f64_expr(inner)
            when :string     then compile_string_expr(inner)
            end
      return { kind: :atomic_primitive, payload_kind: kind, reg: reg } if reg
    end

    inner = inner.init if inner.is_a?(MIR::HeapCreate)

    unless inner.is_a?(MIR::StructInit)
      raise Unsupported, "register emitter only supports CapWrap of StructInit in this tranche (got #{inner.class.name.split('::').last})"
    end
    own_fn = expr.own_fn.to_s
    sync_fn = expr.sync_fn.to_s
    strategy = expr.strategy
    unless ["rcCreate", "arcCreate", ""].include?(own_fn) &&
           ["lockedCreate", "writeLockedCreate", "rwLockedCreate", "versionedCreate", "atomicPtrCreate", ""].include?(sync_fn)
      raise Unsupported, "register emitter only supports @multiowned/@shared/@locked/@writeLocked/@local CapWrap in this tranche (got own_fn=#{own_fn.inspect} sync_fn=#{sync_fn.inspect})"
    end

    type_name = inner.zig_type.to_s
    fields = @struct_fields[type_name]
    raise Unsupported, "register emitter does not know struct #{type_name.inspect} for CapWrap" unless fields

    field_regs = {}
    inner.fields.each do |entry|
      fname = entry.fetch(:name).to_s
      ftype_text = (fields[fname] || "").to_s
      norm = normalize_type(ftype_text)
      norm = :i64 if ftype_text == "bool" || ftype_text == "Bool"
      reg = case norm
            when :i64 then compile_i64_expr(entry.fetch(:value))
            when :f64 then compile_f64_expr(entry.fetch(:value))
            when :string then compile_string_expr(entry.fetch(:value))
            else
              raise Unsupported, "register emitter only supports scalar fields in @multiowned/@shared structs (got #{fname}: #{ftype_text})"
            end
      field_regs[fname] = { type: norm, reg: reg }
    end

    # Two independent capability axes: ownership (Rc/Arc/none) and
    # sync (Locked/WriteLocked/Versioned/AtomicPtr/none). The bc
    # emitter's primary value-kind picks ONE for downstream
    # dispatch (existing behavior), but `caps` records both so
    # loom-mode can distinguish e.g. @shared (atomic refcount only,
    # no lock events) from @shared:locked (atomic refcount + lock
    # acquire/release).
    ownership = case own_fn
                when "arcCreate" then :arc
                when "rcCreate"  then :rc
                else (strategy == :local ? :local : :none)
                end
    sync = case sync_fn
           when "lockedCreate", "rwLockedCreate" then :locked
           when "writeLockedCreate"              then :write_locked
           when "versionedCreate"                then :versioned
           when "atomicPtrCreate"                then :atomic_ptr
           else :none
           end
    caps = { ownership: ownership, sync: sync }

    # Primary kind: sync wins over ownership for tagging because the
    # WITH-block / SnapshotRead / WithMatchDispatch dispatch keys on
    # sync semantics. Single-threaded VM treats sync as a no-op so
    # the choice is stylistic; loom-mode reads `caps` directly.
    cap_kind = case sync
               when :versioned   then :versioned_struct
               when :atomic_ptr  then :atomic_ptr_struct
               when :locked      then ownership == :arc ? :arc_struct : :locked_struct
               when :write_locked then :write_locked_struct
               else
                 case ownership
                 when :arc   then :arc_struct
                 when :rc    then :rc_struct
                 when :local then :local_struct
                 else :rc_struct
                 end
               end
    if sync == :locked && field_regs.size == 1
      fname, finfo = field_regs.first
      if finfo[:type] == :i64
        cell_reg = fresh_ireg
        emit(SCELLNEW, cell_reg)
        emit(SCELLSETI, cell_reg, finfo[:reg])
        field_regs[fname] = { type: :i64, cell: cell_reg }
      end
    end

    { kind: cap_kind, type: type_name, fields: field_regs, caps: caps }
  end

  # `b = a` where `a` is an Rc/Arc handle clones the handle. Compiled
  # CLEAR bumps the refcount; here we just alias the field-reg map
  # so `b.value` reads the same registers as `a.value`. Refcount
  # bookkeeping is unnecessary because we don't free anything until
  # the surrounding scope drops the last handle, which CLEAR's
  # MIR::Cleanup already handles via @cleanups (no-op for our model).
  def compile_rc_retain_value(expr)
    return nil unless expr.source.is_a?(MIR::Ident)
    src = @value_by_name[expr.source.name.to_s]
    return nil unless src && (src[:kind] == :rc_struct || src[:kind] == :arc_struct)
    clone_value(src)
  end

  def compile_rc_downgrade_value(expr)
    src = compile_value_expr(expr.source)
    return nil unless src && %i[struct rc_struct arc_struct].include?(src[:kind])

    value = { kind: :rc_struct, type: src.fetch(:type), fields: src.fetch(:fields), caps: { ownership: :weak, sync: :none } }
    value[:lazy_struct_list] = src[:lazy_struct_list] if src[:lazy_struct_list]
    value[:dirty_fields] = src[:dirty_fields] if src[:dirty_fields]
    value
  end

  def compile_weak_upgrade_value(expr)
    src = compile_value_expr(expr.source)
    return nil unless src && %i[struct rc_struct arc_struct].include?(src[:kind])

    alive_reg = fresh_ireg
    emit(ICONST, alive_reg, add_const(1))
    value = { kind: :rc_struct, type: src.fetch(:type), fields: src.fetch(:fields), alive_reg: alive_reg, caps: { ownership: :rc, sync: :none } }
    value[:lazy_struct_list] = src[:lazy_struct_list] if src[:lazy_struct_list]
    value[:dirty_fields] = src[:dirty_fields] if src[:dirty_fields]
    value
  end

  def compile_struct_array_init(struct_type_name, items, element_kind: :struct)
    fields = @struct_fields[struct_type_name]
    raise Unsupported, "register emitter does not know struct #{struct_type_name.inspect} for ArrayInit" unless fields

    field_lists = {}
    fields.each do |fname, ftype|
      ftype_text = ftype.to_s
      norm = normalize_type(ftype_text)
      norm = :i64 if ftype_text == "bool" || ftype_text == "Bool"
      norm = value_type(ftype_text) if norm == :unsupported
      kind = case norm
             when :i64    then :int_list
             when :f64    then :f64_list
             when :string then :string_list
             when :int_list_handle, :string_list_handle then :handle_list
             else
               raise Unsupported, "register emitter only supports scalar struct fields for ArrayInit (got #{fname}: #{ftype})"
             end
      reg = fresh_vreg
      new_op = case kind
               when :int_list then LNEW
               when :f64_list then LFNEW
               when :string_list then LSNEW
               when :handle_list then LNEW
               end
      emit(new_op, reg)
      stored_type = kind == :handle_list ? norm : ftype
      field_lists[fname] = { kind: kind, reg: reg, type: stored_type }
    end

    items.each do |item|
      raise Unsupported, "register emitter expected StructInit items in struct ArrayInit" unless item.is_a?(MIR::StructInit)
      item.fields.each do |entry|
        fname = entry.fetch(:name).to_s
        info = field_lists[fname]
        raise Unsupported, "register emitter unknown field #{fname.inspect} in #{struct_type_name}" unless info
        case info[:kind]
        when :int_list
          val = compile_i64_expr(entry.fetch(:value))
          emit(LAPPENDI, info[:reg], val)
        when :f64_list
          val = compile_f64_expr(entry.fetch(:value))
          emit(LFAPPEND, info[:reg], val)
        when :string_list
          val = compile_string_expr(entry.fetch(:value))
          emit(LSAPPEND, info[:reg], val)
        when :handle_list
          handle = compile_list_handle_expr(entry.fetch(:value), info.fetch(:type))
          raise Unsupported, "register emitter expected list handle for field #{fname.inspect}" unless handle
          emit(LAPPENDI, info[:reg], handle.fetch(:reg))
        end
      end
    end

    { kind: :struct_list, type: struct_type_name, fields: field_lists, element_kind: element_kind }
  end

  # `~T[N]` bounded stream literal: lowering tags MakeList with
  # elem_type "__bc_stream__" and items are MIR::BgBlock. Single-
  # threaded bc VM evaluates each BG body synchronously into a typed
  # list and stashes a runtime cursor; NEXT fetches the element at
  # the cursor and increments it. FIFO consumption order matches
  # compiled CLEAR's spawn-order semantics.
  def compile_bg_stream_value(items)
    raise Unsupported, "register emitter expected non-empty bounded stream" if items.empty?

    payload_kinds = items.map { |it| bg_block_payload_kind(it) }.uniq
    raise Unsupported, "register emitter does not support mixed payload kinds in bounded stream" if payload_kinds.length != 1

    payload_kind = payload_kinds.first
    list_reg = fresh_vreg
    case payload_kind
    when :i64    then emit(LNEW, list_reg)
    when :f64    then emit(LFNEW, list_reg)
    when :string then emit(LSNEW, list_reg)
    else
      raise Unsupported, "register emitter does not support bounded stream of #{payload_kind}"
    end

    items.each do |item|
      promise = compile_bg_block_value(item)
      reg = promise.fetch(:reg)
      case payload_kind
      when :i64    then emit(LAPPENDI, list_reg, reg)
      when :f64    then emit(LFAPPEND, list_reg, reg)
      when :string then emit(LSAPPEND, list_reg, reg)
      end
    end

    cursor_reg = fresh_ireg
    emit(ICONST, cursor_reg, add_const(0))
    { kind: :bg_stream, payload_kind: payload_kind, reg: list_reg, cursor_reg: cursor_reg }
  end

  def bg_block_payload_kind(item)
    raise Unsupported, "register emitter expected MIR::BgBlock in bounded stream" unless item.is_a?(MIR::BgBlock)
    body = item.run_body || []
    raise Unsupported, "register emitter requires structured run_body for BgBlock in bounded stream" if body.empty?

    inferred_expr_type(body.last)
  end

  def compile_list_value(elem_type, items)
    return compile_bg_stream_value(items) if elem_type.to_s == "__bc_stream__"

    type = normalize_type(elem_type)
    reg = fresh_vreg
    case type
    when :i64
      emit(LNEW, reg)
      items.each do |item|
        item_reg = compile_i64_expr(item)
        emit(LAPPENDI, reg, item_reg)
      end
      { kind: :int_list, reg: reg }
    when :f64
      emit(LFNEW, reg)
      items.each do |item|
        item_reg = compile_f64_expr(item)
        emit(LFAPPEND, reg, item_reg)
      end
      { kind: :f64_list, reg: reg }
    when :string
      emit(LSNEW, reg)
      items.each do |item|
        item_reg = compile_string_expr(item)
        emit(LSAPPEND, reg, item_reg)
      end
      { kind: :string_list, reg: reg }
    else
      # Struct elem types (named in @struct_fields) lower to a
      # field-decomposed parallel-array layout. Empty pipeline-
      # accumulator MakeLists land here too -- compile_struct_array_init
      # handles items=[] by allocating the per-field empty lists.
      text = elem_type.to_s
      return compile_struct_array_init(text, items) if @struct_fields.key?(text)

      raise Unsupported, "register emitter does not support list of #{elem_type.inspect} yet"
    end
  end

  def compile_sharded_map_put(stmt)
    map_reg = map_register_for(stmt.target)
    value_reg = compile_i64_expr(stmt.value)
    if numeric_int_map_target?(stmt.target)
      key_reg = compile_i64_expr(stmt.key)
      emit(NMPUTI, map_reg, key_reg, value_reg)
    else
      key_idx = map_string_key_const(stmt.key)
      emit(MPUTI, map_reg, key_idx, value_reg)
    end
  end

  def compile_index_insert(stmt)
    map = stmt.map.is_a?(MIR::Ident) ? @value_by_name[stmt.map.name.to_s] : compile_value_expr(stmt.map)
    unless map && map[:kind] == :struct_list_map
      raise Unsupported, "register emitter only supports INDEX into struct-list maps in this tranche"
    end

    value = compile_value_expr(stmt.value_expr)
    unless value && value[:kind] == :struct && value[:type] == map[:type]
      raise Unsupported, "register emitter expected #{map[:type]} value for INDEX bucket append"
    end

    key_reg = compile_string_expr(stmt.key_expr)
    map[:fields].each do |fname, finfo|
      field = value.fetch(:fields).fetch(fname)
      handle = ensure_index_bucket_handle(finfo, key_reg)
      case finfo[:kind]
      when :int_handle_map
        emit(IHAPPEND, handle, field.fetch(:reg))
      when :string_handle_map
        emit(SHAPPEND, handle, field.fetch(:reg))
      end
    end
  end

  def ensure_index_bucket_handle(finfo, key_reg)
    exists = fresh_ireg
    emit(MCONTAINSR, exists, finfo.fetch(:reg), key_reg)
    emit(JF, exists, 0)
    create_patch = @ops.length - 1

    fallback = fresh_ireg
    emit(ICONST, fallback, add_const(0))
    handle = fresh_ireg
    emit(MGETIR, handle, finfo.fetch(:reg), key_reg, fallback)
    emit(JMP, 0)
    done_patch = @ops.length - 1

    @ops[create_patch] = @ops.length
    case finfo.fetch(:kind)
    when :int_handle_map
      emit(IHNEW, handle)
    when :string_handle_map
      emit(SHNEW, handle)
    end
    emit(MPUTIR, finfo.fetch(:reg), key_reg, handle)

    @ops[done_patch] = @ops.length
    handle
  end

  def compile_i64_orelse(expr)
    if expr.expr.is_a?(MIR::ShardedMapGet)
      fallback_reg = compile_i64_expr(expr.fallback)
      return compile_i64_sharded_map_get(expr.expr, fallback_reg: fallback_reg)
    end

    raise Unsupported, "register emitter only supports OR fallback for HashMap<Int64> get in this tranche"
  end

  def compile_i64_sharded_map_get(expr, fallback_reg:)
    # Bare `map[k]` (no OR fallback) shows up in `==`/comparison
    # contexts. CLEAR's Optional<Int64> compared against a literal is
    # a "is the key present and equal" check; missing key compares
    # false. Use 0 as the implicit miss value so the comparison is
    # well-defined regardless. This matches the value the compiler
    # would produce after unwrap-or-default.
    unless fallback_reg
      fallback_reg = fresh_ireg
      emit(ICONST, fallback_reg, add_const(0))
    end

    dst = fresh_ireg
    map_reg = map_register_for(expr.target)
    if numeric_int_map_target?(expr.target)
      key_reg = compile_i64_expr(expr.key)
      emit(NMGETI, dst, map_reg, key_reg, fallback_reg)
    else
      key_kind, key_operand = map_string_key_operand(expr.key)
      if key_kind == :literal
        emit(MGETI, dst, map_reg, key_operand, fallback_reg)
      else
        emit(MGETIR, dst, map_reg, key_operand, fallback_reg)
      end
    end
    dst
  end

  def map_register_for(target)
    unless target.is_a?(MIR::Ident)
      raise Unsupported, "register emitter only supports local HashMap<Int64> values in this tranche"
    end

    @vreg_by_name.fetch(target.name.to_s) do
      raise Unsupported, "register emitter does not know HashMap local #{target.name.inspect}"
    end
  end

  def map_string_key_const(expr)
    unless expr.is_a?(MIR::Lit)
      raise Unsupported, "register emitter only supports string literal HashMap keys in this tranche"
    end

    text = expr.value.to_s
    unless text.start_with?('"') && text.end_with?('"')
      raise Unsupported, "register emitter only supports string literal HashMap keys in this tranche"
    end

    add_const(unescape_string(text[1...-1]))
  end

  # Returns [:literal, const_idx] when the key is a string literal, or
  # [:reg, sreg_index] when it's a runtime expression that compiles to
  # a string register. Callers pick the const-key opcode (MPUTI etc.)
  # or the register-key opcode (MPUTIR etc.) accordingly. The key
  # is always COPY'd into the map's heap storage by the dispatch arm,
  # matching CLEAR's compiled HashMap put semantics.
  def map_string_key_operand(expr)
    if expr.is_a?(MIR::Lit)
      text = expr.value.to_s
      if text.start_with?('"') && text.end_with?('"')
        return [:literal, add_const(unescape_string(text[1...-1]))]
      end
    end
    [:reg, compile_string_expr(expr)]
  end

  def numeric_int_map_target?(target)
    target.is_a?(MIR::Ident) && @vkind_by_name.fetch(target.name.to_s, nil) == :numeric_int_map
  end

  def numeric_f64_map_target?(target)
    target.is_a?(MIR::Ident) && @vkind_by_name.fetch(target.name.to_s, nil) == :numeric_f64_map
  end

  def int64_string_map_type?(type)
    text = type.to_s
    text.include?("StringMap(i64)") ||
      text.include?("StringMap(Int64)") ||
      text == "HashMap<Int64>" ||
      text == "HashMap<i64>" ||
      # `HashMap@sharded(N)` lowers to PartitionedStringMap(V, N).
      # Sharding is a runtime concurrency strategy; under the
      # single-threaded bc VM it has no observable difference from
      # the unsharded map. Match any shard count.
      text.match?(/\A(?:CheatLib\.)?PartitionedStringMap\((?:i64|Int64),\s*\d+\)\z/) ||
      # `HashMap@sharded(N):locked` (the lock-striped variant) lowers
      # to MutexShardedStringMap. Same single-threaded equivalence.
      text.match?(/\A(?:CheatLib\.)?MutexShardedStringMap\((?:i64|Int64),\s*\d+\)\z/)
  end

  def numeric_int64_map_type?(type)
    text = type.to_s
    text == "HashMap<Int64, Int64>" ||
      text == "HashMap<i64, i64>" ||
      text.include?("NumericMapType(i64, i64)") ||
      text.include?("NumericMapType(Int64, Int64)") ||
      # `HashMap<Int64, Int64>@sharded(N)` lowers to
      # PartitionedNumericMap(K, V, N).
      text.match?(/\A(?:CheatLib\.)?PartitionedNumericMap\((?:i64|Int64),\s*(?:i64|Int64),\s*\d+\)\z/)
  end

  def numeric_float64_map_type?(type)
    text = type.to_s
    text == "HashMap<Int64, Float64>" ||
      text == "HashMap<i64, f64>" ||
      text.include?("NumericMapType(i64, f64)") ||
      text.include?("NumericMapType(Int64, Float64)") ||
      text.match?(/\A(?:CheatLib\.)?PartitionedNumericMap\((?:i64|Int64),\s*(?:f64|Float64),\s*\d+\)\z/)
  end

  def struct_list_map_type?(type)
    text = type.to_s
    match = text.match(/\A(?:CheatLib\.)?StringMap\((?:std\.)?ArrayListUnmanaged\(([A-Za-z_][A-Za-z0-9_]*)\)\)\z/) ||
            text.match(/\AHashMap<([A-Za-z_][A-Za-z0-9_]*)\[\]>\z/)
    return nil unless match

    struct_type = match[1]
    @struct_fields.key?(struct_type) ? struct_type : nil
  end

  def compile_struct_list_map_init(struct_type)
    fields = @struct_fields.fetch(struct_type) do
      raise Unsupported, "register emitter does not know struct #{struct_type.inspect} for INDEX"
    end

    field_maps = {}
    fields.each do |fname, ftype|
      norm = value_type(ftype)
      kind = case norm
             when :i64 then :int_handle_map
             when :string then :string_handle_map
             else
               raise Unsupported, "register emitter only supports Int64/String fields in INDEX struct-list maps (got #{fname}: #{ftype})"
             end
      reg = fresh_vreg
      emit(MNEW, reg)
      field_maps[fname.to_s] = { kind: kind, reg: reg, type: norm }
    end

    { kind: :struct_list_map, type: struct_type, fields: field_maps }
  end

  def compile_struct_list_map_get(expr)
    map = expr.target.is_a?(MIR::Ident) ? @value_by_name[expr.target.name.to_s] : compile_value_expr(expr.target)
    return nil unless map && map[:kind] == :struct_list_map

    key_reg = compile_string_expr(expr.key)
    fields = {}
    map.fetch(:fields).each do |fname, finfo|
      fallback = fresh_ireg
      case finfo.fetch(:kind)
      when :int_handle_map
        emit(IHNEW, fallback)
      when :string_handle_map
        emit(SHNEW, fallback)
      end

      handle = fresh_ireg
      emit(MGETIR, handle, finfo.fetch(:reg), key_reg, fallback)
      value_kind = case finfo.fetch(:kind)
                   when :int_handle_map then :int_handle_values
                   when :string_handle_map then :string_handle_values
                   end
      fields[fname] = { kind: value_kind, reg: handle, type: finfo.fetch(:type) }
    end

    { kind: :struct_list, type: map.fetch(:type), fields: fields }
  end

  def string_struct_map_type?(type)
    text = type.to_s
    match = text.match(/\A(?:CheatLib\.)?StringMap\(([A-Za-z_][A-Za-z0-9_]*)\)\z/) ||
            text.match(/\AHashMap<([A-Za-z_][A-Za-z0-9_]*)>\z/)
    return nil unless match

    struct_type = match[1]
    @struct_fields.key?(struct_type) ? struct_type : nil
  end

  def compile_struct_map_init(struct_type)
    fields = @struct_fields.fetch(struct_type) do
      raise Unsupported, "register emitter does not know struct #{struct_type.inspect} for HashMap"
    end

    field_maps = {}
    fields.each do |fname, ftype|
      norm = value_type(ftype)
      kind, new_op = case norm
                     when :i64 then [:int_field_map, MNEW]
                     when :string then [:string_field_map, VMNEW]
                     when :int_list_handle then [:int_list_handle_field_map, MNEW]
                     when :string_list_handle then [:string_list_handle_field_map, MNEW]
                     else
                       raise Unsupported, "register emitter only supports scalar/list-handle fields in HashMap<Struct> (got #{fname}: #{ftype})"
                     end
      reg = fresh_vreg
      emit(new_op, reg)
      field_maps[fname.to_s] = { kind: kind, reg: reg, type: norm }
    end

    { kind: :struct_map, type: struct_type, fields: field_maps }
  end

  def compile_struct_map_set(target, value)
    map = @value_by_name[target.object.name.to_s]
    src = compile_value_expr(value)
    unless map && map[:kind] == :struct_map && src && src[:kind] == :struct && src[:type] == map[:type]
      raise Unsupported, "register emitter expected matching struct map assignment"
    end

    key_reg = compile_string_expr(target.index)
    map.fetch(:fields).each do |fname, finfo|
      field = src.fetch(:fields).fetch(fname)
      case finfo.fetch(:kind)
      when :int_field_map
        emit(MPUTIR, finfo.fetch(:reg), key_reg, field.fetch(:reg))
      when :string_field_map
        emit(VMPUTSR, finfo.fetch(:reg), key_reg, field.fetch(:reg))
      when :int_list_handle_field_map, :string_list_handle_field_map
        emit(MPUTIR, finfo.fetch(:reg), key_reg, field.fetch(:reg))
      end
    end
  end

  def compile_struct_map_orelse(expr)
    inner = expr.expr
    return nil unless inner.is_a?(MIR::ShardedMapGet)
    map = inner.target.is_a?(MIR::Ident) ? @value_by_name[inner.target.name.to_s] : compile_value_expr(inner.target)
    return nil unless map && map[:kind] == :struct_map

    result = compile_value_expr(expr.fallback)
    unless result && result[:kind] == :struct && result[:type] == map[:type]
      raise Unsupported, "register emitter expected #{map[:type]} fallback for HashMap<Struct> get"
    end

    key_reg = compile_string_expr(inner.key)
    first = map.fetch(:fields).values.first
    exists = fresh_ireg
    emit(MCONTAINSR, exists, first.fetch(:reg), key_reg)
    emit(JF, exists, 0)
    done_patch = @ops.length - 1

    map.fetch(:fields).each do |fname, finfo|
      field = result.fetch(:fields).fetch(fname)
      case finfo.fetch(:kind)
      when :int_field_map
        emit(MGETIR, field.fetch(:reg), finfo.fetch(:reg), key_reg, field.fetch(:reg))
      when :string_field_map
        emit(VMGETSR, field.fetch(:reg), finfo.fetch(:reg), key_reg)
      when :int_list_handle_field_map, :string_list_handle_field_map
        emit(MGETIR, field.fetch(:reg), finfo.fetch(:reg), key_reg, field.fetch(:reg))
      end
    end

    @ops[done_patch] = @ops.length
    result
  end

  # Polymorphic HashMap. Recognizes HashMap<UserUnion> where the user's
  # union variants are a subset of RegisterValue's variant set
  # ({Nil, Int64, Float64, String}). Returns the union's tag map
  # (variant name -> [reg_value_tag_id, payload_kind]) when supported,
  # nil otherwise. Recursive variants and collection-bearing variants
  # raise the existing Unsupported error -- per the polymorphic-values
  # design doc, those need a separate phase.
  def value_string_map_type?(type)
    text = type.to_s
    return nil unless (m = text.match(/\AStringMap\((.+)\)\z/) ||
                            text.match(/\ACheatLib\.StringMap\((.+)\)\z/) ||
                            text.match(/\AHashMap<([^,>]+)>\z/))
    union_name = m[1].strip
    variants = @union_variants[union_name]
    return nil unless variants

    map = {}
    variants.each_with_index do |variant, _idx|
      vname = variant.is_a?(Hash) ? variant[:name].to_s : variant.to_s
      ztype = variant.is_a?(Hash) ? variant[:zig_type].to_s : "void"
      kind, tag_id = case normalize_type(ztype)
                     when :void   then [:nil, 0]
                     when :i64    then [:int, 1]
                     when :f64    then [:float, 2]
                     when :string then [:string, 3]
                     else return nil
                     end
      map[vname] = { tag_id: tag_id, kind: kind }
    end
    { union_name: union_name, variants: map }
  end

  def list_value_type(type)
    text = type.to_s
    return :f64_list if text == "[]f64" ||
                        text == "Float64[]" ||
                        text.include?("ArrayListUnmanaged(f64)")
    return :int_list if text == "[]i64" ||
                        text == "Int64[]" ||
                        text.include?("ArrayListUnmanaged(i64)") ||
                        text.include?("ArrayListUnmanaged(u64)")
    return :string_list if text == "[][]const u8" ||
                           text == "String[]" ||
                           text.include?("ArrayListUnmanaged([]const u8)")

    nil
  end

  # Polymorphic list (Phase 2 of polymorphic-values). Recognizes
  # `<UserUnion>[]@list` / `ArrayListUnmanaged(<UserUnion>)` where the
  # union's variants are a subset of RegisterValue's variants.
  # Returns the same shape value_string_map_type? does so the same
  # transcoding map can be reused.
  def value_list_type?(type)
    text = type.to_s
    return nil unless (m = text.match(/\A(?:std\.)?ArrayListUnmanaged\((.+)\)\z/))
    union_name = m[1].strip
    variants = @union_variants[union_name]
    return nil unless variants

    map = {}
    variants.each do |variant|
      vname = variant.is_a?(Hash) ? variant[:name].to_s : variant.to_s
      ztype = variant.is_a?(Hash) ? variant[:zig_type].to_s : "void"
      norm = normalize_type(ztype)
      kind, tag_id = case norm
                     when :void   then [:nil, 0]
                     when :i64    then [:int, 1]
                     when :f64    then [:float, 2]
                     when :string then [:string, 3]
                     else
                       # Non-scalar variant (e.g. Items: Int64[] or
                       # List: Value[]). Tag it as :opaque -- the
                       # variant's tag is preserved, but the payload
                       # content isn't stored. Tests that only verify
                       # length / count or only iterate the scalar
                       # variants still work; tests that read the
                       # opaque payload will fault correctly later.
                       [:opaque, 4]
                     end
      map[vname] = { tag_id: tag_id, kind: kind }
    end
    { union_name: union_name, variants: map }
  end

  def compile_container_init_value(expr)
    if (list_type = list_value_type(expr.zig_type))
      reg = fresh_vreg
      new_op = case list_type
               when :f64_list then LFNEW
               when :string_list then LSNEW
               else LNEW
               end
      emit(new_op, reg)
      return { kind: list_type, reg: reg }
    end

    if int64_string_map_type?(expr.zig_type)
      reg = fresh_vreg
      emit(MNEW, reg)
      return { kind: :int_map, reg: reg }
    end

    if numeric_int64_map_type?(expr.zig_type)
      reg = fresh_vreg
      emit(NMNEW, reg)
      return { kind: :numeric_int_map, reg: reg }
    end

    if numeric_float64_map_type?(expr.zig_type)
      reg = fresh_vreg
      emit(NMFNEW, reg)
      return { kind: :numeric_f64_map, reg: reg }
    end

    if (vinfo = value_string_map_type?(expr.zig_type))
      reg = fresh_vreg
      emit(VMNEW, reg)
      return { kind: :value_string_map, reg: reg, union_name: vinfo[:union_name], variant_map: vinfo[:variants] }
    end

    if (struct_type = string_struct_map_type?(expr.zig_type))
      return compile_struct_map_init(struct_type)
    end

    if (vinfo = value_list_type?(expr.zig_type))
      reg = fresh_vreg
      emit(LVNEW, reg)
      return { kind: :value_list, reg: reg, union_name: vinfo[:union_name], variant_map: vinfo[:variants] }
    end

    # Struct list: `T[]@list` lowers to `std.ArrayListUnmanaged(T)`.
    # Allocate per-field empty parallel arrays via the existing
    # field-decomposed path so .append(T{...}) can decompose.
    if (m = expr.zig_type.to_s.match(/\A(?:std\.)?ArrayListUnmanaged\(([A-Za-z_][A-Za-z0-9_]*)\)\z/))
      inner = m[1]
      return compile_struct_array_init(inner, []) if @struct_fields.key?(inner)
    end
    if (m = expr.zig_type.to_s.match(/\A(?:std\.)?ArrayListUnmanaged\((?:CheatLib\.)?(Rc|Arc|WeakRc|WeakArc)\(([A-Za-z_][A-Za-z0-9_]*)\)\)\z/))
      wrapper = m[1]
      inner = m[2]
      element_kind = (wrapper == "Arc" || wrapper == "WeakArc") ? :arc_struct : :rc_struct
      return compile_struct_array_init(inner, [], element_kind: element_kind) if @struct_fields.key?(inner)
    end
    if (m = expr.zig_type.to_s.match(/\A(?:CheatLib\.)?SoaList\(([A-Za-z_][A-Za-z0-9_]*)\)\z/))
      inner = m[1]
      return compile_struct_array_init(inner, []) if @struct_fields.key?(inner)
    end

    # @set collections: `T[]@set` -> CheatLib.Set(T). Represented in
    # the bc VM as a HashMap<T, Int64> where the value is always 1
    # (presence flag). insert/remove/contains?/length all reuse the
    # existing map opcodes.
    if (m = expr.zig_type.to_s.match(/\A(?:CheatLib\.)?Set\(([^)]+)\)\z/))
      elem_text = m[1].strip
      reg = fresh_vreg
      case normalize_type(elem_text)
      when :i64
        emit(NMNEW, reg)
        return { kind: :numeric_int_map, reg: reg, set_view: true, elem: :i64 }
      when :string
        emit(MNEW, reg)
        return { kind: :int_map, reg: reg, set_view: true, elem: :string }
      end
    end

    # @pool / @sharded:pool: parallel-arrays struct_list + an "alive"
    # i64 flags array. Insert appends to every per-field array and to
    # alive (with a 1); get reads alive[id]; remove clears alive[id].
    # Pool IDs are slot indices (no generation; the VM is single-
    # threaded so removed slots aren't reused while the test runs).
    if (m = expr.zig_type.to_s.match(/\A(?:CheatLib\.)?Pool\(([A-Za-z_][A-Za-z0-9_]*)\)\z/))
      inner = m[1]
      return compile_pool_init(inner) if @struct_fields.key?(inner)
    end
    if (m = expr.zig_type.to_s.match(/\A(?:CheatLib\.)?ShardedPool\(([A-Za-z_][A-Za-z0-9_]*),\s*\d+\)\z/))
      inner = m[1]
      return compile_pool_init(inner) if @struct_fields.key?(inner)
    end

    raise Unsupported, "register emitter does not support guest collection values without runtime-faithful handles yet (#{expr.zig_type})"
  end

  # Materialize a Range as a concrete int_list. For `start..<end`,
  # appends [start, start+1, ..., end-1]; for `start..=end`,
  # appends [start, start+1, ..., end]. The lowering distinguishes
  # exclusive vs inclusive via end_val being `MIR::BinOp("+",
  # raw_end, 1)` for the inclusive case -- we don't need to detect
  # this here since end_val is always the exclusive upper bound by
  # the time we see it.
  def compile_range_to_int_list(expr)
    list_reg = fresh_vreg
    emit(LNEW, list_reg)

    start_reg = compile_i64_expr(expr.start)
    end_reg = compile_i64_expr(expr.end_val)
    i_reg = fresh_ireg
    emit(IMOV, i_reg, start_reg)
    one_reg = fresh_ireg
    emit(ICONST, one_reg, add_const(1))

    loop_start = @ops.length
    cond_reg = fresh_ireg
    emit(ILT, cond_reg, i_reg, end_reg)
    emit(JF, cond_reg, 0)
    exit_idx = @ops.length - 1

    emit(LAPPENDI, list_reg, i_reg)
    new_i = fresh_ireg
    emit(IADD, new_i, i_reg, one_reg)
    emit(IMOV, i_reg, new_i)
    emit(JMP, loop_start)
    @ops[exit_idx] = @ops.length

    { kind: :int_list, reg: list_reg }
  end

  # `IF expr AS x THEN ... [ELSE ...] END` -- evaluate expr to an
  # optional Int64; if not -1, bind x in the then-branch. The bc
  # emitter handles single-binding ?Int64 from indexOf and the like.
  def compile_if_bind_stmt(stmt)
    bindings = stmt.bindings
    raise Unsupported, "register emitter expected at least one IfBindStmt binding" unless bindings && !bindings.empty?

    saved_iregs = @ireg_by_name.dup
    saved_values = @value_by_name.dup
    minus_one = fresh_ireg
    emit(ICONST, minus_one, add_const(-1))
    zero = fresh_ireg
    emit(ICONST, zero, add_const(0))
    skip_to_else = []

    bindings.each do |binding|
      capture = binding[:capture].to_s
      expr = binding[:expr]
      cap_struct_kinds = %i[struct rc_struct arc_struct locked_struct write_locked_struct local_struct versioned_struct atomic_ptr_struct]
      if (value = compile_value_expr(expr)) && cap_struct_kinds.include?(value[:kind]) && value[:alive_reg]
        cond_reg = fresh_ireg
        emit(INEQ, cond_reg, value.fetch(:alive_reg), zero)
        emit(JF, cond_reg, 0)
        skip_to_else << (@ops.length - 1)

        @value_by_name[capture] = value
        next
      end

      # Compile the test expression. Today we only handle Int64
      # optionals (indexOf-style). Future: ?Float64, ?String, ?T.
      expr_reg = compile_i64_expr(expr)

      cond_reg = fresh_ireg
      emit(INEQ, cond_reg, expr_reg, minus_one)
      emit(JF, cond_reg, 0)
      skip_to_else << (@ops.length - 1)

      @ireg_by_name[capture] = expr_reg
      record_var_name(:i, expr_reg, capture, "Int64")
    end

    semantic_body(stmt.then_body || []).each { |s| compile_stmt(s) }
    @ireg_by_name = saved_iregs
    @value_by_name = saved_values

    if stmt.else_body && !stmt.else_body.empty?
      emit(JMP, 0)
      end_idx = @ops.length - 1
      else_pc = @ops.length
      skip_to_else.each { |idx| @ops[idx] = else_pc }
      semantic_body(stmt.else_body).each { |s| compile_stmt(s) }
      @ops[end_idx] = @ops.length
    else
      end_pc = @ops.length
      skip_to_else.each { |idx| @ops[idx] = end_pc }
    end
  end

  def compile_pool_init(struct_type_name)
    # Empty struct_list under the hood + an i64 alive flags array.
    base = compile_struct_array_init(struct_type_name, [])
    alive_reg = fresh_vreg
    emit(LNEW, alive_reg)
    { kind: :pool, type: struct_type_name, fields: base[:fields], alive_reg: alive_reg }
  end

  def compile_list_handle_expr(expr, expected_type = nil)
    return compile_list_handle_expr(expr.expr, expected_type) if expr.is_a?(MIR::ItemsAccess)

    if expr.is_a?(MIR::Ident)
      name = resolve_ctx_name(expr.name)
      if (value = @value_by_name[name]) && list_handle_value?(value)
        return value if compatible_list_handle_kind?(value[:kind], expected_type)
      end

      if @vreg_by_name.key?(name)
        case @vkind_by_name[name]
        when :int_list
          if (@borrowed_list_aliases || {})[name] && compatible_list_handle_kind?(:borrowed_int_list_handle, expected_type)
            return { kind: :borrowed_int_list_handle, reg: @vreg_by_name.fetch(name) }
          end

          return clone_vreg_list_to_handle(:int_list_handle, @vreg_by_name.fetch(name))
        when :string_list
          if (@borrowed_list_aliases || {})[name] && compatible_list_handle_kind?(:borrowed_string_list_handle, expected_type)
            return { kind: :borrowed_string_list_handle, reg: @vreg_by_name.fetch(name) }
          end

          return clone_vreg_list_to_handle(:string_list_handle, @vreg_by_name.fetch(name))
        end
      end
    end

    if expr.is_a?(MIR::ContainerInit) || expr.is_a?(MIR::MakeList)
      list_type = list_value_type(expr.respond_to?(:zig_type) ? expr.zig_type : expr.elem_type)
      if list_type == :int_list || expected_type == :int_list_handle
        handle = fresh_ireg
        emit(IHNEW, handle)
        (expr.respond_to?(:items) ? (expr.items || []) : []).each do |item|
          emit(IHAPPEND, handle, compile_i64_expr(item))
        end
        return { kind: :int_list_handle, reg: handle }
      elsif list_type == :string_list || expected_type == :string_list_handle
        handle = fresh_ireg
        emit(SHNEW, handle)
        (expr.respond_to?(:items) ? (expr.items || []) : []).each do |item|
          emit(SHAPPEND, handle, compile_string_expr(item))
        end
        return { kind: :string_list_handle, reg: handle }
      end
    end

    value = compile_value_expr(expr)
    return value if list_handle_value?(value) && compatible_list_handle_kind?(value[:kind], expected_type)

    nil
  end

  def clone_vreg_list_to_handle(kind, list_reg)
    handle = fresh_ireg
    if kind == :int_list_handle
      emit(IHNEW, handle)
      emit_clone_loop(list_reg, handle, LLEN, LGETI, IHAPPEND, :fresh_ireg)
    elsif kind == :string_list_handle
      emit(SHNEW, handle)
      emit_clone_loop(list_reg, handle, LSLEN, LSGET, SHAPPEND, :fresh_sreg)
    end
    { kind: kind, reg: handle }
  end

  def compile_struct_init_value(expr)
    type_name = expr.zig_type.to_s
    if (variants = union_variants_for(type_name))
      field = expr.fields.first
      tag_name = field.fetch(:name).to_s
      tag_reg = compile_tag_const(type_name, tag_name)
      payload_reg = nil
      payload_value = field.fetch(:value)
      variant = variants.find { |entry| entry.fetch(:name).to_s == tag_name }
      if variant && normalize_type(variant.fetch(:zig_type)) == :i64
        payload_reg = compile_i64_expr(payload_value)
      elsif variant && normalize_type(variant.fetch(:zig_type)) == :f64
        payload_reg = compile_f64_expr(payload_value)
      elsif variant && normalize_type(variant.fetch(:zig_type)) == :string
        payload_reg = compile_string_expr(payload_value)
      elsif variant && value_register_type?(value_type(variant.fetch(:zig_type)))
        payload_reg = compile_value_expr(payload_value)
      end

      return {
        kind: :union,
        type: type_name,
        tag: tag_name,
        tag_reg: tag_reg,
        payloads: { tag_name => payload_reg }.compact,
      }
    end

    raise Unsupported, "register emitter does not support unknown struct #{type_name.inspect}" unless @struct_fields.key?(type_name)

    fields = {}
    expr.fields.each do |field|
      name = field.fetch(:name).to_s
      field_type = value_type((@struct_fields[type_name] || {})[name])
      reg = case field_type
            when :i64 then compile_i64_expr(field.fetch(:value))
            when :f64 then compile_f64_expr(field.fetch(:value))
            when :string then compile_string_expr(field.fetch(:value))
            when :int_list_handle, :string_list_handle
              handle = compile_list_handle_expr(field.fetch(:value), field_type)
              raise Unsupported, "register emitter expected #{field_type} field #{name.inspect}" unless handle
              field_type = handle.fetch(:kind)
              handle.fetch(:reg)
            when Array
              if field_type.first == :struct_list
                value = compile_value_expr(field.fetch(:value))
                unless value && value.fetch(:kind) == :struct_list && value.fetch(:type) == field_type.last
                  raise Unsupported, "register emitter expected #{field_type.last} struct-list field #{name.inspect}"
                end
                value
              else
              unless field_type.first == :struct
                raise Unsupported, "register emitter only supports nested struct fields in this tranche"
              end

              value = compile_value_expr(field.fetch(:value))
              unless value && value.fetch(:kind) == :struct && value.fetch(:type) == field_type.last
                raise Unsupported, "register emitter expected #{field_type.last} struct field #{name.inspect}"
              end
              value
              end
            else
              raise Unsupported, "register emitter only supports Int64 and Float64 struct fields in Tranche 7"
            end
      fields[name] = { type: field_type, reg: reg }
    end

    { kind: :struct, type: type_name, fields: fields }
  end

  def allocate_union_storage(type_name)
    tag_reg = fresh_ireg
    emit(ICONST, tag_reg, add_const(0))

    payloads = {}
    (union_variants_for(type_name) || []).each do |variant|
      payload_type = value_type(variant.fetch(:zig_type))
      next if payload_type == :void || payload_type == :unsupported

      payloads[variant.fetch(:name).to_s] = case payload_type
                                            when :i64
                                              fresh_ireg.tap { |reg| emit(ICONST, reg, add_const(0)) }
                                            when :f64
                                              fresh_freg.tap { |reg| emit(FCONST, reg, add_const([:f64, 0.0])) }
                                            when :string
                                              fresh_sreg.tap { |reg| emit(SCONST, reg, add_const("")) }
                                            when Array
                                              if payload_type.first == :struct
                                                zero_value_for_struct(payload_type.last)
                                              else
                                                raise Unsupported, "register emitter only supports scalar/struct union helper returns in this tranche"
                                              end
                                            else
                                              raise Unsupported, "register emitter only supports scalar/struct union helper returns in this tranche"
                                            end
    end

    { kind: :union, type: type_name, tag: nil, tag_reg: tag_reg, payloads: payloads }
  end

  def copy_union_value_into(target, source)
    emit(IMOV, target.fetch(:tag_reg), source.fetch(:tag_reg)) unless target.fetch(:tag_reg) == source.fetch(:tag_reg)

    tag_name = source.fetch(:tag)
    src_payload = source.fetch(:payloads)[tag_name]
    return unless src_payload

    dst_payload = target.fetch(:payloads).fetch(tag_name) do
      raise Unsupported, "register emitter missing union payload storage for #{tag_name.inspect}"
    end

    variant = union_variant(target.fetch(:type), tag_name)
    payload_type = value_type(variant.fetch(:zig_type))
    case payload_type
    when :i64
      emit(IMOV, dst_payload, src_payload) unless dst_payload == src_payload
    when :f64
      emit(FMOV, dst_payload, src_payload) unless dst_payload == src_payload
    when :string
      emit(SMOV, dst_payload, src_payload) unless dst_payload == src_payload
    when Array
      if payload_type.first == :struct
        copy_struct_value_into(dst_payload, src_payload)
      else
        raise Unsupported, "register emitter only supports scalar/struct union helper return payloads in this tranche"
      end
    else
      raise Unsupported, "register emitter only supports scalar/struct union helper return payloads in this tranche"
    end
  end

  def copy_struct_value_into(target, source)
    unless target && source && target.fetch(:kind) == :struct && source.fetch(:kind) == :struct && target.fetch(:type) == source.fetch(:type)
      raise Unsupported, "register emitter expected matching struct payloads"
    end

    target.fetch(:fields).each do |name, target_field|
      source_field = source.fetch(:fields).fetch(name)
      case target_field.fetch(:type)
      when :i64
        emit(IMOV, target_field.fetch(:reg), source_field.fetch(:reg)) unless target_field.fetch(:reg) == source_field.fetch(:reg)
      when :f64
        emit(FMOV, target_field.fetch(:reg), source_field.fetch(:reg)) unless target_field.fetch(:reg) == source_field.fetch(:reg)
      when :string
        emit(SMOV, target_field.fetch(:reg), source_field.fetch(:reg)) unless target_field.fetch(:reg) == source_field.fetch(:reg)
      when Array
        if target_field.fetch(:type).first == :struct
          copy_struct_value_into(target_field.fetch(:reg), source_field.fetch(:reg))
        else
          raise Unsupported, "register emitter only supports nested struct payload copies in this tranche"
        end
      else
        raise Unsupported, "register emitter only supports scalar struct payload copies in this tranche"
      end
    end
  end

  def compile_enum_variant_value(expr)
    type_name = enum_variant_type(expr)
    return nil unless type_name

    {
      kind: :tag,
      type: type_name,
      tag: expr.field.to_s,
      reg: compile_tag_const(type_name, expr.field.to_s),
    }
  end

  def bind_value(name, value)
    case value.fetch(:kind)
    when :tag
      @ireg_by_name[name] = value.fetch(:reg); record_var_name(:i, value.fetch(:reg), name)
      @tag_type_by_name[name] = value.fetch(:type)
    when :struct, :union, :rc_struct, :arc_struct, :locked_struct, :write_locked_struct, :local_struct, :versioned_struct, :atomic_ptr_struct
      @value_by_name[name] = value
      # Pool slots carry an alive flag alongside the struct view.
      # Stash it in the int reg map so a body comparing
      # `Ident(name) == nil` resolves to the flag (0 means dead).
      if value[:alive_reg]
        @ireg_by_name[name] = value[:alive_reg]
      end
    when :bg_stream
      @bg_stream_bindings ||= {}
      @bg_stream_bindings[name] = value
    when :bg_promise
      # Single-threaded bc VM: the BG body has already been inlined and
      # produced its result reg. NEXT just unwraps the underlying scalar,
      # so bind directly to the appropriate scalar reg map.
      @bg_promise_bindings ||= {}
      @bg_promise_bindings[name] = value
      case value.fetch(:payload_kind)
      when :i64
        @ireg_by_name[name] = value.fetch(:reg); record_var_name(:i, value.fetch(:reg), name)
      when :f64
        @freg_by_name[name] = value.fetch(:reg); record_var_name(:f, value.fetch(:reg), name)
      when :string
        @sreg_by_name[name] = value.fetch(:reg); record_var_name(:s, value.fetch(:reg), name)
      end
    when :fn_ref, :lambda
      @callable_by_name[name] = value
    when :int_list, :f64_list, :string_list
      @vreg_by_name[name] = value.fetch(:reg)
      @vkind_by_name[name] = value.fetch(:kind)
    when :int_map, :numeric_int_map, :numeric_f64_map
      @vreg_by_name[name] = value.fetch(:reg)
      @vkind_by_name[name] = value.fetch(:kind)
      # @set is implemented as a presence-flag map; mark the binding
      # so insert/contains?/remove dispatch through the set helpers.
      if value[:set_view]
        @set_views ||= {}
        @set_views[name] = true
      end
    when :value_string_map
      @vreg_by_name[name] = value.fetch(:reg)
      @vkind_by_name[name] = value.fetch(:kind)
      @value_map_variants ||= {}
      @value_map_variants[name] = { union_name: value.fetch(:union_name), variants: value.fetch(:variant_map) }
    when :value_list
      @vreg_by_name[name] = value.fetch(:reg)
      @vkind_by_name[name] = value.fetch(:kind)
      @value_list_variants ||= {}
      @value_list_variants[name] = { union_name: value.fetch(:union_name), variants: value.fetch(:variant_map) }
    when :int_list_handle, :string_list_handle
      @value_by_name[name] = value
    when :struct_list_map
      @value_by_name[name] = value
    when :struct_map
      @value_by_name[name] = value
    when :struct_list
      # @vkind_by_name marks this binding as a struct list; the
      # field-decomposed layout lives in @struct_list_info, indexed
      # by name. compile_struct_list_index_get / compile_for_stmt
      # / compile_i64_length consult it.
      @vkind_by_name[name] = :struct_list
      @struct_list_info ||= {}
      @struct_list_info[name] = { type: value.fetch(:type), fields: value.fetch(:fields), element_kind: value[:element_kind] }
    when :pool
      # @pool: like struct_list but with an extra i64 alive-flags
      # array. The bc emitter implements insert/get/remove/length/
      # FIND/EACH directly via the existing list opcodes.
      @vkind_by_name[name] = :pool
      @pool_info ||= {}
      @pool_info[name] = { type: value.fetch(:type), fields: value.fetch(:fields), alive_reg: value.fetch(:alive_reg) }
    when :atomic_primitive
      # @shared:atomic on a scalar -- bind directly to the
      # underlying scalar reg map. Single-threaded VM: load/store/
      # fetchAdd/fetchSub are observably equivalent to plain ops.
      reg = value.fetch(:reg)
      case value.fetch(:payload_kind)
      when :i64, :bool then @ireg_by_name[name] = reg; record_var_name(:i, reg, name)
      when :f64        then @freg_by_name[name] = reg; record_var_name(:f, reg, name)
      when :string     then @sreg_by_name[name] = reg; record_var_name(:s, reg, name)
      end
    else
      raise Unsupported, "register emitter cannot bind value kind #{value.fetch(:kind).inspect}"
    end
  end

  def clone_value(value)
    case value.fetch(:kind)
    when :struct
      cloned = {
        kind: :struct,
        type: value.fetch(:type),
        fields: value.fetch(:fields).transform_values do |field|
          cloned = field.dup
          cloned[:reg] = clone_value(cloned.fetch(:reg)) if cloned.fetch(:reg).is_a?(Hash)
          cloned
        end,
      }
      cloned[:lazy_struct_list] = value[:lazy_struct_list] if value[:lazy_struct_list]
      cloned[:dirty_fields] = value[:dirty_fields].dup if value[:dirty_fields]
      cloned
    when :union
      {
        kind: :union,
        type: value.fetch(:type),
        tag: value.fetch(:tag),
        tag_reg: value.fetch(:tag_reg),
        payloads: value.fetch(:payloads).transform_values { |payload| payload.is_a?(Hash) ? clone_value(payload) : payload },
      }
    else
      value.dup
    end
  end

  def compile_struct_field_value(expr)
    object = value_for_field_get(expr.object)
    return nil unless object

    case object.fetch(:kind)
    when :struct
      field = ensure_struct_field_loaded(object, expr.field.to_s)
      if field && list_handle_type?(field.fetch(:type))
        return { kind: field.fetch(:type), reg: field.fetch(:reg) }
      end
      if field && field.fetch(:type).is_a?(Array) && field.fetch(:type).first == :struct_list
        return field.fetch(:reg)
      end
      return nil unless field && value_register_type?(field.fetch(:type))

      field.fetch(:reg)
    when :pool_slot
      return object.fetch(:value) if expr.field.to_s == "value"

      nil
    when :union
      variant = union_variant(object.fetch(:type), expr.field.to_s)
      return nil unless variant

      variant_type = value_type(variant.fetch(:zig_type))
      return nil unless value_register_type?(variant_type)

      object.fetch(:payloads)[expr.field.to_s] || zero_value_for_struct(variant_type.last)
    end
  end

  def zero_value_for_struct(type_name)
    fields = @struct_fields.fetch(type_name) do
      raise Unsupported, "register emitter does not know struct #{type_name.inspect}"
    end

    {
      kind: :struct,
      type: type_name,
      fields: fields.to_h do |name, zig_type|
        field_type = value_type(zig_type)
        reg = case field_type
              when :i64
                fresh_ireg.tap { |r| emit(ICONST, r, add_const(0)) }
              when :f64
                fresh_freg.tap { |r| emit(FCONST, r, add_const([:f64, 0.0])) }
              when :string
                fresh_sreg.tap { |r| emit(SCONST, r, add_const("")) }
              when Array
                if field_type.first == :struct
                  zero_value_for_struct(field_type.last)
                else
                  raise Unsupported, "register emitter only supports scalar/nested struct placeholder fields for #{type_name.inspect}"
                end
              else
                raise Unsupported, "register emitter only supports scalar/nested struct placeholder fields for #{type_name.inspect}"
              end
        [name, { type: field_type, reg: reg }]
      end,
    }
  end

  def value_for_field_get(expr)
    # `.ctrl.data` on an Rc/Arc handle is the runtime's two-step
    # unwrap to the underlying T payload. The bc emitter doesn't
    # actually store a control block -- the handle's :rc_struct /
    # :arc_struct value already maps directly to the T fields. Skip
    # both unwrap layers when we see them.
    if expr.is_a?(MIR::FieldGet) && expr.field.to_s == "data" &&
       expr.object.is_a?(MIR::FieldGet) && expr.object.field.to_s == "ctrl"
      handle_source = expr.object.object
      handle = if handle_source.is_a?(MIR::Ident)
                 @value_by_name[handle_source.name.to_s]
               else
                 compile_value_expr(handle_source)
               end
      capability_unwrap = %i[rc_struct arc_struct locked_struct write_locked_struct local_struct versioned_struct atomic_ptr_struct]
      if handle && capability_unwrap.include?(handle[:kind])
        # Loom groundwork: reading a field through `.ctrl.data` is a
        # shared-memory read on the handle's binding.
        record_shared_event(:read, handle_source.name, handle[:kind], caps: caps_for_value(handle)) if handle_source.is_a?(MIR::Ident)
        value = { kind: :struct, type: handle[:type], fields: handle[:fields] }
        value[:lazy_struct_list] = handle[:lazy_struct_list] if handle[:lazy_struct_list]
        value[:dirty_fields] = handle[:dirty_fields] if handle[:dirty_fields]
        return value
      end
    end

    case expr
    when MIR::Ident
      v = @value_by_name[expr.name.to_s]
      # Capability-wrapped scalar structs (rc/arc/locked/local/etc.)
      # behave like plain :struct for field reads -- the bc emitter
      # doesn't model the runtime control block.
      capability_struct_kinds = %i[rc_struct arc_struct locked_struct write_locked_struct local_struct versioned_struct atomic_ptr_struct]
      if v && capability_struct_kinds.include?(v[:kind])
        record_shared_event(:read, expr.name, v[:kind], caps: caps_for_value(v))
        value = { kind: :struct, type: v[:type], fields: v[:fields] }
        value[:lazy_struct_list] = v[:lazy_struct_list] if v[:lazy_struct_list]
        value[:dirty_fields] = v[:dirty_fields] if v[:dirty_fields]
        return value
      end
      # Loom groundwork: a field read through a WITH-block alias
      # is a read on the underlying cap-wrapped source.
      if (alias_src = (@cap_alias_source || {})[expr.name.to_s])
        record_shared_event(:read, alias_src[:name], alias_src[:kind], caps: alias_src[:caps])
      end
      v
    when MIR::FieldGet
      compile_struct_field_value(expr)
    when MIR::IndexGet
      # `<struct_list>[i].field` / `<pool>[i].field` -- materialize
      # the per-index struct view from parallel arrays so subsequent
      # field reads work.
      if (list_name = index_get_list_name(expr.object))
        kind = @vkind_by_name[list_name]
        if kind == :struct_list
          return compile_struct_list_index_get(list_name, expr.index)
        elsif kind == :pool
          return compile_pool_index_get(list_name, expr.index)
        end
      end
      object_value = if expr.object.is_a?(MIR::ListItems)
                       compile_value_expr(expr.object.list)
                     else
                       compile_value_expr(expr.object)
                     end
      if object_value && object_value[:kind] == :struct_list
        return compile_struct_list_value_index_get(object_value, expr.index)
      end
      nil
    when MIR::InlineBc
      # The lowering also lowers `xs[i]` to InlineBc(:getAt, [xs, i]).
      # Same struct_list/pool view as above.
      if expr.op == :getAt
        list_arg = (expr.args || [])[0]
        idx_arg  = (expr.args || [])[1]
        if list_arg.is_a?(MIR::Ident)
          kind = @vkind_by_name[list_arg.name.to_s]
          if kind == :struct_list
            return compile_struct_list_index_get(list_arg.name.to_s, idx_arg)
          elsif kind == :pool
            return compile_pool_index_get(list_arg.name.to_s, idx_arg)
          end
        end
        list_value = compile_value_expr(list_arg)
        if list_value && list_value[:kind] == :struct_list
          return compile_struct_list_value_index_get(list_value, idx_arg)
        end
      end
      nil
    else
      nil
    end
  end

  def compile_i64_field_get(expr)
    enum_value = compile_enum_variant_value(expr)
    return enum_value.fetch(:reg) if enum_value

    object = value_for_field_get(expr.object)
    raise Unsupported, "register emitter does not know value for field #{expr.field.inspect}" unless object

    case object.fetch(:kind)
    when :struct
      field = ensure_struct_field_loaded(object, expr.field.to_s)
      raise Unsupported, "register emitter does not know struct field #{expr.field.inspect}" unless field
      raise Unsupported, "register emitter expected Int64 struct field #{expr.field.inspect}" unless field.fetch(:type) == :i64
      if (cell = field[:cell])
        dst = fresh_ireg
        emit(SCELLGETI, dst, cell)
        return dst
      end
      field.fetch(:reg)
    when :pool_slot
      return object.fetch(:alive_reg) if expr.field.to_s == "alive"

      raise Unsupported, "register emitter does not support pool slot Int64 field #{expr.field.inspect}"
    when :union
      reg = object.fetch(:payloads)[expr.field.to_s]
      unless reg
        variant = union_variant(object.fetch(:type), expr.field.to_s)
        raise Unsupported, "register emitter does not know union payload #{expr.field.inspect}" unless variant && normalize_type(variant.fetch(:zig_type)) == :i64

        reg = fresh_ireg
        emit(ICONST, reg, add_const(0))
      end
      reg
    else
      raise Unsupported, "register emitter does not support #{object.fetch(:kind)} field access yet"
    end
  end

  def compile_f64_field_get(expr)
    object = value_for_field_get(expr.object)
    raise Unsupported, "register emitter does not know value for field #{expr.field.inspect}" unless object

    case object.fetch(:kind)
    when :struct
      field = ensure_struct_field_loaded(object, expr.field.to_s)
      raise Unsupported, "register emitter does not know struct field #{expr.field.inspect}" unless field
      raise Unsupported, "register emitter expected Float64 struct field #{expr.field.inspect}" unless field.fetch(:type) == :f64
      field.fetch(:reg)
    when :union
      reg = object.fetch(:payloads)[expr.field.to_s]
      unless reg
        variant = union_variant(object.fetch(:type), expr.field.to_s)
        raise Unsupported, "register emitter does not know union Float64 payload #{expr.field.inspect}" unless variant && normalize_type(variant.fetch(:zig_type)) == :f64

        reg = fresh_freg
        emit(FCONST, reg, add_const([:f64, 0.0]))
      end
      reg
    else
      raise Unsupported, "register emitter does not support #{object.fetch(:kind)} Float64 field access yet"
    end
  end

  def compile_string_field_get(expr)
    object = value_for_field_get(expr.object)
    raise Unsupported, "register emitter does not know value for field #{expr.field.inspect}" unless object

    case object.fetch(:kind)
    when :struct
      field = ensure_struct_field_loaded(object, expr.field.to_s)
      raise Unsupported, "register emitter does not know struct field #{expr.field.inspect}" unless field
      raise Unsupported, "register emitter expected String struct field #{expr.field.inspect}" unless field.fetch(:type) == :string

      field.fetch(:reg)
    when :union
      reg = object.fetch(:payloads)[expr.field.to_s]
      unless reg
        variant = union_variant(object.fetch(:type), expr.field.to_s)
        raise Unsupported, "register emitter does not know union String payload #{expr.field.inspect}" unless variant && normalize_type(variant.fetch(:zig_type)) == :string

        reg = fresh_sreg
        emit(SCONST, reg, add_const(""))
      end
      reg
    else
      raise Unsupported, "register emitter does not support #{object.fetch(:kind)} String field access yet"
    end
  end

  def compile_tag_subject(expr)
    if expr.is_a?(MIR::FieldGet)
      type_name = enum_variant_type(expr)
      return [compile_i64_expr(expr), type_name] if type_name
    elsif expr.is_a?(MIR::Ident)
      name = expr.name.to_s
      return [@ireg_by_name.fetch(name), @tag_type_by_name.fetch(name)] if @tag_type_by_name.key?(name)
      return [@ireg_by_name.fetch(name), nil] if @ireg_by_name.key?(name)

      value = @value_by_name[name]
      return [value.fetch(:tag_reg), value.fetch(:type)] if value && value.fetch(:kind) == :union
    elsif inferred_expr_type(expr) == :i64 || inferred_expr_type(expr) == :bool
      return [compile_i64_expr(expr), nil]
    end

    raise Unsupported, "register emitter does not support switch subject #{expr.class.name} yet"
  end

  def union_variant(type_name, tag_name)
    variants = union_variants_for(type_name)
    return nil unless variants

    variants.find { |entry| entry.fetch(:name).to_s == tag_name }
  end

  def active_tag_call?(expr)
    return false unless expr.is_a?(MIR::Call)

    expr.callee.to_s == "std.meta.activeTag"
  end

  def compile_active_tag(expr)
    arg = (expr.args || []).first
    unless arg.is_a?(MIR::Ident)
      raise Unsupported, "register emitter only supports activeTag(local) in Tranche 7"
    end

    value = @value_by_name[arg.name.to_s]
    raise Unsupported, "register emitter does not know union #{arg.name.inspect}" unless value && value.fetch(:kind) == :union
    value.fetch(:tag_reg)
  end

  def tag_expr_type(expr)
    if active_tag_call?(expr)
      arg = (expr.args || []).first
      value = arg.is_a?(MIR::Ident) ? @value_by_name[arg.name.to_s] : nil
      return value.fetch(:type) if value && value.fetch(:kind) == :union
    elsif expr.is_a?(MIR::Ident) && expr.name.to_s.start_with?(".")
      return @tag_context_type
    end

    nil
  end

  def with_tag_context(type)
    old = @tag_context_type
    @tag_context_type = type if type
    yield
  ensure
    @tag_context_type = old
  end

  def compile_tag_const(type_name, tag_name)
    variants = @enum_variants[type_name] || union_variants_for(type_name)&.map { |entry| entry.fetch(:name).to_s }
    raise Unsupported, "register emitter does not know tag type #{type_name.inspect}" unless variants

    idx = variants.index(tag_name)
    raise Unsupported, "register emitter does not know tag #{type_name}.#{tag_name}" unless idx

    reg = fresh_ireg
    emit(ICONST, reg, add_const(idx))
    reg
  end

  def enum_variant_type(expr)
    return nil unless expr.object.is_a?(MIR::Ident)

    type_name = expr.object.name.to_s
    return nil unless @enum_variants.key?(type_name)
    return nil unless @enum_variants.fetch(type_name).include?(expr.field.to_s)

    type_name
  end

  def field_get_type(expr)
    return :i64 if enum_variant_type(expr)

    object = value_for_field_get(expr.object)
    return :unsupported unless object

    case object.fetch(:kind)
    when :struct
      field = object.fetch(:fields)[expr.field.to_s]
      field ? field.fetch(:type) : :unsupported
    when :union
      variant = union_variant(object.fetch(:type), expr.field.to_s)
      variant ? normalize_type(variant.fetch(:zig_type)) : :unsupported
    else
      :unsupported
    end
  end

  def compile_i64_inline_bc(expr)
    if expr.op == :eql? || expr.op == :eql || expr.op == :strEql
      args = expr.args || []
      unless args.length == 2 && (string_expr?(args[0]) || string_expr?(args[1]))
        raise Unsupported, "register emitter only supports string equality in this tranche"
      end

      left = compile_string_expr(args[0])
      right = compile_string_expr(args[1])
      dst = fresh_ireg
      emit(SEQ, dst, left, right)
      return dst
    end

    if expr.op == :insert
      args = expr.args || []
      raise Unsupported, "register emitter expected pool.insert(struct) form" unless args.length == 2 && args[0].is_a?(MIR::Ident)
      return compile_pool_insert(args[0].name.to_s, args[1])
    end

    if expr.op == :"contains?" || expr.op == :contains
      args = expr.args || []
      if args.length == 2 && string_expr?(args[0]) && string_expr?(args[1])
        left = compile_string_expr(args[0])
        right = compile_string_expr(args[1])
        return emit_i64_ncall(N_STRING_CONTAINS, [[ARG_S, left], [ARG_S, right]])
      end

      raise Unsupported, "register emitter expected contains?(set, key)" unless args.length == 2 && args[0].is_a?(MIR::Ident)
      name = args[0].name.to_s
      kind = @vkind_by_name[name]
      if (@set_views || {})[name]
        return compile_set_contains(name, args[1], kind)
      elsif kind == :int_map || kind == :numeric_int_map
        return compile_map_contains(name, args[1], kind)
      end
    end

    if expr.op == :get
      args = expr.args || []
      if args.length == 2 && args[0].is_a?(MIR::Ident) && @vkind_by_name[args[0].name.to_s] == :pool
        # Pool get returns an optional; the i64 path here means the
        # caller is comparing with NIL (`p != null`). Return the
        # alive flag so the BinOp `!= null` resolves to the flag,
        # and `== null` resolves to its complement.
        info = (@pool_info || {})[args[0].name.to_s]
        id_reg = compile_i64_expr(args[1])
        flag = fresh_ireg
        emit(LGETI, flag, info[:alive_reg], id_reg)
        return flag
      end
    end

    if expr.op == :getAt
      args = expr.args || []
      receiver_is_plain_vreg = args[0].is_a?(MIR::Ident) && @vreg_by_name.key?(resolve_ctx_name(args[0].name))
      if args.length >= 2 && !receiver_is_plain_vreg && (handle = compile_list_handle_expr(args[0], :int_list_handle))
        dst = fresh_ireg
        op = handle[:kind] == :borrowed_int_list_handle ? LGETI : IHGET
        emit(op, dst, handle.fetch(:reg), compile_i64_expr(args[1]))
        return dst
      end
    end

    if expr.op == :length || expr.op == :count
      args = expr.args || []
      if args.length >= 1 && args[0].is_a?(MIR::Ident) && @vkind_by_name[args[0].name.to_s] == :pool
        return compile_pool_length(args[0].name.to_s)
      end
    end

    if expr.op == :timestampMs
      return emit_i64_ncall(N_TIMESTAMP_MS, [])
    end
    if expr.op == :threadCount
      return emit_i64_ncall(N_THREAD_COUNT, [])
    end
    if expr.op == :framePeakBytes
      return emit_i64_ncall(N_FRAME_PEAK_BYTES, [])
    end
    if expr.op == :currentMemoryKb
      return emit_i64_ncall(N_CURRENT_MEMORY_KB, [])
    end
    if expr.op == :codepointCount
      args = expr.args || []
      raise Unsupported, "register emitter expected one operand for codepointCount" unless args.length == 1
      str = compile_string_expr(args[0])
      return emit_i64_ncall(N_STRING_CODEPOINT_COUNT, [[ARG_S, str]])
    end
    if expr.op == :indexOf
      args = expr.args || []
      raise Unsupported, "register emitter expected two operands for indexOf" unless args.length == 2
      hay = compile_string_expr(args[0])
      needle = compile_string_expr(args[1])
      return emit_i64_ncall(N_STRING_INDEX_OF, [[ARG_S, hay], [ARG_S, needle]])
    end
    if expr.op == :toInt
      args = expr.args || []
      unless args.length == 1
        raise Unsupported, "register emitter expected one operand for toInt"
      end

      if f64_expr?(args[0])
        value = compile_f64_expr(args[0])
        return emit_i64_ncall(N_FLOAT_TO_INT, [[ARG_F, value]])
      end

      return compile_i64_expr(args[0])
    end
    if expr.op == :randomInt
      args = expr.args || []
      unless args.length == 1
        raise Unsupported, "register emitter expected one operand for randomInt"
      end

      max = compile_i64_expr(args[0])
      return emit_i64_ncall(N_RANDOM_INT, [[ARG_I, max]])
    end
    if expr.op == :contains?
      args = expr.args || []
      unless args.length >= 2 && args[0].is_a?(MIR::Ident)
        raise Unsupported, "register emitter only supports local HashMap<Int64> contains? in this tranche"
      end
      kind = @vkind_by_name.fetch(args[0].name.to_s, nil)
      unless [:int_map, :numeric_int_map].include?(kind)
        raise Unsupported, "register emitter only supports HashMap<Int64> contains? in this tranche"
      end

      dst = fresh_ireg
      map_reg = map_register_for(args[0])
      if kind == :numeric_int_map
        key_reg = compile_i64_expr(args[1])
        emit(NMCONTAINS, dst, map_reg, key_reg)
      else
        key_kind, key_operand = map_string_key_operand(args[1])
        if key_kind == :literal
          emit(MCONTAINS, dst, map_reg, key_operand)
        else
          emit(MCONTAINSR, dst, map_reg, key_operand)
        end
      end
      return dst
    end
    if expr.op == :startsWith?
      args = expr.args || []
      unless args.length == 2
        raise Unsupported, "register emitter expected two operands for startsWith?"
      end

      left = compile_string_expr(args[0])
      right = compile_string_expr(args[1])
      return emit_i64_ncall(N_STRING_STARTS_WITH, [[ARG_S, left], [ARG_S, right]])
    end
    if expr.op == :getAt
      args = expr.args || []
      unless args.length >= 2 && args[0].is_a?(MIR::Ident)
        raise Unsupported, "register emitter only supports local Int64 list getAt in this tranche"
      end
      list_reg = @vreg_by_name.fetch(args[0].name.to_s) do
        raise Unsupported, "register emitter does not know list #{args[0].name.inspect}"
      end
      index_reg = compile_i64_expr(args[1])
      dst = fresh_ireg
      emit(LGETI, dst, list_reg, index_reg)
      return dst
    end
    if expr.op == :length || expr.op == :count
      args = expr.args || []
      plain_vreg_length = args[0].is_a?(MIR::Ident) && @vreg_by_name.key?(resolve_ctx_name(args[0].name))
      if args.length >= 1 && !plain_vreg_length && (handle = compile_list_handle_expr(args[0]))
        dst = fresh_ireg
        case handle.fetch(:kind)
        when :int_list_handle then emit(IHLEN, dst, handle.fetch(:reg))
        when :borrowed_int_list_handle then emit(LLEN, dst, handle.fetch(:reg))
        when :string_list_handle then emit(SHLEN, dst, handle.fetch(:reg))
        when :borrowed_string_list_handle then emit(LSLEN, dst, handle.fetch(:reg))
        end
        return dst
      end
      unless args.length >= 1 && args[0].is_a?(MIR::Ident)
        raise Unsupported, "register emitter only supports local Int64/Float64 list length in this tranche"
      end
      name = args[0].name.to_s
      if @vkind_by_name[name] == :struct_list
        # All parallel arrays share the same length by construction;
        # read it off the first field.
        info = (@struct_list_info || {})[name]
        first = info[:fields].values.first
        len_op = case first[:kind]
                 when :int_list then LLEN
                 when :f64_list then LFLEN
                 when :string_list then LSLEN
                 when :handle_list then LLEN
                 when :int_handle_values then IHLEN
                 when :string_handle_values then SHLEN
                 end
        dst = fresh_ireg
        emit(len_op, dst, first[:reg])
        return dst
      end
      list_reg = @vreg_by_name.fetch(name) do
        raise Unsupported, "register emitter does not know list #{args[0].name.inspect}"
      end
      dst = fresh_ireg
      opcode = case @vkind_by_name.fetch(name)
               when :f64_list then LFLEN
               when :string_list then LSLEN
               when :value_list then LVLEN
               when :int_map then MLEN
               when :numeric_int_map then NMLEN
               else LLEN
               end
      emit(opcode, dst, list_reg)
      return dst
    end

    opcode = case expr.op
             when :intAdd, :wrapAdd, :checkAdd then IADD
             when :intSub, :wrapSub, :checkSub then ISUB
             when :intMul, :wrapMul, :checkMul then IMUL
             when :intDiv then IDIV
             when :intMod then IMOD
             else
               raise Unsupported, "register emitter does not support MIR::InlineBc op #{expr.op.inspect} yet"
             end

    args = expr.args || []
    unless args.length == 2
      raise Unsupported, "register emitter expected two operands for #{expr.op.inspect}"
    end

    left = compile_i64_expr(args[0])
    right = compile_i64_expr(args[1])
    dst = fresh_ireg
    emit(opcode, dst, left, right)
    dst
  end

  def compile_i64_inline_zig(expr)
    reason = expr.reason.to_s
    unless reason.start_with?("builtin_int") || reason == "intrinsic"
      raise Unsupported, "register emitter does not support MIR::InlineZig reason #{expr.reason.inspect} yet"
    end

    compile_i64_inline_zig_code(expr.code.to_s)
  end

  def compile_i64_inline_zig_code(code)
    if (match = code.match(/\ACheatLib\.len\(([A-Za-z_][A-Za-z0-9_]*)\)\z/))
      list_reg = @vreg_by_name.fetch(match[1]) do
        raise Unsupported, "register emitter does not know list #{match[1].inspect}"
      end
      dst = fresh_ireg
      opcode = case @vkind_by_name.fetch(match[1])
               when :f64_list then LFLEN
               when :string_list then LSLEN
               when :int_map then MLEN
               else LLEN
               end
      emit(opcode, dst, list_reg)
      return dst
    end

    match = code.match(/\ACheatLib\.(intAdd|intSub|intMul|intDiv|intMod)\((.*)\)\z/)
    raise Unsupported, "register emitter cannot parse InlineZig builtin #{code.inspect}" unless match

    opcode = case match[1]
             when "intAdd" then IADD
             when "intSub" then ISUB
             when "intMul" then IMUL
             when "intDiv" then IDIV
             when "intMod" then IMOD
             end
    args = split_inline_zig_args(match[2])
    unless args.length == 2
      raise Unsupported, "register emitter expected two InlineZig operands for #{code.inspect}"
    end

    left = compile_i64_inline_zig_operand(args[0])
    right = compile_i64_inline_zig_operand(args[1])
    dst = fresh_ireg
    emit(opcode, dst, left, right)
    dst
  end

  def split_inline_zig_args(text)
    args = []
    depth = 0
    start = 0
    text.each_char.with_index do |ch, idx|
      case ch
      when "(", "{", "["
        depth += 1
      when ")", "}", "]"
        depth -= 1
      when ","
        next unless depth.zero?

        args << text[start...idx].strip
        start = idx + 1
      end
    end
    args << text[start..].to_s.strip
    args
  end

  def compile_i64_inline_zig_operand(text)
    text = text.strip
    return compile_i64_expr(MIR::Lit.new(text)) if text.match?(/\A-?\d+(?:_i64)?\z/)

    if text.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      return compile_i64_expr(MIR::Ident.new(text))
    end

    if (match = text.match(/\A([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\z/))
      return compile_i64_field_get(MIR::FieldGet.new(MIR::Ident.new(match[1]), match[2]))
    end

    if (match = text.match(/\ACheatLib\.getAt\(([A-Za-z_][A-Za-z0-9_]*),\s*(.+)\)\z/))
      list_reg = @vreg_by_name.fetch(match[1]) do
        raise Unsupported, "register emitter does not know list #{match[1].inspect}"
      end
      index_reg = compile_i64_inline_zig_operand(match[2])
      dst = fresh_ireg
      emit(LGETI, dst, list_reg, index_reg)
      return dst
    end

    return compile_i64_inline_zig_code(text) if text.start_with?("CheatLib.int")

    raise Unsupported, "register emitter does not support InlineZig operand #{text.inspect} yet"
  end

  def compile_f64_inline_bc(expr)
    if expr.op == :random
      return emit_f64_ncall(N_RANDOM, [])
    end

    if expr.op == :toFloat
      args = expr.args || []
      unless args.length == 1
        raise Unsupported, "register emitter expected one operand for toFloat"
      end
      value = compile_i64_expr(args[0])
      return emit_f64_ncall(N_INT_TO_FLOAT, [[ARG_I, value]])
    end

    if expr.op == :getAt
      args = expr.args || []
      unless args.length >= 2 && args[0].is_a?(MIR::Ident)
        raise Unsupported, "register emitter only supports local Float64 list getAt in this tranche"
      end
      list_reg = @vreg_by_name.fetch(args[0].name.to_s) do
        raise Unsupported, "register emitter does not know list #{args[0].name.inspect}"
      end
      unless @vkind_by_name.fetch(args[0].name.to_s) == :f64_list
        raise Unsupported, "register emitter expected Float64 list #{args[0].name.inspect}"
      end
      index_reg = compile_i64_expr(args[1])
      dst = fresh_freg
      emit(LFGET, dst, list_reg, index_reg)
      return dst
    end

    raise Unsupported, "register emitter does not support MIR::InlineBc f64 op #{expr.op.inspect} yet"
  end

  def compile_i64_index_get(expr)
    unless expr.object.is_a?(MIR::Ident)
      if (handle = compile_list_handle_expr(expr.object, :int_list_handle))
        dst = fresh_ireg
        op = handle[:kind] == :borrowed_int_list_handle ? LGETI : IHGET
        emit(op, dst, handle.fetch(:reg), compile_i64_expr(expr.index))
        return dst
      end
    end

    unless expr.object.is_a?(MIR::Ident)
      raise Unsupported, "register emitter only supports local Int64 list indexing in this tranche"
    end

    list_reg = @vreg_by_name.fetch(expr.object.name.to_s) do
      raise Unsupported, "register emitter does not know list #{expr.object.name.inspect}"
    end
    unless @vkind_by_name.fetch(expr.object.name.to_s) == :int_list
      raise Unsupported, "register emitter expected Int64 list #{expr.object.name.inspect}"
    end

    index_reg = compile_i64_expr(expr.index)
    dst = fresh_ireg
    emit(LGETI, dst, list_reg, index_reg)
    dst
  end

  def compile_f64_index_get(expr)
    unless expr.object.is_a?(MIR::Ident)
      raise Unsupported, "register emitter only supports local Float64 list indexing in this tranche"
    end

    list_reg = @vreg_by_name.fetch(expr.object.name.to_s) do
      raise Unsupported, "register emitter does not know list #{expr.object.name.inspect}"
    end
    unless @vkind_by_name.fetch(expr.object.name.to_s) == :f64_list
      raise Unsupported, "register emitter expected Float64 list #{expr.object.name.inspect}"
    end

    index_reg = compile_i64_expr(expr.index)
    dst = fresh_freg
    emit(LFGET, dst, list_reg, index_reg)
    dst
  end

  def compile_string_index_get(expr)
    unless expr.object.is_a?(MIR::Ident)
      raise Unsupported, "register emitter only supports local String list indexing in this tranche"
    end

    list_reg = @vreg_by_name.fetch(expr.object.name.to_s) do
      raise Unsupported, "register emitter does not know list #{expr.object.name.inspect}"
    end
    unless @vkind_by_name.fetch(expr.object.name.to_s) == :string_list
      raise Unsupported, "register emitter expected String list #{expr.object.name.inspect}"
    end

    index_reg = compile_i64_expr(expr.index)
    dst = fresh_sreg
    emit(LSGET, dst, list_reg, index_reg)
    dst
  end

  def compile_f64_inline_zig_operand(text)
    text = text.strip
    return compile_f64_expr(MIR::Lit.new(text)) if text.match?(/\A-?\d+\.\d+\z/)

    if text.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      return compile_f64_expr(MIR::Ident.new(text))
    end

    if (match = text.match(/\ACheatLib\.getAt\(([A-Za-z_][A-Za-z0-9_]*),\s*(.+)\)\z/))
      list_reg = @vreg_by_name.fetch(match[1]) do
        raise Unsupported, "register emitter does not know list #{match[1].inspect}"
      end
      unless @vkind_by_name.fetch(match[1]) == :f64_list
        raise Unsupported, "register emitter expected Float64 list #{match[1].inspect}"
      end
      index_reg = compile_i64_inline_zig_operand(match[2])
      dst = fresh_freg
      emit(LFGET, dst, list_reg, index_reg)
      return dst
    end

    raise Unsupported, "register emitter does not support Float64 InlineZig operand #{text.inspect} yet"
  end

  def binding_type(stmt)
    annotation = stmt.annotation.to_s
    return inferred_expr_type(stmt.init) if annotation.empty?
    return :bool if annotation == "bool" || annotation == "Bool"

    normalize_type(annotation)
  end

  def enum_binding_type(stmt)
    return enum_type_name(stmt.annotation) unless stmt.annotation.to_s.empty?

    if stmt.init.is_a?(MIR::Call)
      function = @functions_by_name[stmt.init.callee.to_s]
      return enum_type_name(function.ret_type) if function
    elsif stmt.init.is_a?(MIR::Ident)
      return @tag_type_by_name[stmt.init.name.to_s]
    end

    nil
  end

  def parse_i64_literal(value)
    text = value.to_s
    return 1 if text == "true"
    return 0 if text == "false"
    # `null` / `NIL` compare against optionals. The bc emitter
    # represents pool.get() as the alive-flag i64 (0 = NIL,
    # non-zero = alive); comparing against the literal 0 has
    # the right semantics.
    return 0 if text == "null" || text == "NIL" || text == "nil"
    return text.to_i if text.match?(/\A-?\d+\z/)

    raise Unsupported, "register emitter only supports Int64 literals in Tranche 1"
  end

  def parse_f64_literal(value)
    text = value.to_s
    return 0.0 if text == "null"
    return text.to_f if text.match?(/\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\z/)

    raise Unsupported, "register emitter only supports Float64 literals in Tranche 5 (got #{text.inspect})"
  end

  def inferred_expr_type(expr)
    if expr.is_a?(MIR::Lit)
      text = expr.value.to_s
      return :string if text.start_with?('"') && text.end_with?('"')
      return text.include?(".") ? :f64 : :i64
    elsif expr.is_a?(MIR::Ident)
      name = expr.name.to_s
      return :f64 if @freg_by_name.key?(name)
      return :i64 if @ireg_by_name.key?(name)
      return :string if @sreg_by_name.key?(name)
    elsif expr.is_a?(MIR::IndexGet)
      if expr.object.is_a?(MIR::Ident) && @vkind_by_name[expr.object.name.to_s] == :f64_list
        return :f64
      end
    elsif expr.is_a?(MIR::InlineBc)
      return :string if [:toString, :charAt, :substr].include?(expr.op)
      return :void if expr.op == :sleep
      if expr.op == :getAt
        list_arg = (expr.args || []).first
        if list_arg.is_a?(MIR::Ident)
          case @vkind_by_name[list_arg.name.to_s]
          when :f64_list then return :f64
          when :string_list then return :string
          end
        end
      end
      return :i64
    elsif expr.is_a?(MIR::InlineZig)
      return :i64 if expr.reason.to_s.start_with?("builtin_int")
    elsif expr.is_a?(MIR::Orelse)
      return inferred_expr_type(expr.fallback)
    elsif expr.is_a?(MIR::DeepCopy)
      return inferred_expr_type(expr.source)
    elsif expr.is_a?(MIR::DupeSlice)
      return inferred_expr_type(expr.source)
    elsif expr.is_a?(MIR::TryExpr) || expr.is_a?(MIR::TryCatch)
      return inferred_expr_type(expr.expr)
    elsif expr.is_a?(MIR::Call)
      fn = @functions_by_name[expr.callee.to_s]
      return normalize_type(fn.ret_type) if fn
    elsif expr.is_a?(MIR::HeapCreate)
      return inferred_expr_type(expr.init)
    elsif expr.is_a?(MIR::Deref)
      return inferred_expr_type(expr.expr)
    elsif expr.is_a?(MIR::ShardedMapGet)
      return :f64 if numeric_f64_map_target?(expr.target)
      return :i64
    elsif expr.is_a?(MIR::ListLength)
      return :i64
    elsif expr.is_a?(MIR::UnaryOp)
      return inferred_expr_type(expr.operand)
    elsif expr.is_a?(MIR::Cast)
      normalized = normalize_type(expr.target_type)
      return normalized unless normalized == :unsupported
      return inferred_expr_type(expr.expr)
    elsif expr.is_a?(MIR::BlockExpr)
      if expr.body.length == 1 && expr.body.first.is_a?(MIR::IfStmt)
        branch = expr.body.first.then_body&.first || expr.body.first.else_body&.first
        return inferred_expr_type(branch.value) if branch.respond_to?(:value)
      end
      # Pipeline-shape `Let acc = init; ForStmt; break acc` -- the
      # block result is the accumulator's inferred type.
      brk = expr.body&.find { |s| s.is_a?(MIR::BreakStmt) }
      if brk && brk.value.is_a?(MIR::Ident)
        target = expr.body.find { |s| s.is_a?(MIR::Let) && s.name.to_s == brk.value.name.to_s }
        if target
          return normalize_type(target.annotation) if target.annotation
          t = inferred_expr_type(target.init)
          return t if t && t != :unsupported
        end
      end
      return inferred_expr_type(brk.value) if brk && brk.value
      # A BlockExpr with no value-producing break (e.g. a WITH
      # EXCLUSIVE wrapper) is a side-effect-only block.
      return :void
    elsif expr.is_a?(MIR::Pipeline)
      return inferred_expr_type(expr.inner)
    elsif expr.is_a?(MIR::TryExpr)
      return inferred_expr_type(expr.expr)
    elsif expr.is_a?(MIR::MethodCall) && expr.method.to_s == "next" && expr.receiver.is_a?(MIR::Ident)
      name = resolve_ctx_name(expr.receiver.name)
      promise = (@bg_promise_bindings || {})[name]
      return promise.fetch(:payload_kind) if promise
      stream = (@bg_stream_bindings || {})[name]
      return stream.fetch(:payload_kind) if stream
    elsif expr.is_a?(MIR::BinOp)
      return :bool if %w[< > == != <= >=].include?(expr.op.to_s)
      return :string if inferred_expr_type(expr.left) == :string || inferred_expr_type(expr.right) == :string
      return :f64 if f64_expr?(expr.left) || f64_expr?(expr.right)
      return :i64
    elsif expr.is_a?(MIR::Call)
      function = @functions_by_name[expr.callee.to_s]
      return normalize_type(function.ret_type) if function
    elsif expr.is_a?(MIR::FieldGet)
      return :i64 if enum_variant_type(expr)
      return field_get_type(expr)
    elsif expr.is_a?(MIR::ConcatStr)
      return :string
    elsif expr.is_a?(MIR::Cast)
      normalized = normalize_type(expr.target_type)
      return normalized unless normalized == :unsupported
      return inferred_expr_type(expr.expr)
    end

    :unsupported
  end

  def f64_expr?(expr)
    inferred_expr_type(expr) == :f64
  end

  def string_expr?(expr)
    inferred_expr_type(expr) == :string
  end

  def normalize_type(type)
    text = type.to_s.delete_prefix("!").delete_prefix("anyerror!")
    text = text.delete_prefix("?")
    text = text.delete_prefix("*")
    return :i64 if @enum_variants.key?(text)

    case text
    when "i8", "i16", "i32", "i64", "Int8", "Int16", "Int32", "Int64",
         "u8", "u16", "u32", "u64", "UInt8", "UInt16", "UInt32", "UInt64"
      :i64
    when "bool", "Bool"
      :bool
    when "f32", "f64", "Float32", "Float64"
      :f64
    when "String", "[]const u8", "[]u8"
      :string
    when "void", "Void", ""
      :void
    else :unsupported
    end
  end

  def value_type(type)
    normalized = normalize_type(type)
    return normalized unless normalized == :unsupported

    text = type.to_s.delete_prefix("!").delete_prefix("anyerror!")
    text = text.delete_prefix("?").delete_prefix("*")
    if (m = text.match(/\A(?:std\.)?ArrayListUnmanaged\(([A-Za-z_][A-Za-z0-9_]*)\)\z/))
      inner = m[1]
      return [:struct_list, inner] if @struct_fields.key?(inner)
    end
    return :int_list_handle if text == "Int64[]" ||
                               text == "[]i64" ||
                               text.match?(/\A(?:std\.)?ArrayListUnmanaged\(i64\)\z/)
    return :string_list_handle if text == "String[]" ||
                                  text == "[][]const u8" ||
                                  text.match?(/\A(?:std\.)?ArrayListUnmanaged\(\[\]const u8\)\z/)
    return [:struct, text] if @struct_fields.key?(text)
    return [:union, text] if union_variants_for(text)
    # Capability wrappers around scalar structs share the field-
    # decomposed layout, so a fn returning Rc(T)/Arc(T)/Locked(T)/etc.
    # produces the matching cap-struct value-kind. The wrapper kind
    # is preserved so downstream code (.ctrl.data unwrap, cleanup,
    # clone-on-assign) sees the same shape it would for a directly
    # bound cap-wrapped struct.
    if (m = text.match(/\A(?:CheatLib\.)?(Rc|Arc|Locked|RwLocked|WriteLocked|Local|Indirect|Versioned)\((.+)\)\z/))
      wrapper = m[1]
      inner = m[2].strip
      kind = case wrapper
             when "Rc"           then :rc_struct
             when "Arc"          then :arc_struct
             when "Locked"       then :locked_struct
             when "RwLocked"     then :locked_struct
             when "WriteLocked"  then :write_locked_struct
             when "Local"        then :local_struct
             when "Indirect"     then :struct
             when "Versioned"    then :versioned_struct
             end
      return [kind, inner] if kind && @struct_fields.key?(inner)
    end

    :unsupported
  end

  def enum_type_name(type)
    text = type.to_s.delete_prefix("!").delete_prefix("anyerror!")
    @enum_variants.key?(text) ? text : nil
  end

  def union_arg_type(type)
    text = type.to_s.delete_prefix("!").delete_prefix("anyerror!")
    union_variants_for(text) ? [:union, text] : nil
  end

  def union_variants_for(type_name)
    text = type_name.to_s
    return @union_variants[text] if @union_variants.key?(text)

    match = text.match(/\A([A-Za-z_][A-Za-z0-9_]*)\((.+)\)\z/)
    return nil unless match

    variants = @union_variants[match[1]]
    return nil unless variants

    arg_type = match[2]
    variants.map do |entry|
      entry.fetch(:zig_type).to_s == "T" ? entry.merge(zig_type: arg_type) : entry
    end
  end

  def struct_arg_type(type)
    text = type.to_s.delete_prefix("!").delete_prefix("anyerror!")
    @struct_fields.key?(text) ? [:struct, text] : nil
  end

  # MUTABLE / by-pointer params arrive as MIR::AddressOf (and reads
  # back via MIR::Deref) wrapping the binding Ident. Peel those to
  # recover the Ident so cap-wrapped struct args resolve through
  # @value_by_name. Mirrors atomic_receiver_ident.
  def unwrap_to_ident(node)
    node = node.expr while node.is_a?(MIR::AddressOf) || node.is_a?(MIR::Deref)
    node
  end

  def anytype_arg_type(param, arg)
    return nil unless param.zig_type.to_s == "anytype"

    inner = unwrap_to_ident(arg)
    value = inner.is_a?(MIR::Ident) ? @value_by_name[inner.name.to_s] : compile_value_expr(arg)
    return nil unless value
    case value.fetch(:kind)
    when :struct, :rc_struct, :arc_struct, :locked_struct, :write_locked_struct, :local_struct, :versioned_struct, :atomic_ptr_struct
      # Capability-wrapped scalar structs share the field-decomposed
      # layout in the bc VM, so passing one to a helper FN that
      # `REQUIRES` a particular sync family can route through the
      # underlying struct identity. Single-threaded VM has no
      # observable difference between the cap families.
      [:struct, value.fetch(:type)]
    else
      nil
    end
  end

  # Walk the local program's MIR collecting qualified callee names
  # (`<alias>.<fn>`) that appear in MIR::Call expressions. Used to
  # decide which cross-file FN bodies to pull in from the importer.
  # Uses string-search on inspect rather than a recursive walker so
  # we don't loop on shared sub-expressions that the MIR can produce.
  def collect_qualified_calls(items)
    seen = Set.new
    items.each do |item|
      next unless item.is_a?(MIR::FnDef)
      text = item.body.inspect
      text.scan(/callee="([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*!?)"/) do |m|
        seen << m[0]
      end
    end
    seen
  end

  def collect_type_defs(items)
    items.each do |item|
      case item
      when MIR::EnumDef
        @enum_variants[item.name.to_s] = item.variants.map(&:to_s)
      when MIR::UnionTypeDef
        @union_variants[item.name.to_s] = item.variants
      when MIR::StructDef
        @struct_fields[item.name.to_s] = item.fields.to_h { |field| [field.name.to_s, field.zig_type] }
      end
    end
    if @frontend_result.respond_to?(:union_schemas)
      @frontend_result.union_schemas.each do |name, schema|
        # schema can be a `Schemas::UnionSchema` (post-Schemas migration)
        # or a raw Hash on older paths. Normalize to the variants hash
        # before iterating.
        variants = schema.respond_to?(:variants) ? schema.variants : schema
        @union_variants[name.to_s] ||= variants.map do |variant_name, type|
          { name: variant_name.to_s, zig_type: type ? type.zig_type : "void" }
        end
      end
    end

    # Cross-file struct/enum/union types come in via REQUIRE and live in
    # the annotator's global type table, not as MIR::StructDef items in
    # the program. Pull them in so calls like `Point{ x: 1.0, y: 2.0 }`
    # in the importing file resolve.
    annotator = @frontend_result.respond_to?(:annotator) ? @frontend_result.annotator : nil
    types_table = annotator&.scope_stack&.first&.types
    types_table&.each do |name, entry|
      schema = entry.is_a?(Hash) ? entry[:schema] : nil
      next unless schema.is_a?(Hash)
      key = name.to_s
      case schema[:kind]
      when :enum
        @enum_variants[key] ||= (schema[:variants] || []).map(&:to_s)
      when :union
        @union_variants[key] ||= (schema[:variants] || []).map do |variant_name, type|
          { name: variant_name.to_s, zig_type: type ? type.zig_type : "void" }
        end
      else
        next if @struct_fields.key?(key)
        fields = schema.reject { |k, _| k.is_a?(Symbol) }
        next if fields.empty?
        @struct_fields[key] = fields.to_h { |fname, ftype| [fname.to_s, ftype.respond_to?(:zig_type) ? ftype.zig_type : ftype.to_s] }
      end
    end
  end

  def fresh_ireg
    reg = @next_ireg
    @next_ireg += 1
    reg
  end

  def fresh_freg
    reg = @next_freg
    @next_freg += 1
    reg
  end

  def fresh_sreg
    reg = @next_sreg
    @next_sreg += 1
    reg
  end

  def fresh_vreg
    reg = @next_vreg
    @next_vreg += 1
    reg
  end

  def add_const(value)
    idx = @consts.index(value)
    return idx if idx

    @consts << value
    @consts.length - 1
  end

  def emit(*values)
    @ops.concat(values)
    # Source-position metadata: opcode-position entries hold the
    # current CLEAR `(line, column)`; operand positions hold 0 / 0
    # (only opcode positions are consulted on error or by the
    # debugger). We pad here so the parallel arrays stay the same
    # length as @ops across pipeline rewrites; the optimizer can
    # then index by IP. The first emitted value is the opcode (true
    # for every emit() call site today).
    line = @current_source_line.to_i
    col  = @current_source_column.to_i
    values.each_with_index do |_, idx|
      @op_source_lines   << (idx == 0 ? line : 0)
      @op_source_columns << (idx == 0 ? col  : 0)
    end
  end

  def compile_debug_print(stmt)
    if (sprint_reg = parse_debug_print_string(stmt))
      emit(SPRINT, sprint_reg)
      return nil
    end

    prefix, names, suffixes = parse_debug_print_concat(stmt)
    if names.length > 2
      emit(SPRINT, compile_debug_print_concat_string(prefix, names, suffixes))
      return nil
    end

    regs = names.map do |name|
      @ireg_by_name.fetch(name) do
      raise Unsupported, "register emitter cannot print unknown Int64 local #{name.inspect}"
      end
    end

    if regs.length == 2
      emit(IPRINT2, add_const(prefix), regs[0], add_const(suffixes[0] || ""), regs[1], add_const(suffixes[1] || ""))
    elsif regs.length == 1
      emit(IPRINT, add_const(prefix), regs[0], add_const(suffixes[0] || ""))
    else
      emit(IPRINT, add_const(prefix), fresh_zero_ireg, add_const(""))
    end
    nil
  end

  def compile_debug_print_concat_string(prefix, names, suffixes)
    parts = []
    if prefix && !prefix.empty?
      reg = fresh_sreg
      emit(SCONST, reg, add_const(prefix))
      parts << reg
    end

    names.each_with_index do |name, idx|
      int_reg = @ireg_by_name.fetch(name) do
        raise Unsupported, "register emitter cannot print unknown Int64 local #{name.inspect}"
      end
      parts << emit_string_ncall(N_INT_TO_STRING, [[ARG_I, int_reg]])
      suffix = suffixes[idx] || ""
      next if suffix.empty?

      suffix_reg = fresh_sreg
      emit(SCONST, suffix_reg, add_const(suffix))
      parts << suffix_reg
    end

    return parts.first if parts.length == 1

    parts.reduce do |acc, reg|
      dst = fresh_sreg
      emit(SCONCAT, dst, acc, reg)
      dst
    end
  end

  def fresh_zero_ireg
    reg = fresh_ireg
    emit(ICONST, reg, add_const(0))
    reg
  end

  # Detect `print(<string>)` vs `print(<int-interpolation>)`. Returns
  # the s-register holding the value to print, or nil if this isn't a
  # plain-string print (caller falls through to the int-interpolation
  # path). Format `"{s}\n"` indicates a single string operand; we then
  # compile args[1] (`.{<expr>}`) as a string expression.
  def parse_debug_print_string(stmt)
    args = stmt.args || []
    return nil unless args.length >= 2
    fmt_lit = args[0]
    return nil unless fmt_lit.is_a?(MIR::Lit)
    fmt = fmt_lit.value.to_s
    # Strip the surrounding Zig quotes -- `"{s}\n"` arrives as the raw
    # six-char literal string (including the outer `"` chars).
    return nil unless fmt == '"{s}\\n"'
    tuple = args[1]
    return nil unless tuple.is_a?(MIR::Ident)
    text = tuple.name.to_s
    # Tuple shape: `.{<expr>}`. Strip the wrapper.
    return nil unless text.start_with?(".{") && text.end_with?("}")
    inner = text[2...-1]
    compile_string_print_inner(inner)
  end

  # Compile the inner Zig-text expression of a `print(...)` to a
  # string register. We recognize the small set of shapes the lowering
  # actually emits today; anything else raises Unsupported so the
  # caller can fall back or surface a clean error.
  def compile_string_print_inner(text)
    if (m = text.match(/\A"((?:\\.|[^"\\])*)"\z/))
      reg = fresh_sreg
      emit(SCONST, reg, add_const(unescape_string(m[1])))
      return reg
    end
    if text.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      return @sreg_by_name.fetch(text) do
        raise Unsupported, "register emitter cannot print unknown String local #{text.inspect}"
      end
    end
    # `try std.mem.concat(rt.frameAlloc(), u8, &.{ part0, part1, ... })`
    # is what the lowering emits for `"a" + b + "c"` shapes. Each part
    # is a string literal or an identifier. Concat them with SCONCAT.
    if (m = text.match(/\Atry std\.mem\.concat\(.+?, u8, &\.\{\s*(.+?)\s*\}\)\z/))
      parts = split_concat_parts(m[1])
      regs = parts.map { |p| compile_string_print_inner(p) }
      return nil if regs.any?(&:nil?)
      return regs.reduce do |acc, reg|
        dst = fresh_sreg
        emit(SCONCAT, dst, acc, reg)
        dst
      end
    end
    nil
  end

  # Split a concat operand list on top-level commas. We can't just do
  # `text.split(",")` because string literals may legally contain commas.
  def split_concat_parts(text)
    parts = []
    buf = +""
    in_str = false
    escape = false
    text.each_char do |c|
      if escape
        buf << c
        escape = false
      elsif c == "\\"
        buf << c
        escape = true
      elsif c == '"'
        buf << c
        in_str = !in_str
      elsif c == "," && !in_str
        parts << buf.strip
        buf = +""
      else
        buf << c
      end
    end
    parts << buf.strip unless buf.strip.empty?
    parts
  end

  def parse_debug_print_concat(stmt)
    args = stmt.args || []
    tuple = args[1]
    unless tuple.is_a?(MIR::Ident)
      raise Unsupported, "register emitter only supports benchmark scalar print interpolation in Tranche 2"
    end

    text = tuple.name.to_s
    strings = text.scan(/"((?:\\.|[^"\\])*)"/).flatten.map { |s| unescape_string(s) }
    vars = text.scan(/CheatLib\.intToString\(\{alloc\},\s*([A-Za-z_][A-Za-z0-9_]*)\)/).flatten
    return [strings.join, [], []] if vars.empty?

    prefix = strings[0] || ""
    suffixes = strings[1..] || []
    [prefix, vars, suffixes]
  end

  def unescape_string(text)
    text.gsub("\\n", "\n").gsub('\\"', '"').gsub("\\\\", "\\")
  end
end
