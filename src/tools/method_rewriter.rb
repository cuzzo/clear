# typed: strict
require "sorbet-runtime"

require 'set'
require_relative '../ast/lexer'
require_relative '../ast/parser'
require_relative '../ast/ast'
require_relative '../ast/std_lib'

# MethodRewriter — source-level preprocessor for `clear fmt`.
#
# Walks the AST, finds `METHOD`-declared functions, and rewrites every
# prefix call site `foo(v, ...)` to UFCS form `v.foo(...)`. Pipelines
# (`v |> foo`) are left alone. Already-UFCS calls (`v.foo()`) are left
# alone. Calls of `FN`-declared functions are left alone.
#
# Operates as a textual edit pass: produces a new source string that
# the existing formatter then formats. This keeps the rewrite logic
# decoupled from token-level emission and makes idempotence trivial
# (the second pass finds nothing to rewrite).
#
# Nested METHOD calls (`length(filter(xs, p))` with both METHODs)
# rewrite inside-out to method chains (`xs.filter(p).length()`).
module MethodRewriter
  extend T::Sig

  module_function

  sig { params(source: String).returns(String) }
  def rewrite(source)
    tokens = ::Lexer.new(source).tokenize
    ast = ::Parser.new(tokens, source).parse
    methods = collect_method_names(ast)
    return source if methods.empty?

    edits = []
    walk_collect_edits(ast, methods, source, edits)
    return source if edits.empty?

    apply_edits(source, edits)
  end

  # ---- AST traversal ----

  # Returns the set of function names that should be rewritten to
  # UFCS form. A name is included when:
  #   (a) the user declared `METHOD name(...)`, OR
  #   (b) stdlib registers `name` with `is_method: true` AND the user
  #       did NOT shadow it with a non-method `FN name(...)`.
  # User declarations always take precedence over stdlib — if the
  # user wrote `FN length(xs) -> ...`, calls to `length(xs)` stay in
  # prefix form regardless of stdlib's flag.
  sig { params(ast: AST::Program).returns(Set) }
  def collect_method_names(ast)
    user_methods = Set.new
    user_fns = Set.new
    walk_collect_user_decls(ast, user_methods, user_fns)
    set = user_methods.dup
    stdlib_method_names.each do |n|
      set << n unless user_fns.include?(n)
    end
    set
  end

  def walk_collect_user_decls(node, methods, fns)
    case node
    when AST::FunctionDef
      if node.is_method
        methods << node.name
      else
        fns << node.name
      end
      walk_collect_user_decls(node.body, methods, fns) if node.body
    when Array
      node.each { |n| walk_collect_user_decls(n, methods, fns) }
    else
      return unless node.respond_to?(:each_pair)
      node.each_pair { |_, v| walk_collect_user_decls(v, methods, fns) }
    end
  end

  # Stdlib functions tagged with `is_method: true` in std_lib.rb.
  # Cached after the first call since the registries are frozen
  # constants. Walks every top-level registry: STD_LIB plus the
  # collection-shape registries (POOL_METHODS, SET_METHODS, MAP_METHODS)
  # whose entries also carry the marker.
  STDLIB_REGISTRIES = [
    -> { STD_LIB },
    -> { POOL_METHODS rescue nil },
    -> { SET_METHODS rescue nil },
    -> { MAP_METHODS rescue nil },
  ].freeze

  sig { returns(Set) }
  def stdlib_method_names
    @stdlib_method_names ||= begin
      names = Set.new
      STDLIB_REGISTRIES.each do |loader|
        registry = loader.call
        next unless registry.is_a?(Hash)
        IntrinsicRegistry.sigs(registry).each do |name, defs|
          list = defs.is_a?(Array) ? defs : [defs]
          list.each do |d|
            next unless d.is_a?(FunctionSignature)
            next unless d.emit&.is_method
            # Skip stdlib functions whose Zig lowering is FSM-based
            # (suspending I/O calls like readFile / writeFile / accept).
            # Their MIR/FSM lowering reads the call's positional args
            # at fixed indices via FsmOps; UFCS-rewriting moves the
            # first arg into the receiver slot and the FSM lowerer
            # crashes with "FsmOps arg index 0 out of range (0 args)."
            # Detection is structural (`suspends: true` plus an
            # `fsm_*` setup table) so we don't have to enumerate
            # specific names.
            next if fsm_lowered?(d)
            names << name
          end
        end
      end
      names
    end
  end

  # True when an stdlib registry entry uses FSM lowering for I/O. Both
  # markers must be present to count: `suspends: true` means the call
  # yields, and the `fsm_*` keys carry the templates the FSM emitter
  # reads. Either alone wouldn't be enough — `suspends: true` is also
  # set on plain async helpers that don't go through FSM.
  sig { params(defn: FunctionSignature).returns(T::Boolean) }
  def fsm_lowered?(defn)
    em = defn.emit
    return false unless em&.suspends
    !!(em.fsm_setup || em.fsm_state_decls || em.fsm_finish_block ||
       em.fsm_state_finalize || em.fsm_finish_value)
  end

  # Post-order walk: collect edits for inner calls first so outer
  # rewrites see the (logically) rewritten inner. Edits are applied
  # right-to-left on the source so positions don't shift.
  def walk_collect_edits(node, methods, source, edits)
    return if node.nil? || node.is_a?(Symbol) || node.is_a?(String) ||
              node.is_a?(Integer) || node.is_a?(Float) ||
              node.is_a?(TrueClass) || node.is_a?(FalseClass)

    if node.is_a?(Array)
      node.each { |n| walk_collect_edits(n, methods, source, edits) }
      return
    end

    if node.respond_to?(:each_pair)
      node.each_pair { |_, v| walk_collect_edits(v, methods, source, edits) }
    end

    if node.is_a?(AST::FuncCall) && methods.include?(node.name) &&
       node.args.is_a?(Array) && !node.args.empty? &&
       !node.fn_var_call && !node.extern_call
      edit = compute_edit(node, source)
      edits << edit if edit
    end
  end

  # ---- Edit computation ----

  # Compute a {start:, len:, replacement:} edit for a single FuncCall,
  # or nil if the call's source span couldn't be located cleanly
  # (e.g., contains a comment we'd rather not move). Source span is
  # the byte range from the start of the callee name to the closing
  # `)`, inclusive.
  sig { params(call: AST::FuncCall, source: String).returns(T.nilable(Hash)) }
  def compute_edit(call, source)
    start_off = offset_for(source, call.token.line, call.token.column)
    return nil unless start_off
    # Sanity-check: the bytes at start_off should be the callee name.
    # If not (e.g., the source has been edited or the token's column
    # is misaligned for any reason), skip rather than corrupt.
    return nil unless source[start_off, call.name.length] == call.name

    after_name = start_off + call.name.length
    open_off = next_non_ws(source, after_name)
    return nil unless open_off && source[open_off] == '('

    close_off = match_paren(source, open_off)
    return nil unless close_off

    args_text = source[(open_off + 1)...close_off]
    spans = split_args_by_comma(args_text)
    return nil if spans.empty?

    # Bail out if the args span multiple lines or contain newline-anchored
    # comments. The current rewriter would have to redistribute whitespace
    # / comments across the new shape, which is hard to get right; the
    # downstream formatter will still canonicalize spacing of the call we
    # leave in prefix form. Future enhancement.
    if args_text.include?("\n")
      return nil
    end

    first = args_text[spans[0][0]...spans[0][1]].strip
    return nil if first.empty?

    # Wrap the first arg in parens if its top-level AST node would
    # bind looser than `.method()`. Without this, expressions like
    # `toFloat(state MOD 1000)` would be rewritten to
    # `state MOD 1000.toFloat()`, which Zig parses as
    # `state MOD (1000.toFloat())` — a real semantics change.
    # See spec/method_rewriter_spec.rb for the regression case.
    first_arg_node = call.args[0]
    first = "(#{first})" if needs_parens?(first_arg_node, first)

    rest_text = if spans.size > 1
      # Preserve whatever the user wrote between the first comma and
      # the closing `)` (sans leading whitespace). This keeps internal
      # spacing of subsequent args verbatim — the downstream formatter
      # canonicalizes to `, ` separation.
      after_first = spans[0][1] + 1  # position past the first comma
      args_text[after_first..].sub(/\A\s+/, '')
    else
      ''
    end

    rewritten = if rest_text.empty?
      "#{first}.#{call.name}()"
    else
      "#{first}.#{call.name}(#{rest_text})"
    end

    { start: start_off, len: close_off - start_off + 1, replacement: rewritten }
  end

  # True when the source text for `node` would mis-parse if placed
  # immediately before `.method(...)`. Drives the paren wrap above.
  #
  # The check is structural (AST shape) with a textual safety net for
  # node types we don't enumerate. Anything whose top is a binary or
  # unary expression, a pipeline, a CAST, or similar must be wrapped.
  # "Tight" AST shapes — Identifier, Literal, MethodCall, FuncCall,
  # GetField, GetIndex, StructLit, ListLit — already bind tighter than
  # `.method()` and need no wrap. If the source text is already
  # paren-wrapped, no extra wrap either.
  TIGHT_AST_TYPES = [
    :Identifier, :Literal, :MethodCall, :FuncCall, :GetField,
    :GetIndex, :StructLit, :ListLit, :HashLit, :StringLit
  ].freeze

  def needs_parens?(node, text)
    stripped = text.strip
    return false if stripped.start_with?('(') && stripped.end_with?(')')
    return false unless node
    type_name = node.class.name&.split('::')&.last&.to_sym
    return false if TIGHT_AST_TYPES.include?(type_name)
    true
  end

  # ---- Source / span helpers ----

  sig { params(source: String, line: Integer, col: Integer).returns(Integer) }
  def offset_for(source, line, col)
    return nil if line < 1 || col < 1
    off = 0
    cur_line = 1
    while cur_line < line
      nl = source.index("\n", off)
      return nil unless nl
      off = nl + 1
      cur_line += 1
    end
    target = off + col - 1
    return nil if target > source.length
    target
  end

  sig { params(source: String, off: Integer).returns(Integer) }
  def next_non_ws(source, off)
    while off < source.length && (source[off] == ' ' || source[off] == "\t")
      off += 1
    end
    off
  end

  # Find matching ')' for '(' at `open_off`, respecting nested parens,
  # brackets, braces, and string literals. Returns the byte offset of
  # the matching ')' or nil if unbalanced.
  sig { params(source: String, open_off: Integer).returns(Integer) }
  def match_paren(source, open_off)
    depth = 0
    i = open_off
    in_str = false
    in_triple = false
    while i < source.length
      c = source[i]
      if in_triple
        if source[i, 3] == '"""'
          in_triple = false
          i += 3
          next
        end
      elsif in_str
        if c == '\\' && i + 1 < source.length
          i += 2
          next
        elsif c == '"'
          in_str = false
        end
      else
        if source[i, 3] == '"""'
          in_triple = true
          i += 3
          next
        elsif c == '"'
          in_str = true
        elsif c == '#'
          # Skip the rest of the line; CLEAR comments end at newline.
          nl = source.index("\n", i) || source.length
          i = nl
          next
        elsif '([{'.include?(c)
          depth += 1
        elsif ')]}'.include?(c)
          depth -= 1
          return i if depth == 0 && c == ')'
        end
      end
      i += 1
    end
    nil
  end

  # Split args_text into [start, end_exclusive] spans by top-level
  # commas. Respects nested parens / brackets / braces and strings.
  sig { params(args_text: String).returns(Array) }
  def split_args_by_comma(args_text)
    spans = []
    depth = 0
    cur_start = 0
    i = 0
    in_str = false
    in_triple = false
    while i < args_text.length
      c = args_text[i]
      if in_triple
        if args_text[i, 3] == '"""'
          in_triple = false
          i += 3
          next
        end
      elsif in_str
        if c == '\\' && i + 1 < args_text.length
          i += 2
          next
        elsif c == '"'
          in_str = false
        end
      else
        if args_text[i, 3] == '"""'
          in_triple = true
          i += 3
          next
        elsif c == '"'
          in_str = true
        elsif c == '#'
          nl = args_text.index("\n", i) || args_text.length
          i = nl
          next
        elsif '([{'.include?(c)
          depth += 1
        elsif ')]}'.include?(c)
          depth -= 1
        elsif c == ',' && depth == 0
          spans << [cur_start, i]
          cur_start = i + 1
        end
      end
      i += 1
    end
    spans << [cur_start, args_text.length]
    # Drop trailing empty span if user wrote `foo(a,)` — defensive.
    spans.reject! { |s, e| args_text[s...e].strip.empty? }
    spans
  end

  # Apply edits right-to-left so earlier-positioned edits' offsets
  # remain valid. Edits must be non-overlapping; post-order traversal
  # produces inside-out edits which are nested (overlapping). To get
  # the chain rewrite (`xs.filter(p).length()`) we apply the inner
  # edit first to the *replacement string* of the outer edit.
  sig { params(source: String, edits: Array).returns(String) }
  def apply_edits(source, edits)
    # Post-order has inner edits first. Group: an inner edit is one
    # whose span is strictly inside an outer edit's span. Process by
    # building a tree, applying inner replacements to outer's
    # replacement text via recursive substitution.
    sorted = edits.sort_by { |e| [e[:start], -e[:len]] }
    # Resolve nested edits: rewrite the replacement of any outer edit
    # to incorporate the rewritten form of inner edits.
    resolved = resolve_nested_edits(sorted, source)
    apply_flat_edits(source, resolved)
  end

  # For each outer edit, find inner edits inside its span and rewrite
  # the outer's replacement to use the inner's replacement (matched by
  # the inner's original source text). Returns a flat list of
  # non-overlapping outer edits with replacements that include all
  # inner rewrites embedded.
  sig { params(edits: Array, source: String).returns(Array) }
  def resolve_nested_edits(edits, source)
    outers = []
    edits.each do |e|
      enclosing = outers.find { |o| o[:start] < e[:start] && (o[:start] + o[:len]) > (e[:start] + e[:len]) }
      if enclosing
        # Substitute the inner's original text within the outer's replacement
        original = source[e[:start], e[:len]]
        # Replace the original (which still appears in outer's replacement
        # because we haven't yet substituted) with inner's replacement.
        # The outer's replacement was built from the original source's
        # arg text, which contains the inner call verbatim.
        enclosing[:replacement] = enclosing[:replacement].sub(original, e[:replacement])
      else
        outers << e.dup
      end
    end
    outers
  end

  sig { params(source: String, edits: Array).returns(String) }
  def apply_flat_edits(source, edits)
    return source if edits.empty?
    # Apply right-to-left so unaffected positions remain valid.
    sorted = edits.sort_by { |e| -e[:start] }
    out = source.dup
    sorted.each do |e|
      out[e[:start], e[:len]] = e[:replacement]
    end
    out
  end
end
