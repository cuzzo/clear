# typed: strict

class ClearParser
  extend T::Sig

  private

  # Parses a function type annotation: FN(Type, ...) -> ReturnType
  # Parameter names are optional (documentation only): FN(n: Int64) -> Bool is the same as FN(Int64) -> Bool.
  # Returns a Type whose raw is { params: [...], return: { type: Type }, fn_type: true }.
  sig { returns(Type) }
  def parse_fn_type_annotation
    consume(:KEYWORD, 'FN')
    consume(:CHAR, '(')
    param_types = []
    until match?(:CHAR, ')')
      # Allow optional name annotation: `name: Type` or just `Type`
      if match?(:VAR_ID) && peek.type == :CHAR && peek.value == ':'
        consume(:VAR_ID)   # name is for documentation only
        consume(:CHAR, ':')
      end
      param_types << parse_type_annotation(migration_root: false)
      break unless match!(:CHAR, ',')
    end
    consume(:CHAR, ')')
    consume(:ARROW, '->')
    return_type = parse_type_annotation(migration_root: false)
    abi = T.let(:clear, Symbol)
    if match!(:KEYWORD, 'CALLCONV')
      abi_token = current
      consume(abi_token.type)
      abi = abi_token.text!.downcase.to_sym
      error!(abi_token, :PARSER_EXPECTED, expected: "C", got: abi_token.value,
        type: abi_token.type, line: abi_token.line) unless abi == :c
    end
    if match?(:VAR_ID) && %w[@reentrant @nonReentrant].include?(current.value)
      error!(current, :PARSER_EXPECTED, expected: "supported function type annotation", got: current.value, type: current.type, line: current.line)
    end
    Type.function_type_from_parts(param_types, T.unsafe(return_type), false, nil, abi)
  end

  sig { params(migration_root: T::Boolean).returns(Type) }
  def parse_type_annotation(migration_root: true)
    syntax = @budget.nested { parse_type_annotation_syntax(migration_root: migration_root) }
    TypeSyntaxLowering.lower(syntax)
  end

  sig { params(migration_root: T::Boolean).returns(ParsedTypeSyntax) }
  def parse_type_annotation_syntax(migration_root: true)
    start_token = T.must(peek_at(0))
    inline_syntax = inline_type_annotation_start?
    parsed = parse_type_annotation_body
    validate_type_expression_budget!(start_token, parsed.shape.expression) if migration_root
    emit_legacy_type_migration(start_token, previous, parsed) if migration_root && !inline_syntax
    ParsedTypeSyntax.new(
      expression: parsed.shape.expression,
      start_token: start_token,
      end_token: previous,
      auto_token: parsed.auto_token,
      auto: parsed.auto?,
    )
  end

  sig { returns(Type) }
  def parse_type_annotation_body
    if inline_type_annotation_start?
      return Type.new(parse_inline_type_expression)
    end

    # Function type: FN(Type, ...) -> ReturnType
    return parse_fn_type_annotation if match?(:KEYWORD, 'FN')

    # Polymorphic shared-family type: SHARED T, SHARED !T, SHARED ~T, etc.
    # This is distinct from concrete `T @shared` Arc syntax.
    if match?(:KEYWORD, 'SHARED')
      consume(:KEYWORD, 'SHARED')
      return mark_polymorphic_shared_type(parse_type_annotation(migration_root: false))
    end

    # Check for tense (Promise) prefix: ~Type
    tense_prefix = ""
    if match!(:CHAR, '~')
      tense_prefix = "~"
    end

    # Check for error union prefix: !Type (Zig-style error returns)
    error_prefix = ""
    if match!(:CHAR, '!')
      error_prefix = "!"
    end

    # Check for optional prefix: ?Type
    optional_prefix = ""
    if match!(:CHAR, '?')
      optional_prefix = "?"
    end

    # Grouped optional container/value: ?(T[]@list). Prefix binding in the
    # ungrouped spelling is intentionally element-first, so ?T[] means a list
    # of optional T while ?(T[]) means an optional list of T.
    if optional_prefix == "?" && match?(:CHAR, '(')
      if tense_prefix != "" || error_prefix != ""
        error!(current, :PARSER_EXPECTED, expected: "a grouped optional without an outer tense/error prefix", got: current.value, type: current.type, line: current.line)
      end
      consume(:CHAR, '(')
      wrapped = parse_type_annotation(migration_root: false)
      consume(:CHAR, ')')
      return Type.optional_of(wrapped)
    end

    if match?(:KEYWORD, 'Auto') && "#{tense_prefix}#{error_prefix}#{optional_prefix}" != ""
      prefix_chars = "#{tense_prefix}#{error_prefix}#{optional_prefix}"
      error!(current, :AUTO_PREFIX_NOT_SUPPORTED, prefix: prefix_chars, prefix2: prefix_chars, prefix3: prefix_chars, prefix4: prefix_chars)
    end

    if match?(:KEYWORD, 'FN')
      fn_type = parse_fn_type_annotation
      if tense_prefix != "" || error_prefix != ""
        error!(current, :PARSER_EXPECTED, expected: "plain or optional function type annotation", got: "#{tense_prefix}#{error_prefix}FN", type: current.type, line: current.line)
      end

      return optional_prefix == "?" ? Type.optional_of(fn_type) : fn_type
    end

    auto_tok = T.let(nil, T.nilable(Lexer::Token))
    auto_type = false
    base = T.let("", String)
    generic_base = T.let(nil, T.nilable(Symbol))
    generic_argument_expressions = T.let([], T::Array[TypeExpression])
    if match?(:KEYWORD, 'Auto')
      # Auto — gradual-typing placeholder. Resolved to a concrete type
      # by the inference pass (see docs/agents/gradual-typing.md). At
      # parse time it's just a sentinel Type whose `auto?` flag is set;
      # downstream code treats it as "unresolved, fill me in". Stash
      # the keyword token so the fix emitter can replace this exact
      # span with the resolved type's source form.
      auto_tok = consume(:KEYWORD, 'Auto')
      auto_type = true
      base = "Auto"
    else
      base = consume(:TYPE_ID).text!
    end
    inner = ""

    # Generic type arguments: Pair<Number> or Map<String, Number>.
    # Type arguments are full type annotations, so Cache<Box @shared:locked>
    # preserves the synchronization family as part of T.
    # In type-annotation context, '<' is always a generic argument list, never a comparison.
    if match?(:CHAR, '<')
      generic_base = base.to_sym
      consume(:CHAR, '<')
      type_args = []
      until match?(:CHAR, '>')
        argument = parse_type_annotation(migration_root: false)
        type_args << type_annotation_source(argument)
        generic_argument_expressions << argument.shape.expression
        match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
      base = "#{base}<#{type_args.join(',')}>"
    end

    # Element-level capability: T@shared[] means Array<Arc<T>>.
    # Parsed BEFORE the [] suffix so it attaches to the element type, not the collection.
    # Also handles T@shared:locked[] (Arc<Mutex<T>>[]).
    elem_caps = parse_element_capability
    elem_ownership = elem_caps.ownership
    elem_sync = elem_caps.sync
    elem_layout = elem_caps.layout

    if match!(:CHAR, '[')
      # Case 1: Dynamic "Number[]"
      if match!(:CHAR, ']')
        inner = "[]"

      # Case 2: Fixed Inferred "Number[*]"
      elsif match!(:CHAR, '*')
        consume(:CHAR, ']')
        inner = "[*]"

      # Case 3: Fixed Explicit "Number[10]"
      elsif match?(:NUMBER) || match?(:INT64)
        size = consume_number.value.to_i
        consume(:CHAR, ']')
        inner = "[#{size}]"

      # Case 4: Open stream marker "T[?]" (used inside tense type ~T[?])
      elsif match?(:CHAR, '?')
        consume(:CHAR, '?')
        consume(:CHAR, ']')
        inner = "[?]"

      # Case 5: Infinite stream marker "T[INF]" (used inside tense type ~T[INF])
      elsif match?(:TYPE_ID) && current.value == 'INF'
        consume(:TYPE_ID)
        consume(:CHAR, ']')
        inner = "[INF]"

      else
        error!(current, :ARRAY_TYPE_BAD)
      end

      # Allow multiple dimensions (e.g., Number[][][])
      while match?(:CHAR, '[')
        consume(:CHAR, '[')
        if match!(:CHAR, ']')
          inner += "[]"
        elsif match?(:NUMBER) || match?(:INT64)
          size = consume_number.value.to_i
          consume(:CHAR, ']')
          inner += "[#{size}]"
        else
          error!(current, :ARRAY_TYPE_EXPECTED_SIZE)
        end
      end
    end

    # Capability suffix: T @shared, T[]@list:soa, T[N]@soa:shared:locked, HashMap<V>@sharded(N), etc.
    # ClearParser only does token consumption and duplicate detection. Semantic validation
    # (e.g., "@list requires array", "@soa requires fixed array") is in the annotator.
    caps = parse_capabilities
    ownership   = caps.ownership
    sync        = caps.sync
    collection  = caps.collection
    is_soa      = caps.is_soa
    is_indirect = caps.is_indirect
    shard_count = caps.shard_count
    observable  = caps.observable
    observable_token = caps.observable_token


    base_sym = "#{tense_prefix}#{error_prefix}#{optional_prefix}#{base}#{inner}".to_sym

    loc = is_indirect ? :heap : nil
    layout = is_indirect ? :indirect : nil
    # Mirror CapabilityWrap's auto-promotion so @boxed:atomic has the same
    # ownership whether it appears in an expression or a type annotation.
    if sync == :atomic && layout == :indirect && ownership.nil?
      ownership = :shared
    end
    t = Type.new(base_sym, ownership: ownership, sync: sync, layout: layout, location: loc, collection: collection, shard_count: shard_count, observable: observable, auto: auto_type)
    unless generic_base.nil?
      expression = TypeExpressionTree.with_nominal_arguments(
        t.shape.expression,
        generic_base,
        generic_argument_expressions,
      )
      t.replace_shape!(t.shape.with_expression(expression))
    end
    t.auto_token = auto_tok if auto_tok
    t.apply_type_annotation_extras!(soa: is_soa, elem_ownership: elem_ownership, elem_sync: elem_sync, elem_layout: elem_layout, observable_token: observable_token)
    t
  end

  sig { params(start_token: Lexer::Token, end_token: Lexer::Token, type: Type).void }
  def emit_legacy_type_migration(start_token, end_token, type)
    return unless FixCollector.type_migrations_enabled?
    return unless start_token.line == end_token.line
    return unless TypeExpressionTree.each_node(type.shape.expression).any? do |node|
      node.is_a?(LinearTypeExpression) || node.is_a?(MapTypeExpression) || node.is_a?(StreamTypeExpression)
    end

    replacement = Type.inline_migration_name(type)
    return if replacement.nil?

    line = @source_code.lines[start_token.line - 1]
    return if line.nil?

    length = end_token.column + end_token.value.to_s.length - start_token.column
    original = line[(start_token.column - 1), length].to_s
    return if original.gsub(/\s+/, "") == replacement.gsub(/\s+/, "")

    edit = Edit.new(
      span: Span.new(file: nil, line: start_token.line, col: start_token.column, length: length),
      replacement: replacement
    )
    FixCollector.push(FixableFinding.new(
      level: :info,
      message: "Legacy type syntax can be written in Inline Pivot form",
      token: start_token,
      category: :type_migration,
      fixes: [Fix.new(description: fix_description(:REWRITE_INLINE_PIVOT_TYPE, type: replacement), confidence: :auto, edits: [edit])]
    ))
  end

  sig { params(token: Lexer::Token).void }
  def emit_boxed_capability_migration(token)
    return unless FixCollector.type_migrations_enabled?
    return unless %w[@indirect indirect].include?(token.text!)

    replacement = token.text!.start_with?("@") ? "@boxed" : "boxed"
    edit = Edit.new(
      span: Span.new(file: nil, line: token.line, col: token.column, length: token.text!.length),
      replacement: replacement
    )
    FixCollector.push(FixableFinding.new(
      level: :info,
      message: "Legacy @indirect capability is now spelled @boxed",
      token: token,
      category: :type_migration,
      fixes: [Fix.new(
        description: fix_description(:RENAME_BOXED_CAPABILITY, old: token.text!, new: replacement),
        confidence: :auto,
        edits: [edit]
      )]
    ))
  end

  sig { returns(T::Boolean) }
  def inline_type_annotation_start?
    offset = T.let(0, Integer)
    token = T.must(peek_at(0))
    while token.type == :CHAR && %w[? ! ~].include?(token.value)
      offset += 1
      token = peek_at(offset) || token
    end
    token.type == :CHAR && ["[", "{"].include?(token.value)
  end

  sig { returns(TypeExpression) }
  def parse_inline_type_expression
    token = T.must(peek_at(0))
    if token.type == :CHAR
      return parse_inline_prefixed_expression if %w[? ! ~].include?(token.value)
      if token.value == '['
        return parse_inline_stream_expression if peek_at(1)&.value == '~'
        return parse_inline_linear_expression
      end
      return parse_inline_map_expression if token.value == '{'
    end

    parse_inline_atom_expression
  end

  sig { returns(StreamTypeExpression) }
  def parse_inline_stream_expression
    consume(:CHAR, '[')
    consume(:CHAR, '~')
    cardinality = T.let(:FINITE, T.any(Integer, Symbol))
    if match?(:NUMBER) || match?(:INT64)
      cardinality = consume_number.value.to_i
    elsif match?(:TYPE_ID) && current.value == "INF"
      consume(:TYPE_ID, 'INF')
      cardinality = :INF
    end
    consume(:CHAR, ']')
    caps = parse_inline_capabilities
    StreamTypeExpression.new(
      cardinality: cardinality,
      item: parse_inline_type_expression,
      capabilities: caps,
    )
  end

  sig { returns(TypeExpression) }
  def parse_inline_prefixed_expression
    prefix = consume(:CHAR).text!
    inner = parse_inline_type_expression
    return OptionalTypeExpression.new(inner: inner) if prefix == "?"
    return FallibleTypeExpression.new(inner: inner) if prefix == "!"

    FutureTypeExpression.new(inner: inner)
  end

  sig { returns(TypeExpression) }
  def parse_inline_atom_expression
    if match?(:KEYWORD, 'FN')
      expression = parse_fn_type_annotation.shape.expression
      return TypeExpressionTree.with_root_capabilities(expression, parse_inline_capabilities)
    end

    name = consume(:TYPE_ID).text!
    arguments = T.let([], T::Array[TypeExpression])
    if match?(:CHAR, '<')
      consume(:CHAR, '<')
      until match?(:CHAR, '>')
        arguments << parse_inline_type_expression
        break unless match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
    end
    expression = if name == "Tuple"
      TupleTypeExpression.new(items: arguments)
    else
      NamedTypeExpression.new(name: name.to_sym, arguments: arguments)
    end

    TypeExpressionTree.with_root_capabilities(expression, parse_inline_capabilities)
  end

  sig { returns(LinearTypeExpression) }
  def parse_inline_linear_expression
    consume(:CHAR, '[')
    if match!(:CHAR, ']')
      caps = parse_inline_capabilities(collection: :list)
      return LinearTypeExpression.new(kind: :list, dimensions: [:LIST],
        item: parse_inline_type_expression, capabilities: caps)
    end

    kind = T.let(:array, Symbol)
    dimension = T.let(nil, T.nilable(T.any(Integer, Symbol)))
    dimensions = T.let([], T::Array[T.any(Integer, Symbol)])
    allocation_hint = T.let(nil, T.nilable(Integer))
    if match?(:NUMBER) || match?(:INT64)
      dimension = consume_number.value.to_i
    else
      layout = consume(:TYPE_ID).text!
      case layout
      when "List", "Set"
        kind = layout.downcase.to_sym
        dimension = layout == "List" ? :LIST : :SET
        if match!(:CHAR, '(')
          allocation_hint = consume_number.value.to_i
          consume(:CHAR, ')')
        end
      when "Pool"
        kind = :pool
        consume(:CHAR, '(')
        dimension = consume_number.value.to_i
        consume(:CHAR, ')')
      else
        error!(previous, :PARSER_EXPECTED, expected: "an Inline Pivot dimension", got: layout, type: previous.type, line: previous.line)
      end
    end
    dimensions << T.must(dimension)
    while match!(:CHAR, ',')
      if !allocation_hint.nil? || kind == :set || kind == :pool
        error!(previous, :PARSER_EXPECTED, expected: "integer or List dimensions in a flat rank", got: previous.value, type: previous.type, line: previous.line)
      end
      if match?(:NUMBER) || match?(:INT64)
        dimensions << consume_number.value.to_i
      else
        layout = consume(:TYPE_ID).text!
        unless layout == "List"
          error!(previous, :PARSER_EXPECTED, expected: "integer or List dimensions in a flat rank", got: layout, type: previous.type, line: previous.line)
        end
        dimensions << :LIST
      end
    end
    consume(:CHAR, ']')
    kind = :rank if dimensions.length > 1
    collection = %i[list set pool].include?(kind) ? kind : nil
    caps = parse_inline_capabilities(collection: collection)
    LinearTypeExpression.new(
      kind: kind,
      dimensions: dimensions,
      item: parse_inline_type_expression,
      allocation_hint: allocation_hint,
      capabilities: caps
    )
  end

  sig { returns(MapTypeExpression) }
  def parse_inline_map_expression
    consume(:CHAR, '{')
    key = if match?(:CHAR, '}')
      NamedTypeExpression.new(name: :Symbol)
    else
      parsed_key = parse_inline_type_expression
      if match?(:CHAR, ',')
        error!(current, :PARSER_EXPECTED, expected: "a closing brace; nested maps use separate brace layers", got: current.value, type: current.type, line: current.line)
      end
      parsed_key
    end
    consume(:CHAR, '}')
    caps = parse_inline_capabilities
    MapTypeExpression.new(key: key, value: parse_inline_type_expression, capabilities: caps)
  end

  sig { params(collection: T.nilable(Symbol)).returns(TypeCapabilities) }
  def parse_inline_capabilities(collection: nil)
    parsed = parse_capabilities
    unless parsed.collection.nil?
      error!(previous, :PARSER_EXPECTED,
        expected: "collection topology in the Inline Pivot layer sigil",
        got: previous.value, type: previous.type, line: previous.line)
    end
    TypeCapabilities.new(
      ownership: parsed.ownership || :affine,
      sync: parsed.sync,
      layout: parsed.is_indirect ? :indirect : nil,
      collection: collection || parsed.collection,
      shard_count: parsed.shard_count,
      soa: parsed.is_soa,
      observable: parsed.observable,
      observable_token: parsed.observable_token
    )
  end

  sig { params(token: Lexer::Token, expression: TypeExpression).void }
  def validate_type_expression_budget!(token, expression)
    node_count = TypeExpressionTree.node_count(expression)
    error!(token, :TYPE_NODE_LIMIT, count: node_count, limit: 32) if node_count > 32

    capability_sites = TypeExpressionTree.capability_site_count(expression)
    if capability_sites > 3
      error!(token, :TYPE_CAPABILITY_SITE_LIMIT, count: capability_sites, limit: 3)
    end
  end

  sig { params(type: Type).returns(Type) }
  def mark_polymorphic_shared_type(type)
    t = Type.new(type)
    t.apply_reference_ownership!(:shared)
    t.mark_polymorphic_shared!
    t
  end

  sig { params(type: Type).returns(String) }
  def type_annotation_source(type)
    t = type
    if t.polymorphic_shared?
      inner = Type.new(t)
      inner.apply_reference_ownership!(:affine)
      inner.mark_polymorphic_shared!(false)
      return "SHARED #{type_annotation_source(inner)}"
    end

    if t.optional?
      wrapped = T.must(t.wrapped_type)
      inner = type_annotation_source(wrapped)
      return wrapped.array? || wrapped.map? ? "?(#{inner})" : "?#{inner}"
    end

    base = Type.strip_capability_suffix_from(t.resolved.to_s).base
    capabilities = T.let([], T::Array[String])

    collection = case t.collection
    when :list then "list"
    when :pool then "pool"
    when :set then "set"
    end
    if collection
      collection += ":soa" if t.soa?
      collection += ":sharded(#{t.shard_count})" if t.sharded? && t.shard_count
      capabilities << collection
    end

    ownership = case t.ownership
    when :shared then "shared"
    when :shared_node then "shared:node"
    when :multiowned then "multiowned"
    when :link then "link"
    when :split then "split"
    when :frozen then "frozen"
    end
    capabilities << ownership if ownership

    sync = case t.sync
    when :locked then "locked"
    when :write_locked then "writeLocked"
    when :versioned then "versioned"
    when :atomic then "atomic"
    when :local then "local"
    when :always_mutable then "alwaysMutable"
    end
    capabilities << sync if sync
    capabilities << "observable" if t.observable?

    capabilities.empty? ? base : "#{base}@#{capabilities.join(":")}"
  end

  # Parses `CONCURRENT(workers: N)? SELECT|WHERE|EACH ...`
end
