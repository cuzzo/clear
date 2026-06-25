# typed: strict
# fsm_transform/liveness.rb -- live-variable analysis across
# segment boundaries.
#
# A binding defined in one segment and read in a LATER segment
# crosses a suspend boundary -- it must live in the FSM ctx struct
# rather than as a step-local. This module computes that set.
#
# Stage 1: linear segment graphs only. Stage 2 adds back-edges
# (the loop case requires a fixed-point analysis, but for linear
# dispatch-order semantics one forward pass suffices since every
# segment K can only be reached from K-1 or via a back-edge from
# K+M; back-edge sources must already have the variable live, so
# it's the same set).
#
# Returns a struct with:
#
#   cross_segment_vars: { name => CrossSegmentVarFact(type_info:,
#                                                      first_def_seg:,
#                                                      last_use_seg:) }
#
# The lowering uses this to (a) emit ctx struct field decls, and
# (b) rewrite step-local Lets to ctx-field Sets in the segment
# whose body would otherwise declare them locally.

require "sorbet-runtime"
require_relative "../../ast/type"
require_relative "context"

module FsmTransform
  module Liveness
    class CrossSegmentVarFact < T::Struct
      extend T::Sig

      const :type_info, T.nilable(Type)
      const :first_def_seg, Integer
      const :last_use_seg, Integer
    end

    Result = Struct.new(:cross_segment_vars) do
      extend T::Sig
    end

    extend T::Sig

    AstIdentWalkRoot = T.type_alias { T.nilable(T.any(AST::Node, AST::RawBody)) }
    BindingStmt = T.type_alias { T.any(AST::VarDecl, AST::BindExpr) }
    DeclTypeCandidate = T.type_alias { T.nilable(Type::TypeInput) }

    # Returns a Result. ctx provides captured-name set + any
    # already-known state field names that must be excluded
    # (captures aren't local-defined in the body; suspend-stash
    # fields are added by the emitter, not the body).
    sig { params(segments: T::Array[FsmTransform::Segments::Segment], ctx: FsmTransform::ContextMap).returns(Result) }
    def self.analyze(segments, ctx)
      captured = T.cast(ctx.fetch(:captured, {}), FsmTransform::CapturedMap)
      capture_names = T.let(captured.keys.to_set, T::Set[String])

      defs_by_seg = T.let({}, T::Hash[Integer, T::Hash[String, T.nilable(Type)]])
      uses_by_seg = T.let({}, T::Hash[Integer, T::Set[String]])

      segments.each do |seg|
        defs_by_seg[seg.index] = {}
        # Use ||= so collect_tail_uses (which charges suspend-arg
        # reads to seg.index + 1) doesn't get clobbered when the
        # next segment's setup runs.
        uses_by_seg[seg.index] ||= Set.new
        seg.stmts.each do |stmt|
          collect_defs(stmt, defs_by_seg[seg.index])
          collect_uses(stmt, uses_by_seg[seg.index])
        end
        collect_tail_uses(seg, uses_by_seg)
        # The tail can carry a result_var (for IoSuspend /
        # NextSuspend with a binding); that var is "defined" at
        # the end of this segment AND consumed by the next, so
        # it counts as cross-segment by construction.
        if (seg.tail.is_a?(Segments::NextSuspend) ||
            seg.tail.is_a?(Segments::IoSuspend)) &&
           seg.tail.result_var && seg.tail.kind != :io
          # Type info comes from the call's full_type; the
          # emitter resolves it via the AST node when emitting
          # the state field decl.
          T.must(defs_by_seg[seg.index])[seg.tail.result_var] = nil
        end
      end

      first_def = T.let({}, T::Hash[String, Integer])
      last_use = T.let({}, T::Hash[String, Integer])
      type_by_name = T.let({}, T::Hash[String, Type])
      defs_by_seg.each do |seg_idx, defs|
        defs.each do |name, type|
          first_def[name] ||= seg_idx
          # type may have been recorded twice; preserve the first
          # non-nil typing.
          type_by_name[name] ||= type if type
        end
      end
      uses_by_seg.each do |seg_idx, uses|
        uses.each do |name|
          last_use[name] = seg_idx
        end
      end

      # Cycle detection: any segment reachable from itself via tail
      # edges is part of a loop. Defs INSIDE the cycle are read on
      # the next iteration and so cross the iteration boundary --
      # they need ctx fields even when use_seg == def_seg in the
      # linear scan.
      cyclic_segs = compute_cyclic_segments(segments)

      cross = T.let({}, T::Hash[String, CrossSegmentVarFact])
      first_def.each do |name, def_seg|
        next if capture_names.include?(name)

        use_seg = last_use[name]
        next if use_seg.nil?         # defined but never read
        unless use_seg > def_seg
          # Same-segment use is OK only if the segment isn't part
          # of a cycle. In a cycle, "used in def's segment" means
          # "used again next iteration" -> cross-iteration.
          next unless cyclic_segs.include?(def_seg)
        end
        cross[name] = CrossSegmentVarFact.new(
          type_info: type_by_name[name],
          first_def_seg: def_seg,
          last_use_seg: use_seg,
        )
      end

      Result.new(cross)
    end

    # Set of segment indices that are reachable from themselves via
    # tail edges (i.e. members of a non-trivial strongly-connected
    # component, or have a self-loop). Used to widen the live-set
    # for back-edge cases like B2-LOOP's cond+loop_pre+loop_post.
    sig { params(segments: T::Array[FsmTransform::Segments::Segment]).returns(T::Set[Integer]) }
    def self.compute_cyclic_segments(segments)
      adj = {}
      segments.each { |seg| adj[seg.index] = tail_targets(seg) }
      cyclic = Set.new
      segments.each do |seg|
        stack = adj[seg.index].dup
        visited = Set.new
        until stack.empty?
          cur = stack.shift
          if cur == seg.index
            cyclic << seg.index
            break
          end
          next unless visited.add?(cur)
          (adj[cur] || []).each { |t| stack << t }
        end
      end
      cyclic
    end

    # Targets a segment's tail can transition to (for cycle
    # detection). Linear suspends implicitly fall through to
    # seg.index + 1.
    sig { params(seg: T.untyped).returns(T::Array[Integer]) }
    def self.tail_targets(seg)
      case seg.tail
      when Segments::Done                          then []
      when Segments::Goto, Segments::LoopBack      then [seg.tail.target_index]
      when Segments::CondBranch
        [seg.tail.then_index, seg.tail.else_index]
      when Segments::LockSuspend
        [seg.index + 1]
      else
        Segments.suspend_tail?(seg.tail) ? [seg.index + 1] : []
      end
    end

    # Collect identifier reads happening as part of the tail's
    # transition (suspend-call args, etc.).
    #
    # IoSuspend: the kernel reads call args asynchronously between
    # resumeFn returning and the FSM being woken back up. A
    # pre-decl referenced in args MUST live in the ctx struct, not
    # on the runStep0 stack. We charge these reads to seg.index + 1
    # (the post-suspend segment) so they participate in the
    # cross-segment promotion test -- a def in seg K used in K+1
    # crosses, exactly the semantics we want for "the value must
    # outlive seg K's body".
    #
    # NEXT / LOCK suspends already evaluate their source expr
    # inside the body and stash into ctx.sp; subsequent steps
    # reference ctx.sp, not the original identifiers, so no extra
    # tail reads are recorded here.
    sig { params(seg: T.untyped, uses_by_seg: T::Hash[Integer, T::Set[String]]).void }
    def self.collect_tail_uses(seg, uses_by_seg)
      tail = seg.tail
      case tail
      when Segments::IoSuspend
        next_idx = seg.index + 1
        bucket = (uses_by_seg[next_idx] ||= Set.new)
        if tail.call_node.respond_to?(:receiver) && tail.call_node.receiver
          walk_idents(tail.call_node.receiver) { |name| bucket << name }
        end
        args = tail.call_node.respond_to?(:args) ? (tail.call_node.args || []) : []
        args.each do |a|
          walk_idents(a) { |name| bucket << name }
        end
      end
    end

    # Collect names defined by a stmt (var decls + LHS assigns).
    # Type resolution mirrors the legacy collect_fsm_promoted_locals
    # fallback chain so consumers (FSM ctx-field decl emission)
    # always have a usable type.
    sig { params(stmt: T.untyped, into: T.untyped).void }
    def self.collect_defs(stmt, into)
      case stmt
      when AST::VarDecl, AST::BindExpr
        if stmt.name.is_a?(String)
          # Skip non-decl BindExpr (mode :assign) -- not a definition
          # in the live-set sense.
          if stmt.is_a?(AST::BindExpr) && stmt.respond_to?(:mode) &&
              stmt.mode != :decl
            return
          end
          t = stmt_decl_type(stmt)
          into[stmt.name] ||= t
        end
      when AST::Assignment
        if stmt.name.is_a?(String)
          into[stmt.name] ||= nil
        end
      end
    end

    sig { params(stmt: BindingStmt).returns(T.nilable(Type)) }
    def self.stmt_decl_type(stmt)
      candidates = T.let([], T::Array[DeclTypeCandidate])
      candidates << stmt.full_type!(context: "FSM liveness declaration")
      candidates << T.cast(T.unsafe(stmt).type, DeclTypeCandidate) if stmt.respond_to?(:type)
      candidates << T.cast(T.unsafe(stmt).declared_type, DeclTypeCandidate) if stmt.respond_to?(:declared_type)
      value = stmt.value
      candidates << value.full_type!(context: "FSM liveness declaration value") if value
      normalize_decl_type(candidates.compact.first)
    end

    sig { params(value: DeclTypeCandidate).returns(T.nilable(Type)) }
    def self.normalize_decl_type(value)
      return nil if value.nil?

      Type.new(value)
    end

    # Collect identifier reads anywhere in stmt's expressions.
    sig { params(stmt: T.untyped, into: T.nilable(T::Set[String])).void }
    def self.collect_uses(stmt, into)
      return unless into
      walk_idents(stmt) { |name| into << name }
    end

    # Recursively walk AST nodes looking for Identifier reads. We only push
    # AST::Node children from AST structs/arrays so Type objects, tokens, and
    # other struct-valued metadata never become scanner inputs.
    sig { params(node: AstIdentWalkRoot, block: T.proc.params(name: String).void).void }
    def self.walk_idents(node, &block)
      return if node.nil?

      stack = T.let([], T::Array[AST::Node])
      case node
      when Array
        node.reverse_each { |child| stack << child if child.is_a?(AST::Locatable) }
      when AST::Locatable
        stack << node
      end
      until stack.empty?
        current = T.must(stack.pop)
        if current.is_a?(AST::Identifier)
          yield current.name
          next
        end
        next unless current.respond_to?(:each_pair)

        T.unsafe(current).each_pair do |_name, value|
          case value
          when Array
            value.reverse_each { |child| stack << child if child.is_a?(AST::Locatable) }
          when Hash
            value.each do |key, child|
              stack << key if key.is_a?(AST::Locatable)
              stack << child if child.is_a?(AST::Locatable)
            end
          when AST::Locatable
            stack << value
          end
        end
      end
    end
    private_class_method :collect_defs
    private_class_method :collect_tail_uses
    private_class_method :collect_uses
    private_class_method :compute_cyclic_segments
    private_class_method :normalize_decl_type
    private_class_method :stmt_decl_type
    private_class_method :tail_targets

end
end
