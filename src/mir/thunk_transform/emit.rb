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

    end

    SUPPORTED_COMBINE_OPS = T.let(Set[:ADD, :SUB, :MUL, :DIV].freeze, T::Set[Symbol])

    # Synthesize a structural MIR trampoline body for a function whose
    # AST::FunctionDef has a thunk_plan (set by Phase 4c detection).
    sig { params(fn_node: AST::FunctionDef, lowering: Object).returns(MIR::ThunkTrampoline) }
    def build_trampoline(fn_node, lowering)
      plan = thunk_plan!(fn_node)
      return_type = return_type_info(fn_node, lowering)
      assert_non_fallible_ret!(fn_node, return_type)

      params = function_params(fn_node)
      param_fields = params.map { |p| frame_field(p[:name].to_s, param_type_info(p, lowering)) }

      param_init_fields = params.map { |p|
        frame_init(p[:name].to_s, MIR::Ident.new(p[:name].to_s))
      }

      context = current_frame_context(fn_node)

      base_cases = plan.base_cases.map { |bc|
        MIR::ThunkBaseCase.new(
          cond: lower_frame_expr(bc.cond_ast, lowering, context),
          value: lower_frame_expr(bc.value_ast, lowering, context),
        )
      }

      recurse_arg_inits = plan.recurse_args.each_with_index.map { |arg, i|
        param = params[i]
        Kernel.raise "thunk arg/param count mismatch in '#{fn_node.name}'" if param.nil?
        frame_init(param[:name].to_s, lower_frame_expr(arg, lowering, context))
      }

      combine_lhs = lower_frame_expr(plan.combine_lhs, lowering, context)
      validate_combine_op!(plan.combine_op)

      MIR::ThunkTrampoline.new(
        fn_name: fn_node.name,
        return_type: return_type,
        param_fields: param_fields,
        param_init_fields: param_init_fields,
        base_cases: base_cases,
        recurse_arg_inits: recurse_arg_inits,
        combine_lhs: combine_lhs,
        combine_op: plan.combine_op,
        yield_policy: fn_node.tight_reentrance ? :tight_skip : :check,
      )
    end

    # Lower an AST expression through the surrounding MIRLowering, rewrite
    # frame-bound param references structurally, and leave rendering to
    # MIREmitter.
    sig { params(ast_expr: AST::Node, lowering: Object, context: FrameBindingContext).returns(MIR::Node) }
    def lower_frame_expr(ast_expr, lowering, context)
      lowering_api = T.unsafe(lowering)
      mir = lowering_api.lower(ast_expr)
      bind_frame_refs(T.cast(mir, MIR::Node), context)
    end

    sig { params(field_name: String, value: MIR::Node).returns(MIR::ThunkFrameInit) }
    def frame_init(field_name, value)
      MIR::ThunkFrameInit.new(field_name: field_name, value: value)
    end

    sig { params(field_name: String, type_info: Type).returns(MIR::ThunkFrameField) }
    def frame_field(field_name, type_info)
      MIR::ThunkFrameField.new(name: field_name, type_info: type_info)
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
      when MIR::RegistryCall
        MIR::RegistryCall.new(
          entry: mir.entry,
          args: mir.args.map { |arg| MIR::RegistryCallArg.new(expr: bind_frame_refs(arg.expr, context), coerce_type: arg.coerce_type) },
          reason: mir.reason,
          ownership_contract: mir.ownership_contract,
          allocs: mir.allocs,
          target_var: mir.target_var,
          result_type: mir.result_type,
          result_ownership_bearing: mir.result_ownership_bearing,
          key_type: mir.key_type,
          value_type: mir.value_type,
          suppress_try: mir.suppress_try,
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

    sig { params(param: AST::Param, _lowering: Object).returns(Type) }
    def param_type_info(param, _lowering)
      type = param[:type]
      type.is_a?(Type) ? type : Type.new(type)
    end

    sig { params(fn_node: AST::FunctionDef, _lowering: Object).returns(Type) }
    def return_type_info(fn_node, _lowering)
      rt = fn_node.return_type
      return Type.new(:Void) if rt.nil?
      rt.is_a?(Type) ? rt : Type.new(rt)
    end

    sig { params(op: Symbol).returns(NilClass) }
    def validate_combine_op!(op)
      return if SUPPORTED_COMBINE_OPS.include?(op)
      Kernel.raise "thunk: unsupported op #{op}"
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
    sig { params(fn_node: AST::FunctionDef, return_type: Type).returns(NilClass) }
    def assert_non_fallible_ret!(fn_node, return_type)
      return_type_zig = return_type.zig_type
      return unless ZigType.new(return_type_zig).inferred_error_union?
      Kernel.raise "INTERNAL: THUNK trampoline for '#{fn_node.name}' has fallible " \
            "return type (#{return_type_zig.inspect}). The current codegen frees " \
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

      return_type = return_type_info(fn_node, lowering)
      assert_non_fallible_ret!(fn_node, return_type)
      cycle_fns = mtp.cycle_fns

      variants = cycle_fns.map { |cf|
        MIR::ThunkVariant.new(
          name: cf.name,
          param_fields: function_params(cf).map { |p| frame_field(p[:name].to_s, param_type_info(p, lowering)) },
        )
      }

      initial_fields = function_params(fn_node).map { |p|
        frame_init(p[:name].to_s, MIR::Ident.new(p[:name].to_s))
      }

      arms = cycle_fns.map { |cf|
        build_mutual_arm(cf, mtp, lowering)
      }

      MIR::MutualThunkTrampoline.new(
        fn_name: fn_node.name,
        return_type: return_type,
        variants: variants,
        initial_variant: fn_node.name,
        initial_fields: initial_fields,
        arms: arms,
        yield_policy: fn_node.tight_reentrance ? :tight_skip : :check,
      )
    end

    # One switch arm: handle the variant whose payload is `cf`'s
    # params; emit base cases (early returns) and the tail
    # transition that overwrites `current` with the partner variant.
    sig { params(cf: AST::FunctionDef, _mtp: ThunkTransform::RecursiveSplitter::MutualThunkPlan, lowering: Object).returns(MIR::MutualThunkArm) }
    def build_mutual_arm(cf, _mtp, lowering)
      own_plan = mutual_thunk_plan!(cf).own_plan
      context = mutual_frame_context(cf)

      base_cases = own_plan.base_cases.map { |bc|
        MIR::ThunkBaseCase.new(
          cond: lower_frame_expr(bc.cond_ast, lowering, context),
          value: lower_frame_expr(bc.value_ast, lowering, context),
        )
      }

      target_fn = own_plan.target_fn
      target_args = own_plan.target_args
      target_params = function_params(find_cycle_member(cf, target_fn))
      Kernel.raise "thunk: target arg/param count mismatch for '#{cf.name}' -> '#{target_fn}'" \
        if target_args.length != target_params.length
      arg_inits = target_args.each_with_index.map { |arg, i|
        target_param = target_params.fetch(i)
        frame_init(target_param[:name].to_s, lower_frame_expr(arg, lowering, context))
      }
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
