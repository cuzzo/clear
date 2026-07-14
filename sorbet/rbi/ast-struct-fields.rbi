# typed: true
# frozen_string_literal: true

class Lexer::Token
  sig { returns(Integer) }
  def column; end
  sig { returns(Integer) }
  def line; end
  sig { returns(Symbol) }
  def type; end
  sig { returns(T.any(Float, Integer, String)) }
  def value; end
end

class AST::Param
  sig { returns(Type) }
  def type; end
  sig { returns(SymbolEntry) }
  def symbol; end
  sig { returns(T::Boolean) }
  def takes; end
  sig { returns(String) }
  def name; end
  sig { returns(T.any(FalseClass, String, TrueClass)) }
  def mutable; end
  sig { returns(T::Boolean) }
  def required; end
  sig { returns(T::Boolean) }
  def comptime; end
  sig { returns(Symbol) }
  def sync; end
  sig { returns(Lexer::Token) }
  def name_token; end
end

class AST::Identifier
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(String) }
  def name; end
end

class AST::Literal
  sig { returns(Symbol) }
  def storage; end
  sig { returns(Symbol) }
  def type; end
end

class AST::DestructureTarget
  sig { returns(Type) }
  def type; end
  sig { returns(T::Boolean) }
  def mutable; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::StructField
  sig { returns(T::Boolean) }
  def borrowed; end
end

class AST::BinaryOp
  sig { returns(Symbol) }
  def op; end
  sig { returns(TrueClass) }
  def paren_bind; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::FunctionDef
  sig { returns(T::Array[AST::Param]) }
  def params; end
  sig { returns(T::Array[String]) }
  def type_params; end
  sig { returns(Type) }
  def return_type; end
  sig { returns(T::Boolean) }
  def uses_frame; end
  sig { returns(T::Boolean) }
  def tail_call; end
  sig { returns(T::Boolean) }
  def tight_reentrance; end
  sig { returns(T::Boolean) }
  def explicit_return_type; end
  sig { returns(Lexer::Token) }
  def return_type_token; end
  sig { returns(Lexer::Token) }
  def arrow_token; end
  sig { returns(Integer) }
  def max_depth_n; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def name_token; end
  sig { returns(T.any(Array, Type)) }
  def captures; end
  sig { returns(Symbol) }
  def effects_decl; end
  sig { returns(Symbol) }
  def visibility; end
  sig { returns(T::Boolean) }
  def is_method; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::LambdaLit
  sig { returns(T::Array[AST::Param]) }
  def params; end
end

class AST::BindExpr
  sig { returns(Type) }
  def type; end
  sig { returns(Symbol) }
  def compound_op; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::Lit
  sig { returns(T.any(Integer, String)) }
  def value; end
end

class MIR::Comment
  sig { returns(String) }
  def text; end
end

class MIR::OwnedCreate
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def source; end
  sig { returns(Type) }
  def type_info; end
end

class AST::FuncCall
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::Let
  sig { returns(Type) }
  def annotation; end
  sig { returns(T::Boolean) }
  def mutable; end
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def suppression; end
end

class BinaryOpResult
  sig { returns(Type) }
  def type; end
  sig { returns(String) }
  def error; end
  sig { returns(Symbol) }
  def left_coercion; end
  sig { returns(Symbol) }
  def right_coercion; end
  sig { returns(Symbol) }
  def storage; end
end

class AST::Assert
  sig { returns(AST::Node) }
  def condition; end
  sig { returns(T.any(String, Symbol)) }
  def message; end
  sig { returns(Lexer::Token) }
  def token; end
end

class FsmOps::StateField
  sig { returns(String) }
  def name; end
end

class AST::MethodCall
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::GetField
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::VarDecl
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(T::Boolean) }
  def mutable; end
  sig { returns(String) }
  def name; end
end

class AST::ReturnNode
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::Capture
  sig { returns(Type) }
  def type; end
  sig { returns(T::Boolean) }
  def comptime; end
  sig { returns(T::Boolean) }
  def mutable; end
  sig { returns(T::Boolean) }
  def takes; end
  sig { returns(Symbol) }
  def storage; end
  sig { returns(AST::Node) }
  def default; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def name_token; end
end

class MIR::FieldGet
  sig { returns(MIR::Node) }
  def object; end
  sig { returns(T.any(String, Symbol)) }
  def field; end
end

class MIR::Set
  sig { returns(MIR::Node) }
  def target; end
  sig { returns(FalseClass) }
  def needs_field_cleanup; end
  sig { returns(MIR::Node) }
  def value; end
end

class MIR::AllocMark
  sig { returns(Symbol) }
  def scope; end
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def name; end
  sig { returns(Type) }
  def type_info; end
end

class MIR::OwnedDestroy
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def source; end
end

class AST::StructLit
  sig { returns(Symbol) }
  def storage; end
  sig { returns(T.any(String, Type)) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::Ident
  sig { returns(String) }
  def name; end
end

class MIR::ForStmt
  sig { returns(String) }
  def capture; end
end

class MIR::Call
  sig { returns(T::Boolean) }
  def try_wrap; end
  sig { returns(String) }
  def callee; end
  sig { returns(T::Boolean) }
  def owned_return; end
end

class AST::Capability
  sig { returns(Type) }
  def resolved_type; end
  sig { returns(Scope) }
  def old_scope; end
  sig { returns(Symbol) }
  def capability; end
  sig { returns(T::Boolean) }
  def alias_mutable; end
  sig { returns(AST::Node) }
  def var_node; end
  sig { returns(String) }
  def alias; end
  sig { returns(AST::Node) }
  def guard_expr; end
  sig { returns(Lexer::Token) }
  def snapshot_token; end
  sig { returns(Lexer::Token) }
  def view_token; end
end

class AST::Program
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::Cleanup
  sig { returns(String) }
  def name; end
end

class MIR::TransferMark
  sig { returns(String) }
  def name; end
  sig { returns(Symbol) }
  def target; end
  sig { returns(Symbol) }
  def target_alloc; end
end

class MIR::IfStmt
  sig { returns(MIR::Node) }
  def cond; end
end

class MIR::BinOp
  sig { returns(MIR::Node) }
  def left; end
  sig { returns(MIR::Node) }
  def right; end
  sig { returns(String) }
  def op; end
end

class MIR::ExprStmt
  sig { returns(MIR::Node) }
  def expr; end
  sig { returns(T::Boolean) }
  def discard; end
end

class MIR::OwnedTransfer
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def source; end
  sig { returns(Symbol) }
  def target; end
end

class MIR::MethodCall
  sig { returns(T::Array[MIR::Node]) }
  def args; end
  sig { returns(MIR::Node) }
  def receiver; end
  sig { returns(String) }
  def method; end
  sig { returns(Symbol) }
  def owned_result_alloc; end
  sig { returns(T::Boolean) }
  def try_wrap; end
end

class MIR::MoveMark
  sig { returns(String) }
  def name; end
end

class AST::ListLit
  sig { returns(Symbol) }
  def storage; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::Param
  sig { returns(String) }
  def name; end
  sig { returns(T::Boolean) }
  def pointer_passed; end
  sig { returns(String) }
  def zig_type; end
end

class FsmOps::CallExpr
  sig { returns(FsmOps::FunctionPath) }
  def fn; end
  sig { returns(T::Array[T.any(FsmOps::AddrOf, FsmOps::ArgRef, FsmOps::StateField)]) }
  def args; end
  sig { returns(T::Boolean) }
  def is_try; end
end

class MIR::TypeAlias
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def target; end
end

class FsmOps::AssignField
  sig { returns(String) }
  def field; end
end

class AST::IfStatement
  sig { returns(T::Boolean) }
  def comptime; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::GetIndex
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::MatchCase
  sig { returns(T::Boolean) }
  def indirect_payload_as; end
  sig { returns(T::Array[AST::Node]) }
  def extra_values; end
  sig { returns(Symbol) }
  def kind; end
end

class MIR::FnDef
  sig { returns(T::Array[MIR::Node]) }
  def body; end
  sig { returns(T::Boolean) }
  def can_fail; end
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def ret_type; end
  sig { returns(Symbol) }
  def visibility; end
end

class MIR::WhileStmt
  sig { returns(MIR::Node) }
  def cond; end
  sig { returns(T::Array[MIR::Node]) }
  def body; end
  sig { returns(MIR::Node) }
  def update; end
  sig { returns(T::Boolean) }
  def tight; end
  sig { returns(String) }
  def capture; end
  sig { returns(T::Boolean) }
  def mark_per_iter; end
end

class FsmOps::ArgRef
  sig { returns(Integer) }
  def idx; end
end

class StdLibTypeBinding
  sig { returns(Proc) }
  def schema_factory; end
end

class AST::BgBlock
  sig { returns(T::Array[AST::Node]) }
  def body; end
  sig { returns(T.any(FalseClass, Symbol, TrueClass)) }
  def pinned; end
  sig { returns(T::Boolean) }
  def arena_mode; end
  sig { returns(T::Boolean) }
  def can_smash; end
  sig { returns(T::Boolean) }
  def parallel; end
  sig { returns(Symbol) }
  def stack_size; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::StructInit
  sig { returns(T.any(Array, Hash)) }
  def fields; end
  sig { returns(String) }
  def zig_type; end
end

class MIR::Import
  sig { returns(String) }
  def module_path; end
  sig { returns(String) }
  def alias_name; end
  sig { returns(String) }
  def member; end
end

class AST::StructDef
  sig { returns(T::Array[String]) }
  def type_params; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(Symbol) }
  def visibility; end
