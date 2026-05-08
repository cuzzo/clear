# typed: true
# thunk_transform/emit.rb -- Zig codegen for the simple-recurrence
# THUNK shape detected by Phase 4c.
#
# Produces a single top-level Zig fn (Frame as a local type inside
# the fn body) that runs the heap-CPS trampoline. Layout:
#
#   fn <name>(rt: *Runtime, <params>) <ret> {
#       const Frame = struct {
#           <param fields>
#           step: u8 = 0,
#           child_result: <ret> = undefined,
#           parent: ?*@This() = null,
#       };
#       var initial: Frame = .{ <param init> };
#       var current: *Frame = &initial;
#       while (true) {
#           switch (current.step) {
#               0 => {
#                   <base case branches>     -- if matched, set result
#                   <recursive call>: alloc child frame, set parent,
#                                     advance step to 1, current = child
#                   continue;
#               },
#               1 => {
#                   const result = <combine_lhs> <op> current.child_result;
#                   <return-or-pop logic>
#                   continue;
#               },
#               else => unreachable,
#           }
#       }
#   }
#
# The <return-or-pop logic> is shared by base case and combine
# branches: if current.parent is non-null, write result into
# parent.child_result, free current (if heap), and resume in
# parent. If parent is null, return result.
#
# Cooperative yield is wired (Phase 4e) -- `rt.checkYield()` runs
# at the top of every loop iteration; the scheduler preempts when
# the per-fiber yield budget is exhausted. The TIGHT modifier
# (`fn_node.tight_reentrance`) replaces the yield call with a
# comment for hot inner loops where the caller manages preemption
# externally.
#
# Non-fallible body invariant (verified at emit-time): the
# trampoline body is contractually non-fallible. Today this is
# enforced by two upstream layers -- the simple-recurrence splitter
# only accepts `RETURN <lhs> <op> self_call(args)` (no fallible
# wrapper allowed), and the type checker rejects mixed fallible/
# plain in BinaryOp. A future Phase 4 expansion that lifts either
# constraint MUST add an `errdefer` chain-walk that frees every
# heap-allocated child Frame on the error-return path; today's
# `return_or_pop_lines` only frees on the normal path. The
# `assert_non_fallible_ret!` guard at the entry of `emit_trampoline`
# fails loudly if the invariant is ever violated.

require_relative "segments"

