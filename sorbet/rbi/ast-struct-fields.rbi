# typed: true
# frozen_string_literal: true
#
# AUTO-GENERATED. Do not edit by hand. Regenerate with:
#   bundle exec ruby tools/gen_struct_fields_rbi.rb > sorbet/rbi/ast-struct-fields.rbi
#
# Sorbet auto-types `Struct.new(:foo, :bar)` accessors as T.untyped,
# which masks nil-safety errors. This shim declares typed sigs for
# each Struct field so dead `&.` and `.nil?` checks become 7034
# signals.
#
# Type policy is encoded in tools/gen_struct_fields_rbi.rb's
# TYPE_POLICY table. Initial pass tightens only :token (the most
# common attr). Other fields default to T.untyped and can be
# ratcheted up by extending the policy.

class AST::AllOp
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::AnyOp
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::Assert
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def condition; end
  sig { returns(T.untyped) }
  def message; end
end

class AST::AssertRaises
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def kind; end
  sig { returns(T.untyped) }
  def error_name; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::Assignment
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::AverageOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::BatchWindowOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def options; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::BenchmarkStmt
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
  sig { returns(T.untyped) }
  def iterations; end
end

class AST::BgBlock
  sig { returns(Token) }
  def token; end
  sig { returns(T::Array[T.untyped]) }
  def body; end
  sig { returns(T.untyped) }
  def deferred_drops; end
  sig { returns(T.untyped) }
  def stack_size; end
  sig { returns(T.untyped) }
  def pinned; end
  sig { returns(T.untyped) }
  def parallel; end
  sig { returns(T.untyped) }
  def arena_mode; end
  sig { returns(T.untyped) }
  def can_smash; end
end

class AST::BgStreamBlock
  sig { returns(Token) }
  def token; end
  sig { returns(T::Array[T.untyped]) }
  def body; end
  sig { returns(T.untyped) }
  def deferred_drops; end
  sig { returns(T.untyped) }
  def stack_size; end
end

class AST::BinaryOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def left; end
  sig { returns(T.untyped) }
  def op; end
  sig { returns(T.untyped) }
  def right; end
end

class AST::BindExpr
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def type; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::BlockExpr
  sig { returns(Token) }
  def token; end
  sig { returns(T::Array[T.untyped]) }
  def body; end
  sig { returns(T.untyped) }
  def result; end
end

class AST::BreakNode
  sig { returns(Token) }
  def token; end
end

class AST::CallSiteOverride
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def kind; end
  sig { returns(T.untyped) }
  def n; end
  sig { returns(T.untyped) }
  def inner; end
end

class AST::CapabilityWrap
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
  sig { returns(T.untyped) }
  def ownership; end
  sig { returns(T.untyped) }
  def sync; end
  sig { returns(T.untyped) }
  def layout; end
end

class AST::Cast
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
  sig { returns(T.untyped) }
  def target; end
end

class AST::CatchBlock
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def catch_clauses; end
  sig { returns(T.untyped) }
  def default_body; end
end

class AST::CloneNode
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::CollectOp
  sig { returns(T.nilable(Token)) }
  def token; end
end

class AST::ConcurrentOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def op; end
  sig { returns(T.untyped) }
  def options; end
end

class AST::ContinueNode
  sig { returns(Token) }
  def token; end
end

class AST::Copy
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::CopyNode
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::CountOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::DefaultLit
  sig { returns(Token) }
  def token; end
end

class AST::DieNode
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def status; end
end

class AST::DistinctOp
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::DoBlock
  sig { returns(Token) }
  def token; end
  sig { returns(T::Array[T.untyped]) }
  def branches; end
end

class AST::EachOp
  sig { returns(Token) }
  def token; end
  sig { returns(T::Array[T.untyped]) }
  def body; end
end

class AST::EnumDef
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def variants; end
  sig { returns(T.untyped) }
  def visibility; end
end

class AST::ExternFnDecl
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T::Array[T.untyped]) }
  def params; end
  sig { returns(T.untyped) }
  def return_type; end
  sig { returns(T.untyped) }
  def from_module; end
  sig { returns(T.untyped) }
  def effects; end
end

class AST::ExternStructDecl
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def fields; end
  sig { returns(T.untyped) }
  def from_module; end
end

class AST::FindOp
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::ForEach
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def var_name; end
  sig { returns(T.untyped) }
  def collection; end
  sig { returns(T::Array[T.untyped]) }
  def body; end
  sig { returns(T.untyped) }
  def deferred_drops; end
  sig { returns(T.untyped) }
  def is_mutable; end
end

class AST::ForRange
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def var_name; end
  sig { returns(T.untyped) }
  def start_expr; end
  sig { returns(T.untyped) }
  def end_expr; end
  sig { returns(T.untyped) }
  def inclusive; end
  sig { returns(T::Array[T.untyped]) }
  def body; end
  sig { returns(T.untyped) }
  def deferred_drops; end
  sig { returns(T.untyped) }
  def mark_per_iter; end
