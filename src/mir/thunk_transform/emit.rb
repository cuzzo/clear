# typed: strict
# thunk_transform/emit.rb -- Zig codegen for the simple-recurrence
# THUNK shape detected by Phase 4c.
#
# Builds a MIR::ThunkTrampoline statement for a function body. The
# emitter renders it as a local synchronous frame machine. Layout:
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
require_relative "../../backends/zig_type"
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
# heap-allocated child Frame on the error-return path. The
# `assert_non_fallible_ret!` guard at the builder entry points fails
# loudly if the invariant is ever violated.

require "sorbet-runtime"
require "set"
require_relative "../mir_emitter"

module ThunkTransform
  module Emit
    extend T::Sig
    module_function

    class FrameBindingContext < T::Struct
      extend T::Sig

      const :receiver_name, String
      const :param_names, T::Set[String]

      sig { params(name: String).returns(T::Boolean) }
      def binds?(name)
        param_names.include?(name)
      end

      sig { params(name: String).returns(MIR::FieldGet) }
      def field_ref(name)
        MIR::FieldGet.new(MIR::Ident.new(receiver_name), name)
      end

      sig { returns(T::Hash[String, String]) }
      def capture_map
        param_names.each_with_object({}) do |name, map|
          map[name] = "#{receiver_name}.#{name}"
        end
      end
    end

    # Map normalized op codes (from AST::OP_TO_OP_CODE) to Zig
    # operators. Phase 4c restricts to these four; Phase 4f-g may
    # widen if user demand emerges.
    OP_TO_ZIG = T.let({
      ADD: "+",
      SUB: "-",
      MUL: "*",
      DIV: "/",
    }.freeze, T::Hash[Symbol, String])

    # Synthesize a structural MIR trampoline body for a function whose
    # AST::FunctionDef has a thunk_plan (set by Phase 4c detection).
    sig { params(fn_node: AST::FunctionDef, lowering: Object).returns(MIR::ThunkTrampoline) }
    def build_trampoline(fn_node, lowering)
      plan = thunk_plan!(fn_node)
      ret_zig = ret_zig_type(fn_node, lowering)
      assert_non_fallible_ret!(fn_node, ret_zig)

      params = function_params(fn_node)
      param_field_decls = params.map { |p|
        "#{p[:name]}: #{param_zig_type(p, lowering)},"
      }

      param_init_fields = params.map { |p|
        ".#{p[:name]} = #{p[:name]}"
      }

      context = current_frame_context(fn_node)

      base_cases = plan.base_cases.map { |bc|
        cond  = render_expr(bc.cond_ast, lowering, context)
        value = render_expr(bc.value_ast, lowering, context)
        MIR::ThunkBaseCase.new(
          cond_zig: cond,
          value_zig: value,
        )
      }

      recurse_arg_inits = plan.recurse_args.each_with_index.map { |arg, i|
        param = params[i]
        Kernel.raise "thunk arg/param count mismatch in '#{fn_node.name}'" if param.nil?
        rendered = render_expr(arg, lowering, context)
        ".#{param[:name]} = #{rendered}"
      }

      combine_lhs_zig = render_expr(plan.combine_lhs, lowering, context)
      op_zig = OP_TO_ZIG.fetch(plan.combine_op) {
        Kernel.raise "thunk: unsupported op #{plan.combine_op}"
      }
      yield_line = fn_node.tight_reentrance ? "// (TIGHT: scheduler yield-check skipped)" : "rt.checkYield();"

      MIR::ThunkTrampoline.new(
        fn_node.name,
        ret_zig,
        param_field_decls,
        param_init_fields,
        base_cases,
        recurse_arg_inits,
        combine_lhs_zig,
        op_zig,
        yield_line
      )
    end

    # Lower an AST expression through the surrounding MIRLowering, rewrite
    # frame-bound param references structurally, then emit Zig from MIR.
    sig { params(ast_expr: AST::Node, lowering: Object, context: FrameBindingContext).returns(String) }
    def render_expr(ast_expr, lowering, context)
      lowering_api = T.unsafe(lowering)
      mir =
        if lowering_api.respond_to?(:with_fiber_capture_map)
          lowering_api.with_fiber_capture_map(context.capture_map) do
            lowering_api.lower(ast_expr)
          end
        else
          lowering_api.lower(ast_expr)
        end
      lowering_api.send(:emit_expr, bind_frame_refs(mir, context)).to_s
    end

    sig { params(fn_node: AST::FunctionDef).returns(FrameBindingContext) }
    def current_frame_context(fn_node)
      FrameBindingContext.new(receiver_name: "current", param_names: param_names(fn_node))
    end

    sig { params(fn_node: AST::FunctionDef).returns(FrameBindingContext) }
    def mutual_frame_context(fn_node)
      FrameBindingContext.new(receiver_name: "f", param_names: param_names(fn_node))
    end

    sig { params(fn_node: AST::FunctionDef).returns(T::Set[String]) }
    def param_names(fn_node)
      names = T.let(Set.new, T::Set[String])
      function_params(fn_node).each { |p| names << p[:name].to_s }
      names
    end

    sig { params(mir: MIR::Node, context: FrameBindingContext).returns(MIR::Node) }
    def bind_frame_refs(mir, context)
      case mir
      when MIR::Ident
        name = mir.name.to_s
        context.binds?(name) ? context.field_ref(name) : mir
      when MIR::BinOp
        MIR::BinOp.new(mir.op, bind_frame_refs(mir.left, context), bind_frame_refs(mir.right, context))
      when MIR::UnaryOp
        MIR::UnaryOp.new(mir.op, bind_frame_refs(mir.operand, context))
      when MIR::FieldGet
        MIR::FieldGet.new(bind_frame_refs(mir.object, context), mir.field)
      when MIR::IndexGet
        MIR::IndexGet.new(bind_frame_refs(mir.object, context), bind_frame_refs(mir.index, context))
      when MIR::MethodCall
        MIR::MethodCall.new(
          bind_frame_refs(mir.receiver, context),
          mir.method,
          mir.args.map { |arg| bind_frame_refs(arg, context) },
          mir.try_wrap,
          mir.callable_contract,
          mir.owned_result_alloc,
        )
      when MIR::Call
        MIR::Call.new(
          mir.callee,
          mir.args.map { |arg| bind_frame_refs(arg, context) },
          mir.try_wrap == true,
          mir.owned_return?,
          mir.callable_contract,
        )
      when MIR::Cast
        MIR::Cast.new(bind_frame_refs(mir.expr, context), mir.target_type, mir.method)
      when MIR::TryExpr
        MIR::TryExpr.new(bind_frame_refs(mir.expr, context))
      when MIR::TryCatch
        MIR::TryCatch.new(
          bind_frame_refs(mir.expr, context),
          bind_frame_refs(mir.catch_body, context),
          mir.capture,
        )
      when MIR::AddressOf
        MIR::AddressOf.new(bind_frame_refs(mir.expr, context))
      when MIR::Deref
        MIR::Deref.new(bind_frame_refs(mir.expr, context))
      when MIR::OptionalUnwrap
        MIR::OptionalUnwrap.new(bind_frame_refs(mir.expr, context))
      else
        mir
      end
    end

    sig { params(param: AST::Param, _lowering: Object).returns(String) }
    def param_zig_type(param, _lowering)
      type = param[:type]
      type.respond_to?(:zig_type) ? type.zig_type : type.to_s
    end

    sig { params(fn_node: AST::FunctionDef, _lowering: Object).returns(String) }
    def ret_zig_type(fn_node, _lowering)
      rt = fn_node.return_type
      return "void" if rt.nil?
      rt.respond_to?(:zig_type) ? rt.zig_type : rt.to_s
    end

    # Today's THUNK trampolines free heap-allocated child Frames only
    # on the normal return path. Two upstream
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
    sig { params(fn_node: AST::FunctionDef, ret_zig: String).returns(NilClass) }
    def assert_non_fallible_ret!(fn_node, ret_zig)
      return unless ZigType.new(ret_zig).inferred_error_union?
      Kernel.raise "INTERNAL: THUNK trampoline for '#{fn_node.name}' has fallible " \
            "return type (#{ret_zig.inspect}). The current codegen frees " \
            "heap-allocated child Frames only on the normal return path; an " \
            "error return would leak the in-flight chain. Before lifting the " \
            "non-fallible invariant, extend `build_trampoline` and " \
            "`build_mutual_trampoline` to emit an errdefer that walks " \
            "`current.parent` and frees every non-initial Frame."
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
    sig { params(fn_node: AST::FunctionDef, lowering: Object).returns(MIR::MutualThunkTrampoline) }
    def build_mutual_trampoline(fn_node, lowering)
      mtp = mutual_thunk_plan!(fn_node)

      ret_zig = ret_zig_type(fn_node, lowering)
      assert_non_fallible_ret!(fn_node, ret_zig)
      cycle_fns = mtp.cycle_fns

      variants = cycle_fns.map { |cf|
        {
          name: cf.name,
          param_field_decls: function_params(cf).map { |p|
            "#{p[:name]}: #{param_zig_type(p, lowering)},"
          },
        }
      }

      initial_fields = function_params(fn_node).map { |p|
        ".#{p[:name]} = #{p[:name]}"
      }

      arms = cycle_fns.map { |cf|
        build_mutual_arm(cf, mtp, ret_zig, lowering)
      }

      yield_line = fn_node.tight_reentrance ? "// (TIGHT: scheduler yield-check skipped)" : "rt.checkYield();"

      MIR::MutualThunkTrampoline.new(
        fn_node.name,
        ret_zig,
        variants,
        fn_node.name,
        initial_fields,
        arms,
        yield_line
      )
    end

    # One switch arm: handle the variant whose payload is `cf`'s
    # params; emit base cases (early returns) and the tail
    # transition that overwrites `current` with the partner variant.
    sig { params(cf: AST::FunctionDef, _mtp: ThunkTransform::RecursiveSplitter::MutualThunkPlan, ret_zig: String, lowering: Object).returns(MIR::MutualThunkArm) }
    def build_mutual_arm(cf, _mtp, ret_zig, lowering)
      own_plan = mutual_thunk_plan!(cf).own_plan
      context = mutual_frame_context(cf)

      base_cases = own_plan.base_cases.map { |bc|
        cond = render_expr(bc.cond_ast, lowering, context)
        value = render_expr(bc.value_ast, lowering, context)
        MIR::ThunkBaseCase.new(
          cond_zig: cond,
          value_zig: value,
        )
      }

      target_fn = own_plan.target_fn
      target_args = own_plan.target_args
      target_params = function_params(find_cycle_member(cf, target_fn))
      Kernel.raise "thunk: target arg/param count mismatch for '#{cf.name}' -> '#{target_fn}'" \
        if target_args.length != target_params.length
      arg_inits = target_args.each_with_index.map { |arg, i|
        rendered = render_expr(arg, lowering, context)
        target_param = target_params.fetch(i)
        ".#{target_param[:name]} = #{rendered}"
      }
      _ = ret_zig

      MIR::MutualThunkArm.new(
        variant_name: cf.name,
        base_cases: base_cases,
        target_variant: target_fn,
        target_arg_inits: arg_inits,
      )
    end

    sig { params(cf: AST::FunctionDef, name: String).returns(AST::FunctionDef) }
    def find_cycle_member(cf, name)
      mutual_thunk_plan!(cf).cycle_fns.find { |x| x.name == name } or
        Kernel.raise "thunk: cycle member '#{name}' not found for '#{cf.name}'"
    end

    sig { params(fn_node: AST::FunctionDef).returns(ThunkTransform::RecursiveSplitter::Plan) }
    def thunk_plan!(fn_node)
      plan = T.cast(fn_node.thunk_plan, T.nilable(ThunkTransform::RecursiveSplitter::Plan))
      Kernel.raise ArgumentError, "fn '#{fn_node.name}' has no thunk_plan" if plan.nil?
      plan
    end

    sig { params(fn_node: AST::FunctionDef).returns(ThunkTransform::RecursiveSplitter::MutualThunkPlan) }
    def mutual_thunk_plan!(fn_node)
      plan = T.cast(fn_node.mutual_thunk_plan, T.nilable(ThunkTransform::RecursiveSplitter::MutualThunkPlan))
      Kernel.raise ArgumentError, "fn '#{fn_node.name}' has no mutual_thunk_plan" if plan.nil?
      plan
    end

    sig { params(fn_node: AST::FunctionDef).returns(T::Array[AST::Param]) }
    def function_params(fn_node)
      fn_node.params
    end

  end
end
