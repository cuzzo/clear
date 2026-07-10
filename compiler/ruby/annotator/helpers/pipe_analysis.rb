# typed: strict
require "sorbet-runtime"
require_relative "../../ast/ast"
require_relative "../../ast/type"
require 'set'

module PipeAnalysis
    extend T::Sig
    extend T::Helpers

  requires_ancestor { SemanticAnnotator }

  ConcurrentOptions = T.type_alias { T::Hash[String, AST::Node] }
  ShardScanNode = T.type_alias { T.nilable(T.any(AST::Locatable, AST::RawBody)) }

  class PipeArityPlan < T::Struct
    extend T::Sig

    const :params, T::Array[AST::Param]
    const :min_args, Integer
    const :max_args, Integer
    const :given_args, Integer

    sig { returns(T::Boolean) }
    def mismatch?
      given_args < min_args || given_args > max_args
    end

    sig { returns(T::Boolean) }
    def exact?
      min_args == max_args
    end
  end

  class PipelineSourceFact < T::Struct
    extend T::Sig

    const :kind, Symbol
    const :item_type, Symbol

    sig { returns(T::Boolean) }
    def stream?
      valid? && kind != :collection
    end

    sig { returns(T::Boolean) }
    def finite_stream?
      stream? && kind != :inf_stream
    end

    sig { returns(T::Boolean) }
    def inf_stream?
      kind == :inf_stream
    end

    sig { returns(T::Boolean) }
    def valid?
      kind != :invalid
    end
  end

  # =========================================================
  # SMOOTH OPERATOR (|>)
  # =========================================================
  sig { params(node: AST::BinaryOp).returns(T.nilable(Integer)) }
  def visit_Smooth(node)
    T.bind(self, SemanticAnnotator) rescue nil
    with_smooth_context do
      # Logic: x |> f  -> f(x)

      # 1. Visit the Left (Input) FIRST
      visit(node.left)
      source_type = node.left.full_type!(context: "pipeline left")
      record_body_fact_pipe_input_type!(source_type.resolved.to_s) if source_type.catch_snapshot_payload?

      if pipe_complex_op?(node.right)
        analyze_higher_order_op(node)
      elsif node.right.is_a?(AST::FuncCall)
        analyze_pipe_to_func_call(node)
      elsif node.right.is_a?(AST::Identifier)
        analyze_pipe_to_identifier(node)
      else
        # Case 3: Invalid RHS (e.g. 10 |> (expression))
        error!(node, :PIPE_BAD_DESTINATION)
        stamp_type!(node, :Any)
      end
    end
    smooth_depth
  end

  private

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def pipe_complex_op?(node)
    AST.pipeline_complex_op?(node) || node.is_a?(AST::RecoverOp) || node.is_a?(AST::CollectOp)
  end

  sig { params(options: ConcurrentOptions).returns(T::Boolean) }
  def concurrent_parallel_enabled?(options)
    value = options["parallel"]
    !!(value.is_a?(AST::Identifier) && %w[true TRUE].include?(value.name))
  end

  # Observable Phase 2.2 + COLLECT-default: a fold-terminal whose
  # source is a tense stream (`~T[...]`) is observable by default.
  # The pipe BinaryOp gets:
  #   - `observable_terminal = true` (Phase 2.2 marker; consumed by
  #     WITH VIEW gating)
  #   - `observable_dest = true` (codegen marker; consumed by the
  #     pipeline_host SumOp branch to emit accumulator+finish)
  # The caller (analyze_sum_op etc.) ALSO lifts the pipe's
  # full_type to `~T@observable` so the binding inherits the
  # observable type without requiring an explicit annotation. The
  # user joins via `|> COLLECT` (or NEXT) to get back a scalar T.
  sig { params(node: AST::BinaryOp).returns(T.nilable(T::Boolean)) }
  def stamp_observable_terminal!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # RangeLits annotate as `~Int64[]` (a tense dynamic_stream) but
    # fold eagerly to a scalar -- there's no fiber producing values
    # while a reader could WITH VIEW the accumulator. Exclude them.
    return if node.left.is_a?(AST::RangeLit)
    ti = node.left.full_type!(context: "pipeline left")
    return unless ti && ti.future? &&
                  (ti.dynamic_stream? || ti.inf_stream? || ti.open_stream? || ti.bounded_stream?)
    node.observable_terminal = true
    node.observable_dest = true
    if node.left.is_a?(AST::Identifier)
      node.left.was_moved = true
      og_set_moved(node.left.name, at_token: node.left.token, action: :takes)
    end
    true
  end

  # Lift a fold-pipe's result type to its `~T@observable` form when
  # the source qualifies (per stamp_observable_terminal!). Caller
  # passes the terminal kind and the lifted-Type kwargs (raw symbol
  # + capability flags); we wrap and stamp on the pipe so downstream
  # type-checking (the bind site, COLLECT, NEXT) sees the observable
  # type. Type#zig_type uses `observable_terminal` to pick the right
  # `Observable*` wrapper.
  #
  #   lift_to_observable_if_terminal!(node, terminal: :sum,
  #     raw: :"~Int64")
  #   lift_to_observable_if_terminal!(node, terminal: :distinct,
  #     raw: :"~Int64[]", collection: :set)
  sig { params(node: AST::BinaryOp, terminal: Symbol, raw: Symbol, type_kwargs: T.untyped).returns(T.nilable(Type)) }
  def lift_to_observable_if_terminal!(node, terminal:, raw:, **type_kwargs)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless node.observable_terminal
    stamp_type!(node, Type.new(raw,
                               observable: true,
                               observable_terminal: terminal,
                               **type_kwargs))
  end

  # M5: collapse the stamp + lift pair that every analyze_*_op call site
  # repeats. Equivalent to:
  #   stamp_observable_terminal!(node)
  #   lift_to_observable_if_terminal!(node, terminal:, raw:, **type_kwargs)
  # Two-line stamp + lift remained the previous shape because earlier
  # the lift had a separate guard. With both checks now living in
  # stamp_observable_terminal!, the only argumentation a call site
  # carries is terminal kind + raw type + extra type kwargs, so a
  # single helper is enough.
  sig { params(node: AST::BinaryOp, terminal: Symbol, raw: Symbol, type_kwargs: T.untyped).returns(T.nilable(Type)) }
  def mark_observable_terminal!(node, terminal:, raw:, **type_kwargs)
    T.bind(self, SemanticAnnotator) rescue nil
    stamp_observable_terminal!(node)
    lift_to_observable_if_terminal!(node, **T.unsafe({terminal: terminal, raw: raw, **type_kwargs}))
  end

  sig { params(node: AST::Locatable).returns(T::Boolean) }
  def bounded_stream_source?(node)
    T.bind(self, SemanticAnnotator) rescue nil
    node.full_type!(context: "pipeline result").bounded_stream?
  end

  sig { params(source: AST::Locatable, source_type: Type, include_inf_stream: T::Boolean).returns(PipelineSourceFact) }
  def pipeline_source_fact(source, source_type, include_inf_stream: false)
    T.bind(self, SemanticAnnotator) rescue nil
    if include_inf_stream && source_type.inf_stream?
      return PipelineSourceFact.new(kind: :inf_stream, item_type: T.must(source_type.inf_stream_element_type).resolved)
    end

    return PipelineSourceFact.new(kind: :range, item_type: range_element_type(source).resolved) if source.is_a?(AST::RangeLit)

    if source_type.open_stream?
      return PipelineSourceFact.new(kind: :open_stream, item_type: T.must(source_type.open_stream_element_type).resolved)
    end

    if source_type.dynamic_stream?
      return PipelineSourceFact.new(kind: :dynamic_stream, item_type: T.must(source_type.tense_type.element_type).resolved)
    end

    if source_type.bounded_stream?
      return PipelineSourceFact.new(kind: :bounded_stream, item_type: T.must(source_type.tense_type.element_type).resolved)
    end

    element_type = source_type.element_type
    return PipelineSourceFact.new(kind: :collection, item_type: element_type.resolved) if source_type.linear_collection? && element_type

    PipelineSourceFact.new(kind: :invalid, item_type: :Any)
  end

  sig { returns(T::Boolean) }
  def has_catch_blocks?
    T.bind(self, SemanticAnnotator) rescue nil
    fn_name = current_fn_ctx&.name
    fn_nodes = function_node_map
    fn = fn_name ? fn_nodes[fn_name] : nil
    fn ? function_has_catch_clauses?(fn) : false
  end

  sig { params(node: AST::BinaryOp).returns(Type) }
  def analyze_higher_order_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    case node.right
    when AST::SelectOp, AST::WhereOp, AST::IndexOp, AST::OrderByOp
      analyze_select_family_op(node)
    when AST::ReduceOp
      analyze_reduce_op(node)
    when AST::LimitOp
      analyze_limit_op(node)
    when AST::UnnestOp
      analyze_unnest_op(node)
    when AST::DistinctOp
      analyze_distinct_op(node)
    when AST::EachOp
      analyze_each_op(node)
    when AST::FindOp
      analyze_find_op(node)
    when AST::AnyOp
      analyze_any_op(node)
    when AST::AllOp
      analyze_all_op(node)
    when AST::CountOp
      analyze_count_op(node)
    when AST::SumOp
      analyze_sum_op(node)
    when AST::AverageOp
      analyze_average_op(node)
    when AST::MinOp
      analyze_min_op(node)
    when AST::MaxOp
      analyze_max_op(node)
    when AST::ConcurrentOp
      analyze_concurrent_op(node)
    when AST::ShardOp
      analyze_shard_op(node)
    when AST::SkipOp
      analyze_skip_op(node)
    when AST::TapOp
      analyze_tap_op(node)
    when AST::TakeWhileOp
      analyze_take_while_op(node)
    when AST::WindowOp
      analyze_window_op(node)
    when AST::BatchWindowOp
      analyze_batch_window_op(node)
    when AST::JoinOp
      analyze_join_op(node)
    when AST::RecoverOp
      analyze_recover_op(node)
    when AST::CollectOp
      analyze_collect_op(node)
    end

    # Every analyze_* above stamps node.full_type!(context: "pipeline result") with the pipeline's
    # type AFTER this op. The op node itself evaluates to exactly that
    # (a transform op -> the post-op stream type; a terminal -> its
    # result / Void). Stamp it so no pipeline op reaches MIR untyped.
    # Sole owner of a pipeline op node's type — assign unconditionally.
    stamp_type!(node.right, node.full_type!(context: "pipeline result"))
  end

  # COLLECT: pipe-terminal that joins a `~T@observable` and returns
  # the underlying T. Validates the LHS is observable; sets result
  # type to the inner element of the observable. Marks the LHS as
  # moved so the consume-or-transfer rule for ~T futures sees the
  # binding as consumed.
  sig { params(node: AST::BinaryOp).returns(Symbol) }
  def analyze_collect_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    lhs_t = node.left.full_type!(context: "pipeline left")
    unless lhs_t&.future? && lhs_t.observable?
      ty = lhs_t&.resolved || "<unknown>"
      error!(node, :COLLECT_NEEDS_OBSERVABLE, got: ty)
    end
    # Mark the source binding as consumed -- COLLECT is the explicit
    # join, equivalent to NEXT for the future-consume check.
    og_set_moved(node.left.name, at_token: node.left.token, action: :collect) if node.left.is_a?(AST::Identifier)
    inner = lhs_t&.tense_type
    # Collection observable (DISTINCT producing `~T[]@set:observable`):
    # COLLECT yields an owned `T[]` snapshot via `materializeNext`, not
    # the bare set type. Mirrors visit_NextExpr's collection branch so
    # the binding's cleanup classifier picks the list-cleanup template.
    if lhs_t&.observable? && inner&.array?
      elem_sym = inner.element_type.to_sym
      stamp_type!(node, Type.new(:"#{elem_sym}[]"))
      node.storage   = :heap
    else
      stamp_type!(node, inner ? inner.resolved : :Any)
      node.storage   = :stack
    end
  end

  # SELECT, WHERE, INDEX, ORDER_BY share similar structure.
  # SELECT and WHERE also accept a RangeLit or InfStream source (fused lazy path).
  # INDEX accepts finite stream sources (~T[], ~T[N]).
  sig { params(node: AST::BinaryOp).returns(T.nilable(Integer)) }
  def analyze_select_family_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    is_filter = AST.pipeline_select_filter_op?(node.right)
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type, include_inf_stream: is_filter)
    is_stream = source.stream? && (is_filter || node.right.is_a?(AST::IndexOp))
    require_array_input!(node, "SELECT", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    # Create a temporary Scope for the body
    with_new_scope do
      # Declare '_' with the specific item type
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)

      # Analyze the Body (e.g., _["count"])
      with_soa_tracking(node, item_type) do
        visit(node.right.expression)
      end

      if node.right.is_a?(AST::WhereOp) && node.right.expression.resolved_type != :Bool
        error!(node.right, :WHERE_NEEDS_BOOL)
      end
    end

    # Set Result Type based on operator.
    # InfStream sources propagate ~T[INF] so downstream fusible ops and LIMIT
    # can see the source is still infinite; LIMIT will convert to T[].
    case node.right
    when AST::SelectOp
      result_base = node.right.expression.full_type!(context: "pipeline op expression")
      stamp_type!(node, source.inf_stream? ? :"~#{result_base}[INF]" : :"#{result_base}[]")
    when AST::WhereOp
      stamp_type!(node, source.inf_stream? ? :"~#{item_type}[INF]" : :"#{item_type}[]")
    when AST::IndexOp
      # INDEX returns HashMap<KeyType, ElementType[]>
      key_type = node.right.expression.resolved_type
      stamp_type!(node, Type.new(:"HashMap<#{item_type}[]>"))
      stamp_type!(node.right, key_type)
    when AST::OrderByOp
      # ORDER_BY returns the same list type, sorted
      stamp_type!(node, Type.new(:"#{item_type}[]"))
      stamp_type!(node.right, node.right.expression.resolved_type)
    end

    node.storage = :frame

    # WHERE/SELECT/ORDER_BY allocate intermediate ArrayListUnmanaged at the
    # transpiler level via rt.frameAlloc(). InfStream results are not materialized;
    # only count frame allocation for finite (list-producing) results.
    current_fn_ctx&.record_frame_use! unless source.inf_stream?
    nil
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Integer)) }
  def analyze_take_while_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type, include_inf_stream: true)
    is_stream = source.stream?
    require_array_input!(node, "TAKE_WHILE", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, :TAKE_WHILE_NEEDS_BOOL, got: node.right.expression.resolved_type)
    end

    stamp_type!(node, source.inf_stream? ? :"~#{item_type}[INF]" : :"#{item_type}[]")
    node.storage = :frame
    current_fn_ctx&.record_frame_use! unless source.inf_stream?
    nil
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Integer)) }
  def analyze_window_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    require_array_input!(node, "WINDOW")
    item_type = node.left.full_type!(context: "pipeline left").element_type.resolved

    # Validate the size argument is numeric
    visit(node.right.size)
    size_type = node.right.size.resolved_type
    unless [:Int64, :Float64].include?(size_type)
      error!(node.right.size, :WINDOW_SIZE_NEEDS_NUMBER, got: size_type)
    end

    # _ is a sub-slice of the same element type
    with_new_scope do
      current_scope.declare("_", nil, :"#{item_type}[]", false, false, nil, :stack)
      visit(node.right.expression)
    end

    # Result is a list of whatever the expression produces
    expr_type = node.right.expression.full_type!(context: "WINDOW expression")
    stamp_type!(node, Type.new(:"#{expr_type}[]"))
    node.storage = :frame
    current_fn_ctx&.record_frame_use!
    nil
  end

  # Time string format: '500ms', '1s', '2min', '1h'
  BATCH_WINDOW_TIME_RE = T.let(/\A(\d+(?:\.\d+)?)(ms|s|min|h)\z/.freeze, Regexp)
  BATCH_WINDOW_TIME_NS = T.let({ 'ms' => 1_000_000, 's' => 1_000_000_000, 'min' => 60_000_000_000, 'h' => 3_600_000_000_000 }.freeze, T::Hash[String, Integer])

  sig { params(str: String).returns(T.nilable(Integer)) }
  def parse_batch_window_time_ns(str)
    T.bind(self, SemanticAnnotator) rescue nil
    m = BATCH_WINDOW_TIME_RE.match(str)
    return nil unless m
    (m[1].to_f * T.must(BATCH_WINDOW_TIME_NS[T.must(m[2])])).to_i
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Integer)) }
  def analyze_batch_window_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    opts = node.right.options
    bw = node.right

    valid_keys = %w[size time]
    opts.each_key do |k|
      error!(bw.token, :WINDOW_BAD_OPTION, name: k, valid: valid_keys.join(', ')) unless valid_keys.include?(k)
    end

    unless opts.key?("size") || opts.key?("time")
      error!(bw.token, :WINDOW_NEEDS_SIZE_OR_TIME)
    end

    # Validate size
    if opts["size"]
      visit(opts["size"])
      size_type = opts["size"].resolved_type
      unless [:Int64, :Float64].include?(size_type)
        error!(opts["size"], :WINDOW_SIZE_NEEDS_NUMBER, got: size_type)
      end
      if opts["size"].is_a?(AST::Literal)
        v = opts["size"].value.to_f
        error!(opts["size"], :WINDOW_SIZE_NEEDS_POSITIVE) if v <= 0
      end
    end

    # Validate time string and compute nanoseconds
    if opts["time"]
      visit(opts["time"])
      unless opts["time"].is_a?(AST::Literal) && opts["time"].type == :STRING
        error!(opts["time"], :WINDOW_TIME_NEEDS_STRING_LIT)
      end
      ns = parse_batch_window_time_ns(opts["time"].value)
      error!(opts["time"], :WINDOW_TIME_BAD_FORMAT, got: opts["time"].value) unless ns
      error!(opts["time"], :WINDOW_TIME_NEEDS_POSITIVE) if ns <= 0
    end

    # Determine input element type (works for arrays and all stream types)
    left_ti = node.left.full_type!(context: "pipeline left")
    item_type = if left_ti&.inf_stream?
      left_ti.inf_stream_element_type.resolved
    elsif left_ti&.open_stream? || left_ti&.dynamic_stream?
      left_ti.open_stream_element_type.resolved
    elsif left_ti&.bounded_stream?
      left_ti.stream_element_type.resolved
    elsif left_ti&.element_type
      left_ti.element_type.resolved
    else
      error!(node.left, :WINDOW_NEEDS_COLLECTION_INPUT)
    end

    # _ is a batch: T[]
    with_new_scope do
      current_scope.declare("_", nil, :"#{item_type}[]", false, false, nil, :stack)
      visit(bw.expression)
    end

    expr_type = bw.expression.full_type!(context: "BATCH WINDOW expression")
    stamp_type!(node, Type.new(:"#{expr_type}[]"))
    node.storage = :heap
    current_fn_ctx&.record_frame_use!
    nil
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Integer)) }
  def analyze_join_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    require_array_input!(node, "JOIN")
    left_type = node.left.full_type!(context: "pipeline left").element_type.resolved

    # Visit and validate the right source
    visit(node.right.right_source)
    rhs_type_info = node.right.right_source.full_type!(context: "pipeline right source")
    unless node.right.right_source.metatype == :array || rhs_type_info&.collection?
      error!(node.right.right_source, :JOIN_RIGHT_NEEDS_LIST, got: node.right.right_source.resolved_type)
    end
    right_type = rhs_type_info.element_type.resolved

    key_expr = node.right.key_expr

    if key_expr.is_a?(AST::LambdaLit)
      # Lambda form: %(a, b) -> a.id == b.userId
      params = key_expr.params
      error!(key_expr, :JOIN_LAMBDA_ARITY) unless params.size == 2
      left_name  = params[0].name
      right_name = params[1].name
      with_new_scope do
        current_scope.declare(left_name, nil, left_type, false, false, nil, :stack)
        current_scope.declare(right_name, nil, right_type, false, false, nil, :stack)
        AST.lambda_body_nodes(key_expr.body).each { |stmt| visit(stmt) }
      end
      key_result = AST.lambda_body_nodes(key_expr.body).last
      unless key_result&.resolved_type == :Bool
        error!(key_expr, :JOIN_LAMBDA_NEEDS_BOOL, got: key_result&.resolved_type)
      end
      # The JOIN key lambda IS a predicate ((left,right)->Bool). Type
      # the LambdaLit via the standard lambda-signature builder (same
      # as visit_LambdaLit) — its return is the Bool just validated.
      stamp_type!(key_expr, build_lambda_signature(params, :Bool))
    else
      # Shared key form: _.field applied to both sides
      # Validate the key expression with _ as left type
      with_new_scope do
        current_scope.declare("_", nil, left_type, false, false, nil, :stack)
        visit(key_expr)
      end
      # Also validate with right type (both must have the field)
      with_new_scope do
        current_scope.declare("_", nil, right_type, false, false, nil, :stack)
        visit(key_expr)
      end
    end

    # Register a synthetic struct type for the join result so field access works.
    join_type_name = :"JoinResult_#{left_type}_#{right_type}"
    unless current_scope.resolve_type_definition(join_type_name)
      current_scope.declare_type(join_type_name, Schemas::StructSchema.new(fields: {
        "left"  => AST::StructField.new(type: left_type),
        "right" => AST::StructField.new(type: :"?#{right_type}"),
      }))
    end

    stamp_type!(node, Type.new(:"#{join_type_name}[]"))
    node.storage = :frame
    current_fn_ctx&.record_frame_use!
    nil
  end

  sig { params(node: AST::BinaryOp).returns(Symbol) }
  def analyze_recover_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # RECOVER(default): replace error with default value in pipeline
    visit(node.right.default_expr)
    lhs_type = node.left.full_type!(context: "pipeline left")
    lhs_t = lhs_type ? Type.new(lhs_type) : nil
    if lhs_t&.error_union?
      stamp_type!(node, T.must(lhs_t.payload_type).resolved)
    else
      stamp_type!(node, lhs_type)
    end
    node.storage = :stack
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_reduce_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # REDUCE: list |> REDUCE(initial) acc + _.value
    # Also accepts range/stream sources for the fused lazy path.
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type)
    is_stream = source.finite_stream?
    require_array_input!(node, "REDUCE", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    # Analyze the initial value to get the accumulator type
    visit(node.right.initial_value)
    acc_type = node.right.initial_value.resolved_type

    # Create scope with both 'acc' and '_'
    with_new_scope do
      # 'acc' is mutable (it accumulates)
      current_scope.declare("acc", nil, acc_type, true, false, nil, :stack)
      # '_' is the current element
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)

      # Analyze the body expression
      visit(node.right.expression)
    end

    # Result type is the accumulator type
    stamp_type!(node, acc_type)
    stamp_type!(node.right, acc_type)
    node.storage = :stack

    # REDUCE is observable only with a scalar atomic-backing accumulator.
    # Collection accumulators (REDUCE acc.append(_)) use moving structure.
    # H10: scalar must additionally be a numeric primitive -- AtomicReduce
    # uses AtomicFor(T), which only specializes for int/float. String,
    # Bool, struct, and tagged-union accumulators would compile-error
    # inside Zig with "observable accumulator: T must be int or float";
    # reject them here with a CLEAR-level message instead.
    acc_t = Type.new(acc_type)
    unless acc_t.collection_value?
      if observable_reducible_scalar?(acc_type)
        mark_observable_terminal!(node, terminal: :reduce, raw: :"~#{acc_type}")
      end
    end
  end

  # True for accumulator types AtomicReduce(T) can wrap. AtomicFor(T) in
  # observable.zig admits int and float only; Bool / String / structs
  # would compile-error in Zig. Mirrored here so we reject the bind at
  # CLEAR-annotation time with a clear error.
  OBSERVABLE_REDUCIBLE_NUMERIC = %i[
    Int8 Int16 Int32 Int64
    UInt8 Byte UInt16 UInt32 UInt64
    Float32 Float64
  ].freeze

  sig { params(acc_type: Symbol).returns(T::Boolean) }
  def observable_reducible_scalar?(acc_type)
    T.bind(self, SemanticAnnotator) rescue nil
    OBSERVABLE_REDUCIBLE_NUMERIC.include?(acc_type)
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Symbol)) }
  def analyze_limit_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # LIMIT: list |> LIMIT n
    # Also accepts range and stream sources (fused lazy path).
    lhs_ti    = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_ti, include_inf_stream: true)
    is_stream = source.stream?
    require_array_input!(node, "LIMIT", allow_range: is_stream, allow_stream: is_stream)

    item_type = source.item_type

    # Analyze the count expression
    visit(node.right.count)
    count_type = node.right.count.resolved_type
    unless [:Int64, :Float64].include?(count_type)
      error!(node.right.count, :LIMIT_COUNT_NEEDS_NUMBER, got: count_type)
    end

    # Result type is a materialized list of the element type
    stamp_type!(node, Type.new(:"#{item_type}[]"))
    node.storage = :frame
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(SymbolEntry)) }
  def analyze_unnest_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # UNNEST: list |> UNNEST _.arr (flatmap)
    # Optional inner binding: UNNEST _.arr AS $o  parses as UNNEST BIND_VAR(_.arr, $o)
    # because :pipe_expression uses parse_expression(1) which consumes AS at prec 2.
    require_array_input!(node, "UNNEST")
    item_type = node.left.full_type!(context: "pipeline left").element_type.resolved

    # Detect inner binding: UNNEST expr AS @name -> expression is BIND_VAR(expr, @name)
    inner_bind_name = nil
    expr = node.right.expression
    if expr.is_a?(AST::BinaryOp) && expr.op == :BIND_VAR
      inner_bind_name = expr.right.name  # e.g. "$o"
    end

    # Analyze the expression with '_' in scope
    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    # Check that the expression evaluates to an array type
    expr_type = Type.new(node.right.expression.full_type!(context: "pipeline op expression"))
    unless expr_type.array?
      error!(node.right.expression, :UNNEST_NEEDS_ARRAY, got: node.right.expression.resolved_type)
    end

    # Result type is the element type of the nested array
    nested_element_type = T.must(expr_type.element_type).resolved
    stamp_type!(node, Type.new(:"#{nested_element_type}[]"))
    stamp_type!(node.right, node.right.expression.full_type!(context: "pipeline op expression"))
    node.storage = :frame

    # Promote inner binding to the outer scope so subsequent pipeline stages can see it.
    # BIND_VAR was visited inside the temp scope, so $o was declared there and is now gone.
    # Re-declare it in current_scope (the scope that persists after this method returns).
    if inner_bind_name
      current_scope.declare(inner_bind_name, nil, nested_element_type.to_s, false, false, nil, :stack)
    end
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_distinct_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # DISTINCT: list |> DISTINCT _.field (or just DISTINCT _)
    # Returns a Set of unique key values (T[]@set or T[N]@set).
    lhs_type  = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type, include_inf_stream: true)
    is_stream = source.stream?

    require_array_input!(node, "DISTINCT", allow_range: is_stream, allow_stream: is_stream)

    item_type = source.item_type

    # Analyze the expression with '_' in scope
    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    # Key type is what the expression evaluates to; result is a Set of those keys.
    key_type = node.right.expression.resolved_type
    stamp_type!(node.right, key_type)

    # Bounded stream source (~T[N]) → lift to ~K[N]@set:observable so the
    # codegen picks ObservableStreamSetBounded(K, N): fixed-capacity, no
    # grow path, no refcounted snapshots. Falls back to dynamic ~K[]@set
    # for unbounded / range / dynamic / inf-stream sources.
    bounded_n = if lhs_type&.bounded_stream?
      shape = lhs_type.tense_type.fixed? ? lhs_type.tense_type : lhs_type.optional_stream_shape_type
      shape&.capacity
    end
    if bounded_n
      stamp_type!(node, Type.new(:"#{key_type}[#{bounded_n}]", collection: :set))
      node.storage = :heap
      current_fn_ctx&.record_heap_use!
      mark_observable_terminal!(node, terminal: :distinct, raw: :"~#{key_type}[#{bounded_n}]", collection: :set)
    else
      stamp_type!(node, Type.new(:"#{key_type}[]", collection: :set))
      node.storage = :heap
      current_fn_ctx&.record_heap_use!
      mark_observable_terminal!(node, terminal: :distinct, raw: :"~#{key_type}[]", collection: :set)
    end
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_pipe_to_func_call(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # Case 1: x |> f(y)  => f(x, y)
    # We intentionally modify the AST temporarily to leverage visit_FuncCall's
    # existing validation logic (arity, type checks, intrinsics).

    # Inject LHS as the first argument (UFC), call, uninject / eject / pop.
    node.right.args.unshift(node.left)
    visit(node.right)
    node.right.args.shift

    # Propagate Result Type. In functions with CATCH blocks, unwrap error
    # unions — the CATCH handles errors locally, so the pipe result is T not !T.
    result_type = node.right.full_type!(context: "pipeline right")
    if has_catch_blocks? && result_type
      t = Type.new(result_type)
      result_type = T.must(t.payload_type).resolved if t.error_union?
    end
    stamp_type!(node, result_type)
  end

  sig { params(node: AST::BinaryOp).void }
  def analyze_pipe_to_identifier(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # Case 2: x |> f  => f(x)
    # We must MANUALLY validate this because we aren't creating a FuncCall node.

    visit(node.right) # Resolves 'f' to its Signature/Type

    callable_type = node.right.full_type!(context: "pipeline callable")
    sig = callable_type.fn_type? ? callable_type.function_signature : callable_type.resolved
    func_name = node.right.name

    if sig.is_a?(FunctionSignature)
      # Named Function or Lambda (both use standard signature format)
      analyze_pipe_to_named_function(node, sig, func_name)
    elsif sig == :Intrinsic || sig == :Nil
      # Builtin / Intrinsic
      # e.g. 'print' returns :Nil. 'map' returns :Intrinsic (resolved later via call).
      stamp_type!(node, (sig == :Intrinsic) ? :Any : sig)
    else
      # Not a Callable
      error!(node, :PIPE_NOT_CALLABLE, name: func_name, type: sig)
    end
  end

  sig { params(node: AST::BinaryOp, sig: FunctionSignature, func_name: String).void }
  def analyze_pipe_to_named_function(node, sig, func_name)
    T.bind(self, SemanticAnnotator) rescue nil
    # 1. Validate Arity: Must accept exactly 1 argument (the pipe input)
    plan = pipe_arity_plan(sig, 1)

    if plan.mismatch?
      if plan.exact?
        error!(node, :ARITY_MISMATCH, name: func_name, expected: plan.min_args, got: plan.given_args)
      else
        error!(node, :ARITY_MISMATCH_RANGE,
          name: func_name, min: plan.min_args, max: plan.max_args, got: plan.given_args)
      end
    end

    # 2. Validate Type: The Input must match Parameter 1
    if plan.max_args >= 1
      param = T.must(plan.params[0])
      expected = param.type
      actual = node.left.resolved_type

      # Type.accepts? handles slice coercion (Number[3] -> Number[])
      unless is_safe_autocast?(actual, expected)
        error!(node.left, :ARGUMENT_TYPE_ERROR, fn: "Pipe Input '#{param.name}'", index: 1, expected: expected, got: actual)
      end
    end

    # 3. Set Result Type. Unwrap error unions in CATCH functions.
    result_type = sig.return_type
    if has_catch_blocks? && result_type
      t = result_type.is_a?(Type) ? result_type : Type.new(result_type)
      result_type = T.must(t.payload_type).resolved if t.error_union?
    end
    stamp_type!(node, result_type)
  end

  sig { params(sig: FunctionSignature, given_args: Integer).returns(PipeArityPlan) }
  def pipe_arity_plan(sig, given_args)
    params = sig.params
    PipeArityPlan.new(
      params: params,
      min_args: params.count(&:required),
      max_args: params.size,
      given_args: given_args,
    )
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Symbol)) }
  def analyze_each_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # EACH accepts arrays, collections, and finite streams.
    lhs_type  = node.left.full_type!(context: "pipeline left")
    iterable = pipeline_source_fact(node.left, lhs_type)

    unless iterable.valid?
      error!(node.left, :EACH_NEEDS_COLLECTION, got: node.left.resolved_type)
      stamp_type!(node, :Void)
      return
    end

    item_type = iterable.item_type

    with_new_scope(current_scope) do
      # Mutable: EACH body may mutate the item via field assignment (_.field = value)
      # Use current_scope as parent so outer variables remain visible for reassignment
      # (sum = sum + _ inside EACH should reassign the outer sum, not shadow it).
      current_scope.declare("_", nil, item_type, true, false, nil, :stack)
      with_soa_tracking(node, item_type) do
        node.right.body.each { |stmt| visit(stmt) }
      end
    end

    stamp_type!(node, :Void)
    node.storage   = :frame
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Symbol)) }
  def analyze_skip_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # SKIP: list |> SKIP n -> same list type with first n elements removed (also accepts range/InfStream)
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type, include_inf_stream: true)
    is_stream = source.stream?
    require_array_input!(node, "SKIP", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    visit(node.right.count)
    count_type = node.right.count.resolved_type
    unless [:Int64, :Float64].include?(count_type)
      error!(node.right.count, :SKIP_COUNT_NEEDS_NUMBER, got: count_type)
    end

    stamp_type!(node, source.inf_stream? ? :"~#{item_type}[INF]" : :"#{item_type}[]")
    node.storage = :frame
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Symbol)) }
  def analyze_tap_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # TAP: list |> TAP { body } -> same list type (pass-through); also accepts range/stream source.
    lhs_type = node.left.full_type!(context: "pipeline left")
    iterable = pipeline_source_fact(node.left, lhs_type, include_inf_stream: true)

    unless iterable.valid?
      error!(node.left, :TAP_NEEDS_COLLECTION, got: node.left.resolved_type)
      stamp_type!(node, :Void)
      return
    end

    item_type = iterable.item_type

    with_new_scope do
      # Read-only: TAP is for observation, not mutation
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      node.right.body.each { |stmt| visit(stmt) }
    end

    # TAP returns the original collection (pass-through); range stays range
    stamp_type!(node, lhs_type)
    node.storage = node.left.storage
  end

  # =========================================================
  # Phase 3: Predicate Query Operators (FIND, ANY, ALL, COUNT)
  # =========================================================

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_find_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # FIND: list |> FIND predicate  → ?ElemType (first match or null; also accepts range)
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type)
    is_stream = source.finite_stream?
    require_array_input!(node, "FIND", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, :PIPE_CLAUSE_NEEDS_BOOL, clause: "FIND", got: node.right.expression.resolved_type)
    end

    stamp_type!(node, Type.new(:"?#{item_type}"))
    node.storage   = :stack
    mark_observable_terminal!(node, terminal: :find, raw: :"~?#{item_type}")
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_any_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # ANY: list |> ANY predicate  → Bool (short-circuits; also accepts range)
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type)
    is_stream = source.finite_stream?
    require_array_input!(node, "ANY", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, :PIPE_CLAUSE_NEEDS_BOOL, clause: "ANY", got: node.right.expression.resolved_type)
    end

    stamp_type!(node, :Bool)
    node.storage   = :stack
    mark_observable_terminal!(node, terminal: :any, raw: :"~Bool")
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_all_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # ALL: list |> ALL predicate  → Bool (vacuous truth on empty; also accepts range)
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type)
    is_stream = source.finite_stream?
    require_array_input!(node, "ALL", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, :PIPE_CLAUSE_NEEDS_BOOL, clause: "ALL", got: node.right.expression.resolved_type)
    end

    stamp_type!(node, :Bool)
    node.storage   = :stack
    mark_observable_terminal!(node, terminal: :all, raw: :"~Bool")
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_count_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # COUNT: list |> COUNT predicate  → Int64 (also accepts range)
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type)
    is_stream = source.finite_stream?
    require_array_input!(node, "COUNT", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, :PIPE_CLAUSE_NEEDS_BOOL, clause: "COUNT", got: node.right.expression.resolved_type)
    end

    stamp_type!(node, :Int64)
    node.storage   = :stack
    mark_observable_terminal!(node, terminal: :count, raw: :"~Int64")
  end

  # =========================================================
  # Phase 4: Numeric Aggregation Operators (SUM, AVERAGE, MIN, MAX)
  # =========================================================

  # Use Type#numeric? for consistency with the type system.
  # Covers :Float64, :Int64, :Byte, :Float64.

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_sum_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # SUM: list |> SUM expr  → upsized numeric type (int→Int64/UInt64, float→same float)
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type)
    is_stream = source.finite_stream?
    require_array_input!(node, "SUM", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
      error!(node.right, :PIPE_NEEDS_NUMERIC, op: "SUM", got: expr_type)
    end

    stamp_type!(node, sum_result_clear_type(expr_type))
    node.storage   = :stack
    mark_observable_terminal!(node, terminal: :sum, raw: :"~#{sum_result_clear_type(expr_type)}")
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_average_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # AVERAGE: list |> AVERAGE expr  → Float64 (0 for empty; also accepts range)
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type)
    is_stream = source.finite_stream?
    require_array_input!(node, "AVERAGE", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
      error!(node.right, :PIPE_NEEDS_NUMERIC, op: "AVERAGE", got: expr_type)
    end

    stamp_type!(node, :Float64)
    node.storage   = :stack
    mark_observable_terminal!(node, terminal: :avg, raw: :"~Float64")
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_min_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # MIN: list |> MIN expr  → exact expression type (panics on empty; also accepts range)
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type)
    is_stream = source.finite_stream?
    require_array_input!(node, "MIN", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
      error!(node.right, :PIPE_NEEDS_NUMERIC, op: "MIN", got: expr_type)
    end

    stamp_type!(node, expr_type)
    node.storage   = :stack
    mark_observable_terminal!(node, terminal: :min, raw: :"~#{expr_type}")
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Type)) }
  def analyze_max_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # MAX: list |> MAX expr  → exact expression type (panics on empty; also accepts range)
    lhs_type = node.left.full_type!(context: "pipeline left")
    source = pipeline_source_fact(node.left, lhs_type)
    is_stream = source.finite_stream?
    require_array_input!(node, "MAX", allow_range: is_stream, allow_stream: is_stream)
    item_type = source.item_type

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
      error!(node.right, :PIPE_NEEDS_NUMERIC, op: "MAX", got: expr_type)
    end

    stamp_type!(node, expr_type)
    node.storage   = :stack
    mark_observable_terminal!(node, terminal: :max, raw: :"~#{expr_type}")
  end

  # =========================================================
  # SHARD: route pipeline items to owning schedulers by key hash
  # =========================================================

  # SHARD + CONCURRENT EACH: the EACH body sees `_` typed as the map's key type.
  sig { params(node: AST::BinaryOp, shard_node: AST::ShardOp).returns(Symbol) }
  def analyze_shard_each_op(node, shard_node)
    T.bind(self, SemanticAnnotator) rescue nil
    conc = node.right
    each_op = conc.op

    # `_` is the routing key — String for string-keyed maps, numeric for numeric maps.
    ti = shard_node.target_map.full_type!(context: "shard target map")
    key_type = (ti.numeric_map? && ti.key_type&.resolved) || :String

    with_new_scope do
      current_scope.declare("_", nil, key_type, true, false, nil, :stack)
      each_op.body.each { |stmt| visit(stmt) }
    end

    # key_allocates_frame / body_allocates_frame are set by LoopFrameAnalysis in
    # Pass 2 after CleanupClassifier finalizes allocators. Defaulting to false here.
    if (ctx = conc.shard_context)
      conc.shard_context = T.cast(ctx, AST::PipelineShardContext).with_frame_allocations(
        key_allocates_frame: false,
        body_allocates_frame: false,
      )
    end

    stamp_type!(node, :Void)
    node.storage   = :stack
  end

  # Pre-scan: check if the EACH body references any @sharded map variable
  # by scanning for identifiers that are in scope as @sharded (without :locked).
  # This runs BEFORE visiting the body, so we only check unvisited AST.
  sig { params(conc: AST::ConcurrentOp, sharded_names: T.untyped).void }
  def emit_multi_map_warning(conc, sharded_names)
    T.bind(self, SemanticAnnotator) rescue nil
    shard_counts = sharded_names.map do |name|
      sc = lookup_scope_for(name)&.resolve_entry(name)&.type
      t = sc.is_a?(Type) ? sc : Type.new(sc)
      t.shard_count
    end.compact.uniq
    names_str = sharded_names.to_a.join(', ')
    if shard_counts.length == 1
      note!(conc, "CONCURRENT EACH accesses #{sharded_names.length} @sharded maps " \
            "(#{names_str}). Co-located (same shard count #{shard_counts.first}), " \
            "but auto-sharding requires a single map. Use explicit SHARD() or @sharded(N):locked.")
    else
      note!(conc, "CONCURRENT EACH accesses @sharded maps with different shard counts " \
            "(#{names_str}). Cross-shard routing is likely — consider @sharded(N):locked.")
    end
  end

  sig { params(node: ShardScanNode, names: T::Set[String]).void }
  def collect_sharded_names(node, names)
    T.bind(self, SemanticAnnotator) rescue nil
    each_shard_scan_node(node) do |n|
      names << n.name if n.is_a?(AST::Identifier) && sharded_unsynced_identifier?(n)
    end
  end

  # Analyze CONCURRENT EACH with auto-detected @sharded map access.
  # Accepts range inputs (unlike analyze_each_op which requires collections).
  # Visits the body, then extracts the key expression and sets shard_context.
  sig { params(smooth_node: AST::BinaryOp, conc: AST::ConcurrentOp, proxy: AST::BinaryOp).void }
  def analyze_auto_shard_each_op(smooth_node, conc, proxy)
    T.bind(self, SemanticAnnotator) rescue nil
    lhs_type = smooth_node.left.full_type!(context: "pipeline left")
    iterable = pipeline_source_fact(smooth_node.left, lhs_type)

    unless iterable.valid?
      error!(smooth_node.left, :CONCURRENT_EACH_BAD_INPUT, got: smooth_node.left.resolved_type)
      item_type = :Any
    else
      item_type = iterable.item_type
    end

    with_new_scope do
      current_scope.declare("_", nil, item_type, true, false, nil, :stack)
      conc.op.body.each { |stmt| visit(stmt) }
    end

    stamp_type!(smooth_node, :Void)
    smooth_node.storage   = :stack

    # Now extract the @sharded map access from the visited body
    auto_detect_sharded_access(smooth_node, conc)
  end

  # Auto-detect @sharded map access in CONCURRENT EACH body.
  # Walks the body AST looking for map[key_expr] patterns where map is @sharded.
  # If found, sets shard_context on the ConcurrentOp so the transpiler emits
  # routed sharding instead of the normal worker pool.
  sig { params(smooth_node: AST::BinaryOp, conc: AST::ConcurrentOp).void }
  def auto_detect_sharded_access(smooth_node, conc)
    T.bind(self, SemanticAnnotator) rescue nil
    each_op = conc.op
    return unless each_op.is_a?(AST::EachOp)

    # Collect all GetIndex nodes that target a @sharded map
    sharded_accesses = T.let([], T::Array[AST::PipelineShardedAccess])
    walk_for_sharded_access(each_op.body, sharded_accesses)

    return if sharded_accesses.empty?

    # At this point, sharded_accesses should all target one map (multi-map handled upstream).
    first_access = sharded_accesses.first
    return unless first_access
    map_name = first_access.map_name
    # Find the map's scope entry to get shard_count
    scope = lookup_scope_for(map_name)
    return unless scope
    entry = scope.resolve_entry(map_name)
    map_type = entry&.type
    map_type = Type.new(map_type) unless map_type.is_a?(Type)
    return unless map_type.sharded? && entry&.sync.nil?

    # Check for multiple different key expressions on the same map
    this_map_accesses = sharded_accesses.select { |a| a.map_name == map_name }
    key_sources = this_map_accesses.map do |a|
      key_expr = a.key_expr
      key_name = key_expr.is_a?(AST::Identifier) ? key_expr.name : key_expr.to_s
      key_expr.class.name + ":" + key_name
    end.uniq
    if key_sources.length > 1
      note!(conc, "CONCURRENT EACH uses #{key_sources.length} different key expressions on " \
            "@sharded map '#{map_name}'. Routing is based on the first key; other accesses " \
            "with different keys may trigger cross-shard remote calls.")
    end
    key_expr = T.must(this_map_accesses.first).key_expr

    # Build a synthetic map identifier node for the shard_context
    map_ident = AST::Identifier.new(first_access.map_token, map_name)
    stamp_type!(map_ident, map_type)

    each_op = conc.op
    conc.shard_context = AST::PipelineShardContext.new(
      map_var: map_ident,
      shard_count: map_type.shard_count,
      key_expr: key_expr,
      auto_detected: true,  # flag so transpiler knows body uses original _ not key
      key_allocates_frame: false,   # set by LoopFrameAnalysis in Pass 2
      body_allocates_frame: false   # set by LoopFrameAnalysis in Pass 2
    )
  end

  # Recursively walk AST nodes to find GetIndex on @sharded maps.
  sig { params(nodes: T::Array[AST::Locatable], results: T::Array[AST::PipelineShardedAccess]).void }
  def walk_for_sharded_access(nodes, results)
    T.bind(self, SemanticAnnotator) rescue nil
    each_shard_scan_node(nodes) do |node|
      access = sharded_get_index_access(node, context: "sharded pipeline target")
      results << access if access
    end
  end

  sig { params(node: ShardScanNode, blk: T.proc.params(n: AST::Locatable).void).void }
  def each_shard_scan_node(node, &blk)
    T.bind(self, SemanticAnnotator) rescue nil
    if node.is_a?(Array)
      node.each { |child| each_shard_scan_node(child, &blk) }
      return
    end
    return unless node.is_a?(AST::Locatable)

    yield node
    return if node.is_a?(AST::BgBlock) || node.is_a?(AST::DoBlock)

    node.class.members.each do |member|
      val = node[member]
      if val.is_a?(Array) || val.is_a?(AST::Locatable)
        each_shard_scan_node(val, &blk)
      end
    end
  end

  sig { params(entry: T.nilable(SymbolEntry)).returns(T::Boolean) }
  def sharded_unsynced_entry?(entry)
    return false unless entry
    type = entry.type
    type = Type.new(type) unless type.is_a?(Type)
    type.sharded? && entry.sync.nil?
  end

  sig { params(node: AST::Identifier).returns(T::Boolean) }
  def sharded_unsynced_identifier?(node)
    T.bind(self, SemanticAnnotator) rescue nil
    sharded_unsynced_entry?(node.symbol || lookup_scope_for(node.name)&.resolve_entry(node.name))
  end

  sig { params(node: AST::Locatable, context: String).returns(T.nilable(AST::PipelineShardedAccess)) }
  def sharded_get_index_access(node, context:)
    return nil unless node.is_a?(AST::GetIndex) && node.target.is_a?(AST::Identifier)
    return nil unless sharded_unsynced_identifier?(node.target)

    ti = node.target.full_type!(context: context)
    return nil unless ti.is_a?(Type) && ti.sharded?

    AST::PipelineShardedAccess.new(
      map_name: node.target.name,
      key_expr: node.index,
      map_token: node.target.token,
    )
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Symbol)) }
  def analyze_shard_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    shard_op = node.right  # ShardOp node

    # LHS must be iterable (range or array)
    lhs_type = node.left.full_type!(context: "pipeline left")
    iterable = pipeline_source_fact(node.left, lhs_type)

    unless iterable.valid?
      error!(node.left, :SHARD_NEEDS_RANGE_OR_COLLECTION, got: node.left.resolved_type)
      stamp_type!(node, :Void)
      return
    end

    # Determine element type for `_` binding
    item_type = iterable.item_type

    # Type-check key expression with `_` in scope
    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(shard_op.key_expr)
    end

    key_type = shard_op.key_expr.resolved_type

    # Target must be a @sharded map — NOT :locked. Visit before key type check
    # so we can validate numeric key type against the map's declared key type.
    visit(shard_op.target_map)
    target_info = shard_op.target_map.full_type!(context: "shard op target map")
    target_sync = shard_op.target_map.respond_to?(:symbol) ? shard_op.target_map.symbol&.sync : nil
    unless target_info&.sharded? && target_sync.nil?
      error!(shard_op.target_map, :SHARD_TARGET_BAD, remediation: "SHARD routes items to owning schedulers — :locked maps don't have ownership.")
    end

    map_key_type = target_info&.key_type&.resolved
    if map_key_type == :String || map_key_type.nil?
      unless key_type == :String
        error!(shard_op.key_expr, :SHARD_KEY_NEEDS_STRING, got: key_type)
      end
    else
      # Numeric-keyed map: key expression must match the map's key type
      unless Type.new(key_type).numeric?
        error!(shard_op.key_expr, :SHARD_KEY_NEEDS_NUMERIC, map_key_type: map_key_type, got: key_type)
      end
    end

    # SHARD is consumed by the subsequent CONCURRENT EACH — not standalone.
    # Set type to Void; the ConcurrentOp handler reads ShardOp from its LHS.
    stamp_type!(node, :Void)
    node.storage = :stack
  end

  VALID_CONCURRENT_OPTIONS = %w[workers capacity batch parallel size].freeze
  VALID_CONCURRENT_SIZES   = %w[MICRO STANDARD LARGE XL].freeze

  sig { params(name: String, expr: AST::Node).void }
  def validate_positive_numeric_concurrent_option!(name, expr)
    T.bind(self, SemanticAnnotator) rescue nil
    visit(expr)
    unless [:Float64, :Int64].include?(expr.resolved_type)
      error!(expr, :CONCURRENT_OPT_NEEDS_NUMBER, name: name, got: expr.resolved_type)
    end

    literal_val = numeric_literal_value(expr)
    if literal_val && literal_val <= 0
      error!(expr, :CONCURRENT_OPT_NEEDS_POSITIVE, name: name, got: literal_val.to_i)
    end
  end

  sig { params(expr: AST::Node).returns(T.nilable(Float)) }
  def numeric_literal_value(expr)
    T.bind(self, SemanticAnnotator) rescue nil
    if expr.is_a?(AST::Literal)
      expr.value.to_f
    elsif expr.is_a?(AST::UnaryOp) && expr.op == :SUB
      right = expr.right
      -right.value.to_f if right.is_a?(AST::Literal)
    end
  end

  sig { params(node: AST::BinaryOp).returns(T::Boolean) }
  def queue_backed_concurrent_source?(node)
    T.bind(self, SemanticAnnotator) rescue nil
    lhs = node.left
    lhs_type = lhs.full_type!(context: "pipeline lhs")
    shard_concurrent_source?(lhs) || bounded_stream_source?(lhs) ||
      lhs_type&.inf_stream? || lhs_type&.dynamic_stream? ||
      lhs_type&.open_stream? || lhs.is_a?(AST::RangeLit)
  end

  sig { params(lhs: AST::Node).returns(T::Boolean) }
  def shard_concurrent_source?(lhs)
    T.bind(self, SemanticAnnotator) rescue nil
    lhs.is_a?(AST::BinaryOp) && lhs.smooth? && lhs.right.is_a?(AST::ShardOp)
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Symbol)) }
  def analyze_concurrent_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    conc    = node.right   # the ConcurrentOp node
    options = T.cast(conc.options, ConcurrentOptions)
    validate_concurrent_options!(node, conc, options)
    stamp_concurrent_option_values!(options)

    # Type analysis for concurrent ops is identical to synchronous versions.
    # Create a proxy BinaryOp(SMOOTH, left, inner_op) so we can reuse the existing analyze_* methods.
    lhs_type = node.left.full_type!(context: "pipeline left")
    shard_node = prepare_concurrent_shard_context!(node, conc)
    proxy = AST::BinaryOp.new(node.token, node.left, :SMOOTH, conc.op)

    case conc.op
    when AST::SelectOp, AST::WhereOp
      if bounded_stream_source?(node.left)
        analyze_concurrent_bounded_select_family_op(node)
      elsif concurrent_stream_source?(node.left, lhs_type)
        analyze_concurrent_stream_select_family_op(node)
      else
        analyze_select_family_op(proxy)
      end
    when AST::EachOp
      if bounded_stream_source?(node.left)
        analyze_concurrent_bounded_each_op(node)
      elsif concurrent_stream_source?(node.left, lhs_type)
        analyze_concurrent_stream_each_op(node)
      elsif shard_node
        # Explicit SHARD + CONCURRENT EACH: items are String keys.
        analyze_shard_each_op(node, shard_node)
      else
        # Check for @sharded map access — emit warnings for multi-map, auto-shard for single map.
        sharded_names = Set.new
        conc.op.body.each { |stmt| collect_sharded_names(stmt, sharded_names) }

        conc.capture_analysis = with_fiber_capture_analysis(is_parallel: false) do
          if sharded_names.length > 1
            emit_multi_map_warning(conc, sharded_names)
            analyze_each_op(proxy)
          elsif sharded_names.length == 1
            analyze_auto_shard_each_op(node, conc, proxy)
          else
            analyze_each_op(proxy)
          end
        end
      end
    when AST::SumOp
      analyze_sum_op(proxy)
    when AST::CountOp
      analyze_count_op(proxy)
    when AST::MinOp
      analyze_min_op(proxy)
    when AST::MaxOp
      analyze_max_op(proxy)
    when AST::AverageOp
      analyze_average_op(proxy)
    else
      error!(conc, :CONCURRENT_BAD_FOLLOWING_OP, got: conc.op.class.name.split('::').last)
    end

    # Validate that OR PRUNE / OR RAISE is only used with error-returning expressions
    inner_expr = case conc.op
    when AST::SelectOp, AST::WhereOp then conc.op.expression
    else nil
    end

    if inner_expr.is_a?(AST::BinaryOp) && inner_expr.op == :OR_RESCUE
      modifier = inner_expr.right
      if modifier.is_a?(AST::OrPrune) || modifier.is_a?(AST::OrRaise)
        inner_fn_type = inner_expr.left.full_type!(context: "inner pipeline left")
        # CLEAR's auto-propagate strips `!T` from a fallible call's
        # full_type (saving the union on `error_union_type`). The
        # OR PRUNE / OR RAISE validators must honor that fallback so
        # `f() OR PRUNE` (where f is `!T`) doesn't false-positive
        # as "got T (not !T)".
        is_error_union = inner_fn_type&.error_union? ||
                         (inner_expr.left.respond_to?(:error_union_type) &&
                          inner_expr.left.error_union_type)
        unless is_error_union
          mod_name = modifier.is_a?(AST::OrPrune) ? "OR PRUNE" : "OR RAISE"
          error!(modifier, :MODIFIER_NEEDS_ERROR_UNION, name: mod_name, got: inner_expr.left.resolved_type)
        end
      end
    end

    # SELECT/WHERE/EACH on stream sources set node.full_type!(context: "pipeline result") directly in their analyze
    # methods. REDUCE ops (SUM/COUNT/etc.) and array sources still use the proxy.
    stream_op_analyzed = AST.pipeline_stream_value_op?(conc.op) &&
                         (bounded_stream_source?(node.left) || concurrent_stream_source?(node.left, lhs_type))
    unless stream_op_analyzed
      stamp_type!(node, proxy.full_type!(context: "concurrent proxy result"))
      node.storage   = (node.full_type!(context: "pipeline result") == :Void) ? :stack : :heap
    end

    # CONCURRENT wraps an inner op (conc.op) and analyzes it through a
    # throwaway proxy SMOOTH, bypassing analyze_higher_order_op's
    # op-stamp. The wrapped op evaluates to the pipeline's post-op
    # type just computed here — stamp it (and its WHERE/SELECT
    # expression sub-node) so no wrapped op reaches MIR untyped.
    inner = conc.op
    stamp_type!(inner, node.full_type!(context: "CONCURRENT inner op result"))
    nil # sig: returns(T.nilable(Symbol)) — don't leak the Type assignment
  end

  sig { params(node: AST::BinaryOp, conc: AST::ConcurrentOp, options: ConcurrentOptions).void }
  def validate_concurrent_options!(node, conc, options)
    T.bind(self, SemanticAnnotator) rescue nil

    validate_concurrent_numeric_option!(options, "workers")
    validate_concurrent_capacity_option!(node, options)
    validate_concurrent_numeric_option!(options, "batch")
    validate_concurrent_parallel_option!(options)
    validate_concurrent_size_option!(options)
    validate_known_concurrent_options!(conc, options)
  end

  sig { params(options: ConcurrentOptions, name: String).void }
  def validate_concurrent_numeric_option!(options, name)
    T.bind(self, SemanticAnnotator) rescue nil
    expr = options[name]
    validate_positive_numeric_concurrent_option!(name, expr) if expr
  end

  sig { params(node: AST::BinaryOp, options: ConcurrentOptions).void }
  def validate_concurrent_capacity_option!(node, options)
    T.bind(self, SemanticAnnotator) rescue nil
    cap = options["capacity"]
    return unless cap

    error!(cap, :CONCURRENT_CAPACITY_BAD_INPUT) unless queue_backed_concurrent_source?(node)
    validate_positive_numeric_concurrent_option!("capacity", cap)
  end

  sig { params(options: ConcurrentOptions).void }
  def validate_concurrent_parallel_option!(options)
    T.bind(self, SemanticAnnotator) rescue nil
    par_val = options["parallel"]
    return unless par_val

    return if concurrent_bool_option?(par_val)

    error!(par_val, :CONCURRENT_PARALLEL_NEEDS_BOOL, got: concurrent_option_label(par_val))
  end

  sig { params(value: AST::Node).returns(T::Boolean) }
  def concurrent_bool_option?(value)
    T.bind(self, SemanticAnnotator) rescue nil
    !!((value.is_a?(AST::Literal) && value.type == :BOOLEAN) ||
      (value.is_a?(AST::Identifier) && %w[true false TRUE FALSE].include?(value.name)))
  end

  sig { params(options: ConcurrentOptions).void }
  def validate_concurrent_size_option!(options)
    T.bind(self, SemanticAnnotator) rescue nil
    size = options["size"]
    return unless size
    return if size.is_a?(AST::Identifier) && VALID_CONCURRENT_SIZES.include?(size.name)

    error!(size,
      :CONCURRENT_SIZE_BAD_VALUE,
      valid: VALID_CONCURRENT_SIZES.join(', '),
      got: concurrent_option_label(size))
  end

  sig { params(value: AST::Node).returns(String) }
  def concurrent_option_label(value)
    T.bind(self, SemanticAnnotator) rescue nil
    return value.name if value.is_a?(AST::Identifier)

    class_name = value.class.name
    class_name ? class_name.split("::").last : value.class.to_s
  end

  sig { params(conc: AST::ConcurrentOp, options: ConcurrentOptions).void }
  def validate_known_concurrent_options!(conc, options)
    T.bind(self, SemanticAnnotator) rescue nil
    options.each_key do |key|
      error!(conc, :CONCURRENT_UNKNOWN_OPTION, name: key, valid: VALID_CONCURRENT_OPTIONS.join(', ')) unless VALID_CONCURRENT_OPTIONS.include?(key)
    end
  end

  sig { params(options: ConcurrentOptions).void }
  def stamp_concurrent_option_values!(options)
    T.bind(self, SemanticAnnotator) rescue nil

    # Bare identifiers are compile-time keyword selectors consumed
    # structurally via .name; non-identifiers are runtime values.
    options.each_value do |v|
      if v.is_a?(AST::Identifier)
        stamp_type!(v, Type.new(:Type))
      else
        visit(v)
      end
    end
  end

  sig { params(node: AST::BinaryOp, conc: AST::ConcurrentOp).returns(T.nilable(AST::ShardOp)) }
  def prepare_concurrent_shard_context!(node, conc)
    T.bind(self, SemanticAnnotator) rescue nil

    return nil unless shard_concurrent_source?(node.left)

    shard_node = node.left.right
    target_info = shard_node.target_map.full_type!(context: "shard target map")
    conc.shard_context = AST::PipelineShardContext.new(
      map_var: shard_node.target_map,
      shard_count: target_info&.shard_count,
      key_expr: shard_node.key_expr
    )
    shard_node
  end

  sig { params(node: AST::Locatable, lhs_type: Type).returns(T::Boolean) }
  def concurrent_stream_source?(node, lhs_type)
    lhs_type.inf_stream? || lhs_type.dynamic_stream? ||
      lhs_type.open_stream? || node.is_a?(AST::RangeLit)
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(Integer)) }
  def analyze_concurrent_bounded_select_family_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    lhs_type = node.left.full_type!(context: "pipeline left")
    item_type = lhs_type.stream_element_type.resolved
    is_parallel = concurrent_parallel_enabled?(node.right.options)

    analysis = with_fiber_capture_analysis(is_parallel: is_parallel) do
      with_new_scope do
        current_scope.declare("_", nil, item_type, false, false, nil, :stack)
        with_soa_tracking(node, item_type) do
          visit(node.right.op.expression)
        end
      end
    end

    node.right.capture_analysis =
      validate_capture_analysis!(node.right, analysis, is_parallel, false) || analysis

    validate_concurrent_where_expression!(node)

    result_type = concurrent_select_family_result_type(node, item_type)
    stamp_type!(node, Type.new(result_type))
    node.storage = :heap
    current_fn_ctx&.record_frame_use!
    nil
  end

  sig { params(node: AST::BinaryOp).returns(Symbol) }
  def analyze_concurrent_bounded_each_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    lhs_type = node.left.full_type!(context: "pipeline left")
    item_type = lhs_type.stream_element_type.resolved
    is_parallel = concurrent_parallel_enabled?(node.right.options)

    analysis = with_fiber_capture_analysis(is_parallel: is_parallel) do
      with_new_scope(current_scope) do
        current_scope.declare("_", nil, item_type, true, false, nil, :stack)
        with_soa_tracking(node, item_type) do
          node.right.op.body.each { |stmt| visit(stmt) }
        end
      end
    end

    node.right.capture_analysis =
      validate_capture_analysis!(node.right, analysis, is_parallel, false) || analysis

    stamp_type!(node, :Void)
    node.storage   = :stack
  end

  # CONCURRENT SELECT/WHERE on ~T[] (dynamic stream) or ~T[INF] (InfStream).
  # Uses BoundedChannel for SPMC back pressure: feeder reads source, workers compete.
  # Produces a materialized list (not another stream) regardless of source kind.
  sig { params(node: AST::BinaryOp).returns(Integer) }
  def analyze_concurrent_stream_select_family_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    lhs_type = node.left.full_type!(context: "pipeline left")
    item_type = pipeline_source_fact(node.left, lhs_type, include_inf_stream: true).item_type
    is_parallel = concurrent_parallel_enabled?(node.right.options)

    analysis = with_fiber_capture_analysis(is_parallel: is_parallel) do
      with_new_scope do
        current_scope.declare("_", nil, item_type, false, false, nil, :stack)
        with_soa_tracking(node, item_type) do
          visit(node.right.op.expression)
        end
      end
    end

    node.right.capture_analysis =
      validate_capture_analysis!(node.right, analysis, is_parallel, false) || analysis

    validate_concurrent_where_expression!(node)

    result_type = concurrent_select_family_result_type(node, item_type)
    stamp_type!(node, Type.new(result_type))
    node.storage = :heap
    current_fn_ctx&.record_frame_use!
    0
  end

  sig { params(node: AST::BinaryOp).void }
  def validate_concurrent_where_expression!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    op = node.right.op
    return unless op.is_a?(AST::WhereOp)
    return if op.expression.resolved_type == :Bool

    error!(op, :WHERE_NEEDS_BOOL)
  end

  sig { params(node: AST::BinaryOp, item_type: Symbol).returns(Symbol) }
  def concurrent_select_family_result_type(node, item_type)
    op = node.right.op
    if op.is_a?(AST::SelectOp)
      return :"#{op.expression.full_type!(context: "concurrent op expression")}[]"
    end
    return :"#{item_type}[]" if op.is_a?(AST::WhereOp)

    Kernel.raise "expected CONCURRENT SELECT/WHERE, got #{op.class.name}"
  end

  # CONCURRENT EACH on ~T[] (dynamic stream) or ~T[INF] (InfStream).
  sig { params(node: AST::BinaryOp).returns(Symbol) }
  def analyze_concurrent_stream_each_op(node)
    T.bind(self, SemanticAnnotator) rescue nil
    lhs_type = node.left.full_type!(context: "pipeline left")
    item_type = pipeline_source_fact(node.left, lhs_type, include_inf_stream: true).item_type
    is_parallel = concurrent_parallel_enabled?(node.right.options)

    analysis = with_fiber_capture_analysis(is_parallel: is_parallel) do
      with_new_scope(current_scope) do
        current_scope.declare("_", nil, item_type, true, false, nil, :stack)
        with_soa_tracking(node, item_type) do
          node.right.op.body.each { |stmt| visit(stmt) }
        end
      end
    end

    node.right.capture_analysis =
      validate_capture_analysis!(node.right, analysis, is_parallel, false) || analysis

    stamp_type!(node, :Void)
    node.storage   = :stack
  end

  # Helper to validate array/pool input for higher-order ops.
  # Accepts:
  #   - Array types (metatype :array)
  #   - @pool and @pool:sharded(N) collection types
  #   - @list and @list:sharded(N) collection types
  # Returns the CLEAR result type for SUM based on the expression's input type.
  # Signed integers upsize to Int64; unsigned to UInt64; floats stay their own type.
  sig { params(expr_sym: Symbol).returns(Symbol) }
  def sum_result_clear_type(expr_sym)
    T.bind(self, SemanticAnnotator) rescue nil
    case expr_sym
    when :Int8, :Int16, :Int32, :Int64 then :Int64
    when :UInt8, :Byte, :UInt16, :UInt32, :UInt64 then :UInt64
    when :Float32 then :Float32
    else :Float64
    end
  end

  sig { params(node: AST::BinaryOp, op_name: String, allow_range: T::Boolean, allow_stream: T::Boolean).returns(NilClass) }
  def require_array_input!(node, op_name, allow_range: false, allow_stream: false)
    T.bind(self, SemanticAnnotator) rescue nil
    lhs_type = node.left.full_type!(context: "pipeline left")
    return if node.left.metatype == :array
    return if lhs_type&.collection?
    return if allow_range && node.left.is_a?(AST::RangeLit)
    return if allow_stream && lhs_type&.runtime_stream?
    # SELECT uses "from" in error message for historical reasons
    if op_name == "SELECT"
      error!(node.left, :SELECT_NEEDS_LIST, got: node.left.resolved_type)
    else
      error!(node.left, :PIPE_OP_NEEDS_LIST, op: op_name, got: node.left.resolved_type)
    end
  end

  # Element type for a range source (used by fusible stage ops applied to ranges).
  sig { params(range_node: AST::RangeLit).returns(Type) }
  def range_element_type(range_node)
    T.bind(self, SemanticAnnotator) rescue nil
    range_node.start.full_type!(context: "range element")
  end

  # =========================================================
  # SOA Opportunity Detection
  # =========================================================
  # Called after visiting a pipeline lambda body.  Checks whether
  # the lambda accessed less than half of the element struct's
  # fields — a signal that SOA layout would improve cache usage.
  #
  # Only triggers for struct elements with >= 4 fields (small
  # structs don't benefit meaningfully from SOA).

  SOA_MIN_FIELDS = 4
  SOA_THRESHOLD  = 0.5  # warn when < 50% of fields accessed

  sig { params(node: AST::BinaryOp, item_type: Symbol).void }
  def check_soa_opportunity!(node, item_type)
    T.bind(self, SemanticAnnotator) rescue nil
    accessed = phase_receiver_state.pipeline_accessed_fields
    return unless accessed
    return if accessed.empty?

    schema = lookup_type_schema(item_type)
    return unless Schemas.field_bearing?(schema)

    total = schema.fields.keys.size
    return if total < SOA_MIN_FIELDS

    ratio = accessed.size.to_f / total
    if ratio < SOA_THRESHOLD
      fields_str = accessed.to_a.sort.join(", ")
      note!(node, "Pipeline accesses #{accessed.size} of #{total} fields (#{fields_str}). " \
                  "Consider @soa for better cache performance on '#{item_type}'.")
    end
  end

  # Wraps a pipeline body visit with SOA field tracking.
  sig { params(node: AST::BinaryOp, item_type: Symbol, blk: T.untyped).void }
  def with_soa_tracking(node, item_type, &blk)
    T.bind(self, SemanticAnnotator) rescue nil
    receiver_state = phase_receiver_state
    receiver_state.pipeline_accessed_fields = Set.new
    yield
    check_soa_opportunity!(node, item_type)
  ensure
    receiver_state.pipeline_accessed_fields = nil if receiver_state
  end
end