end

class MIR::Undef
  sig { returns(String) }
  def zig_type; end
end

class AST::Assignment
  sig { returns(Symbol) }
  def compound_op; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::NextExpr
  sig { returns(AST::Node) }
  def expr; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::WithBlock
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::Suppress
  sig { returns(String) }
  def name; end
end

class MIR::ScopeBlock
  sig { returns(T::Array[MIR::Node]) }
  def body; end
end

class MIR::DeepCopy
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(MIR::Node) }
  def source; end
  sig { returns(Symbol) }
  def copy_shape; end
  sig { returns(String) }
  def elem_type; end
  sig { returns(Symbol) }
  def strategy; end
  sig { returns(String) }
  def zig_type; end
end

class MIR::FieldDef
  sig { returns(MIR::Node) }
  def default; end
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def zig_type; end
end

class FsmOps::SubField
  sig { returns(FsmOps::StateField) }
  def base; end
  sig { returns(String) }
  def name; end
end

class FsmOps::StmtCall
  sig { returns(FsmOps::FunctionPath) }
  def fn; end
  sig { returns(T::Boolean) }
  def is_try; end
end

class MIR::FsmCtxStruct
  sig { returns(T::Array[String]) }
  def promoted_field_decls; end
end

class MIR::FsmStateArm
  sig { returns(T.nilable(MIR::FsmTailCondSkip)) }
  def pre_body_skip; end
  sig { returns(T::Array[MIR::Emittable]) }
  def pre_body_stmts; end
  sig { returns(T::Array[MIR::Emittable]) }
  def err_cleanups; end
end

class MIR::CatchWrapper
  sig { returns(T::Array[MIR::CatchReassign]) }
  def error_reassigns; end
end

class MIR::SortedLockAcquire
  sig { returns(T.nilable(MIR::FailureAction)) }
  def action; end
end

class AST::ExternStructDecl
  sig { returns(T.nilable(String)) }
  def from_module; end
end

class AST::OrElseExit
  sig { returns(T.nilable(Symbol)) }
  def kind; end
  sig { returns(T.nilable(String)) }
  def error_name; end
end

class AST::Raise
  sig { returns(T.nilable(String)) }
  def error_name; end
end

class AST::Require
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(String) }
  def path; end
end

class AST::Param
  sig { returns(T.nilable(AST::Locatable)) }
  def default; end
end

class AST::Literal
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::UnionVariantLit
  sig { returns(T::Hash[String, AST::Node]) }
  def fields; end
end

class LSP::AnalysisResult
  sig { returns(T.nilable(LSP::Analyzer::SyntheticFinding)) }
  def fatal_error; end
end

class LSP::Analyzer::SyntheticFinding
  sig { returns(T::Array[Fix]) }
  def fixes; end
end

class AST::ExternFnDecl
  sig { returns(FunctionSignature::ExternEffects) }
  def effects; end
end

class AST::BatchWindowOp
  sig { returns(T::Hash[String, AST::Node]) }
  def options; end
end

class AST::ConcurrentOp
  sig { returns(T::Hash[String, AST::Node]) }
  def options; end
end

class MIR::SnapshotTransaction
  sig { returns(T.nilable(MIR::FailureAction)) }
  def conflict_action; end
  sig { returns(T.nilable(Integer)) }
  def retries; end
end

class MIR::SnapshotMultiTxn
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(T.nilable(MIR::FailureAction)) }
  def conflict_action; end
  sig { returns(T.nilable(Integer)) }
  def retries; end
  sig { returns(T.nilable(String)) }
  def with_label; end
end

class MIR::MethodCall
  sig { returns(T.nilable(MIR::CallableContract)) }
  def callable_contract; end
end

class MIR::TailCall
  sig { returns(T.nilable(MIR::CallableContract)) }
  def callable_contract; end
end

class MIR::IfChain
  sig { returns(T.nilable(T::Array[MIR::Emittable])) }
  def default_body; end
end

class MIR::UnionMatchStmt
  sig { returns(T.nilable(T::Array[MIR::Emittable])) }
  def default_body; end
end

class FsmTransform::Segments::Segment
  sig { returns(Integer) }
  def index; end
  sig { returns(T::Array[T.any(AST::Node, MIR::Node)]) }
  def stmts; end
end

class MIR::BlockExpr
  sig { returns(T::Array[MIR::Node]) }
  def body; end
  sig { returns(String) }
  def label; end
end

class MIR::ConcatStr
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(T::Array[MIR::Node]) }
  def parts; end
  sig { returns(String) }
  def rt_expr; end
end

class MIR::ContainerInit
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(Integer) }
  def capacity; end
  sig { returns(Symbol) }
  def strategy; end
  sig { returns(String) }
  def zig_type; end
end

class MIR::Cast
  sig { returns(MIR::Node) }
  def expr; end
  sig { returns(Symbol) }
  def method; end
  sig { returns(String) }
  def target_type; end
end

class AST::CapabilityWrap
  sig { returns(Integer) }
  def lock_rank; end
  sig { returns(Symbol) }
  def layout; end
  sig { returns(Symbol) }
  def ownership; end
  sig { returns(Symbol) }
  def sync; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::CopyNode
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(AST::Node) }
  def value; end
end

class MIR::AssertStmt
  sig { returns(MIR::Node) }
  def cond; end
  sig { returns(String) }
  def message; end
end

class MIR::DupeSlice
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(MIR::Node) }
  def source; end
end

class AST::ForRange
  sig { returns(T::Boolean) }
  def mark_per_iter; end
  sig { returns(AST::Node) }
  def end_expr; end
  sig { returns(AST::Node) }
  def start_expr; end
  sig { returns(TrueClass) }
  def tight; end
  sig { returns(T::Boolean) }
  def inclusive; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(String) }
  def var_name; end
end

class MIR::ErrCleanup
  sig { returns(CleanupEntry) }
  def cleanup_entry; end
  sig { returns(String) }
  def name; end
end

class MIR::AddressOf
  sig { returns(MIR::Node) }
  def expr; end
end

class FsmOps::IntCast
  sig { returns(T.any(FsmOps::ArgRef, FsmOps::CallExpr, FsmOps::SubField)) }
  def expr; end
  sig { returns(String) }
  def zig_type; end
end

class FsmOps::IoSubmit
  sig { returns(T::Array[T.any(FsmOps::ArgRef, FsmOps::StateField)]) }
  def extra_args; end
  sig { returns(Symbol) }
  def verb; end
  sig { returns(FsmOps::StateField) }
  def waiter; end
end

