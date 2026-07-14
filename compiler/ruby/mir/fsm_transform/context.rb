# typed: strict

require "sorbet-runtime"
require "set"
require_relative "../../ast/type"
require_relative "lowering_protocol"
require_relative "../mir"

module FsmTransform
  CapturedMap = T.type_alias { T::Hash[String, Type] }
  TransformValue = T.type_alias do
    T.nilable(T.any(
      AST::BgBlock,
      String,
      Integer,
      Symbol,
      T::Boolean,
      CapturedMap,
      T::Hash[String, Schemas::ResourceClosePlan],
      T::Set[String],
      T::Array[MIR::ContextFieldDecl],
      T::Array[MIR::StructInitField],
      T::Array[String],
      T::Array[MIR::CaptureCleanupAction],
      T::Array[MIR::Emittable],
    ))
  end
  ContextMap = T.type_alias { T::Hash[Symbol, TransformValue] }
  LoweringApi = T.type_alias { FsmTransform::LoweringProtocol }
  BgBlockInput = T.type_alias { T.any(AST::BgBlock, Struct) }

  module Emit
    class FsmEmitContext < T::Struct
      extend T::Sig

      const :id, Integer
      const :bg_rt, String
      const :blk_label, String
      const :ctx_type, String
      const :promise_zig, String
      const :capture_fields, T::Array[MIR::ContextFieldDecl]
      const :alloc_var, String
      const :promise_var, String
      const :ctx_var, String
      const :rt_name, String
      const :promoted_decls, T::Array[MIR::Emittable]
      const :capture_inits, T::Array[MIR::StructInitField]
      const :captured, FsmTransform::CapturedMap
      const :capture_close_plans, T::Hash[String, Schemas::ResourceClosePlan]
      const :pointer_captures, T::Set[String]
      const :extra_ctx_fields, T::Array[MIR::ContextFieldDecl]
      const :recursive_promoted_names, T::Array[String]
      const :fresh_heap_cleanup_names, T::Array[String]
      const :capture_finalizers, T::Array[MIR::Emittable], factory: -> { [] }
      const :arena_init_flag, T::Boolean
      const :is_void, T::Boolean
      const :pin_mode, T.nilable(T.any(T::Boolean, Symbol))
      const :parallel, T::Boolean
      const :profile_site_id, T.nilable(Integer)
      const :profile_line, T.nilable(Integer)
      const :profile_column, T.nilable(Integer)
      prop :destroy_actions, T::Array[MIR::FsmDestroyAction], default: []

      sig { params(fields: T::Array[MIR::ContextFieldDecl]).returns(FsmEmitContext) }
      def with_extra_ctx_fields(fields)
        FsmEmitContext.new(
          id: id,
          bg_rt: bg_rt,
          blk_label: blk_label,
          ctx_type: ctx_type,
          promise_zig: promise_zig,
          capture_fields: capture_fields,
          alloc_var: alloc_var,
          promise_var: promise_var,
          ctx_var: ctx_var,
          rt_name: rt_name,
          promoted_decls: promoted_decls,
          capture_inits: capture_inits,
          captured: captured,
          capture_close_plans: capture_close_plans,
          pointer_captures: pointer_captures,
          extra_ctx_fields: fields,
          recursive_promoted_names: recursive_promoted_names,
          fresh_heap_cleanup_names: fresh_heap_cleanup_names,
          capture_finalizers: capture_finalizers,
          arena_init_flag: arena_init_flag,
          is_void: is_void,
          pin_mode: pin_mode,
          parallel: parallel,
          profile_site_id: profile_site_id,
          profile_line: profile_line,
          profile_column: profile_column,
          destroy_actions: destroy_actions,
        )
      end
    end
  end
end