end

class AST::FreezeNode
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::FuncCall
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T::Array[T.untyped]) }
  def args; end
end

class AST::FunctionDef
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T::Array[T.untyped]) }
  def params; end
  sig { returns(T.nilable(T::Array[T.untyped])) }
  def captures; end
  sig { returns(T.untyped) }
  def return_type; end
  sig { returns(T.untyped) }
  def return_lifetime; end
  sig { returns(T::Array[T.untyped]) }
  def body; end
  sig { returns(T.untyped) }
  def catch_clauses; end
  sig { returns(T.untyped) }
  def default_catch; end
  sig { returns(T.untyped) }
  def visibility; end
  sig { returns(T.untyped) }
  def deferred_drops; end
  sig { returns(T.untyped) }
  def uses_frame; end
end

class AST::GetField
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def target; end
  sig { returns(T.untyped) }
  def field; end
end

class AST::GetIndex
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def target; end
  sig { returns(T.untyped) }
  def index; end
end

class AST::HashLit
  sig { returns(Token) }
  def token; end
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def pairs; end
  sig { returns(T.untyped) }
  def storage; end
end

class AST::Identifier
  sig { returns(Token) }
  def token; end
  sig { returns(String) }
  def name; end
end

class AST::IfBind
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def bindings; end
  sig { returns(T.untyped) }
  def then_branch; end
  sig { returns(T.untyped) }
  def else_branch; end
end

class AST::IfStatement
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def condition; end
  sig { returns(T.untyped) }
  def then_branch; end
  sig { returns(T.untyped) }
  def else_branch; end
  sig { returns(T.untyped) }
  def then_drops; end
  sig { returns(T.untyped) }
  def else_drops; end
end

class AST::IndexOp
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::JoinOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def right_source; end
  sig { returns(T.untyped) }
  def key_expr; end
end

class AST::LambdaLit
  sig { returns(Token) }
  def token; end
  sig { returns(T::Array[T.untyped]) }
  def params; end
  sig { returns(T::Array[T.untyped]) }
  def captures; end
  sig { returns(T.untyped) }
  def body; end
  sig { returns(T.untyped) }
  def storage; end
  sig { returns(T.untyped) }
  def deferred_drops; end
end

class AST::LetBinding
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def expr; end
end

class AST::LimitOp
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def count; end
end

class AST::LinkNode
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::ListLit
  sig { returns(Token) }
  def token; end
  sig { returns(T::Array[T.untyped]) }
  def items; end
  sig { returns(T.untyped) }
  def storage; end
end

class AST::Literal
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def type; end
  sig { returns(T.untyped) }
  def value; end
  sig { returns(T.untyped) }
  def storage; end
end

class AST::MatchStatement
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expr; end
  sig { returns(T::Array[T.untyped]) }
  def cases; end
  sig { returns(T.untyped) }
  def default_case; end
  sig { returns(T.untyped) }
  def case_drops; end
  sig { returns(T.untyped) }
  def default_drops; end
  sig { returns(T.untyped) }
  def exhaustive; end
  sig { returns(T.untyped) }
  def takes; end
end

class AST::MaxOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::MethodCall
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def object; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T::Array[T.untyped]) }
  def args; end
end

class AST::MinOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::MoveNode
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::NextExpr
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expr; end
end

class AST::OptionalUnwrap
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def target; end
end

class AST::OrBreak
  sig { returns(Token) }
  def token; end
end

class AST::OrExit
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def kind; end
  sig { returns(T.untyped) }
  def error_name; end
  sig { returns(T.untyped) }
  def message; end
end

class AST::OrPass
  sig { returns(Token) }
  def token; end
end

class AST::OrPrune
  sig { returns(Token) }
  def token; end
end

class AST::OrRaise
  sig { returns(Token) }
  def token; end
end

class AST::OrderByOp
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::PassStmt
  sig { returns(Token) }
  def token; end
end

class AST::Placeholder
  sig { returns(T.nilable(Token)) }
  def token; end
end

class AST::ProfileStmt
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::Program
  sig { returns(Token) }
  def token; end
  sig { returns(T::Array[T.untyped]) }
  def statements; end
end

class AST::Raise
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def kind; end
  sig { returns(T.untyped) }
  def error_name; end
  sig { returns(T.untyped) }
  def message_expr; end
end

class AST::RangeLit
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def start; end
  sig { returns(T.untyped) }
  def finish; end
  sig { returns(T.untyped) }
  def inclusive; end
end

class AST::RecoverOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def default_expr; end
end

class AST::ReduceOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def initial_value; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::Require
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def path; end
end