class FsmOps::ErrDeferCall
  sig { returns(FsmOps::FunctionPath) }
  def fn; end
  sig { returns(T::Array[FsmOps::StateField]) }
  def args; end
end

class FsmOps::IfFieldSubLtZeroReturnCall
  sig { returns(String) }
  def field; end
  sig { returns(T::Array[FsmOps::SubField]) }
  def return_args; end
  sig { returns(FsmOps::FunctionPath) }
  def return_fn; end
  sig { returns(String) }
  def sub; end
end

class MIR::ReassignPlan
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def zig_type; end
end

class Capabilities::Conflict
  sig { returns(T::Array[Symbol]) }
  def set_a; end
  sig { returns(T::Array[Symbol]) }
  def set_b; end
end

class AST::MatchStatement
  sig { returns(T::Array[AST::MatchCase]) }
  def cases; end
end

class AST::IfBind
  sig { returns(T::Array[AST::Binding]) }
  def bindings; end
end

class AST::StructPattern
  sig { returns(T::Array[AST::PatternField]) }
  def fields; end
end

class AST::DoBlock
  sig { returns(T::Array[AST::DoBranch]) }
  def branches; end
end

class AST::ThenChain
  sig { returns(T::Array[AST::ThenStep]) }
  def steps; end
end

class AST::Slice
  sig { returns(T.any(AST::GetIndex, AST::Identifier)) }
  def target; end
end

class AST::ExternFnDecl
  sig { returns(String) }
  def from_module; end
end

class AST::WhenBlock
  sig { returns(T::Array[T.any(AST::BindExpr, AST::PassStmt, AST::StubDecl)]) }
  def setup; end
end

class MIR::ShardedMapPut
  sig { returns(MIR::InlineAllocMetadata) }
  def resolved_allocs; end
end

class MIR::FsmB1Body
  sig { returns(MIR::FsmB1CtxStruct) }
  def ctx_struct; end
end

class LSP::AnalysisResult
  sig { returns(T::Array[T.any(FixableFinding, LSP::Analyzer::SyntheticFinding)]) }
  def findings; end
end

class MIR::FnDef
  sig { returns(T::Array[String]) }
  def comptime_params; end
end

class MIR::StructDef
  sig { returns(T::Array[MIR::FnDef]) }
  def methods; end
end

class MIR::Let
  sig { returns(MIR::Emittable) }
  def init; end
  sig { returns(T.nilable(T::Boolean)) }
  def alias_safe; end
end

class MIR::IfStmt
  sig { returns(T::Array[MIR::Emittable]) }
  def then_body; end
  sig { returns(T.nilable(T::Array[MIR::Emittable])) }
  def else_body; end
end

class MIR::IfBindStmt
  sig { returns(T::Array[MIR::Emittable]) }
  def then_body; end
  sig { returns(T.nilable(T::Array[MIR::Emittable])) }
  def else_body; end
end

class MIR::ForStmt
  sig { returns(MIR::Emittable) }
  def iter; end
end

class MIR::SwitchStmt
  sig { returns(T.nilable(T::Array[MIR::Emittable])) }
  def default_body; end
end

class MIR::ReturnStmt
  sig { returns(T.nilable(MIR::Emittable)) }
  def value; end
end

class MIR::BreakStmt
  sig { returns(T.nilable(MIR::Emittable)) }
  def value; end
end

class MIR::BgBlock
  sig { returns(T::Hash[String, Type]) }
  def captures; end
  sig { returns(T.nilable(MIR::FsmStructure)) }
  def fsm_structure; end
end

class MIR::StreamSpawn
  sig { returns(T::Hash[String, Type]) }
  def captures; end
end

class MIR::Call
  sig { returns(T::Array[MIR::Emittable]) }
  def args; end
  sig { returns(T.nilable(MIR::CallableContract)) }
  def callable_contract; end
end

class MIR::RuntimeCall
  sig { returns(T::Array[MIR::Emittable]) }
  def args; end
end

class MIR::ArrayInit
  sig { returns(T::Array[MIR::Emittable]) }
  def items; end
end

class MIR::TryCatch
  sig { returns(MIR::Emittable) }
  def catch_body; end
end

class MIR::LambdaExpr
  sig { returns(T.nilable(T::Array[String])) }
  def captures; end
end

class CompilerFrontend::Result
  sig { returns(T::Hash[String, AST::FunctionDef]) }
  def fn_nodes; end
  sig { returns(T::Hash[String, FunctionSignature]) }
  def fn_sigs; end
  sig { returns(T::Hash[Symbol, Schemas::StructSchema]) }
  def struct_schemas; end
  sig { returns(T::Hash[Symbol, MIRLoweringSchemas::EnumVariants]) }
  def enum_schemas; end
  sig { returns(T::Hash[Symbol, Schemas::UnionSchema]) }
  def union_schemas; end
  sig { returns(MIRLoweringInput::MovedGuardInfo) }
  def moved_guard_info; end
end

class ModuleImporter::CompiledModule
  sig { returns(AST::Program) }
  def ast; end
  sig { returns(T::Hash[Symbol, Schemas::StructSchema]) }
  def struct_schemas; end
  sig { returns(T::Hash[Symbol, Schemas::UnionSchema]) }
  def union_schemas; end
  sig { returns(T::Hash[Symbol, MIRLoweringSchemas::EnumVariants]) }
  def enum_schemas; end
  sig { returns(T::Array[MIR::Emittable]) }
  def mir_items; end
  sig { returns(T::Array[MIR::Emittable]) }
  def type_items; end
end

class FsmTransform::Liveness::Result
  sig { returns(T::Hash[String, FsmTransform::Liveness::CrossSegmentVarFact]) }
  def cross_segment_vars; end
end

class FsmTransform::Segments::IoSuspend
  sig { returns(T.any(AST::FuncCall, AST::MethodCall)) }
  def call_node; end
  sig { returns(FunctionSignature) }
  def stdlib_def; end
end

class FsmTransform::Segments::LockSuspend
  sig { returns(AST::WithBlock) }
  def with_node; end
  sig { returns(FsmTransform::Segments::LockCap) }
  def cap; end
end

class FsmOps::AssignField
  sig { returns(FsmOps::Expr) }
  def value; end
end

class FsmOps::StmtCall
  sig { returns(T::Array[FsmOps::Expr]) }
  def args; end
end


class MIR::OwnedStore
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def source; end
  sig { returns(String) }
  def target; end
end

class AST::WhileLoop
  sig { returns(TrueClass) }
  def tight; end
  sig { returns(Lexer::Token) }
  def token; end
end

class CompilerFrontend::Result
  sig { returns(SemanticAnnotator) }
  def annotator; end
  sig { returns(AST::Program) }
  def ast; end
end

class AST::MatchStatement
  sig { returns(AST::Node) }
  def expr; end
  sig { returns(T::Boolean) }
  def exhaustive; end
  sig { returns(T::Boolean) }
  def takes; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::FsmStateArm
  sig { returns(String) }
  def body_fn_name; end
  sig { returns(Integer) }
  def index; end
end

class AST::UnionDef
  sig { returns(T::Array[String]) }
  def type_params; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(Symbol) }
  def visibility; end
end

class MIR::BgBlock
  sig { returns(T::Array[MIR::Node]) }
  def run_body; end
  sig { returns(MIR::Node) }
  def code; end
end

class AST::UnaryOp
  sig { returns(AST::Node) }
  def right; end
  sig { returns(Symbol) }
  def op; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::RangeLit
  sig { returns(AST::Node) }
  def start; end
  sig { returns(AST::Node) }
  def finish; end
  sig { returns(T::Boolean) }
  def inclusive; end
  sig { returns(Lexer::Token) }
  def token; end
end

class FsmTransform::Segments::Goto
  sig { returns(Integer) }
  def target_index; end
end

class MIR::BreakStmt
  sig { returns(String) }
  def label; end
end

class MIR::UnionMatchStmt
  sig { returns(MIR::Node) }
  def subject; end
  sig { returns(T::Array[MIR::UnionMatchArm]) }
  def arms; end