module ThunkTransform
  module Emit
    module_function

    # Map normalized op codes (from AST::OP_TO_OP_CODE) to Zig
    # operators. Phase 4c restricts to these four; Phase 4f-g may
    # widen if user demand emerges.
    OP_TO_ZIG = {
      ADD: "+",
      SUB: "-",
      MUL: "*",
      DIV: "/",
    }.freeze

    # Synthesize the trampoline body Zig for a function whose
    # AST::FunctionDef has a thunk_plan (set by Phase 4c detection).
    # Returns a String -- inserted into the function via a single
    # MIR::RawZig node.
    def emit_trampoline(fn_node, lowering)
      T.bind(self, T.untyped) rescue nil
      plan = fn_node.thunk_plan
      raise ArgumentError, "fn '#{fn_node.name}' has no thunk_plan" if plan.nil?
      ret_zig = ret_zig_type(fn_node, lowering)
      assert_non_fallible_ret!(fn_node, ret_zig)

      param_field_decls = (fn_node.params || []).map { |p|
        "#{p[:name]}: #{param_zig_type(p, lowering)},"
      }.join("\n        ")

      param_init = (fn_node.params || []).map { |p|
        ".#{p[:name]} = #{p[:name]}"
      }.join(", ")

      base_case_branches = plan.base_cases.map { |bc|
        cond  = render_expr(bc[:cond_ast], lowering)
        value = render_expr(bc[:value_ast], lowering)
        # Rewrite param refs in cond / value to current.<name>:
        cond_q  = qualify_params(cond, fn_node)
        value_q = qualify_params(value, fn_node)
        <<~ZIG.chomp
          if (#{cond_q}) {
                            const result: #{ret_zig} = #{value_q};
          #{return_or_pop_lines(ret_zig)}
                        }
        ZIG
      }.join("\n                    ")

      recurse_arg_inits = plan.recurse_args.each_with_index.map { |arg, i|
        param = (fn_node.params || [])[i]
        raise "thunk arg/param count mismatch in '#{fn_node.name}'" if param.nil?
        rendered = qualify_params(render_expr(arg, lowering), fn_node)
        ".#{param[:name]} = #{rendered}"
      }.join(", ")

      combine_lhs_zig = qualify_params(render_expr(plan.combine_lhs, lowering), fn_node)
      op_zig = OP_TO_ZIG.fetch(plan.combine_op) {
        raise "thunk: unsupported op #{plan.combine_op}"
      }

      # Build the full body. The whitespace is fragile-ish but the
      # output goes through Zig which doesn't care; readability is
      # for compiler debugging.
      yield_line = fn_node.tight_reentrance ? "// (TIGHT: scheduler yield-check skipped)" : "rt.checkYield();"
      <<~ZIG
        const Frame = struct {
                #{param_field_decls}
                step: u8 = 0,
                child_result: #{ret_zig} = undefined,
                parent: ?*@This() = null,
            };
            var initial: Frame = .{ #{param_init} };
            var current: *Frame = &initial;
            while (true) {
                // Cooperative yield: hands control back to the scheduler
                // periodically (rt.checkYield uses its own internal
                // counter -- thunk depth doesn't fight the fiber's
                // own yield budget). Strippable via :TIGHT:THUNK
                // for tight inner loops where the caller manages
                // scheduler hand-off externally.
                #{yield_line}
                switch (current.step) {
                    0 => {
                        #{base_case_branches}
                        // recursive call -- push child frame
                        const child = rt.heapAlloc().create(Frame) catch unreachable;
                        child.* = .{ #{recurse_arg_inits}, .parent = current };
                        current.step = 1;
                        current = child;
                        continue;
                    },
                    1 => {
                        const result: #{ret_zig} = #{combine_lhs_zig} #{op_zig} current.child_result;
        #{return_or_pop_lines(ret_zig)}
                    },
                    else => unreachable,
                }
            }
      ZIG
    end

    # Lines that handle "frame finished -- return or pop to parent".
    # Same shape for both base case and combine branches.
    def return_or_pop_lines(_ret_zig)
      T.bind(self, T.untyped) rescue nil
      <<~ZIG.chomp
                            if (current.parent) |p| {
                                p.child_result = result;
                                if (current != &initial) rt.heapAlloc().destroy(current);
                                current = p;
                                continue;
                            }
                            return result;
      ZIG
    end

    # Lower an AST expression to Zig text via the surrounding
    # MIRLowering (mirrors fsm_transform/recursive_splitter.rb's
    # pattern).
    def render_expr(ast_expr, lowering)
      T.bind(self, T.untyped) rescue nil
      mir = lowering.lower(ast_expr)
      lowering.send(:emit_expr, mir)
    end

    def param_zig_type(param, _lowering)
      T.bind(self, T.untyped) rescue nil
      type = param[:type]
      type.respond_to?(:zig_type) ? type.zig_type : type.to_s
    end

    def ret_zig_type(fn_node, _lowering)
      T.bind(self, T.untyped) rescue nil
      rt = fn_node.return_type
      return "void" if rt.nil?
      rt.respond_to?(:zig_type) ? rt.zig_type : rt.to_s
    end

    # Today's THUNK trampolines free heap-allocated child Frames only
    # on the normal return path (`return_or_pop_lines`). Two upstream
    # constraints keep the body contractually non-fallible: the
    # simple-recurrence splitter only accepts `RETURN <lhs> <op>
    # self_call(args)` (no fallible wrapper allowed), and the type
    # checker rejects mixed fallible/plain in a BinaryOp -- so a fn
    # whose body would `try`/raise can't reach this codegen.
    #
    # If a future Phase 4 expansion lifts either constraint, the
    # error-return path will leak the in-flight frame chain. Adding
    # an `errdefer` chain-walk in the emitted body is the surgical
    # fix; this guard fails loudly so the extension can't ship the
    # leak silently.
    def assert_non_fallible_ret!(fn_node, ret_zig)
      T.bind(self, T.untyped) rescue nil
      return unless ret_zig.start_with?("!")
      raise "INTERNAL: THUNK trampoline for '#{fn_node.name}' has fallible " \
            "return type (#{ret_zig.inspect}). The current codegen frees " \
            "heap-allocated child Frames only on the normal return path; an " \
            "error return would leak the in-flight chain. Before lifting the " \
            "non-fallible invariant, extend `emit_trampoline` and " \
            "`emit_mutual_trampoline` to emit an errdefer that walks " \
            "`current.parent` and frees every non-initial Frame."
    end

    # Rewrite bare param refs to `current.<name>` so the rendered
    # body reads from the live frame instead of the (now-stale)
    # outer fn parameters. The render_expr path emits parameter
    # identifiers as their bare Zig names; we substitute them here
    # via a word-boundary regex sweep.
    def qualify_params(zig_text, fn_node)
      T.bind(self, T.untyped) rescue nil
      out = zig_text.dup
      (fn_node.params || []).each do |p|
        name = p[:name]
        out = out.gsub(/(?<![A-Za-z0-9_.])#{Regexp.escape(name)}(?![A-Za-z0-9_])/, "current.#{name}")
      end
      out
    end

    # Phase 4f.1: emit a tagged-union trampoline for one member of a
    # mutual-recurrence cycle. Layout:
    #
    #   fn <fn_name>(rt: *Runtime, <params>) <ret> {
    #       const Frame = union(enum) {
    #           <variant_a>: struct { <params_a> },
    #           <variant_b>: struct { <params_b> },
    #           ...
    #       };
    #       var current: Frame = .{ .<self_variant> = .{ <init> } };
    #       while (true) {
    #           rt.checkYield();
    #           switch (current) {
    #               .<variant_a> => |f| {
    #                   <base cases for variant_a>
    #                   current = .{ .<target_a> = .{ <args> } };
    #                   continue;
    #               },
    #               ...
    #           }
    #       }
    #   }
    #
    # Each cycle member emits its own trampoline (same union layout,
    # different starting variant). Callers reach the cycle through
    # the public fn name they actually call.
    def emit_mutual_trampoline(fn_node, lowering)
      T.bind(self, T.untyped) rescue nil
      mtp = fn_node.mutual_thunk_plan
      raise ArgumentError, "fn '#{fn_node.name}' has no mutual_thunk_plan" if mtp.nil?

      ret_zig = ret_zig_type(fn_node, lowering)
      assert_non_fallible_ret!(fn_node, ret_zig)
      cycle_fns = mtp.cycle_fns

      variant_decls = cycle_fns.map { |cf|
        fields = (cf.params || []).map { |p|
          "#{p[:name]}: #{param_zig_type(p, lowering)},"
        }.join("\n            ")
        "#{cf.name}: struct {\n            #{fields}\n        },"
      }.join("\n        ")

      self_init_fields = (fn_node.params || []).map { |p|
        ".#{p[:name]} = #{p[:name]}"
      }.join(", ")

      switch_arms = cycle_fns.map { |cf|
        emit_mutual_arm(cf, mtp, ret_zig, lowering)
      }.join("\n                ")

      yield_line = fn_node.tight_reentrance ? "// (TIGHT: scheduler yield-check skipped)" : "rt.checkYield();"
      <<~ZIG
        const Frame = union(enum) {
            #{variant_decls}
        };
        var current: Frame = .{ .#{fn_node.name} = .{ #{self_init_fields} } };
        while (true) {
            #{yield_line}
            switch (current) {
                #{switch_arms}
            }
        }
      ZIG
    end

    # One switch arm: handle the variant whose payload is `cf`'s
    # params; emit base cases (early returns) and the tail
    # transition that overwrites `current` with the partner variant.
    def emit_mutual_arm(cf, _mtp, ret_zig, lowering)
      T.bind(self, T.untyped) rescue nil
      own_plan = cf.mutual_thunk_plan.own_plan

      base_branches = own_plan.base_cases.map { |bc|
        cond  = qualify_with_f(render_expr(bc[:cond_ast], lowering),  cf)
        value = qualify_with_f(render_expr(bc[:value_ast], lowering), cf)
        <<~ZIG.chomp
          if (#{cond}) {
                                return #{value};
                            }
        ZIG
      }.join("\n                        ")

      target_fn = own_plan.target_fn
      target_args = own_plan.target_args
      target_params = (find_cycle_member(cf, target_fn).params || [])
      raise "thunk: target arg/param count mismatch for '#{cf.name}' -> '#{target_fn}'" \
        if target_args.length != target_params.length
      arg_inits = target_args.each_with_index.map { |arg, i|
        rendered = qualify_with_f(render_expr(arg, lowering), cf)
        ".#{target_params[i][:name]} = #{rendered}"
      }.join(", ")
      _ = ret_zig

      <<~ZIG.chomp
        .#{cf.name} => |f| {
                        #{base_branches}
                        current = .{ .#{target_fn} = .{ #{arg_inits} } };
                        continue;
                    },
      ZIG
    end

    def find_cycle_member(cf, name)
      T.bind(self, T.untyped) rescue nil
      cf.mutual_thunk_plan.cycle_fns.find { |x| x.name == name } or
        raise "thunk: cycle member '#{name}' not found for '#{cf.name}'"
    end

    # Mutual variant: bare param refs become `f.<name>` (the switch
    # capture binds the active variant's payload to `f`).
    def qualify_with_f(zig_text, cf)
      T.bind(self, T.untyped) rescue nil
      out = zig_text.dup
      (cf.params || []).each do |p|
        name = p[:name]
        out = out.gsub(/(?<![A-Za-z0-9_.])#{Regexp.escape(name)}(?![A-Za-z0-9_])/, "f.#{name}")
      end
      out
    end

    # Phase 4d's stub for the legacy entry; kept so future wider-
    # shape passes have a consistent name.
    def build(segments, liveness, lowering, ctx)
      T.bind(self, T.untyped) rescue nil
      _ = segments
      _ = liveness
      _ = lowering
      _ = ctx
      nil
    end
  end
end
