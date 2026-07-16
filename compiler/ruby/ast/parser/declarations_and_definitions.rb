# typed: strict

class ClearParser
  extend T::Sig

  private

  sig { returns(T::Array[AST::Capture]) }
  def parse_argument_specs
    parse_comma_seq(:CHAR, '(', ')') do
      takes = match!(:KEYWORD, 'TAKES')
      is_mutable = match!(:KEYWORD, 'MUTABLE')

      # comptime: T — compile-time type parameter (EXTERN FN only)
      is_comptime = false
      if match?(:VAR_ID) && current.value == "comptime"
        # Peek ahead: if next is ':', it's a comptime param
        if peek_at(1)&.type == :CHAR && peek_at(1)&.value == ":"
          consume(:VAR_ID) # consume 'comptime'
          is_comptime = true
        end
      end

      name_tok = is_comptime ? nil : consume(:VAR_ID)
      p_name = T.let(nil, T.nilable(String))
      p_name = name_tok.text! if name_tok
      p_type = T.let(nil, T.nilable(ArgumentType))
      default_val = nil

      if is_comptime
        consume(:CHAR, ':')
        p_type = consume(:TYPE_ID).text!.to_sym  # The type param name (T)
        p_name = "comptime"
      else
        if match!(:CHAR, ':')
          p_type = parse_type_annotation
          default_val = parse_expression if match!(:CHAR, '=')
        elsif match!(:CHAR, '=')
          # Compatibility with the original spelling, `name=default: Type`.
          # New code should use `name: Type = default`.
          default_val = parse_expression
          p_type = parse_type_annotation if match!(:CHAR, ':')
        elsif @gradual
          # Gradual mode: omitted annotation becomes implicit Auto.
          # The inference pass resolves these from call-site arg types.
          p_type = Type.new(:Auto, auto: true)
        end
      end

      AST::Capture.new(name: p_name, type: p_type, default: default_val,
                       mutable: is_mutable, takes: takes,
                       comptime: is_comptime, name_token: name_tok)
    end
     .last # always ignore the first token
  end

  sig { returns(T::Array[AST::Param]) }
  def parse_argument_list
    parse_argument_specs.map do |spec|
      AST::Param.new(name: spec.name, type: spec.type, default: spec.default,
                     mutable: spec.mutable, takes: spec.takes,
                     comptime: spec.comptime, name_token: spec.name_token)
    end
  end

  sig { returns(T::Array[AST::Capture]) }
  def parse_capture_list
    parse_argument_specs
  end

  # `MUTABLE name: T = expr;` (with initializer)
  # `MUTABLE name: T[N];`     (bare, fixed-size primitive array, zero-default)
  #
  # The bare form requires an explicit fixed-size array type whose element
  # type has a known zero literal (Int64/Float64/String/Bool family). It keeps
  # the default as one compact node; materializing N literal children here makes
  # large fixed arrays explode before annotation or MIR lowering can optimize it.
  sig { returns(T.any(AST::VarDecl, AST::DestructuringAssignment)) }
  def parse_mutable_var_decl
    start_token = consume(:KEYWORD, 'MUTABLE')
    if destructuring_assignment?
      return parse_destructuring_assign(default_mutable: true)
    end

    name = consume(:VAR_ID).text!
    type_annotation = T.let(nil, T.nilable(Type))
    if match!(:CHAR, ':')
      type_annotation = parse_type_annotation
    end

    if match!(:CHAR, '=')
      value = parse_expression
      consume(:CHAR, ';')
      return AST::VarDecl.new(start_token, name, type_annotation, value, true)
    end

    consume(:CHAR, ';')
    if type_annotation
      value = synthesize_default_for_type(start_token, type_annotation)
      return AST::VarDecl.new(start_token, name, type_annotation, value, true)
    end
    error!(start_token, :MUTABLE_BARE_NEEDS_TYPE)
  end

  # Build a compact default-initialized AST value for a `T[N]` annotation.
  # Used by `parse_mutable_var_decl` when no `= expr` was given. Restricted to
  # fixed-size raw arrays of element types with an obvious zero (primitives
  # and String); other types must be initialized explicitly.
  sig { params(tok: Lexer::Token, type: Type).returns(AST::DefaultArrayLit) }
  def synthesize_default_for_type(tok, type)
    unless type.fixed?
      error!(tok, :MUTABLE_BARE_NEEDS_FIXED, type: type.resolved)
    end
    elem = type.element_type
    elem = T.must(elem)
    elem_resolved = elem.resolved
    unless %i[Int64 Int32 Int16 Int8 Float64 Float32 String Bool Boolean].include?(elem_resolved)
      error!(tok, :MUTABLE_BARE_BAD_ELEMENT, type: elem_resolved.inspect)
    end
    AST::DefaultArrayLit.new(tok, Type.new(type), :stack)
  end

  sig { returns(AST::RequireNode) }
  def parse_require
    tok = consume(:KEYWORD, 'REQUIRE')
    raw = consume(:STRING).text!
    namespace = T.let("", String)
    kind = T.let(:local, Symbol)

    if raw.start_with?("pkg:")
      # Package import: REQUIRE "pkg:math"  →  kind=:package, path="math"
      pkg_name  = raw.sub(/\Apkg:/, '')
      path      = pkg_name
      namespace = pkg_name.gsub(/[^a-zA-Z0-9_]/, '_').sub(/\A(\d)/, '_\1')
      kind      = :package
    else
      # Local file import: REQUIRE "file.clear"
      path      = raw
      namespace = File.basename(path, '.clear')
                      .gsub(/[^a-zA-Z0-9_]/, '_')
                      .sub(/\A(\d)/, '_\1')
      kind      = :local
    end

    if match!(:KEYWORD, 'AS')
      namespace = consume(:VAR_ID).text!
    end
    match!(:CHAR, ';')
    AST::RequireNode.new(tok, path, namespace, kind)
  end

  sig { params(visibility: Symbol).returns(AST::Node) }
  def parse_visibility_decl(visibility)
    consume(:KEYWORD)  # consume PUB or PRIVATE
    if match?(:KEYWORD, 'FN')
      parse_function_def(visibility)
    elsif match?(:KEYWORD, 'METHOD')
      parse_function_def(visibility, is_method: true)
    elsif match?(:KEYWORD, 'STRUCT')
      parse_struct_def(visibility)
    elsif match?(:KEYWORD, 'PROTOCOL')
      parse_protocol_def(visibility)
    elsif match?(:KEYWORD, 'ENUM')
      parse_enum_def(visibility)
    elsif match?(:KEYWORD, 'UNION')
      parse_union_def(visibility)
    else
      error!(current, :VISIBILITY_BAD_KIND, got: current.value)
    end
  end

  # EXTERN FN name(params) RETURNS type FROM "module_name";
  # EXTERN STRUCT Name { fields } FROM "module_name";
  sig { returns(T.any(AST::ExternFnDecl, AST::ExternStructDecl)) }
  def parse_extern_decl
    tok = consume(:KEYWORD, 'EXTERN')
    if match?(:KEYWORD, 'FN')
      parse_extern_fn(tok)
    elsif match?(:KEYWORD, 'STRUCT')
      parse_extern_struct(tok)
    else
      error!(current, :EXTERN_BAD_KIND, got: current.value)
    end
  end

  sig { params(extern_tok: Lexer::Token).returns(AST::ExternFnDecl) }
  def parse_extern_fn(extern_tok)
    consume(:KEYWORD, 'FN')

    # Parse name: either "fnName", "fnName<T>", or "TypeName<T>.methodName"
    owner_type = T.let(nil, T.nilable(String))
    owner_type_params = T.let([], T::Array[Symbol])
    fn_type_params = T.let([], T::Array[Symbol])
    name = T.let("", String)

    if match?(:TYPE_ID)
      # Could be TypeName<T>.method or just a TYPE_ID-named function
      type_name = consume(:TYPE_ID).text!
      owner_type_params = parse_generic_type_param_symbols
      if match!(:CHAR, '.')
        # It's a method: TypeName<T>.methodName
        owner_type = type_name
        name = consume(:VAR_ID).text!
      else
        # TYPE_ID without dot — treat as function name (unusual but valid)
        name = type_name
        fn_type_params = owner_type_params
        owner_type_params = []
      end
    else
      name = consume(:VAR_ID).text!
      # Optional generic type params on the function: fnName<T>
      fn_type_params = parse_generic_type_param_symbols
    end

    params = parse_argument_list
    explicit_return = match!(:KEYWORD, 'RETURNS')
    return_type = explicit_return ? parse_type_annotation : nil

    # Optional: EFFECTS :alloc:frame, :alloc:heap, :safe — declare side effects.
    # :alloc:frame → inject rt.frameAlloc() for Alloc-typed parameters
    # :alloc:heap  → inject rt.heapAlloc() for Alloc-typed parameters
    # :alloc       → shorthand for :alloc:frame
    # :safe        → run directly on fiber stack (skip onRootStack trampoline).
    #                Use for pure compute FFI (SHA256, math, JSON parsing).
    #                Do NOT use for filesystem I/O or deep-stack functions.
    effects = parse_extern_effects

    native_name = T.let(name, String)
    if match!(:KEYWORD, 'AS')
      native_name = consume(:STRING).text!
    end

    consume(:KEYWORD, 'FROM')
    from_module = consume(:STRING).text!
    source = parse_extern_source(from_module, native_name)
    match!(:CHAR, ';')
    AST::ExternFnDecl.new(extern_tok, name, params, return_type, from_module, effects.to_h,
                          owner_type, owner_type_params, fn_type_params, source)
  end

  sig { returns(ParsedExternEffects) }
  def parse_extern_effects
    effects = ParsedExternEffects.new
    return effects unless match!(:KEYWORD, 'EFFECTS')

    loop do
      consume(:CHAR, ':')
      effect_token = consume(:VAR_ID)
      effect = effect_token.text!.to_sym
      unless [:alloc, :safe].include?(effect)
        emit_typo_suggestion!(
          effect_token, effect_token.text!, %w[alloc safe],
          "Unknown effect ':#{effect}'",
          "closest effect",
          category: :type, cascade: true
        )
      end

      if effect == :safe
        effects.safe = true
      elsif effect == :alloc && match?(:CHAR, ':')
        consume(:CHAR, ':')
        qualifier_token = consume(:VAR_ID)
        qualifier = qualifier_token.text!.to_sym
        unless [:frame, :heap].include?(qualifier)
          emit_typo_suggestion!(
            qualifier_token, qualifier_token.text!, %w[frame heap],
            "Unknown alloc qualifier ':#{qualifier}'",
            "closest alloc qualifier",
            category: :type, cascade: true
          )
        end
        effects.alloc = qualifier
      else
        effects.alloc = :frame
      end
      break unless match!(:CHAR, ',')
    end
    effects
  end

  sig { params(extern_tok: Lexer::Token).returns(AST::ExternStructDecl) }
  def parse_extern_struct(extern_tok)
    consume(:KEYWORD, 'STRUCT')
    name = consume(:TYPE_ID).text!

    # Optional generic type params: EXTERN STRUCT Parsed<T> { ... }
    type_params = parse_generic_type_param_symbols

    # Fields can be empty: EXTERN STRUCT Opaque {} FROM "mod";
    fields = parse_struct_body

    # Optional: CLOSE "method" — register cleanup method for RAII
    close_method = T.let(nil, T.nilable(String))
    if match!(:KEYWORD, 'CLOSE')
      close_method = consume(:STRING).text!
    end

    # Optional: AS "ZigTypeExpr" — alias to parameterized Zig type (e.g. Parsed(JsonRecord))
    as_type = T.let(nil, T.nilable(String))
    if match!(:KEYWORD, 'AS')
      as_type = consume(:STRING).text!
    end

    from_module = T.let(nil, T.nilable(String))
    if match!(:KEYWORD, 'FROM')
      from_module = consume(:STRING).text!
    end
    source = parse_extern_source(from_module || "", as_type || name)
    match!(:CHAR, ';')
    AST::ExternStructDecl.new(extern_tok, name, fields, from_module,
                              type_params, close_method, as_type, source)
  end

  sig { params(dependency: String, native_name: String).returns(Schemas::ExternSource) }
  def parse_extern_source(dependency, native_name)
    abi = T.let(:zig, Symbol)
    callconv = T.let(:c, Symbol)
    header = T.let(nil, T.nilable(String))

    if match!(:KEYWORD, 'ABI')
      abi_token = current
      consume(abi_token.type)
      abi = abi_token.text!.downcase.to_sym
      error!(abi_token, :PARSER_EXPECTED, expected: "C or ZIG", got: abi_token.value,
        type: abi_token.type, line: abi_token.line) unless %i[c zig].include?(abi)
    end
    if match!(:KEYWORD, 'CALLCONV')
      callconv_token = current
      consume(callconv_token.type)
      callconv = callconv_token.text!.downcase.to_sym
      error!(callconv_token, :PARSER_EXPECTED, expected: "C, SYSTEM, or WINAPI",
        got: callconv_token.value, type: callconv_token.type,
        line: callconv_token.line) unless %i[c system winapi].include?(callconv)
    end
    if match!(:KEYWORD, 'HEADER')
      header = consume(:STRING).text!
    end

    Schemas::ExternSource.new(
      dependency: dependency,
      abi: abi,
      symbol: native_name,
      callconv: callconv,
      header: header
    )
  end

  sig { params(visibility: Symbol).returns(AST::StructDef) }
  def parse_struct_def(visibility = :package)
    tok = consume(:KEYWORD, 'STRUCT')
    name = consume(:TYPE_ID).text!
    generic_params = parse_generic_type_params
    fields = parse_struct_body
    node = AST::StructDef.new(tok, name, fields, visibility, generic_params.map(&:name))
    node.generic_params = generic_params
    node
  end

  sig { params(visibility: Symbol).returns(AST::ProtocolDef) }
  def parse_protocol_def(visibility = :package)
    token = consume(:KEYWORD, 'PROTOCOL')
    name_token = consume(:TYPE_ID)
    associated_types = parse_generic_type_params
    consume(:CHAR, '{')
    requirements = T.let([], T::Array[AST::ProtocolRequirement])
    until match?(:CHAR, '}')
      requirements << parse_protocol_requirement
    end
    consume(:CHAR, '}')
    AST::ProtocolDef.new(
      token, name_token.text!, name_token, associated_types, requirements, visibility,
    )
  end

  sig { returns(AST::ProtocolRequirement) }
  def parse_protocol_requirement
    token = if match?(:KEYWORD, 'METHOD')
      consume(:KEYWORD, 'METHOD')
    else
      consume(:KEYWORD, 'FN')
    end
    method = token.text! == 'METHOD'
    name_token = consume(:VAR_ID)
    name = name_token.text!
    params = parse_argument_list
    return_type = if match!(:KEYWORD, 'RETURNS')
      parse_type_annotation
    else
      Type.new(:Void)
    end
    effects = parse_effects_decl
    consume(:CHAR, ';')
    AST::ProtocolRequirement.new(
      token: token,
      name: name,
      params: params,
      return_type: return_type,
      is_method: method,
      effects_decl: effects.kind,
      max_depth_n: effects.max_depth,
      tight_reentrance: effects.tight,
    )
  end

  sig { returns(T.any(AST::ImplementationDef, AST::ConformanceDef)) }
  def parse_implementation_def
    conformance = conformance_implementation_header?
    token = consume(:KEYWORD, 'IMPLEMENTATION')
    return parse_conformance_def(token) if conformance

    owner_token = consume(:TYPE_ID)
    binders = parse_generic_type_params
    members = parse_implementation_members
    AST::ImplementationDef.new(token, owner_token.text!, owner_token, binders, members)
  end

  sig { returns(T::Boolean) }
  def conformance_implementation_header?
    index = @pos
    while index < @tokens.length
      token = T.must(@tokens[index])
      return true if token.type == :KEYWORD && token.value == 'FOR'
      return false if token.type == :CHAR && token.value == '{'
      index += 1
    end
    false
  end

  sig { params(token: Lexer::Token).returns(AST::ConformanceDef) }
  def parse_conformance_def(token)
    binders = match?(:CHAR, '<') ? parse_generic_type_params : []
    protocol_type = parse_type_annotation
    consume(:KEYWORD, 'FOR')
    owner_type = parse_type_annotation
    AST::ConformanceDef.new(token, binders, protocol_type, owner_type, parse_implementation_members)
  end

  sig { returns(T::Array[AST::FunctionDef]) }
  def parse_implementation_members
    consume(:CHAR, '{')
    members = T.let([], T::Array[AST::FunctionDef])
    until match?(:CHAR, '}')
      member_start = current
      visibility = T.let(:package, Symbol)
      if match!(:KEYWORD, 'PUB')
        visibility = :pub
      elsif match!(:KEYWORD, 'PRIVATE')
        visibility = :private
      end

      member = if match?(:KEYWORD, 'METHOD')
        parse_function_def(visibility, is_method: true)
      elsif match?(:KEYWORD, 'FN')
        parse_function_def(visibility)
      else
        error!(current, :PARSER_EXPECTED,
          expected: "FN, METHOD, or } in IMPLEMENTATION",
          got: current.value, type: current.type, line: current.line)
      end
      stamp_source_range!(member, member_start, previous)
      members << member
    end
    consume(:CHAR, '}')
    members
  end

  sig { params(visibility: Symbol).returns(AST::EnumDef) }
  def parse_enum_def(visibility = :package)
    tok = consume(:KEYWORD, 'ENUM')
    name = consume(:TYPE_ID).text!
    consume(:CHAR, '{')
    variants = []
    until match?(:CHAR, '}')
      variants << consume(:TYPE_ID).text!
      match!(:CHAR, ',')
    end
    consume(:CHAR, '}')
    AST::EnumDef.new(tok, name, variants, visibility)
  end

  sig { params(visibility: Symbol).returns(AST::UnionDef) }
  def parse_union_def(visibility = :package)
    tok = consume(:KEYWORD, 'UNION')
    name = consume(:TYPE_ID).text!

    # Parse optional generic type parameters: UNION Option<T> { ... }
    generic_params = parse_generic_type_params

    consume(:CHAR, '{')
    variants = {}
    method_reqs = []
    until match?(:CHAR, '}')
      if starts_function_requirement?
        # Method requirement stub: [PUB|PRIVATE] FN name(param: Type, ...) RETURNS Type
        stub_vis = :package
        if match?(:KEYWORD, 'PUB')
          consume(:KEYWORD, 'PUB')
          stub_vis = :pub
        elsif match?(:KEYWORD, 'PRIVATE')
          consume(:KEYWORD, 'PRIVATE')
          stub_vis = :private
        end
        fn_tok = consume(:KEYWORD, 'FN')
        fn_name = consume(:VAR_ID).text!
        _, raw_params = parse_comma_seq(:CHAR, '(', ')') do
          p_name = consume(:VAR_ID).text!
          consume(:CHAR, ':')
          p_type = parse_type_annotation
          AST::UnionMethodParamRequirement.new(name: p_name, type: p_type)
        end
        ret_type = nil
        if match!(:KEYWORD, 'RETURNS')
          ret_type = parse_type_annotation
        end
        # Optional default body: FN name(...) RETURNS T -> body END
        default_body = T.let([], T::Array[AST::Node])
        has_default_body = false
        if match?(:ARROW, '->')
          consume(:ARROW, '->')
          default_body = parse_block_body(['END'])
          has_default_body = true
          consume(:KEYWORD, 'END')
        end
        method_reqs << AST::UnionMethodRequirement.new(
          token: fn_tok,
          name: fn_name,
          params: raw_params,
          return_type: ret_type,
          body: default_body,
          has_default_body: has_default_body,
          visibility: stub_vis,
        )
      else
        var_name = consume(:TYPE_ID).text!
        if match?(:CHAR, '{')
          # Inline struct variant: Circle { radius: Number, color: String }
          field_pairs = T.let([], T::Array[[String, Type::TypeInput]])
          _, field_pairs = parse_comma_seq(:CHAR, '{', '}') do
            fname_tok = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
            fname = fname_tok.text!
            consume(:CHAR, ':')
            ftype = parse_type_annotation
            reject_auto_in_aggregate_field!(ftype, fname, fname_tok, "UNION inline-variant")
            [fname, T.unsafe(ftype)]
          end
          variants[var_name] = Schemas::InlineStructVariant.new(fields: field_pairs.to_h)
        elsif match!(:CHAR, ':')
          # Single-type payload: Data: Number  (or Data: Number @boxed)
          vtype = parse_type_annotation
          reject_auto_in_aggregate_field!(vtype, var_name, nil, "UNION variant payload")
          variants[var_name] = vtype
        else
          # Unit variant: Point
          variants[var_name] = nil
        end
      end
      match!(:CHAR, ',')
    end
    consume(:CHAR, '}')
    methods = T.let(nil, T.nilable(T::Array[AST::UnionMethodRequirement]))
    methods = method_reqs unless method_reqs.empty?
    node = AST::UnionDef.new(tok, name, variants, visibility, generic_params.map(&:name), methods)
    node.generic_params = generic_params
    node
  end

  # Slice the source text spanning [start_tok, end_tok). Used to capture
  # the textual form of an expression we just parsed, so the runtime
  # error path can quote it back to the user (e.g. PRE clauses).
  sig { params(start_tok: Lexer::Token, end_tok: Lexer::Token).returns(String) }
  def source_slice_between(start_tok, end_tok)
    return "" unless @source_code && start_tok && end_tok
    lines = @source_code.lines
    sl, sc = start_tok.line, start_tok.column
    el, ec = end_tok.line, end_tok.column
    return "" if sl < 1 || sl > lines.length
    if sl == el
      T.must(lines[sl - 1])[sc - 1, ec - sc].to_s.strip
    else
      parts = []
      parts << T.must(lines[sl - 1])[sc - 1..]
      ((sl + 1)..(el - 1)).each { |l| parts << lines[l - 1] }
      parts << (T.must(lines[el - 1])[0, ec - 1] || "")
      parts.join.strip
    end
  end

  sig { params(visibility: Symbol, is_method: T::Boolean).returns(AST::FunctionDef) }
  def parse_function_def(visibility = :package, is_method: false)
    fn_token = if is_method
      consume(:KEYWORD, 'METHOD')
    elsif match?(:KEYWORD, 'METHOD')
      is_method = true
      consume(:KEYWORD, 'METHOD')
    else
      consume(:KEYWORD, 'FN')
    end
    name_tok = consume(:VAR_ID)
    name = name_tok.text!
    # Predicate suffix: FN name?(...) — ? is part of the function name
    if match?(:CHAR, '?')
      consume(:CHAR, '?')
      name = "#{name}?"
    end

    # Parse optional generic type parameters: FN name<T, U>(...)
    generic_params = parse_generic_type_params
    type_params = generic_params.map(&:name)

    params = parse_argument_list()

    captures = []
    if match!(:KEYWORD, 'USE')
      captures = parse_capture_list
    end

    # Return lifetime syntax:
    #   - omitted              -- no lifetime constraint on the return
    #   - `foo:T`              -- single-source: returned value's lifetime
    #                              is bound to param `foo`. Stored as a
    #                              one-element Array of Identifier.
    #   - `(foo bar baz):T`    -- multi-source: returned value's lifetime
    #                              is the intersection of every named
    #                              binding's lifetime. Names are space-
    #                              and/or comma-separated inside the parens.
    #                              Stored as a multi-element Array.
    #   - `*:T`                -- wildcard / lazy: every parameter's
    #                              lifetime is conservatively folded into
    #                              the source set. Stored as the symbol
    #                              `:wildcard`; the annotator can replace it
    #                              with an explicit list.
    return_type = T.let(nil, T.nilable(Type))
    return_type_token = T.let(nil, T.nilable(Lexer::Token))
    return_lifetime_token = T.let(nil, T.nilable(Lexer::Token))
    return_lifetime = T.let(nil, ReturnLifetime)
    explicit_return = match?(:KEYWORD, 'RETURNS')  # peek for the post-#335 stamp
    # Gradual mode: when RETURNS is omitted, treat as implicit Auto so
    # the inference pass picks the return type up from RETURN exprs.
    # We mark explicit_return = true so the existing fallible-return
    # enforcement uses the inferred type once resolved. Without
    # `--gradual`, omitted RETURNS keeps its current behavior
    # (implicit-Void / inferred per the legacy path).
    if !explicit_return && @gradual
      return_type = Type.new(:Auto, auto: true)
      explicit_return = true
    end
    if match!(:KEYWORD, 'RETURNS')
      shared_return = match!(:KEYWORD, 'SHARED')

      if match?(:CHAR, '(')
        # Multi-binding form: collect VAR_IDs separated by ',' or
        # whitespace until ')'. The lexer skips whitespace, so a
        # space-separated list parses as a sequence of bare VAR_IDs.
        return_lifetime_token = consume(:CHAR, '(')
        names = T.let([], T::Array[AST::Node])
        while !match?(:CHAR, ')')
          names << parse_var_id
          # Allow optional commas between names; they're sugar.
          match!(:CHAR, ',')
        end
        consume(:CHAR, ')')
        consume(:CHAR, ':')
        return_lifetime = names
      elsif match?(:CHAR, '*')
        return_lifetime_token = consume(:CHAR, '*')
        consume(:CHAR, ':')
        return_lifetime = :wildcard
      elsif current.type == :VAR_ID
        # Backward-compat single-binding form. Wrap in a one-element
        # Array so downstream code uniformly iterates a list.
        return_lifetime_token = current
        names = T.let([parse_var_id], T::Array[AST::Node])
        return_lifetime = names
        consume(:CHAR, ':')
      end

      return_type_token = current
      return_type = parse_type_annotation()
      return_type = mark_polymorphic_shared_type(return_type) if shared_return
    end

    # Gates which sync families this function accepts on its parameters.
    # Mandatory whenever the body uses WITH on a parameter.
    requires_clause = T.let(nil, T.nilable(T::Hash[String, T::Set[Symbol]]))
    early_requires_clauses = T.let({}, T::Hash[String, Symbol])
    if match!(:KEYWORD, 'REQUIRES')
      parsed_requires = parse_requires_clause
      requires_clause = parsed_requires.capabilities
      early_requires_clauses = parsed_requires.reentrance
    end

    # EFFECTS REENTRANT variants:
    #   EFFECTS REENTRANT             -> :reentrant              (real recursion;
    #                                                             caller runs on @service)
    #   EFFECTS REENTRANT:THUNK       -> :reentrant_thunk        (CPS + trampoline)
    #   EFFECTS REENTRANT:TAIL_CALL   -> :reentrant_tail_call    (self-loop, verified)
    #   EFFECTS REENTRANT:NOT_LOGICAL -> :reentrant_not_logical  (runtime StackGuard;
    #                                                             requires `!T` return)
    parsed_effects = parse_effects_decl
    effects_decl = parsed_effects.kind
    effects_span = parsed_effects.span

    # Reentrance constraints bind by parameter name; the annotator validates
    # that each name references a real parameter so the parser stays syntactic.
    requires_clauses = parse_requires_clauses(name)
    # Merge any reentrance kinds caught by the early-position
    # parse_requires_clause into the canonical hash. Duplicates
    # across the two positions still error.
    unless early_requires_clauses.empty?
      early_requires_clauses.each do |k, v|
        if requires_clauses.key?(k)
          error!(fn_token, :DUPLICATE_REQUIRES_CLAUSE, fn: name, name: k)
        end
        requires_clauses[k] = v
      end
    end

    # PRE predicates keep their source slice so runtime failures can quote
    # the condition that failed.
    pre_clauses = []
    while match!(:KEYWORD, 'PRE')
      consume(:CHAR, ':')
      start_tok = current
      expr = parse_expression
      end_tok = current
      src = source_slice_between(start_tok, end_tok)
      pre_clauses << { expr: expr, source: src }
    end

    # DEBUG_POST predicates may reference parameters and the synthetic `result`.
    post_clauses = []
    while match!(:KEYWORD, 'DEBUG_POST')
      consume(:CHAR, ':')
      start_tok = current
      expr = parse_expression
      end_tok = current
      src = source_slice_between(start_tok, end_tok)
      post_clauses << { expr: expr, source: src }
    end

    arrow_token = current
    consume(:ARROW, '->')
    body = parse_block_body(['END', 'CATCH'])

    # Parse CATCH clauses (unified error-system grammar):
    #
    #   CATCH <item> (',' <item>)* [ WITH(<filter> (',' <filter>)*) ]
    #
    # <item>   is a TYPE_ID — disambiguated via ERROR_KINDS into a kind
    #         or a type. Any mix and any count is valid:
    #           CATCH Input, NotFound           — kinds only
    #           CATCH ParseErr, BadJson         — types only
    #           CATCH Input, ParseErr           — mix
    # <filter> is a TYPE_ID (error type name) OR a STRING (message to
    #         match). The annotator validates the types against the
    #         registry; messages are compared as-is at runtime.
    #
    # Match semantics:
    #   Items are ORed. WITH filters (if present) are ORed among
    #   themselves and ANDed against the item-list match. Example:
    #     CATCH Input, ParseErr WITH(BadJson, "bad header")
    #   matches iff (kind is Input OR type is ParseErr) AND
    #               (type is BadJson OR message == "bad header").
    #
    # Clause shape stored on the AST:
    #   { items:        [{ form: :kind|:type, name:, token: }, ...],
    #     filters:      [{ form: :type|:message, value: }, ...],
    #     body:         [...] }
    # Annotator fills in clause[:kinds] / [:types] / [:filter_types] /
    # [:filter_messages] for lowering.
    catch_clauses = T.let([], T::Array[AST::CatchClause])
    default_body = T.let(nil, T.nilable(T::Array[AST::Node]))
    if match?(:KEYWORD, 'CATCH')
      while match?(:KEYWORD, 'CATCH')
        consume(:KEYWORD, 'CATCH')

        items = [parse_catch_item]
        while match!(:CHAR, ',')
          items << parse_catch_item
        end

        filters = []
        if match?(:KEYWORD, 'WITH')
          consume(:KEYWORD, 'WITH')
          consume(:CHAR, '(')
          filters << parse_catch_filter
          while match!(:CHAR, ',')
            filters << parse_catch_filter
          end
          consume(:CHAR, ')')
        end

        clause_body = parse_block_body(['CATCH', 'DEFAULT', 'END'])
        catch_clauses << AST::CatchClause.new(
          items: items,
          filters: filters,
          body: clause_body,
          kinds: [],
          types: [],
          filter_types: [],
          filter_messages: [],
        )
      end
      if match?(:KEYWORD, 'DEFAULT')
        consume(:KEYWORD, 'DEFAULT')
        default_body = parse_block_body(['END'])
      end
    end

    consume(:KEYWORD, 'END')
    max_depth_n = parsed_effects.max_depth
    tight_reentrance = parsed_effects.tight
    stored_requires_clauses = requires_clauses.empty? ? nil : requires_clauses
    stored_pre_clauses = pre_clauses.empty? ? nil : pre_clauses
    stored_post_clauses = post_clauses.empty? ? nil : post_clauses
    node = AST::FunctionDef.new(
      fn_token, name, params, captures, return_type, return_lifetime, body,
      catch_clauses, default_body, visibility, nil, nil, explicit_return, type_params,
      effects_decl == :reentrant_tail_call, requires_clause, arrow_token, name_tok,
      effects_decl, effects_span, max_depth_n, tight_reentrance, stored_requires_clauses,
      return_type_token, stored_pre_clauses, stored_post_clauses, is_method
    )
    node.generic_params = generic_params
    node
  end

  # Parse the REQUIRES clause body (the keyword has already been consumed):
  #
  #   <name-list> ':' <family-disjunction>
  #     [',' <name-list> ':' <family-disjunction>]*
  #
  # Disambiguation: while parsing a name-list (before ':'), every ',NAME'
  # extends the name-list. After ':' and the family disjunction, a ','
  # starts a new group.
  #
  # Returns capability families and reentrance constraints explicitly.
  # Family table for REQUIRES.
  #   - LOCKED: mutex / rwlock (admits @locked, @writeLocked).
  #   - SNAPSHOTTED: retry-style umbrella (admits @versioned, @atomic).
  #   - VERSIONED / ATOMIC: escape hatches that forbid the other.
  #   - LOCAL: non-sync umbrella (admits @local, @multiowned, plain T).
  #     A WITH POLYMORPHIC body on a LOCAL-typed param lowers to direct
  #     field access -- no lock, no Arc unwrap, no snapshot. Lets a
  #     single transaction fn accept every supported binding kind.
  REQUIRES_VALID_FAMILIES = T.let(%w[LOCKED SNAPSHOTTED VERSIONED ATOMIC LOCAL ACTOR LOCK_FREE].to_set.freeze, T::Set[String])
  # Reentrancy constraints share the REQUIRES grammar slot, but are routed
  # into `requires_clauses` so they don't pollute the capability-family hash.
  REQUIRES_REENTRANCE_KINDS = T.let(%w[NON_REENTRANT].to_set.freeze, T::Set[String])

  sig { returns(ParsedRequiresClause) }
  def parse_requires_clause
    requires_hash = T.let({}, T::Hash[String, T::Set[Symbol]])
    requires_reentrance = T.let({}, T::Hash[String, Symbol])

    loop do
      names = T.let([consume(:VAR_ID).text!], T::Array[String])
      while match!(:CHAR, ',')
        names << consume(:VAR_ID).text!
      end
      consume(:CHAR, ':')

      families = T.let(Set.new, T::Set[Symbol])
      reentrance_kinds = T.let([], T::Array[Symbol])
      first = parse_requires_family_or_reentrance
      family = first.family
      reentrance = first.reentrance
      families << family if family
      reentrance_kinds << reentrance if reentrance
      while match!(:CHAR, '|')
        nxt = parse_requires_family_or_reentrance
        family = nxt.family
        reentrance = nxt.reentrance
        families << family if family
        reentrance_kinds << reentrance if reentrance
      end

      names.each do |n|
        requires_hash[n] = families if !families.empty?
        reentrance_kinds.each { |k| requires_reentrance[n] = k }
      end

      break unless match!(:CHAR, ',')
    end

    ParsedRequiresClause.new(capabilities: requires_hash, reentrance: requires_reentrance)
  end

  # Returns { family: Symbol } or { reentrance: Symbol } based on the
  # token. Family kinds go into the capability `requires` hash; reentrance
  # kinds are forwarded into `requires_clauses`.
  sig { returns(RequiresKind) }
  def parse_requires_family_or_reentrance
    tok = consume(:TYPE_ID)
    token_value = tok.text!
    result = if REQUIRES_VALID_FAMILIES.include?(token_value)
      RequiresKind.new(family: token_value.to_sym)
    elsif REQUIRES_REENTRANCE_KINDS.include?(token_value)
      RequiresKind.new(reentrance: :non_reentrant)
    else
      candidates = REQUIRES_VALID_FAMILIES.to_a + REQUIRES_REENTRANCE_KINDS.to_a
      emit_typo_suggestion!(
        tok, token_value, candidates,
        "Unknown REQUIRES family '#{token_value}' (valid: #{REQUIRES_VALID_FAMILIES.to_a.join(', ')}; kinds: #{REQUIRES_REENTRANCE_KINDS.to_a.join(', ')})",
        "closest REQUIRES family/kind",
        category: :type, cascade: true
      )
    end
    T.must(result)
  end

  # Legacy thin wrapper: callers that only need families.
  sig { returns(Symbol) }
  def parse_requires_family
    res = parse_requires_family_or_reentrance
    family = res.family
    error!(current, :EXPECTED_CAP_FAMILY) unless family
    family
  end

  # Legacy reentrance REQUIRES clauses can appear between the function header
  # and `->`. They coexist with capability-family REQUIRES until the grammar
  # is unified.
  #
  #   REQUIRES f: NON_REENTRANT REQUIRES g: NON_REENTRANT ->
  sig { params(fn_name: String).returns(T::Hash[String, Symbol]) }
  def parse_requires_clauses(fn_name)
    out = T.let({}, T::Hash[String, Symbol])
    while match?(:KEYWORD, 'REQUIRES')
      consume(:KEYWORD, 'REQUIRES')
      name_tok = consume(:VAR_ID)
      name = name_tok.text!
      consume(:CHAR, ':')
      kind_tok = consume(:TYPE_ID)
      kind_value = kind_tok.text!
      unless kind_value == 'NON_REENTRANT'
        emit_typo_suggestion!(
          kind_tok, kind_value, %w[NON_REENTRANT],
          "Unknown REQUIRES kind '#{kind_value}'",
          "closest REQUIRES kind",
          category: :type, cascade: true
        )
      end
      kind = :non_reentrant
      if out.key?(name)
        error!(name_tok, :DUPLICATE_REQUIRES_CLAUSE, fn: fn_name, name: name)
      end
      out[name] = kind
    end
    out
  end

  # REENTRANT, THUNK, and TAIL_CALL parse as TYPE_IDs matched by value because
  # the only context they appear in is right after EFFECTS.
  sig { returns(ParsedEffectsDecl) }
  def parse_effects_decl
    return ParsedEffectsDecl.new unless match?(:KEYWORD, 'EFFECTS')
    eff_kw = consume(:KEYWORD, 'EFFECTS')
    eff_tok = consume(:TYPE_ID)
    effect_value = eff_tok.text!
    unless effect_value == 'REENTRANT'
      emit_typo_suggestion!(
        eff_tok, effect_value, %w[REENTRANT],
        "Unknown function effect '#{effect_value}'",
        "closest function effect",
        category: :type, cascade: true
      )
    end
    span_start = eff_kw
    span_end_tok = eff_tok # tail of `EFFECTS REENTRANT` so far
    unless match!(:CHAR, ':')
      span = AST::EffectSpan.new(start_token: span_start, end_token: span_end_tok)
      return ParsedEffectsDecl.new(kind: :reentrant, span: span)
    end

    # Optional `:TIGHT` modifier (mirrors `TIGHT WHILE`). Order:
    # `REENTRANT:TIGHT:VARIANT`. Valid before THUNK / TAIL_CALL only;
    # MAX_DEPTH implies TIGHT (so :TIGHT:MAX_DEPTH is redundant and
    # rejected); NOT_LOGICAL has depth=1 so TIGHT is meaningless and
    # rejected too.
    tight = false
    tight_tok = nil
    if match?(:KEYWORD, 'TIGHT')
      tight_tok = consume(:KEYWORD, 'TIGHT')
      tight = true
      span_end_tok = tight_tok
      # `:TIGHT` alone (no following variant) is allowed -- means "plain
      # :reentrant but skip the entry yield-check".
      if match!(:CHAR, ':')
        # fall through to variant parsing below
      else
        span = AST::EffectSpan.new(start_token: span_start, end_token: span_end_tok)
        return ParsedEffectsDecl.new(kind: :reentrant, span: span, tight: true)
      end
    end

    variant_tok = consume(:TYPE_ID)
    variant_value = variant_tok.text!
    kind = T.let(:reentrant, Symbol)
    if variant_value == 'THUNK'
      kind = :reentrant_thunk
    elsif variant_value == 'TAIL_CALL'
      kind = :reentrant_tail_call
    elsif variant_value == 'NOT_LOGICAL'
      kind = :reentrant_not_logical
    elsif variant_value == 'MAX_DEPTH'
      kind = :reentrant_max_depth
    else
      emit_typo_suggestion!(
        variant_tok, variant_value, %w[THUNK TAIL_CALL NOT_LOGICAL MAX_DEPTH],
        "Unknown REENTRANT variant '#{variant_value}'",
        "closest REENTRANT variant",
        category: :type, cascade: true
      )
    end
    if tight && (kind == :reentrant_not_logical || kind == :reentrant_max_depth)
      label = kind == :reentrant_not_logical ? "NOT_LOGICAL" : "MAX_DEPTH"
      explanation = label == 'MAX_DEPTH' ?
        'MAX_DEPTH(N) implies TIGHT (the bounded depth replaces the yield-check); just write :MAX_DEPTH(N).' :
        'NOT_LOGICAL has depth=1 by runtime assertion, so TIGHT is meaningless.'
      error!(variant_tok, :INVALID_TIGHT_VARIANT, label: label, explanation: explanation)
    end
    span_end_tok = variant_tok
    max_depth_n = T.let(nil, T.nilable(Integer))
    if kind == :reentrant_max_depth
      consume(:CHAR, '(')
      n_tok = current
      n_lit = consume_number
      max_depth_n = n_lit.integer!
      if max_depth_n <= 0
        error!(n_tok, :MAX_DEPTH_NONPOSITIVE, got: max_depth_n)
      end
      close_tok = consume(:CHAR, ')')
      span_end_tok = close_tok
    end
    span = AST::EffectSpan.new(start_token: span_start, end_token: span_end_tok)
    ParsedEffectsDecl.new(kind: kind, span: span, max_depth: max_depth_n, tight: tight)
  end

  sig { returns(T::Hash[String, AST::StructField]) }
  def parse_struct_body
    pairs = T.let([], T::Array[[String, AST::StructField]])
    _, pairs = parse_comma_seq(:CHAR, '{', '}') do
      name_tok = consume(:VAR_ID)
      name = name_tok.text!

      # Syntax: name=default: Type  (default before type annotation)
      default_val = nil
      if match!(:CHAR, '=')
        default_val = parse_expression()
      end

      consume(:CHAR, ':')

      # Optional BORROWED modifier: field is a reference, not owned
      borrowed = match!(:KEYWORD, 'BORROWED') ? true : false

      type = parse_type_annotation()

      reject_auto_in_aggregate_field!(type, name, name_tok, "STRUCT")

      [name, AST::StructField.new(type: type, default: default_val, borrowed: borrowed)]
    end
    pairs.to_h
  end

  # Cross-callsite type inference into named aggregates is intentionally not
  # supported; aggregate field types must be concrete.
  sig { params(type: Type, field_name: String, field_tok: T.nilable(Lexer::Token), context_label: String).void }
  def reject_auto_in_aggregate_field!(type, field_name, field_tok, context_label)
    return unless type.auto?
    auto_tok = type.respond_to?(:auto_token) ? type.auto_token : nil
    anchor = auto_tok || field_tok
    error!(anchor, :AUTO_NOT_ALLOWED_IN_FIELD, context: context_label, field: field_name)
  end


  public

  sig do
    type_parameters(:Elem)
      .params(
        type: Symbol,
        open: String,
        close: String,
        blk: T.proc.returns(T.type_parameter(:Elem)),
      )
      .returns([Lexer::Token, T::Array[T.type_parameter(:Elem)]])
  end
  def parse_comma_seq(type, open, close, &blk)
    start_token = consume(type, open)
    items = T.let([], T::Array[T.type_parameter(:Elem)])
    until match?(:CHAR, close)
      items << blk.call
      match!(:CHAR, ',')
    end
    consume(:CHAR, close)
    [start_token, items]
  end

  sig { returns(T::Array[AST::GenericParamDecl]) }
  def parse_generic_type_params
    return [] unless match?(:CHAR, '<')

    _, params = parse_comma_seq(:CHAR, '<', '>') do
      name_token = consume(:TYPE_ID)
      bounds = T.let([], T::Array[AST::GenericBoundDecl])
      if match!(:CHAR, ':')
        loop do
          bound_token = current
          bounds << AST::GenericBoundDecl.new(
            token: bound_token,
            type: parse_type_annotation(migration_root: false),
          )
          break unless match!(:CHAR, '&')
        end
      end
      AST::GenericParamDecl.new(token: name_token, name: name_token.text!, bounds: bounds)
    end
    params
  end

  sig { returns(T::Boolean) }
  def starts_function_requirement?
    return true if match?(:KEYWORD, 'FN')
    return false unless match?(:KEYWORD, 'PUB') || match?(:KEYWORD, 'PRIVATE')

    peek.type == :KEYWORD && peek.value == 'FN'
  end

  sig { returns(T::Array[Symbol]) }
  def parse_generic_type_param_symbols
    return [] unless match?(:CHAR, '<')

    _, names = parse_comma_seq(:CHAR, '<', '>') { consume(:TYPE_ID).text!.to_sym }
    names
  end

  # Deep-clone an AST node for compound assignment desugaring.
  # The target appears on both sides (LHS = target, RHS = target op expr),
  # so each side needs its own node to avoid double-visit issues.
  sig { params(node: AST::Node).returns(AST::Node) }
  def deep_clone_node(node)
    case node
    when AST::Identifier
      AST::Identifier.new(node.token, node.name)
    when AST::GetField
      AST::GetField.new(node.token, deep_clone_node(node.target), node.field)
    when AST::GetIndex
      AST::GetIndex.new(node.token, deep_clone_node(node.target), deep_clone_node(node.index))
    else
      node.dup
    end
  end

  # ── Test Framework Parsing ──────────────────────────────────────

  # TEST <name> DO ... END
  sig { returns(AST::TestBlock) }
  def parse_test_block
    tok = consume(:KEYWORD, 'TEST')
    name = consume(:TYPE_ID).text!  # TestName is a TYPE_ID (capitalized)
    consume(:KEYWORD, 'DO')

    setup = []
    whens = []
    before_each = []
    after_each = []
    before_all = []
    after_all = []
    lets = []

    until match?(:KEYWORD, 'END')
      if match?(:KEYWORD, 'WHEN')
        whens << parse_when_block
      elsif test_hook_match?('BEFORE', 'EACH')
        before_each << parse_test_hook('BEFORE', 'EACH')
      elsif test_hook_match?('AFTER', 'EACH')
        after_each << parse_test_hook('AFTER', 'EACH')
      elsif test_hook_match?('BEFORE', 'ALL')
        before_all << parse_test_hook('BEFORE', 'ALL')
      elsif test_hook_match?('AFTER', 'ALL')
        after_all << parse_test_hook('AFTER', 'ALL')
      elsif match?(:KEYWORD, 'LET')
        lets << parse_let_binding
      else
        setup << parse_statement
      end
    end
    consume(:KEYWORD, 'END')

    block = AST::TestBlock.new(tok, name, setup, whens)
    block.before_each = before_each
    block.after_each = after_each
    block.before_all = before_all
    block.after_all = after_all
    block.lets = lets
    block
  end

  # `LET <name> = <expr>;` — fixture declaration. Same shape as a
  # var binding but stored on the enclosing TEST/WHEN block rather
  # than emitted in setup, so lowering can inject a fresh evaluation
  # at the top of every TEST THAT.
  sig { returns(AST::LetBinding) }
  def parse_let_binding
    tok = consume(:KEYWORD, 'LET')
    name = consume(:VAR_ID).text!
    consume(:CHAR, '=')
    expr = parse_expression
    consume(:CHAR, ';')
    AST::LetBinding.new(tok, name, expr)
  end

  # Match `BEFORE EACH` or `AFTER EACH` as a two-keyword sequence. Used by
  # the test-block / when-block parsers; both share the same hook syntax.
  sig { params(first: String, second: String).returns(T::Boolean) }
  def test_hook_match?(first, second)
    match?(:KEYWORD, first) && @tokens[@pos + 1]&.value == second
  end

  # Parse `BEFORE EACH DO <stmts> END` (or AFTER EACH); returns the body
  # statement array. The kind sequence (BEFORE/AFTER + EACH/ALL) is
  # already validated by test_hook_match? at the call site.
  sig { params(first: String, second: String).returns(AST::RawBody) }
  def parse_test_hook(first, second)
    consume(:KEYWORD, first)
    consume(:KEYWORD, second)
    parse_keyword_block('DO')
  end

  # WHEN "description" [TAGS [tag1, tag2, ...]] DO ... END
  sig { returns(AST::WhenBlock) }
  def parse_when_block
    tok = consume(:KEYWORD, 'WHEN')
    desc = consume(:STRING).text!
    tags = parse_when_tags  # [] if no TAGS clause
    consume(:KEYWORD, 'DO')

    setup = []
    tests = []
    benchmarks = []
    before_each = []
    after_each = []
    before_all = []
    after_all = []
    lets = []

    until match?(:KEYWORD, 'END')
      if match?(:KEYWORD, 'TEST') && @tokens[@pos + 1]&.value == 'THAT'
        tests << parse_test_that
      elsif match?(:KEYWORD, 'PENDING') &&
            @tokens[@pos + 1]&.value == 'TEST' &&
            @tokens[@pos + 2]&.value == 'THAT'
        # PENDING TEST THAT "..." DO ... END  — type-checked but skipped
        # at runtime via `return error.SkipZigTest;` in lowering.
        consume(:KEYWORD, 'PENDING')
        tt = parse_test_that
        tt.pending = true
        tests << tt
      elsif test_hook_match?('BEFORE', 'EACH')
        before_each << parse_test_hook('BEFORE', 'EACH')
      elsif test_hook_match?('AFTER', 'EACH')
        after_each << parse_test_hook('AFTER', 'EACH')
      elsif test_hook_match?('BEFORE', 'ALL')
        before_all << parse_test_hook('BEFORE', 'ALL')
      elsif test_hook_match?('AFTER', 'ALL')
        after_all << parse_test_hook('AFTER', 'ALL')
      elsif match?(:KEYWORD, 'LET')
        lets << parse_let_binding
      elsif match?(:KEYWORD, 'BENCHMARK')
        benchmarks << parse_benchmark_stmt
      elsif match?(:KEYWORD, 'SMASH')
        benchmarks << parse_smash_stmt
      elsif match?(:KEYWORD, 'PROFILE')
        benchmarks << parse_profile_stmt
      elsif match?(:KEYWORD, 'STUB')
        setup << parse_stub
      else
        setup << parse_statement
      end
    end
    consume(:KEYWORD, 'END')

    block = AST::WhenBlock.new(tok, desc, setup, tests, benchmarks)
    block.before_each = before_each
    block.after_each = after_each
    block.before_all = before_all
    block.after_all = after_all
    block.lets = lets
    block.tags = tags
    block
  end

  # `TAGS [tag1, tag2, ...]` — optional bracketed list of bare
  # identifiers that lower to test-name suffixes. Returns [] when the
  # clause is absent. Names are validated to be VAR_IDs (snake_case)
  # so `--tag slow` filtering can match unambiguously; allowing
  # arbitrary strings would invite typo-mismatches that pass silently.
  sig { returns(T::Array[String]) }
  def parse_when_tags
    return [] unless match!(:KEYWORD, 'TAGS')
    consume(:CHAR, '[')
    names = []
    until match?(:CHAR, ']')
      tag_tok = consume(:VAR_ID)
      names << tag_tok.text!
      break unless match!(:CHAR, ',')
    end
    consume(:CHAR, ']')
    names
  end

  # TEST THAT "description" DO ... END
  sig { returns(AST::TestThat) }
  def parse_test_that
    tok = consume(:KEYWORD, 'TEST')
    consume(:KEYWORD, 'THAT')
    desc = consume(:STRING).text!
    body = parse_keyword_block('DO')

    AST::TestThat.new(tok, desc, body)
  end

  # ASSERT_RAISES Kind, expr;  OR  ASSERT_RAISES Kind, ErrorName, expr;
  sig { returns(AST::AssertRaises) }
  def parse_assert_raises
    tok = consume(:KEYWORD, 'ASSERT_RAISES')
    kind = consume(:TYPE_ID).text!  # e.g., Input, System, Transient

    consume(:CHAR, ',')

    # Peek: if next is TYPE_ID followed by comma, it's ASSERT_RAISES Kind, ErrorName, expr
    error_name = nil
    if current.type == :TYPE_ID && @tokens[@pos + 1]&.type == :CHAR && @tokens[@pos + 1]&.value == ','
      error_name = consume(:TYPE_ID).text!
      consume(:CHAR, ',')
    end

    expr = parse_expression
    consume(:CHAR, ';')

    AST::AssertRaises.new(tok, kind, error_name, expr)
  end

  # BENCHMARK expr x<N>;
  sig { returns(AST::BenchmarkStmt) }
  def parse_benchmark_stmt
    tok = consume(:KEYWORD, 'BENCHMARK')
    expr = parse_expression

    # Parse optional iteration count: x1000 or x 1000
    iterations = 1000  # default
    if match?(:VAR_ID) && current.value =~ /^x(\d+)$/
      iterations = $1.to_i
      consume(:VAR_ID)
    end
    consume(:CHAR, ';')

    AST::BenchmarkStmt.new(tok, expr, iterations)
  end

  # SMASH expr;
  sig { returns(AST::SmashStmt) }
  def parse_smash_stmt
    tok = consume(:KEYWORD, 'SMASH')
    expr = parse_expression
    consume(:CHAR, ';')
    AST::SmashStmt.new(tok, expr)
  end

  # PROFILE expr;
  sig { returns(AST::ProfileStmt) }
  def parse_profile_stmt
    tok = consume(:KEYWORD, 'PROFILE')
    expr = parse_expression
    consume(:CHAR, ';')
    AST::ProfileStmt.new(tok, expr)
  end

  # STUB fn RETURNS value;
  # STUB fn CAPTURES var;
  # STUB fn SEQUENCE [values];
  # STUB fn WITH %(params) -> expr;
  sig { returns(AST::StubDecl) }
  def parse_stub
    tok = consume(:KEYWORD, 'STUB')
    fn_name = consume(:VAR_ID).text!

    kind_tok = current
    if match?(:KEYWORD, 'RETURNS')
      consume(:KEYWORD, 'RETURNS')
      value = parse_expression
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :returns, value)
    elsif match?(:KEYWORD, 'CAPTURES')
      consume(:KEYWORD, 'CAPTURES')
      var_name = consume(:VAR_ID).text!
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :captures, var_name)
    elsif match?(:KEYWORD, 'SEQUENCE')
      consume(:KEYWORD, 'SEQUENCE')
      bracket_tok, items = parse_comma_seq(:CHAR, '[', ']') { parse_expression }
      values = AST::ListLit.new(bracket_tok, items, :stack)
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :sequence, values)
    elsif match?(:KEYWORD, 'WITH')
      consume(:KEYWORD, 'WITH')
      lambda_node = parse_expression  # should parse a lambda %(params) -> expr
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :with, lambda_node)
    else
      error!(kind_tok, :STUB_BAD_AFTER, fn: fn_name)
    end
  end

end