end

class AST::Binding
  sig { returns(Type) }
  def unwrapped_type; end
  sig { returns(SymbolEntry) }
  def symbol; end
  sig { returns(Symbol) }
  def predicate; end
  sig { returns(AST::Node) }
  def expr; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def name_token; end
  sig { returns(String) }
  def capture; end
end

class MIR::FsmMemberFn
  sig { returns(String) }
  def bg_rt; end
  sig { returns(T::Array[MIR::Node]) }
  def body_stmts; end
  sig { returns(Integer) }
  def ctx_id; end
  sig { returns(T::Array[MIR::Node]) }
  def extra_prologue_stmts; end
  sig { returns(String) }
  def fn_name; end
  sig { returns(T::Boolean) }
  def suppress_runtime_ref; end
end

class MIR::StructDef
  sig { returns(String) }
  def name; end
  sig { returns(Symbol) }
  def visibility; end
  sig { returns(T::Array[MIR::FieldDef]) }
  def fields; end
end

class MIR::DeferStmt
  sig { returns(T.any(Array, MIR::Node)) }
  def body; end
end

class AST::YieldExpr
  sig { returns(AST::Node) }
  def expr; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::ForStmt
  sig { returns(T::Array[MIR::Node]) }
  def body; end
  sig { returns(String) }
  def index_capture; end
  sig { returns(T::Boolean) }
  def mark_per_iter; end
  sig { returns(T::Boolean) }
  def tight; end
end

class MIR::ArrayInit
  sig { returns(T.any(Integer, String)) }
  def count; end
  sig { returns(String) }
  def elem_type; end
end

class AST::HashLit
  sig { returns(Symbol) }
  def storage; end
  sig { returns(Lexer::Token) }
  def token; end
end

class FsmOps::LocalRef
  sig { returns(String) }
  def name; end
end

class FsmOps::AllocExpr
  sig { returns(FsmOps::LocalRef) }
  def count; end
  sig { returns(String) }
  def elem_type; end
end

class FsmOps::ErrDeferFreeField
  sig { returns(String) }
  def field; end
end

class FsmOps::DeferFreeField
  sig { returns(String) }
  def field; end
end

class FsmOps::SliceUntilIntCast
  sig { returns(FsmOps::StateField) }
  def base; end
  sig { returns(FsmOps::SubField) }
  def end_expr; end
end

class FsmOps::LetConst
  sig { returns(String) }
  def name; end
  sig { returns(FsmOps::IntCast) }
  def value; end
  sig { returns(String) }
  def zig_type; end
end

class FsmOps::BinOp
  sig { returns(FsmOps::CallExpr) }
  def left; end
  sig { returns(String) }
  def op; end
  sig { returns(FsmOps::IntCast) }
  def right; end
end

class Capabilities::Conflict
  sig { returns(String) }
  def message; end
  sig { returns(T::Array[Symbol]) }
  def set_a; end
  sig { returns(T::Array[Symbol]) }
  def set_b; end
end

class AST::BgStreamBlock
  sig { returns(T::Array[AST::Node]) }
  def body; end
  sig { returns(Symbol) }
  def stack_size; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::OrElseRaise
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::TestThat
  sig { returns(T::Array[AST::Node]) }
  def body; end
  sig { returns(String) }
  def description; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::ReassignWithCleanup
  sig { returns(MIR::Node) }
  def value; end
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def zig_type; end
end

class MIR::OwnedReturn
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def source; end
end

class MIR::TupleLiteral
  sig { returns(T::Array[MIR::Node]) }
  def items; end
end

class MIR::CapWrap
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(MIR::Node) }
  def inner; end
  sig { returns(String) }
  def own_fn; end
  sig { returns(Symbol) }
  def strategy; end
  sig { returns(String) }
  def sync_fn; end
  sig { returns(String) }
  def sync_type; end
  sig { returns(String) }
  def zig_base; end
end

class MIR::Orelse
  sig { returns(MIR::Node) }
  def expr; end
  sig { returns(MIR::Node) }
  def fallback; end
end

class AST::StringConcat
  sig { returns(T::Array[AST::Node]) }
  def parts; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::FsmTailJump
  sig { returns(Integer) }
  def next_step; end
end

class AST::SumOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::FrameSave
  sig { returns(String) }
  def rt_expr; end
end

class AST::ConcurrentOp
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::FrameRestore
  sig { returns(String) }
  def rt_expr; end
end

class AST::EachOp
  sig { returns(T::Array[AST::Node]) }
  def body; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::IndexGet
  sig { returns(MIR::Node) }
  def index; end
  sig { returns(MIR::Node) }
  def object; end
end

class MIR::UnaryOp
  sig { returns(String) }
  def op; end
  sig { returns(MIR::Node) }
  def operand; end
end

class MIR::AllocatorRef
  sig { returns(Symbol) }
  def kind; end
end

class MIR::FsmStructure
  sig { returns(T::Array[MIR::Node]) }
  def captures; end
  sig { returns(T::Array[String]) }
  def finalize_cleanups; end
  sig { returns(T::Array[MIR::Node]) }
  def state_fields; end
  sig { returns(Integer) }
  def ctx_id; end
  sig { returns(String) }
  def result_aliases_finalized; end
  sig { returns(T::Array[MIR::Node]) }
  def steps; end
end

class AST::SelectOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::OptionalUnwrap
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::WhereOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::MakeList
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def elem_type; end
  sig { returns(T::Array[MIR::Node]) }
  def items; end
end

class MIR::TryExpr
  sig { returns(MIR::Node) }
  def expr; end
end

class MIR::ShardedMapPut
  sig { returns(MIR::Node) }
  def key; end
  sig { returns(MIR::Node) }
  def target; end
  sig { returns(MIR::Node) }
  def value; end
  sig { returns(Type) }
  def key_type; end
  sig { returns(Symbol) }
  def map_kind; end
  sig { returns(MIR::Node) }
  def shard_idx; end
  sig { returns(MIR::Node) }
  def shard_key; end
  sig { returns(FunctionSignature) }
  def stdlib_def; end
  sig { returns(String) }
  def target_var; end
  sig { returns(IntrinsicTemplateKind) }
  def template_kind; end
  sig { returns(Type) }
  def value_type; end
end

class MIR::FsmSpawnSetup
  sig { returns(MIR::Node) }
  def alloc_expr; end
  sig { returns(String) }
  def alloc_var; end
  sig { returns(T::Array[MIR::Node]) }
  def ctx_init_fields; end
  sig { returns(String) }
  def ctx_type; end
  sig { returns(String) }
  def ctx_var; end
  sig { returns(Integer) }
  def profile_dispatch_id; end
  sig { returns(Integer) }
  def profile_site_id; end
  sig { returns(String) }
  def promise_var; end
  sig { returns(String) }
  def promise_zig; end
  sig { returns(T::Array[MIR::Node]) }
  def promoted_decls; end
  sig { returns(String) }
  def rt_name; end
  sig { returns(MIR::Node) }
  def spawn_call; end
end

class MIR::FsmDispatch
  sig { returns(T::Array[MIR::Node]) }
  def arms; end
  sig { returns(Integer) }
  def ctx_id; end
  sig { returns(T::Boolean) }
  def uses_loop_label; end
end

class MIR::FsmGenericBody
  sig { returns(String) }
  def blk_label; end
  sig { returns(MIR::Node) }
  def spawn_setup; end
  sig { returns(MIR::FsmGenericCtxStruct) }
  def ctx_struct; end
end

class MIR::FsmGenericCtxStruct
  sig { returns(T::Array[MIR::Node]) }
  def capture_fields; end
  sig { returns(T::Array[MIR::Node]) }
  def extra_field_decls; end
  sig { returns(T::Array[MIR::Node]) }
  def member_fns; end
  sig { returns(String) }
  def promise_zig; end
  sig { returns(T::Array[MIR::Node]) }
  def promoted_field_decls; end
  sig { returns(String) }
  def type_name; end
end

class MIR::TryCatch
  sig { returns(String) }
  def capture; end
  sig { returns(MIR::Node) }
  def expr; end
