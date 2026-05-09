# typed: true
# LintFixRewriter — source-level pre-pass for `clear fmt` that applies
# stylistic auto-fixes detectable only via real semantic analysis:
#
#   1. Drop `MUTABLE ` from declarations whose binding is never
#      reassigned. The annotator already emits a `:auto`-confidence
#      lint finding for this; we drain it here and apply the edit.
#
#   2. Drop redundant explicit type annotations like
#      `s: Float64 = 0.0` -> `s = 0.0`, where the right-hand side
#      already determines the same type the user wrote. Walks the AST
#      and compares VarDecl.type against the value's inferred
#      full_type. Only triggers when the declared type is "bare"
#      (no sigils — `?`, `!`, `~`, `@`, `%` — and no array/optional/
#      error-union/capability decoration), because those carry
#      semantic intent that isn't always recoverable from the value
#      alone.
#
# Both rules need the annotator's output, so this module runs the
# annotator once and serves both. If annotation raises (the file has
# a compile error), the rewriter returns the source unchanged — fmt
# must still format files with errors.
#
# Idempotent: a second pass finds nothing left to rewrite.

require 'set'
require_relative '../ast/lexer'
require_relative '../ast/parser'
require_relative '../ast/ast'
require_relative '../ast/fixable_error'
require_relative '../annotator'