class AST::RequireNode
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def path; end
  sig { returns(T.untyped) }
  def namespace; end
  sig { returns(T.untyped) }
  def kind; end
end

class AST::ResolveNode
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::ReturnNode
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::SelectOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::ShardOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def key_expr; end
  sig { returns(T.untyped) }
  def target_map; end
end

class AST::ShareNode
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::SkipOp
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def count; end
end

class AST::Slice
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def target; end
  sig { returns(T.untyped) }
  def start; end
  sig { returns(T.untyped) }
  def end; end
end

class AST::SmashStmt
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::StaticCall
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def type_name; end
  sig { returns(T.untyped) }
  def method_name; end
  sig { returns(T::Array[T.untyped]) }
  def args; end
end

class AST::StringConcat
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def parts; end
end

class AST::StructDef
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def fields; end
  sig { returns(T.untyped) }
  def visibility; end
  sig { returns(T::Array[T.untyped]) }
  def type_params; end
end

class AST::StructLit
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def fields; end
  sig { returns(T.untyped) }
  def storage; end
  sig { returns(T.untyped) }
  def type_args; end
end

class AST::StructPattern
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def fields; end
  sig { returns(T.untyped) }
  def partial; end
end

class AST::StubDecl
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def function_name; end
  sig { returns(T.untyped) }
  def kind; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::SumOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::SyncPolicyDecl
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def handlers; end
end

class AST::TakeWhileOp
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::TapOp
  sig { returns(Token) }
  def token; end
  sig { returns(T::Array[T.untyped]) }
  def body; end
end

class AST::TestBlock
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def setup; end
  sig { returns(T.untyped) }
  def whens; end
end

class AST::TestThat
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def description; end
  sig { returns(T::Array[T.untyped]) }
  def body; end
end

class AST::ThenChain
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def steps; end
end

class AST::ThrowNode
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def value; end
end

class AST::UnaryOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def op; end
  sig { returns(T.untyped) }
  def right; end
end

class AST::UnionDef
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def variants; end
  sig { returns(T.untyped) }
  def visibility; end
end

class AST::UnionVariantLit
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def union_name; end
  sig { returns(T.untyped) }
  def variant_name; end
  sig { returns(T.untyped) }
  def fields; end
  sig { returns(T.untyped) }
  def storage; end
end

class AST::UnnestOp
  sig { returns(T.nilable(Token)) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::VarDecl
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def type; end
  sig { returns(T.untyped) }
  def value; end
  sig { returns(T.untyped) }
  def mutable; end
end

class AST::WhenBlock
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def description; end
  sig { returns(T.untyped) }
  def setup; end
  sig { returns(T.untyped) }
  def tests; end
  sig { returns(T.untyped) }
  def benchmarks; end
end

class AST::WhereOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::WhileBindLoop
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def condition; end
  sig { returns(T.untyped) }
  def binding_name; end
  sig { returns(T.untyped) }
  def binding_token; end
  sig { returns(T.untyped) }
  def do_branch; end
  sig { returns(T.untyped) }
  def deferred_drops; end
end

class AST::WhileLoop
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def condition; end
  sig { returns(T.untyped) }
  def do_branch; end
  sig { returns(T.untyped) }
  def deferred_drops; end
end

class AST::WindowOp
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def size; end
  sig { returns(T.untyped) }
  def expression; end
end

class AST::WithBlock
  sig { returns(Token) }
  def token; end
  sig { returns(T::Array[T.untyped]) }
  def capabilities; end
  sig { returns(T::Array[T.untyped]) }
  def body; end
  sig { returns(T.untyped) }
  def deferred_drops; end
end

class AST::YieldExpr
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def expr; end
end

class MIR::Alloc
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def kind; end
  sig { returns(T.untyped) }
  def alloc; end
end

class MIR::Drop
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def kind; end
  sig { returns(T.untyped) }
  def alloc; end
  sig { returns(T.untyped) }
  def has_moved_guard; end
  sig { returns(T.untyped) }
  def type_info; end
  sig { returns(T.untyped) }
  def resource_close_zig; end
  sig { returns(T.untyped) }
  def source_node; end
end

class MIR::FieldCleanup
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def target_name; end
  sig { returns(T.untyped) }
  def field; end
  sig { returns(T.untyped) }
  def alloc; end
end

class MIR::Promote
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def zig_type; end
  sig { returns(T.untyped) }
  def strategy; end
  sig { returns(T.untyped) }
  def fields; end
  sig { returns(T.untyped) }
  def elem_type; end
end

class MIR::ReassignCleanup
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def alloc; end
end

class MIR::Return
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def escaped_vars; end
end

class MIR::SuppressCleanup
  sig { returns(Token) }
  def token; end
  sig { returns(T.untyped) }
  def name; end
end