end

class MIR::Pipeline
  sig { returns(MIR::Node) }
  def inner; end
  sig { returns(AST::Node) }
  def ast_node; end
  sig { returns(Symbol) }
  def sink_alloc; end
  sig { returns(Symbol) }
  def source_type; end
end

class MIR::ListLength
  sig { returns(MIR::Node) }
  def expr; end
end

class AST::Raise
  sig { returns(Symbol) }
  def kind; end
  sig { returns(AST::Node) }
  def message_expr; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::IfBind
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::OrElseExit
  sig { returns(AST::Node) }
  def message; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::CatchClause
  sig { returns(T::Array[Symbol]) }
  def kinds; end
  sig { returns(T::Array[String]) }
  def types; end
  sig { returns(T::Array[AST::Node]) }
  def filter_messages; end
  sig { returns(T::Array[String]) }
  def filter_types; end
  sig { returns(T::Array[AST::Node]) }
  def body; end
end

class AST::ForEach
  sig { returns(T::Array[AST::Node]) }
  def body; end
  sig { returns(T::Boolean) }
  def is_mutable; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(String) }
  def var_name; end
end

class AST::WhenBlock
  sig { returns(T::Array[AST::Node]) }
  def benchmarks; end
  sig { returns(String) }
  def description; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(T::Array[AST::TestThat]) }
  def tests; end
end

class MIR::CapabilityLockTarget
  sig { returns(T::Boolean) }
  def arc_wrapped; end
  sig { returns(T::Boolean) }
  def comptime_arc_unwrap; end
  sig { returns(MIR::Node) }
  def source; end
end

class MIR::RcRelease
  sig { returns(MIR::Node) }
  def alloc; end
  sig { returns(String) }
  def func; end
  sig { returns(MIR::Node) }
  def source; end
  sig { returns(String) }
  def zig_base; end
end

class MIR::ReassignMark
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def name; end
end

class AST::UnionVariantLit
  sig { returns(Symbol) }
  def storage; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(String) }
  def union_name; end
  sig { returns(String) }
  def variant_name; end
end

class MIR::ShardedMapGet
  sig { returns(MIR::Node) }
  def key; end
  sig { returns(MIR::Node) }
  def target; end
  sig { returns(Type) }
  def key_type; end
  sig { returns(Symbol) }
  def map_kind; end
  sig { returns(MIR::InlineAllocMetadata) }
  def resolved_allocs; end
  sig { returns(MIR::Node) }
  def shard_idx; end
  sig { returns(MIR::Node) }
  def shard_key; end
  sig { returns(FunctionSignature) }
  def stdlib_def; end
  sig { returns(IntrinsicTemplateKind) }
  def template_kind; end
  sig { returns(Type) }
  def value_type; end
end

class MIR::ItemsAccess
  sig { returns(MIR::Node) }
  def expr; end
  sig { returns(T::Boolean) }
  def safe; end
end

class MIR::LockAcquire
  sig { returns(T::Boolean) }
  def fallible; end
  sig { returns(MIR::Node) }
  def lock_expr; end
  sig { returns(Symbol) }
  def lock_sync; end
end

class AST::ExternFnDecl
  sig { returns(T::Array[Symbol]) }
  def fn_type_params; end
  sig { returns(T::Array[Symbol]) }
  def owner_type_params; end
  sig { returns(T::Array[AST::Param]) }
  def params; end
  sig { returns(Type) }
  def return_type; end
  sig { returns(String) }
  def owner_type; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::CatchItem
  sig { returns(Symbol) }
  def form; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::SnapshotRead
  sig { returns(T::Array[MIR::Node]) }
  def body; end
  sig { returns(MIR::Node) }
  def cell_unwrap; end
  sig { returns(String) }
  def alias_name; end
  sig { returns(String) }
  def guard_var; end
  sig { returns(String) }
  def rt; end
end

class FsmTransform::Segments::NextSuspend
  sig { returns(AST::Node) }
  def promise_ast; end
  sig { returns(String) }
  def result_var; end
  sig { returns(Integer) }
  def next_index; end
end

class MIR::IfOptional
  sig { returns(MIR::Node) }
  def optional; end
  sig { returns(MIR::Node) }
  def else_expr; end
  sig { returns(MIR::Node) }
  def then_expr; end
  sig { returns(String) }
  def capture; end
end

class MIR::HeapCreate
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(MIR::Node) }
  def init; end
  sig { returns(String) }
  def label; end
  sig { returns(String) }
  def zig_type; end
end

class AST::MoveNode
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::InlineBc
  sig { returns(T::Array[MIR::Node]) }
  def args; end
  sig { returns(Symbol) }
  def op; end
end

class MIR::Deref
  sig { returns(MIR::Node) }
  def expr; end
end

class AST::BlockExpr
  sig { returns(T::Array[AST::Node]) }
  def body; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::CountOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::ReassignCleanup
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class FsmTransform::Segments::LockSuspend
  sig { returns(Integer) }
  def lock_index; end
  sig { returns(Integer) }
  def next_index; end
  sig { returns(Integer) }
  def post_acquire_idx; end
  sig { returns(T::Array[T.any(CapabilityPlan::CapabilityTransition, Symbol)]) }
  def prior_caps; end
  sig { returns(T::Array[Integer]) }
  def prior_lock_indices; end
end

class MIR::CapabilityUnwrap
  sig { returns(MIR::Node) }
  def source; end
end

class AST::RequireNode
  sig { returns(Symbol) }
  def kind; end
  sig { returns(String) }
  def namespace; end
  sig { returns(String) }
  def path; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::ReduceOp
  sig { returns(AST::Node) }
  def initial_value; end
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::EnumDef
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(T::Array[T.any(String, Symbol)]) }
  def variants; end
  sig { returns(Symbol) }
  def visibility; end
end

class MIR::IterRange
  sig { returns(Symbol) }
  def capture_type; end
  sig { returns(MIR::Node) }
  def end_val; end
  sig { returns(MIR::Node) }
  def start; end
end

class AST::LimitOp
  sig { returns(AST::Node) }
  def count; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::PatternField
  sig { returns(T.any(AST::Node, Symbol)) }
  def value; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def name_token; end
end

class AST::TestBlock
  sig { returns(String) }
  def name; end
  sig { returns(T::Array[AST::Node]) }
  def setup; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(T::Array[AST::WhenBlock]) }
  def whens; end
end

class MIR::TypeOf
  sig { returns(MIR::Node) }
  def expr; end
end

class ModuleImporter::CompiledModule
  sig { returns(Scope) }
  def global_scope; end
  sig { returns(String) }
  def source_dir; end
  sig { returns(String) }
  def transpiled_body; end
  sig { returns(String) }
  def type_defs; end
end

class AST::AllOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::AverageOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::ModuleNamespace
  sig { returns(T::Array[MIR::Node]) }
  def items; end
  sig { returns(String) }
  def name; end
end

class MIR::ListItems
  sig { returns(MIR::Node) }
  def list; end
end

class AST::AnyOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::LambdaLit
  sig { returns(Symbol) }
  def storage; end
  sig { returns(T.any(AST::Node, Array)) }
  def body; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::DistinctOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::MaxOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::LinkNode
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(AST::Node) }
  def value; end
end

class AST::MinOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::ExternStructDecl
  sig { returns(T::Array[String]) }
  def type_params; end
  sig { returns(String) }
  def as_type; end
  sig { returns(String) }
  def close_method; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::UnionTypeDef
  sig { returns(String) }
  def name; end
  sig { returns(Symbol) }
  def visibility; end
  sig { returns(T::Array[T.any(Hash, MIR::UnionTypeVariant)]) }
  def variants; end
end

class AST::FindOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class FsmTransform::Segments::IoSuspend
  sig { returns(String) }
  def result_var; end
  sig { returns(Integer) }
  def next_index; end
end

class MIR::SwitchStmt
  sig { returns(MIR::Node) }
  def subject; end
  sig { returns(T::Array[MIR::SwitchArm]) }
  def arms; end
end

