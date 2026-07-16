# typed: strict

class ClearParser
  extend T::Sig

  private

  # Unified capability parser. Parses an optional @cap or @cap:chain sequence.
  # Returns an empty typed result if no capability token is present.
  # No semantic validation — just token consumption and duplicate detection.
  sig { returns(CapabilityParseResult) }
  def parse_capabilities
    result = CapabilityParseResult.new
    return result unless match?(:VAR_ID) && CAPABILITY_TOKENS.include?(current.value)

    apply_capability!(result, consume(:VAR_ID))

    # ':' chaining (e.g., @shared:locked, @soa:shared:locked, @list:soa)
    parse_capability_chain!(result)

    result
  end

  private

  sig { params(type_token: Lexer::Token, constructor_name: String).returns(CapabilityParseResult) }
  def parse_constructor_capabilities(type_token, constructor_name)
    result = CapabilityParseResult.new
    return result unless (match?(:VAR_ID) && CAPABILITY_TOKENS.include?(current.value)) || match?(:CHAR, ':')

    allowed = ["@soa", "@sharded"]
    cap_tok = Lexer::Token.new(:VAR_ID, "@#{constructor_name.downcase}", type_token.line, type_token.column)

    if match?(:VAR_ID)
      tok = consume(:VAR_ID)
      normalized = tok.text!.start_with?("@") ? tok.text! : "@#{tok.text!}"
      unless allowed.include?(normalized)
        error!(tok, :CAP_BAD_MODIFIER, cap: cap_tok.text!, modifier: tok.text!)
      end
      apply_capability!(result, tok, normalized, validate_shard_count: true)
    end

    parse_capability_chain!(result, allowed_values: allowed, cap_tok: cap_tok, validate_shard_count: true)
    result
  end

  sig do
    params(
      result: CapabilityParseResult,
      allowed_values: T::Array[String],
      cap_tok: T.nilable(Lexer::Token),
      validate_shard_count: T::Boolean
    ).void
  end
  def parse_capability_chain!(result, allowed_values: [], cap_tok: nil, validate_shard_count: false)
    while match?(:CHAR, ':')
      consume(:CHAR, ':')
      error!(current, :EXPECTED_CAP_AFTER_COLON) unless current.type == :VAR_ID

      tok = consume(:VAR_ID)
      normalized_value = tok.text!.start_with?('@') ? tok.text! : "@#{tok.text!}"
      if !allowed_values.empty? && !allowed_values.include?(normalized_value)
        error!(tok, :CAP_BAD_MODIFIER, cap: cap_tok&.text! || "capability", modifier: tok.text!)
      end
      apply_capability!(result, tok, normalized_value, validate_shard_count: validate_shard_count)
    end
  end

  sig { returns(ElementCapability) }
  def parse_element_capability
    result = ElementCapability.new
    return result unless match?(:VAR_ID) && ELEMENT_CAPABILITY_TOKENS.include?(current.value)
    return result unless element_capability_suffix?

    token = consume(:VAR_ID)
    emit_boxed_capability_migration(token)
    apply_element_capability!(result, token.text!)
    if match?(:CHAR, ':')
      consume(:CHAR, ':')
      token = consume(:VAR_ID)
      emit_boxed_capability_migration(token)
      apply_element_capability!(result, token.text!)
    end
    result
  end

  sig { returns(T::Boolean) }
  def element_capability_suffix?
    next_tok = peek_at(1)
    return true if token_char?(next_tok, '[')
    return false unless token_char?(next_tok, ':')

    sync_tok = peek_at(2)
    return false unless token_var?(sync_tok) && token_char?(peek_at(3), '[')

    joined = T.must(sync_tok).text!
    ELEMENT_SYNC_TOKENS.include?(joined) || %w[node @node shared @shared].include?(joined)
  end

  sig { params(result: ElementCapability, value: String).void }
  def apply_element_capability!(result, value)
    case value
    when "@shared"
      result.ownership = result.ownership == :node ? :shared_node : :shared
    when "@multiowned"
      result.ownership = :multiowned
    when "@node"
      result.ownership = result.ownership == :shared ? :shared_node : :node
    when "shared"
      result.ownership = result.ownership == :node ? :shared_node : :shared
    when "node"
      result.ownership = result.ownership == :shared ? :shared_node : :node
    when "@locked", "locked"
      result.sync = :locked
    when "@writeLocked", "writeLocked"
      result.sync = :write_locked
    when "@link"
      result.ownership = :link
    when "@boxed", "boxed", "@indirect", "indirect"
      result.layout = :indirect
    end
  end

  sig { params(token: T.nilable(Lexer::Token), value: String).returns(T::Boolean) }
  def token_char?(token, value)
    return false unless token

    token.type == :CHAR && token.value == value
  end

  sig { params(token: T.nilable(Lexer::Token)).returns(T::Boolean) }
  def token_var?(token)
    token&.type == :VAR_ID
  end

  # Apply a single capability token to the result hash. Detects duplicates.
  sig { params(result: CapabilityParseResult, token: Lexer::Token, value: String, validate_shard_count: T::Boolean).void }
  def apply_capability!(result, token, value = token.value, validate_shard_count: false)
    emit_boxed_capability_migration(token)
    ownership = CAPABILITY_OWNERSHIP_VALUES[value]
    if ownership
      current = result.ownership
      if (current == :shared && ownership == :node) || (current == :node && ownership == :shared)
        result.ownership = :shared_node
      else
        error!(token, :DUPLICATE_OWNERSHIP_CAP) if current
        result.ownership = ownership
      end
      return
    end

    sync = CAPABILITY_SYNC_VALUES[value]
    if sync
      error!(token, :DUPLICATE_SYNC_CAP) if result.sync
      result.sync = sync
      return
    end

    collection = CAPABILITY_COLLECTION_VALUES[value]
    if collection
      error!(token, :DUPLICATE_COLLECTION_CAP) if result.collection
      result.collection = collection
      return
    end

    case value
    when "@boxed", "@indirect"
      error!(token, :DUPLICATE_LAYOUT_CAP) if result.is_indirect
      result.is_indirect = true
    when "@soa"
      error!(token, :DUPLICATE_SOA_CAP) if result.is_soa
      result.is_soa = true
    when "@sharded"
      error!(token, :DUPLICATE_SHARD_COUNT_CAP) if result.shard_count
      consume(:CHAR, '(')
      count_tok = consume_number
      count = count_tok.value.to_i
      error!(count_tok, :SHARDED_TOO_FEW, count: count) if validate_shard_count && count < 2
      result.shard_count = count
      consume(:CHAR, ')')
    when "@observable"
      error!(token, :DUPLICATE_OBSERVABLE_CAP) if result.observable
      result.observable = true
      # Keep the token span so fixable errors can delete the source capability.
      result.observable_token = token
    else
      emit_typo_suggestion!(
        token, value, CAPABILITY_TOKENS,
        "Unknown capability modifier '#{value}'",
        "closest capability",
        category: :capability, cascade: true
      )
    end
  end


  public

  # parse_striped_modifier! removed — striped is now :sharded(N) @locked composition

  sig { returns(T.nilable(AST::WithBlock)) }
  def parse_with_capability
    with_token = consume(:KEYWORD, 'WITH')

    # VIEW forms are routed before the generic capability-list parser so they
    # don't participate in the comma-separated capability grammar.
    if match?(:KEYWORD, 'VIEW') || match?(:KEYWORD, 'MATERIALIZED') || match?(:KEYWORD, 'UNSAFE')
      return parse_view_block(with_token)
    end

    # SNAPSHOT requires its own list shape, with each cell prefixed by SNAPSHOT.
    if match?(:KEYWORD, 'SNAPSHOT')
      return parse_snapshot_block(with_token)
    end

    # POLYMORPHIC marks a binding whose admissible sync family set has more
    # than one member; the annotator enforces that it matches REQUIRES.
    polymorphic = false
    if match?(:KEYWORD, 'POLYMORPHIC')
      consume(:KEYWORD, 'POLYMORPHIC')
      polymorphic = true
    end

    # Optional deadlock-escape modifier: one of POSSIBLE_DEADLOCK /
    # POSSIBLE_LOCK_CYCLE, immediately after WITH. Acts as a per-block
    # opt-out from the static nested-lock checks; code still emits a
    # [Note] at each opted-out site so the risk remains visible.
    escape_tok = nil
    if match?(:KEYWORD, 'POSSIBLE_DEADLOCK') || match?(:KEYWORD, 'POSSIBLE_LOCK_CYCLE')
      escape_tok = consume(:KEYWORD)
    end

    # Parse comma-separated list of capability specifications.
    # Syntax: WITH var_name { } — capability is inferred from the variable's type.
    # Explicit form: WITH RESTRICT/EXCLUSIVE var_name { } — traditional capabilities.
    # Locked form:   WITH EXCLUSIVE lockedVar AS alias { } — acquire mutex, bind inner value.
    capabilities = []

    # `WITH RESTRIKT x { ... }` — a typo of an UPPERCASE capability
    # keyword tokenizes as TYPE_ID and the loop below would silently
    # exit the capability list, then fail at the `{` body. Catch this
    # shape early and offer a typo suggestion against the known
    # capability keyword set.
    if match?(:TYPE_ID)
      typo_tok = current
      emit_typo_suggestion!(
        typo_tok, typo_tok.value, AST::CAPABILITIES.map(&:to_s),
        "Unknown WITH capability '#{typo_tok.value}'",
        "closest WITH capability",
        category: :capability, cascade: true
      )
    end

    while match?(:KEYWORD) || match?(:VAR_ID) do
      capability = if match?(:KEYWORD) && current.value != 'AS'
        cap_tok = consume(:KEYWORD)
        cap = cap_tok.text!.to_sym
        unless AST::CAPABILITIES.include?(cap)
          emit_typo_suggestion!(
            cap_tok, cap_tok.text!, AST::CAPABILITIES.map(&:to_s),
            "Unknown WITH capability '#{cap}'",
            "closest WITH capability",
            category: :capability, cascade: true
          )
        end
        cap
      else
        :infer  # VAR_ID: capability inferred from variable's type at annotation time
      end

      # Parse variable (supports foo, foo.bar, foo.bar.baz, etc.)
      var_node = parse_var_id

      # Optional alias binding: WITH EXCLUSIVE lockedVar AS [MUTABLE] alias { }
      alias_name = nil
      alias_mutable = false
      if match!(:KEYWORD, 'AS')
        if match!(:KEYWORD, 'MUTABLE')
          alias_mutable = true
        end
        alias_name = consume(:VAR_ID).text!
      end

      guard_expr = nil
      if match!(:KEYWORD, 'GUARD')
        unless alias_name
          error!(previous, :WITH_GUARD_REQUIRES_AS)
        end
        guard_expr = parse_expression
      end

      capabilities << AST::Capability.new(capability: capability, var_node: var_node, alias: alias_name, alias_mutable: alias_mutable, guard_expr: guard_expr)

      # Check for comma (continue) or opening brace (done)
      break unless match!(:CHAR, ',')
    end

    # WITH MATCH introduces per-family arms after the binding list.
    if match!(:KEYWORD, 'MATCH')
      arms = parse_with_match_arms
      consume(:KEYWORD, 'END')
      node = AST::WithBlock.new(with_token, capabilities, [])
      node.arms = arms
      node.polymorphic = polymorphic
      if escape_tok
        node.deadlock_escape = {
          kind: escape_tok.value == 'POSSIBLE_DEADLOCK' ? :deadlock : :lock_cycle,
          token: escape_tok,
        }
      end
      return node
    end

    # Parse block
    body = parse_brace_block

    node = AST::WithBlock.new(with_token, capabilities, body)
    node.lock_error_clause = parse_lock_error_clause
    node.polymorphic = polymorphic
    if escape_tok
      node.deadlock_escape = {
        kind: escape_tok.value == 'POSSIBLE_DEADLOCK' ? :deadlock : :lock_cycle,
        token: escape_tok,
      }
    end
    node
  end

  # Snapshot grammar:
  #
  #   WITH SNAPSHOT <var> AS <alias> { <body> }
  #     -- single read (immutable view).
  #
  #   WITH SNAPSHOT <var> AS MUTABLE <alias> { <body> }
  #     ON Conflict [RETRY(N) THEN] <action>
  #     -- single transaction (mutable view).
  #
  #   WITH SNAPSHOT a AS [MUTABLE] va, SNAPSHOT b AS [MUTABLE] vb
  #     [, ...]
  #   { <body> } [ON Conflict ...]
  #     -- multi-cell. Mixed read + mutable. ON Conflict required if
  #     any AS MUTABLE; the runtime sorts cell pointers by address
  #     (no deadlock) and commits via `Shared.updateMulti`.
  #
  # The annotator enforces ON Conflict presence when any cell is MUTABLE.
  sig { params(with_token: Lexer::Token).returns(T.nilable(AST::WithBlock)) }
  def parse_snapshot_block(with_token)
    capabilities = []
    any_mutable = T.let(false, T::Boolean)
    loop do
      snapshot_tok = consume(:KEYWORD, 'SNAPSHOT')
      var_node = parse_var_id
      consume(:KEYWORD, 'AS')
      alias_mutable = false
      alias_mutable = true if match!(:KEYWORD, 'MUTABLE')
      alias_name = consume(:VAR_ID).text!

      capabilities << AST::Capability.new(
        capability: :SNAPSHOT,
        var_node: var_node,
        alias: alias_name,
        alias_mutable: alias_mutable,
        snapshot_token: snapshot_tok,
      )
      any_mutable ||= alias_mutable

      break unless match!(:CHAR, ',')
    end

    # VERSIONED and ATOMIC snapshot surfaces differ on conflict handling, so
    # MATCH arms let the user choose per family.
    if match!(:KEYWORD, 'MATCH')
      arms = parse_with_match_arms
      consume(:KEYWORD, 'END')
      node = AST::WithBlock.new(with_token, capabilities, [])
      node.arms = arms
      node.snapshot_mode = any_mutable ? :transaction : :read
      return node
    end

    body = parse_brace_block

    # Optional `ON Conflict ...` handler. Reuses the same generic
    # `parse_lock_error_clause` path so `RETRY(N) THEN` and the
    # action-list grammar match exactly. Conflict is registered as
    # a type in `error_registry.rb`, so the bare TYPE_ID selector
    # path accepts it without further changes.
    clause = parse_lock_error_clause

    node = AST::WithBlock.new(with_token, capabilities, body)
    node.snapshot_mode = any_mutable ? :transaction : :read
    node.lock_error_clause = clause
    node
  end

  # View grammar:
  #
  #   WITH VIEW <var> AS <alias> { <body> } [END]
  #   WITH MATERIALIZED VIEW <var> AS <alias> { <body> } [END]
  #   WITH UNSAFE VIEW <var> LENGTH <count> AS <alias> { <body> } [END]
  #
  # Builds an AST::WithBlock with view_kind = :view / :materialized_view /
  # :unsafe_view and a single capability entry,
  # var_node:, alias: }. The optional END after `}` is consumed if present.
  sig { params(with_token: Lexer::Token).returns(AST::WithBlock) }
  def parse_view_block(with_token)
    view_kind = nil
    view_token = nil
    view_length = nil
    if match?(:KEYWORD, 'UNSAFE')
      view_token = consume(:KEYWORD, 'UNSAFE')
      consume(:KEYWORD, 'VIEW')
      view_kind = :unsafe_view
      capability = :UNSAFE_VIEW
    elsif match?(:KEYWORD, 'MATERIALIZED')
      mat_tok = consume(:KEYWORD, 'MATERIALIZED')
      view_token = consume(:KEYWORD, 'VIEW')
      view_kind = :materialized_view
      capability = :MATERIALIZED_VIEW
      view_token = mat_tok # span starts at MATERIALIZED
    else
      view_token = consume(:KEYWORD, 'VIEW')
      view_kind = :view
      capability = :VIEW
    end

    var_node = parse_var_id
    if view_kind == :unsafe_view
      consume(:KEYWORD, 'LENGTH')
      # Stop before AS (precedence 2), which introduces the lexical alias.
      view_length = parse_expression(2)
    end
    as_token = consume(:KEYWORD, 'AS')
    alias_name = consume(:VAR_ID).text!

    # Optional ARROW for the WITH ... AS s -> ... shape used in docs.
    # The brace form `{ body }` is canonical; the arrow form is sugar.
    if match!(:ARROW, '->')
      body = parse_block_body(['END'])
      consume(:KEYWORD, 'END')
    else
      body = parse_brace_block
    end

    # `view_token` lets fixable errors replace VIEW with MATERIALIZED VIEW
    # using the exact source span.
    node = AST::WithBlock.new(with_token, [AST::Capability.new(
      capability: capability,
      var_node: var_node,
      alias: alias_name,
      alias_mutable: false,
      view_token: view_token,
      view_length: view_length,
      as_token: as_token,
    )], body)
    node.view_kind = view_kind
    node
  end

  # Parse one or more WHEN arms. Grammar:
  #
  #   WHEN <FAMILY>
  #       '->' '{' <body> '}'
  #       [ ON <selectors> <action> | RETRY '(' N ')' THEN <action> ]*
  #
  # Returns an array of typed arms. The terminating END is consumed by
  # the caller.
  sig { returns(T::Array[AST::WithMatchArm]) }
  def parse_with_match_arms
    arms = []
    while match?(:KEYWORD, 'WHEN')
      when_tok = consume(:KEYWORD, 'WHEN')
      family = parse_requires_family
      consume(:ARROW, '->')
      body = parse_brace_block

      # Per-arm ON / RETRY clauses, zero or more.
      lock_error_clauses = []
      while match?(:KEYWORD, 'ON') || match?(:KEYWORD, 'RETRY')
        clause = parse_lock_error_clause
        lock_error_clauses << clause if clause
      end

      arms << AST::WithMatchArm.new(
        family: family,
        body: body,
        lock_error_clauses: lock_error_clauses,
        token: when_tok,
      )
    end

    if arms.empty?
      error!(current, :WITH_MATCH_NO_WHEN)
    end

    arms
  end

  # Top-level SYNC POLICY uses the same handler grammar as per-WITH ON clauses.
  # The annotator enforces single-instance, main-file-only, and required
  # handler coverage.
  sig { returns(AST::SyncPolicyDecl) }
  def parse_sync_policy_block
    sync_tok = consume(:KEYWORD, 'SYNC')
    consume(:KEYWORD, 'POLICY')
    consume(:KEYWORD, 'START')

    handlers = []
    while match?(:KEYWORD, 'ON') || match?(:KEYWORD, 'RETRY')
      clause = parse_lock_error_clause
      handlers << clause if clause
    end

    if handlers.empty?
      error!(current, :SYNC_POLICY_NO_HANDLER)
    end

    consume(:KEYWORD, 'END')
    AST::SyncPolicyDecl.new(sync_tok, handlers)
  end

  # Parse an optional error-handling clause following a WITH block's `}`:
  #   ON <selectors> [RETRY(N) THEN] <action>
  #   RETRY(N) THEN <action>                  -- sugar for ON Transient
  # Returns an ErrorClause or nil.
  # Selector validation (existence, retry-is-Transient) runs in the annotator.
  sig { returns(T.nilable(AST::ErrorClause)) }
  def parse_lock_error_clause
    if match?(:KEYWORD, 'ON')
      consume(:KEYWORD, 'ON')
      selectors = parse_error_selectors
      retries = match_optional_retry!
      action = parse_lock_action
      AST::ErrorClause.from_action(selectors: selectors, retries: retries, action: action)
    elsif match?(:KEYWORD, 'RETRY')
      retries = match_optional_retry!
      action = parse_lock_action
      # Sugar: `RETRY(N) THEN <action>` == `ON Transient RETRY(N) THEN <action>`.
      AST::ErrorClause.from_action(
        selectors: [AST::ErrorSelector.new(form: :kind, name: :Transient, token: action.token)],
        retries: retries,
        action: action,
      )
    else
      nil
    end
  end

  # Consume `RETRY '(' N ')' THEN` if present. Returns the N or nil.
  sig { returns(T.nilable(Integer)) }
  def match_optional_retry!
    return nil unless match!(:KEYWORD, 'RETRY')
    consume(:CHAR, '(')
    tok = consume_number
    n = tok.value.to_i
    error!(tok, :RETRY_N_NONPOSITIVE, got: n) if n <= 0
    consume(:CHAR, ')')
    consume(:KEYWORD, 'THEN')
    n
  end

  # Parse comma-separated error selectors. Each is a bare TYPE_ID. A
  # TYPE_ID matching one of the 6 reserved kind names is a kind
  # selector; anything else is a type selector. Types are enum values
  # (no `:` prefix) per the unified error-system design; the 6 kind
  # names are effectively reserved.
  sig { returns(T::Array[AST::ErrorSelector]) }
  def parse_error_selectors
    selectors = [parse_error_selector]
    while match!(:CHAR, ',')
      selectors << parse_error_selector
    end
    selectors
  end

  sig { returns(AST::ErrorSelector) }
  def parse_error_selector
    unless match?(:TYPE_ID)
      error!(current, :EXPECTED_ERROR_SELECTOR)
    end
    tok = consume(:TYPE_ID)
    form = ERROR_KINDS.include?(tok.text!) ? :kind : :type
    AST::ErrorSelector.new(form: form, name: tok.text!.to_sym, token: tok)
  end

  # Parse a single error-handler action: RAISE | PASS | RETURN expr | EXIT "msg" | -> { stmts }.
  sig { returns(AST::ErrorAction) }
  def parse_lock_action
    if match!(:KEYWORD, 'RAISE')
      AST::ErrorAction.new(action: AST::ErrorActionKind::Raise, token: previous)
    elsif match!(:KEYWORD, 'PASS')
      AST::ErrorAction.new(action: AST::ErrorActionKind::Pass, token: previous)
    elsif match!(:KEYWORD, 'RETURN')
      tok = previous
      value = parse_expression
      AST::ErrorAction.new(action: AST::ErrorActionKind::Return, value: value, token: tok)
    elsif match!(:KEYWORD, 'EXIT')
      tok = previous
      msg = parse_expression
      AST::ErrorAction.new(action: AST::ErrorActionKind::Exit, message: msg, token: tok)
    elsif match?(:ARROW, '->')
      tok = consume(:ARROW, '->')
      body = parse_brace_block
      AST::ErrorAction.new(action: AST::ErrorActionKind::Block, body: body, token: tok)
    else
      error!(current, :EXPECTED_AFTER_ERROR_CLAUSE)
    end
  end

  # Parses an optional `:@cap` continuation after an expression-level capability sigil.
  # `tok` is the already-consumed first sigil token; `first_attrs` is its CAP_SIGIL_ATTRS entry.
  # Returns a named capability record whose dimensions may be nil.
  # Handles order-independent joins: @shared:locked and @locked:shared both work.
  # Parses a capability chain: @a:b:c (order-independent, max one per dimension).
  # The record also carries an optional lock rank.
  sig { params(tok: Lexer::Token, first_attrs: SigilAttrs).returns(CapJoin) }
  def parse_cap_join(tok, first_attrs)
    dims = CapJoin.new
    apply_cap_dim!(tok, first_attrs, dims)
    parse_lock_rank_arg!(tok, first_attrs, dims)

    while match?(:CHAR, ':')
      consume(:CHAR, ':')
      unless current.type == :VAR_ID
        error!(current, :EXPECTED_CAP_SIGIL_AFTER_COLON)
      end
      normalized = current.value.start_with?('@') ? current.value : "@#{current.value}"
      attrs = CAP_SIGIL_ATTRS[normalized]
      unless attrs
        # Chain form `@shared:foo` arrives without the `@`; root form
        # arrives with it. Match the candidate-set shape to whichever
        # form the user typed so the replacement slots in cleanly.
        has_at = current.value.start_with?('@')
        candidates = has_at ? CAP_SIGIL_ATTRS.keys : CAP_SIGIL_ATTRS.keys.map { |k| k.sub(/^@/, '') }
        emit_typo_suggestion!(
          current, current.value, candidates,
          "Unknown capability sigil '#{current.value}'",
          "closest capability sigil",
          category: :capability, cascade: true
        )
      end
      attrs = T.must(attrs)
      next_tok = consume(:VAR_ID)
      emit_boxed_capability_migration(next_tok)
      apply_cap_dim!(next_tok, attrs, dims)
      parse_lock_rank_arg!(next_tok, attrs, dims)
    end

    # Reject T @cap1 @cap2 (must use : join, e.g. @shared:locked)
    if match?(:VAR_ID) && current.value.start_with?('@') && CAP_SIGIL_ATTRS.key?(current.value)
      error!(current, :MIXED_AT_CAPABILITIES)
    end

    dims
  end

  sig { params(tok: Lexer::Token, attrs: SigilAttrs, dims: CapJoin).returns(T.nilable(Symbol)) }
  def apply_cap_dim!(tok, attrs, dims)
    dim = attrs.dim
    val = attrs.val
    return nil unless dim && val

    current_value = case dim
    when :ownership then dims.ownership
    when :sync then dims.sync
    when :layout then dims.layout
    else return nil
    end

    if dim == :ownership && ((current_value == :shared && val == :node) || (current_value == :node && val == :shared))
      dims.ownership = :shared_node
      return :shared_node
    end

    if current_value
      error!(tok, :DUPLICATE_CAPABILITY_DIM, dim: dim, current: current_value, attempted: val)
    end

    case dim
    when :ownership then dims.ownership = val
    when :sync then dims.sync = val
    when :layout then dims.layout = val
    end
    val
  end

  # Parse an optional `(rank: N)` argument after @locked / @writeLocked.
  # The N is an integer; sign and magnitude are free. Duplicate rank on
  # the same capability chain is an error.
  sig { params(sigil_tok: Lexer::Token, attrs: SigilAttrs, dims: CapJoin).returns(T.nilable(Integer)) }
  def parse_lock_rank_arg!(sigil_tok, attrs, dims)
    return unless attrs.dim == :sync
    return unless attrs.val == :locked || attrs.val == :write_locked
    return unless match?(:CHAR, '(')
    consume(:CHAR, '(')
    unless match?(:VAR_ID, 'rank')
      error!(current, :EXPECTED_RANK_KEYWORD, sigil: attrs.val)
    end
    consume(:VAR_ID, 'rank')
    consume(:CHAR, ':')
    neg = match!(:CHAR, '-')
    num_tok = consume_number
    rank = num_tok.value.to_i
    rank = -rank if neg
    consume(:CHAR, ')')
    if dims.lock_rank
      error!(sigil_tok, :DUPLICATE_LOCK_RANK, current: dims.lock_rank, attempted: rank)
    end
    dims.lock_rank = rank
  end


  # Parse an optional chained task prefix. The caller supplies the allowed
  # sigils and diagnostic wording; accumulation has one typed result.
  sig do
    params(
      sigils: SigilTable,
      kind: String,
      prefix_label: String,
      suggestion_label: String,
    ).returns(TaskPrefix)
  end
  def parse_task_prefix(sigils, kind, prefix_label, suggestion_label)
    pinned     = T.let(false, T::Boolean)
    parallel   = T.let(false, T::Boolean)
    arena      = T.let(false, T::Boolean)
    can_smash  = T.let(false, T::Boolean)
    stack_size = T.let(nil, T.nilable(Symbol))
    stack_size_token = T.let(nil, T.nilable(Lexer::Token))
    can_smash_token = T.let(nil, T.nilable(Lexer::Token))

    looks_like_sigil = current.type == :VAR_ID && current.value.start_with?('@')
    unless looks_like_sigil
      return TaskPrefix.new(
        pinned: pinned, parallel: parallel, stack_size: stack_size,
        arena: arena, can_smash: can_smash,
      )
    end

    loop do
      tok = consume(:VAR_ID)
      token_text = tok.text!
      cap_name = token_text.start_with?('@') ? token_text : "@#{token_text}"
      attrs = sigils[cap_name]
      unless attrs
        has_at = token_text.start_with?('@')
        candidates = has_at ? sigils.keys : sigils.keys.map { |key| key.sub(/^@/, '') }
        emit_typo_suggestion!(
          tok, token_text, candidates,
          "Unknown #{prefix_label} prefix #{token_text.inspect}",
          suggestion_label,
          category: :type, cascade: true
        )
      end
      attrs = T.must(attrs)

      stack_size_attr = attrs.stack_size
      if stack_size_attr
        error!(tok, :DUPLICATE_STACK_SIZE, kind: kind) if stack_size
        stack_size = stack_size_attr
        stack_size_token = tok
      end
      pinned    = true if attrs.pinned
      parallel  = true if attrs.parallel
      arena     = true if attrs.arena
      if attrs.can_smash
        can_smash = true
        can_smash_token = tok
      end

      break unless match?(:CHAR, ':')
      consume(:CHAR, ':')
    end

    consume(:ARROW, '->')
    TaskPrefix.new(
      pinned: pinned,
      parallel: parallel,
      stack_size: stack_size,
      arena: arena,
      can_smash: can_smash,
      stack_size_token: stack_size_token,
      can_smash_token: can_smash_token,
    )
  end

  sig { returns(AST::DoBlock) }
  def parse_do_block
    do_token = consume(:KEYWORD, 'DO')
    consume(:CHAR, '{')
    branches = []

    until match?(:CHAR, '}') || match?(:EOF)
      prefix = parse_task_prefix(DO_BRANCH_SIGILS, "branch", "branch", "closest DO branch sigil")

      # A branch is either a block-statement (WITH, IF, etc.) starting with a keyword,
      # or a bare expression. Keyword branches don't need a trailing semicolon.
      stmt = if match?(:KEYWORD)
        parse_statement
      else
        parse_expression
      end
      branches << AST::DoBranch.new(
        body: [stmt].compact,
        pinned: prefix.pinned,
        parallel: prefix.parallel,
        stack_size: prefix.stack_size,
        can_smash: prefix.can_smash,
      )
      break unless match!(:CHAR, ',')
    end

    consume(:CHAR, '}')
    AST::DoBlock.new(do_token, branches)
  end

  sig { returns(AST::BgNode) }
  def parse_bg_block
    bg_token = consume(:KEYWORD, 'BG')
    if match?(:KEYWORD, 'STREAM')
      return parse_bg_stream_block(bg_token)
    end
    open_brace = consume(:CHAR, '{')
    prefix = parse_task_prefix(BG_SIGILS, "BG", "BG", "closest BG body sigil")
    body = parse_bg_then_body
    consume(:CHAR, '}')
    node = AST::BgBlock.new(bg_token, body, nil, prefix.stack_size, prefix.pinned, prefix.parallel, prefix.arena, prefix.can_smash)
    node.open_brace_token = open_brace
    node.prefix_token = prefix.stack_size_token
    node.can_smash_token = prefix.can_smash_token
    node
  end

  # Custom body parser for BG blocks that recognises THEN chains.
  sig { returns(AST::RawBody) }
  def parse_bg_then_body
    stmts = []
    until match?(:CHAR, '}') || match?(:EOF)
      stmt = parse_bg_body_stmt
      stmts << stmt if stmt
    end
    stmts
  end

  # Parse one statement from a BG block body.
  # If the expression is followed by AS or THEN, builds a ThenChain node.
  sig { returns(AST::Node) }
  def parse_bg_body_stmt
    if current.type == :VAR_ID && destructuring_assignment?
      return parse_destructuring_assign
    end

    # Keyword statements (IF, WHILE, RETURN, etc.) — cannot start THEN chains
    rule = STMT_RULE_INDEX[ClearParser.token_rule_key(current)]
    return dispatch_stmt_rule(rule) if rule

    parsed_var = current.type == :VAR_ID ? parse_var_form : nil
    if parsed_var&.assignment
      consume(:CHAR, ';')
      return parsed_var.node
    end
    expr = parsed_var ? parsed_var.node : parse_expression

    # THEN chain: expr [AS name] THEN expr [AS name] THEN ...
    if match?(:KEYWORD, 'AS') || match?(:KEYWORD, 'THEN')
      binding_name = nil
      if match?(:KEYWORD, 'AS')
        consume(:KEYWORD, 'AS')
        binding_name = consume(:VAR_ID).text!
      end

      unless match?(:KEYWORD, 'THEN')
        error!(current, :EXPECTED_THEN_AFTER_AS_BG, got: current.value.inspect)
      end

      steps = [AST::ThenStep.new(expr: expr, binding: binding_name)]
      while match?(:KEYWORD, 'THEN')
        consume(:KEYWORD, 'THEN')
        next_expr = parse_expression
        next_binding = nil
        if match?(:KEYWORD, 'AS')
          consume(:KEYWORD, 'AS')
          next_binding = consume(:VAR_ID).text!
        end
        steps << AST::ThenStep.new(expr: next_expr, binding: next_binding)
      end
      match!(:CHAR, ';')
      return AST::ThenChain.new(steps.first.expr.token, steps)
    end

    consume(:CHAR, ';')
    expr
  end

  sig { params(bg_token: Lexer::Token).returns(AST::BgStreamBlock) }
  def parse_bg_stream_block(bg_token)
    consume(:KEYWORD, 'STREAM')
    yields_token = T.let(nil, T.nilable(Lexer::Token))
    declared_yield_type = T.let(nil, T.nilable(Type))
    if match?(:KEYWORD, 'YIELDS')
      yields_token = consume(:KEYWORD, 'YIELDS')
      declared_yield_type = parse_type_annotation
    end
    body = parse_brace_block
    node = AST::BgStreamBlock.new(bg_token, body, nil)
    node.set_yield_contract(declared_yield_type, yields_token)
    node
  end

  sig { returns(AST::YieldExpr) }
  def parse_yield_expr
    tok = consume(:KEYWORD, 'YIELD')
    expr = parse_expression
    consume(:CHAR, ';')
    AST::YieldExpr.new(tok, expr)
  end

  sig { returns(AST::CloseStream) }
  def parse_close_stream
    tok = consume(:KEYWORD, 'CLOSE')
    consume(:CHAR, ';')
    AST::CloseStream.new(tok)
  end

  sig { returns(AST::NextExpr) }
  def parse_next_expr
    tok = consume(:KEYWORD, 'NEXT')
    expr = parse_expression
    AST::NextExpr.new(tok, expr)
  end
end