module LintFixRewriter
  module_function

  def rewrite(source)
    ast, findings = annotate(source)
    return source unless ast
    bg_names = collect_bg_referenced_names(ast)
    mutation_sensitive_names = collect_mutation_sensitive_names(ast)
    edits = []
    edits.concat(mutable_unused_edits(findings, bg_names, mutation_sensitive_names))
    edits.concat(redundant_type_annotation_edits(ast, source))
    return source if edits.empty?
    apply_edits(source, edits)
  end

  # Walk the AST collecting every Identifier name referenced inside a
  # `BG { ... }` or `BG STREAM { ... }` block. The annotator's
  # MUTABLE-never-reassigned check doesn't propagate "mutably borrowed
  # via a callee" through BG captures, so a binding can be flagged as
  # unused-MUTABLE even when a BG-captured call mutates it via a
  # MUTABLE param. Dropping MUTABLE in that case breaks the next
  # build (the param's mutability check fires at the call site).
  # Skip those names defensively until the annotator is fixed.
  def collect_bg_referenced_names(ast)
    set = Set.new
    walk_for_bg_names(ast, false, set)
    set
  end

  def walk_for_bg_names(node, in_bg, set)
    return if terminal?(node)
    if node.is_a?(Array)
      node.each { |n| walk_for_bg_names(n, in_bg, set) }
      return
    end
    inside = in_bg || node.is_a?(AST::BgBlock) || node.is_a?(AST::BgStreamBlock)
    if inside && node.is_a?(AST::Identifier) && node.respond_to?(:name)
      set << node.name
    end
    return unless node.respond_to?(:each_pair)
    node.each_pair { |_, v| walk_for_bg_names(v, inside, set) }
  end

  def collect_mutation_sensitive_names(ast)
    set = Set.new
    walk_for_mutation_sensitive_names(ast, set)
    set
  end

  def walk_for_mutation_sensitive_names(node, set)
    return if terminal?(node)
    if node.is_a?(Array)
      node.each { |n| walk_for_mutation_sensitive_names(n, set) }
      return
    end

    if node.is_a?(AST::FuncCall) && node.name.end_with?("!")
      node.args.each { |arg| collect_identifier_names(arg, set) }
    elsif node.is_a?(AST::MethodCall) && mutating_method_name?(node.name)
      collect_identifier_names(node.object, set)
    end

    return unless node.respond_to?(:each_pair)
    node.each_pair { |_, v| walk_for_mutation_sensitive_names(v, set) }
  end

  def collect_identifier_names(node, set)
    return if terminal?(node)
    if node.is_a?(Array)
      node.each { |n| collect_identifier_names(n, set) }
      return
    end
    if node.is_a?(AST::Identifier) && node.respond_to?(:name)
      set << node.name
      return
    end
    return unless node.respond_to?(:each_pair)
    node.each_pair { |_, v| collect_identifier_names(v, set) }
  end

  def mutating_method_name?(name)
    %w[
      append clear delete insert pop push remove reserve resize set shift
      swap truncate unshift
    ].include?(name.to_s)
  end

  # Run the annotator with FixCollector enabled. Returns
  # [annotated_ast, findings] on success; [nil, []] if anything
  # raised. Errors are swallowed because fmt must remain robust
  # against files with compile errors.
  def annotate(source)
    FixCollector.enable!
    begin
      tokens = ::Lexer.new(source).tokenize
      ast = ::Parser.new(tokens, source).parse
      annotator = SemanticAnnotator.new
      annotator.source_code = source if annotator.respond_to?(:source_code=)
      annotator.annotate!(ast)
      [ast, FixCollector.drain]
    rescue StandardError, CompilerError, ParserError
      FixCollector.drain  # clear collector even on error
      [nil, []]
    end
  ensure
    FixCollector.disable!
  end

  # ---- Rule 1: MUTABLE never reassigned ----

  def mutable_unused_edits(findings, bg_names, mutation_sensitive_names)
    findings.flat_map do |finding|
      next [] unless mutable_unused_finding?(finding)
      next [] if mentions_name_in_set?(finding, bg_names)
      next [] if mentions_name_in_set?(finding, mutation_sensitive_names)
      finding.fixes
             .select { |fx| fx.confidence == :auto }
             .flat_map(&:edits)
             .map { |e| edit_from_span(e.span, e.replacement) }
    end
  end

  def mutable_unused_finding?(finding)
    finding.respond_to?(:message) &&
      finding.message&.include?("is never reassigned")
  end

  # Pull the binding name out of the finding's message
  # ("MUTABLE 'name' is never reassigned ...") and check it against a
  # set of names where dropping MUTABLE would be unsafe.
  def mentions_name_in_set?(finding, names)
    return false if names.empty?
    msg = finding.respond_to?(:message) ? finding.message.to_s : ""
    m = msg.match(/MUTABLE '([^']+)'/)
    return false unless m
    names.include?(m[1])
  end

  # Translate a Span/Edit (1-based line/col) into a flat byte-offset
  # edit so we can apply both rules through the same machinery.
  def edit_from_span(span, replacement)
    { line: span.line, col: span.col, length: span.length, replacement: replacement.to_s }
  end

  # ---- Rule 2: redundant type annotation ----

  def redundant_type_annotation_edits(ast, source)
    edits = []
    walk_for_redundant_type(ast, source, edits)
    edits
  end

  def walk_for_redundant_type(node, source, edits)
    return if node.nil? || terminal?(node)
    if node.is_a?(Array)
      node.each { |n| walk_for_redundant_type(n, source, edits) }
      return
    end
    if (node.is_a?(AST::VarDecl) || decl_mode_bind_expr?(node)) && node.type
      edit = compute_redundant_type_edit(node, source)
      edits << edit if edit
    end
    return unless node.respond_to?(:each_pair)
    node.each_pair { |_, v| walk_for_redundant_type(v, source, edits) }
  end

  def terminal?(n)
    n.nil? || n.is_a?(Symbol) || n.is_a?(String) || n.is_a?(Integer) ||
      n.is_a?(Float) || n.is_a?(TrueClass) || n.is_a?(FalseClass)
  end

  def decl_mode_bind_expr?(node)
    node.is_a?(AST::BindExpr) && node.respond_to?(:mode) && node.mode == :decl
  end

  # Return an edit that strips the `: Type` annotation, or nil if
  # the annotation should be kept. Conservative: keeps the annotation
  # whenever the declared and inferred types don't match exactly, OR
  # when the declared type carries any decoration (sigil, capability,
  # array, optional, error union, generic instance).
  def compute_redundant_type_edit(node, source)
    declared = node.type
    inferred = node.value && node.value.respond_to?(:full_type) ? node.value.full_type : nil
    return nil unless inferred
    return nil unless types_match_for_drop?(declared, inferred)

    span = locate_type_annotation_span(node, source)
    return nil unless span
    { line: span[:line], col: span[:col], length: span[:length], replacement: '' }
  end

  # True only when dropping `: Type` keeps semantics identical.
  def types_match_for_drop?(declared, inferred)
    decl_t = to_type(declared)
    inf_t  = to_type(inferred)
    return false unless decl_t && inf_t
    # Bail on any decoration — sigils, capabilities, array/optional/
    # error-union/generic — because those convey intent the value
    # alone may not fully express (e.g. `?Int64 = NIL`,
    # `@Counter = ...`, `String[]@list = []`).
    return false if any_decoration?(decl_t)
    return false if any_decoration?(inf_t)
    decl_t.resolved == inf_t.resolved
  end

  def to_type(t)
    return nil if t.nil?
    return t if t.respond_to?(:resolved) && t.respond_to?(:any_sync?)
    Type.new(t) rescue nil
  end

  def any_decoration?(t)
    return true if t.respond_to?(:optional?) && t.optional?
    return true if t.respond_to?(:error_union?) && t.error_union?
    return true if t.respond_to?(:array?) && t.array?
    return true if t.respond_to?(:map?) && t.map?
    return true if t.respond_to?(:future?) && t.future?
    # Use `#sync` directly rather than `any_sync?` — the latter
    # excludes `:raw` and `:symbol` (data-access modes, not locks),
    # but for drop-the-annotation purposes ANY sync stamp changes
    # semantics. `String@raw` uses byte indexing; `String` uses
    # UTF-8 codepoint indexing — same resolved type, different
    # behavior. Keep the annotation either way.
    return true if t.respond_to?(:sync) && t.sync
    return true if t.respond_to?(:ownership) && t.ownership && t.ownership != :affine
    return true if t.respond_to?(:generic_instance?) && t.generic_instance?
    false
  end

  # Locate the `: Type` span on a VarDecl / BindExpr in source.
  # Returns { line:, col:, length: } that, when removed, yields a
  # well-formed declaration the formatter can re-space. Span starts
  # at the `:` and ends just before the `=` (after stripping trailing
  # whitespace), so the surrounding spacing is left to the formatter.
  def locate_type_annotation_span(node, source)
    return nil unless node.token
    name_off = offset_for(source, node.token.line, node.token.column)
    return nil unless name_off
    # token.column points at the var name (or at MUTABLE for mutable
    # decls). We want the `:` immediately after the name. Skip past
    # the name + any whitespace.
    name_start = source.index(node.name, name_off)
    return nil unless name_start
    cursor = name_start + node.name.length
    while cursor < source.length && (source[cursor] == ' ' || source[cursor] == "\t")
      cursor += 1
    end
    return nil unless source[cursor] == ':'
    colon_off = cursor
    # Walk forward to the `=` that ends the type annotation. Respect
    # nesting in case the type contains `[` `(` `{` (generics, fixed
    # arrays). We stop at the FIRST top-level `=` that isn't part of
    # `==` / `=>` etc.
    depth = 0
    i = colon_off + 1
    eq_off = nil
    while i < source.length
      c = source[i]
      if '([{'.include?(c) then depth += 1
      elsif ')]}'.include?(c) then depth -= 1
      elsif c == '=' && depth == 0 && source[i + 1] != '=' && source[i - 1] != '!' &&
            source[i - 1] != '<' && source[i - 1] != '>'
        eq_off = i
        break
      end
      i += 1
    end
    return nil unless eq_off

    # Strip back from `=` over whitespace to find the last char of the
    # type annotation. The span we remove is [colon_off, last_type_char].
    j = eq_off - 1
    j -= 1 while j > colon_off && (source[j] == ' ' || source[j] == "\t")
    return nil if j < colon_off

    # Translate to (line, col, length). All edits go through the same
    # 1-based-line/col model the FixableFinding edits use.
    line, col = line_col_for_offset(source, colon_off)
    length = j - colon_off + 1
    { line: line, col: col, length: length }
  end

  # ---- Edit application ----

  # Apply edits to source. Multiple edits per line are sorted right-
  # to-left so earlier ones don't shift later positions.
  def apply_edits(source, edits)
    grouped = edits.group_by { |e| e[:line] }
    lines = source.split("\n", -1)
    grouped.each do |ln_idx, ln_edits|
      idx = ln_idx - 1
      next if idx < 0 || idx >= lines.length
      ln = lines[idx]
      ln_edits.sort_by { |e| -e[:col] }.each do |e|
        start_col = e[:col] - 1
        next if start_col < 0 || start_col > ln.length
        end_col = start_col + e[:length]
        end_col = ln.length if end_col > ln.length
        ln = ln[0...start_col] + e[:replacement].to_s + ln[end_col..]
      end
      lines[idx] = ln
    end
    lines.join("\n")
  end

  # ---- Source-offset helpers ----

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

  def line_col_for_offset(source, off)
    line = 1
    col = 1
    i = 0
    while i < off
      if source[i] == "\n"
        line += 1
        col = 1
      else
        col += 1
      end
      i += 1
    end
    [line, col]
  end
end