class MIR::TestDef
  sig { returns(T::Array[MIR::Node]) }
  def body; end
  sig { returns(String) }
  def name; end
end

class AST::PassStmt
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::StaticCall
  sig { returns(T::Array[AST::Node]) }
  def args; end
  sig { returns(String) }
  def method_name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::ErrDeferStmt
  sig { returns(MIR::Node) }
  def body; end
end

class AST::CatchFilter
  sig { returns(Symbol) }
  def form; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(T.any(AST::Node, String)) }
  def value; end
end

class AST::UnnestOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::StructPattern
  sig { returns(T::Boolean) }
  def partial; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::OwnedSlice
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(MIR::Node) }
  def expr; end
end

class AST::DoBlock
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::FsmTailLockTry
  sig { returns(Integer) }
  def error_step; end
  sig { returns(String) }
  def lock_field_ref; end
  sig { returns(Integer) }
  def ok_step; end
  sig { returns(String) }
  def try_method; end
  sig { returns(Integer) }
  def wait_step; end
end

class MIR::FsmTailRetryOrError
  sig { returns(Integer) }
  def fail_step; end
  sig { returns(Integer) }
  def retries; end
  sig { returns(Integer) }
  def retry_step; end
end

class MIR::FsmTailWokenCheck
  sig { returns(Integer) }
  def error_step; end
  sig { returns(Integer) }
  def ok_step; end
end

class AST::TakeWhileOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::ResolveNode
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(AST::Node) }
  def value; end
end

class AST::BatchWindowOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::FsmTailRegisterYield
  sig { returns(Integer) }
  def next_step; end
  sig { returns(MIR::Node) }
  def register_expr; end
  sig { returns(String) }
  def yield_reason; end
end

class MIR::SuspendDescriptor
  sig { returns(T::Array[MIR::Node]) }
  def bind_stmts; end
  sig { returns(T::Array[MIR::Node]) }
  def ctx_field_decls; end
  sig { returns(T::Boolean) }
  def result_needs_cleanup; end
  sig { returns(String) }
  def result_var; end
  sig { returns(String) }
  def result_zig_type; end
  sig { returns(T::Array[MIR::Node]) }
  def setup_stmts; end
  sig { returns(MIR::Node) }
  def tail; end
end

class MIR::DestroyPtr
  sig { returns(T.any(MIR::Node, Symbol)) }
  def alloc; end
  sig { returns(MIR::Node) }
  def ptr; end
end

class AST::CollectOp
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::StubDecl
  sig { returns(String) }
  def function_name; end
  sig { returns(Symbol) }
  def kind; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::SkipOp
  sig { returns(AST::Node) }
  def count; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::FsmTailYield
  sig { returns(Integer) }
  def next_step; end
  sig { returns(String) }
  def yield_reason; end
end

class TestLowering::TestThatEnv
  sig { returns(TestLowering::TestBlockCtx) }
  def ctx; end
  sig { returns(T::Array[MIR::Node]) }
  def stub_mir; end
  sig { returns(String) }
  def tag_suffix; end
  sig { returns(T::Array[Array]) }
  def when_after_each_mir; end
  sig { returns(T::Array[Array]) }
  def when_before_each_mir; end
  sig { returns(String) }
  def when_desc; end
  sig { returns(T::Array[MIR::Node]) }
  def when_setup_mir; end
  sig { returns(AST::WhenBlock) }
  def when_block; end
end

class FsmTransform::Segments::Done
  sig { returns(NilClass) }
  def _; end
end

class MIR::FsmGenericCtxStruct
  sig { returns(MIR::FsmDispatch) }
  def dispatch; end
  sig { returns(T::Array[MIR::FsmDestroyAction]) }
  def destroy_actions; end
end

class MIR::FsmSpawnSetup
  sig { returns(MIR::ProfileTaskSite) }
  def profile_site; end
end

class MIR::FsmStateArm
  sig do
    returns(T.any(
      MIR::FsmTailDone,
      MIR::FsmTailJump,
      MIR::FsmTailYield,
      MIR::FsmTailRegisterYield,
      MIR::FsmTailCondJump,
      MIR::FsmTailLockTry,
      MIR::FsmTailWokenCheck,
      MIR::FsmTailRetryOrError,
    ))
  end
  def tail; end
end

class MIR::InlineBc
  sig { returns(FunctionSignature) }
  def stdlib_def; end
end

class AST::CloneNode
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(AST::Node) }
  def value; end
end

class AST::ShardOp
  sig { returns(AST::Node) }
  def key_expr; end
  sig { returns(AST::Node) }
  def target_map; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::DestructuringAssignment
  sig { returns(AST::Node) }
  def value; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::BreakNode
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::ThenChain
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::RangeLit
  sig { returns(Symbol) }
  def elem_type; end
  sig { returns(MIR::Node) }
  def end_val; end
  sig { returns(MIR::Node) }
  def start; end
end

class MIR::Noop
  sig { returns(String) }
  def reason; end
end

class AST::TapOp
  sig { returns(T::Array[AST::Node]) }
  def body; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::WhileBindLoop
  sig { returns(String) }
  def binding_name; end
  sig { returns(Lexer::Token) }
  def binding_token; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::SoaFieldAccess
  sig { returns(String) }
  def field_name; end
  sig { returns(MIR::Node) }
  def soa_expr; end
end

class AST::OrElsePass
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::Slice
  sig { returns(AST::Node) }
  def end; end
  sig { returns(T::Boolean) }
  def exclusive; end
  sig { returns(AST::Node) }
  def start; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::OptionalUnwrap
  sig { returns(MIR::Node) }
  def expr; end
end

class MIR::TypeSentinel
  sig { returns(Symbol) }
  def extreme; end
  sig { returns(String) }
  def zig_type; end
end

class MIR::DoBlock
  sig { returns(T::Array[Array]) }
  def branch_bodies; end
  sig { returns(MIR::Node) }
  def code; end
end

class AST::IndexOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class LSP::DocumentStore::Document
  sig { returns(String) }
  def text; end
  sig { returns(Integer) }
  def version; end
  sig { returns(String) }
  def uri; end
end

class MIR::SnapshotTransaction
  sig { returns(MIR::Node) }
  def cell_unwrap; end
  sig { returns(String) }
  def alias_name; end
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(Type) }
  def bare_type; end
  sig { returns(T::Boolean) }
  def is_atomic_ptr; end
  sig { returns(String) }
  def rt; end
  sig { returns(String) }
  def with_label; end
end

class MIR::BatchWindowFlush
  sig { returns(MIR::Node) }
  def value_expr; end
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def batch_var; end
  sig { returns(String) }
  def elem_zig; end
  sig { returns(String) }
  def result_var; end
  sig { returns(String) }
  def window; end
end

class MIR::BatchWindowPush
  sig { returns(MIR::Node) }
  def item_expr; end
  sig { returns(MIR::Node) }
  def value_expr; end
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def batch_var; end
  sig { returns(String) }
  def elem_zig; end
  sig { returns(String) }
  def result_var; end
  sig { returns(String) }
  def window; end
end

class AST::WindowOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(AST::Node) }
  def size; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::DefaultStreamCapacity
  sig { returns(MIR::Node) }
  def worker_count; end
end

class MIR::CatchWrapper
  sig { returns(T::Array[MIR::Node]) }
  def default_body; end
  sig { returns(MIR::Node) }
  def default_action; end
  sig { returns(MIR::Node) }
  def inner_call; end
  sig { returns(String) }
  def rt_name; end
  sig { returns(Type) }
  def snapshot_type; end
  sig { returns(T::Array[MIR::CatchClause]) }
  def clauses; end
end

class MIR::CapabilityLockAddress
  sig { returns(T::Boolean) }
  def arc_wrapped; end
  sig { returns(MIR::Node) }
  def source; end
end

class MIR::EnumOrdinal
  sig { returns(MIR::Node) }
  def value; end
end

class AnchorToken
  sig { returns(Integer) }
  def column; end
  sig { returns(Integer) }
  def line; end
end

class AST::ShareNode
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(AST::Node) }
  def value; end
