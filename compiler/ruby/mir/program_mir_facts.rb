# typed: strict
# frozen_string_literal: true

require "digest"
require "json"
require "set"
require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../annotator/helpers/function_signature"
require_relative "../annotator/phases/body_analysis"
require_relative "../compiler/entrypoint"
require_relative "cleanup_classifier"
require_relative "mir_planning"

class FunctionMIRFacts < T::Struct
  extend T::Sig

  const :name, String
  const :needs_runtime, T::Boolean
  sig { returns(String) }
  def fingerprint
    Digest::SHA256.hexdigest(JSON.generate([
      name,
      needs_runtime,
    ]))
  end
end

class ProgramMIRFacts
  extend T::Sig

  FunctionMap = T.type_alias { T::Hash[String, FunctionMIRFacts] }

  sig { returns(FunctionMap) }
  attr_reader :functions

  sig { params(functions: FunctionMap).void }
  def initialize(functions:)
    @functions = T.let(functions.sort.to_h.freeze, FunctionMap)
    freeze
  end

  sig { returns(ProgramMIRFacts) }
  def self.empty
    new(functions: {})
  end
end

# The only whole-program runtime-requirement fixed point after local cleanup
# planning. It consumes the annotation call summaries instead of walking every
# function body again to rediscover the graph. AST stamping is retained as one
# compatibility seam for the current lowerer.
class ProgramMIRFinalizer
  extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }
  CleanupPlans = T.type_alias { MIRPlanningResult::CleanupPlans }
  BodySummaries = T.type_alias { T::Hash[String, Annotator::Phases::FunctionBodySummary] }

  sig do
    params(
      fn_nodes: FnNodes,
      cleanup_plans: CleanupPlans,
      body_summaries: BodySummaries,
      schema_lookup: Type::SchemaLookup,
    ).returns(ProgramMIRFacts)
  end
  def self.finalize(fn_nodes:, cleanup_plans:, body_summaries:, schema_lookup:)
    needs_runtime = local_runtime_requirements(fn_nodes, cleanup_plans, schema_lookup)
    propagate_runtime_requirements!(needs_runtime, body_summaries)

    functions = T.let({}, ProgramMIRFacts::FunctionMap)
    fn_nodes.keys.sort.each do |name|
      functions[name] = function_facts(name, needs_runtime.fetch(name, false))
    end
    ProgramMIRFacts.new(functions: functions)
  end

  class << self
    extend T::Sig

    private

    sig do
      params(
        fn_nodes: FnNodes,
        cleanup_plans: CleanupPlans,
        schema_lookup: Type::SchemaLookup,
      ).returns(T::Hash[String, T::Boolean])
    end
    def local_runtime_requirements(fn_nodes, cleanup_plans, schema_lookup)
      result = T.let({}, T::Hash[String, T::Boolean])
      fn_nodes.each do |name, function|
        next unless function.body

        result[name] = function_needs_runtime?(function, cleanup_plans.fetch(name).facts, fn_nodes, schema_lookup)
      end
      result
    end

    sig do
      params(
        function: AST::FunctionDef,
        cleanup: T.nilable(CleanupClassifier::FrozenCleanupFacts),
        fn_nodes: FnNodes,
        schema_lookup: Type::SchemaLookup,
      ).returns(T::Boolean)
    end
    def function_needs_runtime?(function, cleanup, fn_nodes, schema_lookup)
      return true if finalized_runtime_input?(function)
      return true if params_need_runtime_cleanup?(function.params)
      return true if cleanup && runtime_cleanup_facts?(cleanup)

      found = T.let(false, T::Boolean)
      AST.each_locatable(function.body) do |node|
        found = true if ast_node_needs_runtime?(node, fn_nodes, schema_lookup)
      end
      found || return_path_needs_allocator?(function, schema_lookup)
    end

    sig { params(function: AST::FunctionDef).returns(T::Boolean) }
    def finalized_runtime_input?(function)
      function.name.to_s == Compiler::Entrypoint::NAME ||
        !function.conformance_protocol.nil? ||
        function.uses_rt == true ||
        function_error_context?(function) ||
        function.uses_alloc == true ||
        function.fn_value_ref == true ||
        !function.thunk_plan.nil? ||
        !function.mutual_thunk_plan.nil? ||
        AST.recursion_yield_needed?(function)
    end

    sig { params(function: AST::FunctionDef).returns(T::Boolean) }
    def function_error_context?(function)
      return true if function.pre_clauses&.any?
      return true if function.catch_clauses.is_a?(Array) && function.catch_clauses.any?

      function.default_catch.is_a?(Array) && function.default_catch.any?
    end

    sig { params(params: T::Array[AST::Param]).returns(T::Boolean) }
    def params_need_runtime_cleanup?(params)
      params.any? do |param|
        next false unless param.takes

        type = param.type
        type.any? || (!type.primitive? && !type.id_handle?)
      end
    end

    sig { params(facts: CleanupClassifier::FrozenCleanupFacts).returns(T::Boolean) }
    def runtime_cleanup_facts?(facts)
      found = T.let(false, T::Boolean)
      facts.each_entry { |_place, entry| found = true if entry.heap? || entry.frame? }
      found
    end

    sig do
      params(
        node: AST::Node,
        fn_nodes: FnNodes,
        schema_lookup: Type::SchemaLookup,
      ).returns(T::Boolean)
    end
    def ast_node_needs_runtime?(node, fn_nodes, schema_lookup)
      AST.declaration_with_heap_symbol?(node) || ast_node_lowers_through_runtime?(node, fn_nodes, schema_lookup)
    end

    sig do
      params(
        node: AST::Node,
        fn_nodes: FnNodes,
        schema_lookup: Type::SchemaLookup,
      ).returns(T::Boolean)
    end
    def ast_node_lowers_through_runtime?(node, fn_nodes, schema_lookup)
      case node
      when AST::FuncCall, AST::MethodCall
        ast_call_needs_runtime?(node, fn_nodes)
      when AST::BgBlock, AST::BgStreamBlock
        true
      when AST::Assignment
        indexed_assignment_lowers_through_runtime?(node)
      when AST::CopyNode, AST::CloneNode
        copy_node_lowers_through_runtime?(node, schema_lookup)
      when AST::WithBlock
        with_block_lowers_through_runtime?(node)
      else
        false
      end
    end

    sig { params(node: T.any(AST::FuncCall, AST::MethodCall), fn_nodes: FnNodes).returns(T::Boolean) }
    def ast_call_needs_runtime?(node, fn_nodes)
      return false if fn_nodes.key?(node.name.to_s)

      signature = FunctionSignature.unwrap(node.matched_signature)
      signature&.needs_rt == true || signature&.emits_allocating? == true
    end

    sig { params(node: T.any(AST::CopyNode, AST::CloneNode), schema_lookup: Type::SchemaLookup).returns(T::Boolean) }
    def copy_node_lowers_through_runtime?(node, schema_lookup)
      type = Type.from_node!(node, context: "COPY runtime requirement").success_type
      return false if type.primitive? || type.symbol? || type.id_handle?

      type.string? || type.heap_ptr? || type.collection_value? || type.collection? ||
        type.any_sync? || type.needs_cleanup?(T.unsafe(schema_lookup)) ||
        type.recursive_cleanup_shape?(T.unsafe(schema_lookup))
    end

    sig { params(node: AST::Assignment).returns(T::Boolean) }
    def indexed_assignment_lowers_through_runtime?(node)
      return false unless node.name.is_a?(AST::GetIndex)

      target = node.name.target
      return false unless target.is_a?(AST::Locatable)
      return true if node.name.protocol_operation == :map_put

      type = target.full_type!(context: "indexed assignment target")
      return false if type.fixed? && !type.string? && !type.collection?

      key = type.dispatch_key
      key && INDEX_OPS.dig(key, :set) ? true : false
    end

    sig { params(node: AST::WithBlock).returns(T::Boolean) }
    def with_block_lowers_through_runtime?(node)
      return true if node.snapshot_mode == :transaction || node.view_kind == :materialized_view || node.universal_poly

      clause = node.lock_error_clause
      return false unless clause

      [AST::ErrorActionKind::Raise, AST::ErrorActionKind::Exit].include?(clause.action) || clause.bubble_types.any?
    end

    sig { params(function: AST::FunctionDef, schema_lookup: Type::SchemaLookup).returns(T::Boolean) }
    def return_path_needs_allocator?(function, schema_lookup)
      return false unless function.heap_carry_return

      found = T.let(false, T::Boolean)
      AST.each_locatable(function.body) do |node|
        next unless node.is_a?(AST::ReturnNode) && node.value

        found ||= return_expr_needs_allocator?(function, node.value, schema_lookup)
      end
      found
    end

    sig do
      params(
        function: AST::FunctionDef,
        expression: AST::Node,
        schema_lookup: Type::SchemaLookup,
      ).returns(T::Boolean)
    end
    def return_expr_needs_allocator?(function, expression, schema_lookup)
      node = unwrap_return_expr(expression)
      return true if node.is_a?(AST::CopyNode)

      type = node.is_a?(AST::Locatable) ? node.full_type!(context: "return allocator expression").success_type : nil
      return false if type&.any_rc? || type&.any_sync?

      if node.is_a?(AST::Identifier)
        return false if function.params.any? { |param| param.name.to_s == node.name.to_s && param.takes }

        return type ? type.string? || type.recursive_cleanup_shape?(T.unsafe(schema_lookup)) : false
      end

      return true if node.is_a?(AST::StringConcat)
      return true if node.is_a?(AST::BinaryOp) && node.string_concat == true

      type ? !node.is_a?(AST::Literal) && (
        type.string? || type.heap_ptr? || type.collection_value? || type.collection? ||
          type.needs_cleanup?(T.unsafe(schema_lookup)) || type.recursive_cleanup_shape?(T.unsafe(schema_lookup))
      ) : false
    end

    sig { params(expression: AST::Node).returns(AST::Node) }
    def unwrap_return_expr(expression)
      case expression
      when AST::MoveNode, AST::Cast, AST::FreezeNode
        unwrap_return_expr(expression.value)
      when AST::BinaryOp
        expression.op == :OR_ELSE ? unwrap_return_expr(expression.left) : expression
      else
        expression
      end
    end

    sig do
      params(
        needs_runtime: T::Hash[String, T::Boolean],
        body_summaries: BodySummaries,
      ).void
    end
    def propagate_runtime_requirements!(needs_runtime, body_summaries)
      changed = T.let(true, T::Boolean)
      while changed
        changed = false
        needs_runtime.each_key do |name|
          next if needs_runtime.fetch(name)

          callees = body_summaries[name]&.callees || Set.new
          next unless callees.any? { |callee| needs_runtime.fetch(callee, false) }

          needs_runtime[name] = true
          changed = true
        end
      end
    end

    sig do
      params(
        name: String,
        needs_runtime: T::Boolean,
      ).returns(FunctionMIRFacts)
    end
    def function_facts(name, needs_runtime)
      FunctionMIRFacts.new(
        name: name,
        needs_runtime: needs_runtime,
      ).freeze
    end
  end
end
