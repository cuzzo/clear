# typed: strict
require "sorbet-runtime"
require "set"

require_relative "../../ast/ast"
require_relative "../../semantic/semantic_ids"
require_relative "declaration_index"

module Annotator
  module Phases
    BindingNode = T.type_alias { T.any(AST::VarDecl, AST::BindExpr) }
    AssignmentNode = T.type_alias { T.any(AST::Assignment, AST::BindExpr) }
    AsyncBodyNode = T.type_alias { T.any(AST::BgBlock, AST::BgStreamBlock, AST::DoBranch) }
    AsyncValidationNode = T.type_alias { T.any(AST::BgBlock, AST::BgStreamBlock, AST::DoBlock) }
    WithScopeNodes = T.type_alias { T::Hash[Integer, T::Array[AST::Locatable]] }
    LambdaIdentifierRefs = T.type_alias { T::Hash[Integer, T::Array[AST::Identifier]] }

    class BodyScanSummary < T::Struct
      const :definition_id, Semantic::DefId, default: Semantic::UNASSIGNED_DEF_ID
      const :body_id, Semantic::BodyId, default: Semantic::UNASSIGNED_BODY_ID
      const :callees, T::Set[String]
      const :propagating_callees, T::Set[String]
      prop :has_fnptr_call, T::Boolean
      prop :raises_directly, T::Boolean
      const :call_site_facts, T::Array[Semantic::CallSiteFact], factory: -> { [] }
      const :local_facts, T::Array[Semantic::LocalFact], factory: -> { [] }
      const :return_nodes, T::Array[AST::ReturnNode], factory: -> { [] }
      const :binding_nodes, T::Array[BindingNode], factory: -> { [] }
      const :assignment_nodes, T::Array[AssignmentNode], factory: -> { [] }
      const :escape_nodes, T::Array[AST::Locatable], factory: -> { [] }
      const :with_scope_nodes, WithScopeNodes, factory: -> { {} }
      const :lambda_body_identifier_refs, LambdaIdentifierRefs, factory: -> { {} }
      const :with_blocks, T::Array[AST::WithBlock], factory: -> { [] }
      const :suspend_points, T::Array[Semantic::SuspendPointFact], factory: -> { [] }
      const :pipe_input_types, T::Set[String], factory: -> { Set.new }
      prop :references_snapshot, T::Boolean, default: false
    end

    class BodyFactContext < T::Struct
      const :record_call_sites, T::Boolean
      const :failure_absorbed, T::Boolean
      const :track_with_scope_stack, T::Boolean
      const :with_scope_stack, T::Array[AST::WithBlock]
      const :lambda_body_stack, T::Array[AST::LambdaLit]
    end

    class BodyFactFrame < T::Struct
      extend T::Sig

      const :summary, BodyScanSummary
      prop :record_call_sites, T::Boolean, default: true
      prop :failure_absorbed, T::Boolean, default: false
      prop :track_with_scope_stack, T::Boolean, default: true
      prop :with_scope_stack, T::Array[AST::WithBlock], factory: -> { [] }
      prop :lambda_body_stack, T::Array[AST::LambdaLit], factory: -> { [] }
      prop :next_local_ordinal, Integer, default: 0
      prop :next_place_ordinal, Integer, default: 0
      prop :next_call_site_ordinal, Integer, default: 0

      sig { params(identity: Semantic::BodyIdentity).returns(BodyFactFrame) }
      def self.for_identity(identity)
        new(summary: BodyScanSummary.new(
          definition_id: identity.definition_id,
          body_id: identity.body_id,
          callees: Set.new,
          propagating_callees: Set.new,
          has_fnptr_call: false,
          raises_directly: false
        ))
      end

      sig { returns(BodyScanSummary) }
      def to_summary
        summary
      end

      sig { returns(BodyFactContext) }
      def context
        BodyFactContext.new(
          record_call_sites: record_call_sites,
          failure_absorbed: failure_absorbed,
          track_with_scope_stack: track_with_scope_stack,
          with_scope_stack: with_scope_stack.dup,
          lambda_body_stack: lambda_body_stack.dup
        )
      end

      sig { params(context: BodyFactContext).void }
      def restore_context(context)
        self.record_call_sites = context.record_call_sites
        self.failure_absorbed = context.failure_absorbed
        self.track_with_scope_stack = context.track_with_scope_stack
        self.with_scope_stack = context.with_scope_stack.dup
        self.lambda_body_stack = context.lambda_body_stack.dup
      end

    end

    class BgSpawnDecision < T::Struct
      const :spawn_form, Symbol
      const :reason, T.nilable(Symbol)
    end

    class AsyncBodyFact < T::Struct
      const :node, AsyncBodyNode
      const :summary, BodyScanSummary
      const :validation_node, AsyncValidationNode
    end

    class FunctionBodySummary < T::Struct
      const :name, String
      const :definition_id, Semantic::DefId, default: Semantic::UNASSIGNED_DEF_ID
      const :body_id, Semantic::BodyId, default: Semantic::UNASSIGNED_BODY_ID
      const :callees, T::Set[String]
      const :propagating_callees, T::Set[String]
      const :has_fnptr_call, T::Boolean
      const :raises_directly, T::Boolean
      const :call_site_facts, T::Array[Semantic::CallSiteFact], factory: -> { [] }
      const :local_facts, T::Array[Semantic::LocalFact], factory: -> { [] }
      const :return_nodes, T::Array[AST::ReturnNode], factory: -> { [] }
      const :binding_nodes, T::Array[BindingNode], factory: -> { [] }
      const :assignment_nodes, T::Array[AssignmentNode], factory: -> { [] }
      const :escape_nodes, T::Array[AST::Locatable], factory: -> { [] }
      const :with_scope_nodes, WithScopeNodes, factory: -> { {} }
      const :lambda_body_identifier_refs, LambdaIdentifierRefs, factory: -> { {} }
      const :with_blocks, T::Array[AST::WithBlock], factory: -> { [] }
      const :suspend_points, T::Array[Semantic::SuspendPointFact], factory: -> { [] }
    end

    module BodyAnalysis
      extend T::Sig

      sig { params(summary: FunctionBodySummary).void }
      def record_function_body_summary!(summary)
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.record_body_summary!(summary)
      end

      sig { returns(T::Hash[String, FunctionBodySummary]) }
      def function_body_summaries
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.body_summaries
      end

      sig { returns(T::Hash[String, T::Set[String]]) }
      def function_call_graph
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.call_graph
      end

      sig { returns(T::Hash[String, T::Set[String]]) }
      def function_propagating_callees
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.propagating_callees
      end

      sig { params(name: String).returns(T::Boolean) }
      def function_has_fnptr_call?(name)
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.fnptr_call?(name)
      end

      sig { params(name: String).returns(T::Boolean) }
      def function_raises_directly?(name)
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.raises_directly?(name)
      end

      sig { returns(T::Array[BodyFactFrame]) }
      def body_fact_frames
        T.bind(self, SemanticAnnotator)
        phase_receiver_state.body_fact_frames
      end

      sig { params(identity: Semantic::BodyIdentity, block: T.proc.void).returns(BodyScanSummary) }
      def with_body_fact_frame(identity, &block)
        T.bind(self, SemanticAnnotator)

        frame = BodyFactFrame.for_identity(identity)
        body_fact_frames << frame
        begin
          yield
          frame.to_summary
        ensure
          popped = body_fact_frames.pop
          raise "BUG: body fact frame mismatch" unless popped.equal?(frame)
        end
      end

      sig do
        type_parameters(:Result)
          .params(block: T.proc.returns(T.type_parameter(:Result)))
          .returns(T.type_parameter(:Result))
      end
      def with_body_fact_nested_body(&block)
        frames = T.let([], T::Array[BodyFactFrame])
        snapshots = T.let([], T::Array[BodyFactContext])
        begin
          frames = body_fact_frames
          snapshots = frames.map(&:context)
          frames.each do |frame|
            frame.record_call_sites = false
            frame.track_with_scope_stack = false
            frame.with_scope_stack = []
          end
          yield
        ensure
          frames.zip(snapshots).each { |frame, snapshot| frame.restore_context(T.must(snapshot)) }
        end
      end

      sig do
        type_parameters(:Result)
          .params(block: T.proc.returns(T.type_parameter(:Result)))
          .returns(T.type_parameter(:Result))
      end
      def with_body_fact_scopes_cleared(&block)
        frames = T.let([], T::Array[BodyFactFrame])
        snapshots = T.let([], T::Array[BodyFactContext])
        begin
          frames = body_fact_frames
          snapshots = frames.map(&:context)
          frames.each do |frame|
            frame.track_with_scope_stack = false
            frame.with_scope_stack = []
          end
          yield
        ensure
          frames.zip(snapshots).each { |frame, snapshot| frame.restore_context(T.must(snapshot)) }
        end
      end

      sig do
        type_parameters(:Result)
          .params(node: AST::LambdaLit, block: T.proc.returns(T.type_parameter(:Result)))
          .returns(T.type_parameter(:Result))
      end
      def with_body_fact_lambda_body(node, &block)
        frames = T.let([], T::Array[BodyFactFrame])
        snapshots = T.let([], T::Array[BodyFactContext])
        begin
          frames = body_fact_frames
          snapshots = frames.map(&:context)
          frames.each { |frame| frame.lambda_body_stack << node }
          yield
        ensure
          frames.zip(snapshots).each { |frame, snapshot| frame.restore_context(T.must(snapshot)) }
        end
      end

      sig do
        type_parameters(:Result)
          .params(absorbed: T::Boolean, block: T.proc.returns(T.type_parameter(:Result)))
          .returns(T.type_parameter(:Result))
      end
      def with_body_fact_failure_absorbed(absorbed, &block)
        return yield unless absorbed

        frames = T.let([], T::Array[BodyFactFrame])
        snapshots = T.let([], T::Array[BodyFactContext])
        begin
          frames = body_fact_frames
          snapshots = frames.map(&:context)
          frames.each { |frame| frame.failure_absorbed = true }
          yield
        ensure
          frames.zip(snapshots).each { |frame, snapshot| frame.restore_context(T.must(snapshot)) }
        end
      end

      sig do
        type_parameters(:Result)
          .params(scope: AST::WithBlock, block: T.proc.returns(T.type_parameter(:Result)))
          .returns(T.type_parameter(:Result))
      end
      def with_body_fact_scope(scope, &block)
        frames = T.let([], T::Array[BodyFactFrame])
        snapshots = T.let([], T::Array[BodyFactContext])
        begin
          frames = body_fact_frames
          snapshots = frames.map(&:context)
          frames.each { |frame| frame.with_scope_stack = [scope] if frame.track_with_scope_stack }
          yield
        ensure
          frames.zip(snapshots).each { |frame, snapshot| frame.restore_context(T.must(snapshot)) }
        end
      end

      sig { params(node: AST::WithBlock).returns(T::Array[AST::Locatable]) }
      def current_body_fact_scope_nodes(node)
        frame = body_fact_frames.last
        return [] unless frame

        frame.summary.with_scope_nodes[node.object_id] || []
      end

      sig { params(node: AST::WithBlock).void }
      def record_body_fact_with_block!(node)
        T.bind(self, SemanticAnnotator)
        frame = body_fact_frames.last
        return unless frame

        suspends = with_block_suspends?(node)
        summary = frame.summary
        summary.with_blocks << node
        summary.with_scope_nodes[node.object_id] ||= []
        if suspends
          summary.suspend_points << Semantic::SuspendPointFact.new(
            id: Semantic::SuspendPointId.new(value: summary.suspend_points.length),
            kind: :lock,
            node: node
          )
        end
      end

      sig { params(type_name: String).void }
      def record_body_fact_pipe_input_type!(type_name)
        body_fact_frames.each do |frame|
          frame.summary.pipe_input_types << type_name
        end
      end

      sig { returns(T::Array[AsyncBodyFact]) }
      def async_body_facts
        T.bind(self, SemanticAnnotator)
        phase_receiver_state.async_body_facts
      end

      sig { params(node: AsyncBodyNode, summary: BodyScanSummary, validation_node: AsyncValidationNode).returns(AsyncBodyFact) }
      def record_async_body_fact!(node, summary, validation_node)
        T.bind(self, SemanticAnnotator)
        fact = AsyncBodyFact.new(node: node, summary: summary, validation_node: validation_node)
        async_body_facts << fact
        fact
      end

      sig do
        params(
          node: AsyncBodyNode,
          validation_node: AsyncValidationNode,
          block: T.proc.void
        ).returns(BodyScanSummary)
      end
      def with_async_body_fact_frame(node, validation_node, &block)
        summary = with_body_fact_frame(Semantic::BodyIdentity.unassigned) do
          with_body_fact_scopes_cleared { yield }
        end
        record_async_body_fact!(node, summary, validation_node)
        summary
      end

      sig { params(node: AST::Node).void }
      def record_body_fact_node!(node)
        T.bind(self, SemanticAnnotator)
        frames = body_fact_frames
        return if frames.empty?

        suspend_kind = T.let(nil, T.nilable(Symbol))
        if node.is_a?(AST::FuncCall) || node.is_a?(AST::MethodCall)
          if func_call_suspends?(node)
            suspend_kind = node.matched_stdlib_def&.intrinsic_suspends? ? :io : :call
          end
        end
        with_block_raises = node.is_a?(AST::WithBlock) && with_block_raises_directly?(node)

        frames.each do |frame|
          summary = frame.summary
          if node.is_a?(AST::Locatable) && !node.is_a?(AST::FunctionDef)
            summary.escape_nodes << node
            if frame.track_with_scope_stack
              frame.with_scope_stack.each { |scope| (summary.with_scope_nodes[scope.object_id] ||= []) << node }
            end
          end

          if node.is_a?(AST::Identifier)
            lambda_node = frame.lambda_body_stack.last
            (summary.lambda_body_identifier_refs[lambda_node.object_id] ||= []) << node if lambda_node
          end

          if suspend_kind && node.is_a?(AST::Locatable)
            summary.suspend_points << Semantic::SuspendPointFact.new(
              id: Semantic::SuspendPointId.new(value: summary.suspend_points.length),
              kind: suspend_kind,
              node: node
            )
          end

          case node
          when AST::ReturnNode
            summary.return_nodes << node
          when AST::VarDecl
            summary.binding_nodes << node
            frame.next_local_ordinal += 1
            frame.next_place_ordinal += 1
            body_id_base = summary.body_id.value * Semantic::BODY_ID_STRIDE
            summary.local_facts << Semantic::LocalFact.new(
              id: Semantic::LocalId.new(value: body_id_base + frame.next_local_ordinal),
              place_id: Semantic::PlaceId.new(value: body_id_base + frame.next_place_ordinal),
              name: node.name.to_s
            )
          when AST::BindExpr
            if node.mode == :assign
              summary.assignment_nodes << node
            else
              summary.binding_nodes << node
              frame.next_local_ordinal += 1
              frame.next_place_ordinal += 1
              body_id_base = summary.body_id.value * Semantic::BODY_ID_STRIDE
              summary.local_facts << Semantic::LocalFact.new(
                id: Semantic::LocalId.new(value: body_id_base + frame.next_local_ordinal),
                place_id: Semantic::PlaceId.new(value: body_id_base + frame.next_place_ordinal),
                name: node.name.to_s
              )
            end
          when AST::Assignment
            summary.assignment_nodes << node
          when AST::Identifier
            summary.references_snapshot = true if node.name == "snapshot"
          when AST::Raise, AST::OrRaise, AST::BgBlock, AST::BgStreamBlock
            summary.raises_directly = true
          when AST::WithBlock
            summary.raises_directly = true if with_block_raises
          when AST::NextExpr
            summary.suspend_points << Semantic::SuspendPointFact.new(
              id: Semantic::SuspendPointId.new(value: summary.suspend_points.length),
              kind: :next,
              node: node
            )
          when AST::YieldExpr
            summary.suspend_points << Semantic::SuspendPointFact.new(
              id: Semantic::SuspendPointId.new(value: summary.suspend_points.length),
              kind: :yield,
              node: node
            )
          when AST::FuncCall
            if frame.record_call_sites
              frame.next_call_site_ordinal += 1
              summary.call_site_facts << Semantic::CallSiteFact.new(
                id: Semantic::CallSiteId.new(value: summary.body_id.value * Semantic::BODY_ID_STRIDE + frame.next_call_site_ordinal),
                node: node,
                callee_name: node.name,
                args: node.args,
                fn_var_call: node.fn_var_call == true,
                propagates_failure: !frame.failure_absorbed
              )
            end

            if node.fn_var_call
              summary.has_fnptr_call = true
            else
              summary.callees.add(node.name)
              summary.propagating_callees.add(node.name) unless frame.failure_absorbed
            end
          end
        end
      end

      sig { params(node: AST::WithBlock).returns(T::Boolean) }
      def with_block_raises_directly?(node)
        return true if node.snapshot_mode == :transaction

        clause = node.lock_error_clause
        return false unless clause

        [AST::ErrorActionKind::Raise, AST::ErrorActionKind::Exit].include?(clause.action) || !clause.bubble_types.empty?
      end

      sig { params(declarations: DeclarationIndex, program: AST::Program).void }
      def analyze_program_bodies!(declarations, program)
        T.bind(self, SemanticAnnotator)

        declarations.body_statements.each { |stmt| visit(stmt) }

        synthetic_function_definitions.each do |fn|
          visit_FunctionDef(fn)
          program.statements << fn
        end
      end
          private :record_async_body_fact!
      private :with_block_raises_directly?
      private :with_body_fact_frame
      private :with_body_fact_scopes_cleared

end
  end
end