end

class MIR::EnumDef
  sig { returns(String) }
  def name; end
  sig { returns(T::Array[String]) }
  def variants; end
  sig { returns(Symbol) }
  def visibility; end
end

class AST::Cast
  sig { returns(T.any(Symbol, Type)) }
  def target; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(AST::Node) }
  def value; end
end

class AST::OrderByOp
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::DefaultLit
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::Panic
  sig { returns(String) }
  def message; end
end

class MIR::Conditional
  sig { returns(MIR::Node) }
  def cond; end
  sig { returns(MIR::Node) }
  def else_val; end
  sig { returns(MIR::Node) }
  def then_val; end
end

class MIR::SliceExpr
  sig { returns(String) }
  def elem_type; end
  sig { returns(MIR::Node) }
  def end_expr; end
  sig { returns(MIR::Node) }
  def start; end
  sig { returns(MIR::Node) }
  def target; end
end

class MIR::FsmStep
  sig { returns(String) }
  def bg_rt; end
  sig { returns(T::Array[T.any(MIR::Node, String)]) }
  def body_stmts; end
  sig { returns(Integer) }
  def ctx_id; end
  sig { returns(Integer) }
  def index; end
  sig { returns(T::Boolean) }
  def suppress_runtime_ref; end
end

class MIR::RcRetain
  sig { returns(String) }
  def func; end
  sig { returns(MIR::Node) }
  def source; end
  sig { returns(String) }
  def zig_base; end
end

class MIR::SymbolLit
  sig { returns(String) }
  def value; end
end

class MIR::RcDowngrade
  sig { returns(String) }
  def func; end
  sig { returns(MIR::Node) }
  def source; end
  sig { returns(String) }
  def zig_base; end
end

class MIR::FallibleLockBinding
  sig { returns(String) }
  def acquire_block; end
  sig { returns(MIR::Node) }
  def acquire_call; end
  sig { returns(String) }
  def alias_name; end
  sig { returns(T::Array[Symbol]) }
  def bubble_types; end
  sig { returns(String) }
  def guard_var; end
  sig { returns(T::Array[Symbol]) }
  def matched_types; end
  sig { returns(Integer) }
  def retries; end
  sig { returns(String) }
  def rt_name; end
  sig { returns(String) }
  def source_line; end
  sig { returns(MIR::FailureAction) }
  def action; end
end

class AST::BenchmarkStmt
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Integer) }
  def iterations; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::RecoverOp
  sig { returns(AST::Node) }
  def default_expr; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::Drop
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::SyncPolicyDecl
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(T::Array[AST::ErrorClause]) }
  def handlers; end
end

class MIR::PolymorphicMutateFlow
  sig { returns(T::Array[MIR::Node]) }
  def guard_fail_body; end
  sig { returns(String) }
  def alias_name; end
  sig { returns(Type) }
  def bare_type; end
  sig { returns(MIR::Node) }
  def cell; end
  sig { returns(MIR::Node) }
  def guard_cond; end
  sig { returns(Type) }
  def return_type; end
  sig { returns(String) }
  def rt; end
end

class AST::LetBinding
  sig { returns(AST::Node) }
  def expr; end
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::SortedLockAcquire
  sig { returns(T::Array[Symbol]) }
  def bubble_types; end
  sig { returns(T::Boolean) }
  def fallible; end
  sig { returns(String) }
  def loop_label; end
  sig { returns(T::Array[Symbol]) }
  def matched_types; end
  sig { returns(Integer) }
  def retries; end
  sig { returns(String) }
  def rt_name; end
  sig { returns(String) }
  def source_line; end
  sig { returns(T::Array[MIR::SortedLockAcquireEntry]) }
  def entries; end
end

class MIR::WeakUpgrade
  sig { returns(String) }
  def func; end
  sig { returns(MIR::Node) }
  def source; end
  sig { returns(String) }
  def zig_base; end
end

class MIR::IndexInsert
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def elem_zig_type; end
  sig { returns(MIR::Node) }
  def key_expr; end
  sig { returns(String) }
  def key_zig_type; end
  sig { returns(MIR::Node) }
  def map; end
  sig { returns(MIR::Node) }
  def value_expr; end
end

class AST::OrElsePrune
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::DestructureTarget
  sig { returns(Type) }
  def annotation; end
  sig { returns(Symbol) }
  def declaration_kind; end
  sig { returns(String) }
  def name; end
end

class AST::ContinueNode
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::JoinOp
  sig { returns(AST::Node) }
  def key_expr; end
  sig { returns(AST::Node) }
  def right_source; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::FieldCleanup
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def field; end
  sig { returns(String) }
  def target_name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::FreezeNode
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(AST::Node) }
  def value; end
end

class MIR::FieldCleanupMark
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def field; end
  sig { returns(String) }
  def target_name; end
end

class AST::IsA
  sig { returns(String) }
  def binding; end
  sig { returns(AST::Node) }
  def left; end
  sig { returns(T.any(AST::Node, Type)) }
  def right; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::FnRef
  sig { returns(String) }
  def name; end
end

class MIR::NextPromiseList
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def elem_zig; end
  sig { returns(String) }
  def label; end
  sig { returns(MIR::Node) }
  def list_expr; end
  sig { returns(String) }
  def results_var; end
end

class MIR::PointerCast
  sig { returns(MIR::Node) }
  def expr; end
  sig { returns(String) }
  def target_type; end
end

class MIR::FsmCtxStruct
  sig { returns(T::Array[MIR::Node]) }
  def capture_fields; end
  sig { returns(String) }
  def promise_zig; end
  sig { returns(T::Array[FsmOps::StateFieldDecl]) }
  def state_decls; end
  sig { returns(MIR::Node) }
  def step0; end
  sig { returns(MIR::Node) }
  def step1; end
  sig { returns(String) }
  def type_name; end
  sig { returns(MIR::FsmDispatch) }
  def resume_fn; end
end

class MIR::FsmIoBody
  sig { returns(String) }
  def blk_label; end
  sig { returns(MIR::Node) }
  def spawn_setup; end
  sig { returns(MIR::FsmCtxStruct) }
  def ctx_struct; end
end

class AST::DefaultArrayLit
  sig { returns(Symbol) }
  def storage; end
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(Type) }
  def type_info; end
end

class AST::ProfileStmt
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::SmashStmt
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::SuppressCleanup
  sig { returns(String) }
  def name; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::WithMatchDispatch
  sig { returns(String) }
  def alias_name; end
  sig { returns(MIR::Node) }
  def cell; end
  sig { returns(String) }
  def rt_name; end
  sig { returns(T::Array[MIR::WithMatchArm]) }
  def arms; end
end

class MIR::ConstCast
  sig { returns(MIR::Node) }
  def expr; end
end

class MIR::DebugOnly
  sig { returns(T::Array[MIR::Node]) }
  def body; end
end

class MIR::Sort
  sig { returns(String) }
  def elem_type; end
  sig { returns(MIR::Node) }
  def items_expr; end
  sig { returns(MIR::Node) }
  def key_a; end
  sig { returns(MIR::Node) }
  def key_b; end
end

class FsmOps::AddrOf
  sig { returns(T.any(FsmOps::StateField, FsmOps::SubField)) }
  def expr; end
end

class LSP::Analyzer::SyntheticFinding
  sig { returns(Symbol) }
  def category; end
  sig { returns(Symbol) }
  def level; end
  sig { returns(String) }
  def message; end
  sig { returns(T.any(LSP::Analyzer::SyntheticToken, Lexer::Token)) }
  def token; end
end

class MIR::FreeSlice
  sig { returns(T.any(MIR::Node, Symbol)) }
  def alloc; end
  sig { returns(MIR::Node) }
  def slice; end
end

class MIR::DestructureSet
  sig { returns(T::Array[MIR::Node]) }
  def targets; end
  sig { returns(MIR::Node) }
  def value; end
end

class MIR::FreezeExpr
  sig { returns(MIR::Node) }
  def inner; end
  sig { returns(String) }
  def zig_base; end
  sig { returns(MIR::AllocatorRef) }
  def alloc_ref; end
end

class MIR::FsmB1Body
  sig { returns(String) }
  def blk_label; end
  sig { returns(MIR::Node) }
  def spawn_setup; end
end

class FsmTransform::Segments::CondBranch
  sig { returns(T.any(AST::Node, MIR::Node)) }
  def cond_ast; end
  sig { returns(Integer) }
  def else_index; end
  sig { returns(Integer) }
  def then_index; end
end

class FsmTransform::Segments::LoopBack
  sig { returns(Integer) }
  def target_index; end
end

class AST::OrElseBreak
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::Comptime
  sig { returns(MIR::Node) }
  def expr; end
end

class MIR::FsmB1CtxStruct
  sig { returns(T::Array[MIR::Node]) }
  def capture_fields; end
  sig { returns(String) }
  def promise_zig; end
  sig { returns(String) }
  def type_name; end
  sig { returns(MIR::FsmStep) }
  def run_body; end
end

class MIR::PolymorphicMutate
  sig { returns(T::Array[MIR::Node]) }
  def body; end
  sig { returns(String) }
  def alias_name; end
  sig { returns(Type) }
  def bare_type; end
  sig { returns(MIR::Node) }
  def cell; end
  sig { returns(String) }
  def rt; end
end

class MIR::TailCall
  sig { returns(T::Array[MIR::Node]) }
  def args; end
  sig { returns(String) }
  def callee; end
end

class AST::AssertRaises
  sig { returns(T.any(String, Symbol)) }
  def error_name; end
  sig { returns(AST::Node) }
  def expression; end
  sig { returns(T.any(String, Symbol)) }
  def kind; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::SnapshotMultiTxn
  sig { returns(T::Array[String]) }
  def aliases; end
  sig { returns(T::Array[MIR::Node]) }
  def cells; end
  sig { returns(String) }
  def rt; end
end

class MIR::AssertRaisesCheck
  sig { returns(T.any(String, Symbol)) }
  def error_name; end
  sig { returns(MIR::Node) }
  def expr; end
  sig { returns(Symbol) }
  def kind; end
  sig { returns(String) }
  def rt_name; end
end

class MIR::PolymorphicFlowSignal
  sig { returns(Symbol) }
  def kind; end
  sig { returns(MIR::Node) }
  def ret; end
end

class MIR::SharePromote
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(MIR::Node) }
  def source; end
  sig { returns(String) }
  def zig_base; end
end

class AST::CallSiteOverride
  sig { returns(AST::Node) }
  def inner; end
  sig { returns(Symbol) }
  def kind; end
  sig { returns(Integer) }
  def n; end
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::DieNode
  sig { returns(Lexer::Token) }
  def token; end
end

class AnonymousStruct
  sig { returns(Integer) }
  def column; end
  sig { returns(Integer) }
  def line; end
end

class MIR::AllocSlice
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def elem_type; end
  sig { returns(MIR::Node) }
  def len; end
end

class MIR::ArrayDefaultInit
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(String) }
  def count; end
  sig { returns(MIR::Node) }
  def default_value; end
  sig { returns(String) }
  def elem_type; end
end

class MIR::BreakExpr
  sig { returns(String) }
  def label; end
  sig { returns(MIR::Node) }
  def value; end
end

class MIR::DiscardOwned
  sig { returns(CleanupEntry) }
  def cleanup_entry; end
  sig { returns(MIR::Node) }
  def expr; end
  sig { returns(String) }
  def zig_type; end
end

class MIR::UnionPayloadGet
  sig { returns(MIR::Node) }
  def subject; end
  sig { returns(T.any(String, Symbol)) }
  def variant; end
end

class MIR::FsmTailCondJump
  sig { returns(MIR::Node) }
  def condition; end
  sig { returns(Integer) }
  def else_step; end
  sig { returns(Integer) }
  def then_step; end
end

class MIR::PubConst
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def value; end
end

class MIR::StreamSpawn
  sig { returns(T::Array[MIR::Node]) }
  def body; end
end

class AST::Placeholder
  sig { returns(Lexer::Token) }
  def token; end
end

class AST::ThrowNode
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(AST::Node) }
  def value; end
end

class MIR::OrElseExitBcRewrite
  sig { returns(T::Boolean) }
  def clear_type; end
  sig { returns(T::Boolean) }
  def has_message; end
  sig { returns(String) }
  def kind; end
  sig { returns(Integer) }
  def line; end
  sig { returns(MIR::Node) }
  def message; end
  sig { returns(Integer) }
  def name_id; end
end

class MIR::ReturnMark
  sig { returns(T::Array[String]) }
  def escaped_vars; end
end

class MIR::UnionVariantGet
  sig { returns(MIR::Node) }
  def object; end
  sig { returns(T.any(String, Symbol)) }
  def variant; end
  sig { returns(String) }
  def zig_type; end
end

class AST::CatchBlock
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::Cleanup
  sig { returns(CleanupEntry) }
  def cleanup_entry; end
end

class MIR::ContinueStmt
  sig { returns(NilClass) }
  def unused; end
end

class MIR::TestPreamble
  sig { returns(NilClass) }
  def unused; end
end

class MIR::FsmTailDone
  sig { returns(NilClass) }
  def _; end
end

class MIR::IfChain
  sig { returns(T::Array[MIR::IfChainBranch]) }
  def branches; end
end

class MIR::WithMatchDispatch
  sig { returns(T::Boolean) }
  def snapshot_mode; end
end

class TestLowering::TestThatEnv
  sig { returns(T::Hash[String, AST::LetBinding]) }
  def let_ast_map; end
end



class AST::Copy
  sig { returns(Lexer::Token) }
  def token; end
  sig { returns(AST::Node) }
  def value; end
end

class LSP::Analyzer::SyntheticToken
  sig { returns(Integer) }
  def column; end
  sig { returns(Integer) }
  def line; end
  sig { returns(String) }
  def value; end
end

class MIR::FallibleOk
  sig { returns(MIR::Node) }
  def expr; end
end

class MIR::FsmTailCondSkip
  sig { returns(MIR::Node) }
  def condition; end
  sig { returns(Integer) }
  def skip_step; end
end

class MIR::OwnedBorrow
  sig { returns(String) }
  def name; end
  sig { returns(String) }
  def source; end
end

class MIR::Return
  sig { returns(T::Array[String]) }
  def escaped_vars; end
  sig { returns(Lexer::Token) }
  def token; end
end

class MIR::TypeEq
  sig { returns(MIR::Node) }
  def left; end
  sig { returns(MIR::Node) }
  def right; end
end

class OpenStruct
  sig { returns(Symbol) }
  def alloc; end
  sig { returns(MIR::AllocMark) }
  def mark; end
end

class MIR::FutureReady
  sig { returns(MIR::Node) }
  def expr; end
end

class MIR::HasField
  sig { returns(MIR::Node) }
  def expr; end
  sig { returns(String) }
  def field; end
end

class MIR::StreamYield
  sig { returns(MIR::Node) }
  def value; end
end

class MIR::TryOrPanic
  sig { returns(MIR::Node) }
  def expr; end
  sig { returns(String) }
  def panic_msg; end
end
class MIR::RuntimeCall
  sig { returns(MIR::RuntimeCallSpec) }
  def spec; end
end

class MIR::LambdaExpr
  sig { returns(MIR::FnDef) }
  def fn_def; end
end

# Parser-owned collection shapes. Keep these structural contracts beside the
# generated field RBI until the Struct declarations themselves become typed.
class AST::Program
  sig { returns(AST::RawBody) }
  def statements; end
end

class AST::ListLit
  sig { returns(AST::RawBody) }
  def items; end
end

class AST::FuncCall
  sig { returns(AST::RawBody) }
  def args; end
end

class AST::MethodCall
  sig { returns(AST::RawBody) }
  def args; end
end

class AST::CatchBlock
  sig { returns(T::Array[AST::CatchClause]) }
  def catch_clauses; end
  sig { returns(T.nilable(AST::RawBody)) }
  def default_body; end
end
