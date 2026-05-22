# typed: true
# Hoist -- lift anonymous allocating expressions into temp bindings.
#
# Runs after annotation, before escape analysis. An allocating expression
# that is not already the value of a declaration has no SymbolEntry --
# so escape analysis cannot record a definitive decision for it on
# symbol.storage, and would be forced into a renegade node.storage
# write. This pass rewrites such an expression into
#   __hoist_N = <expr>
# a real declaration with a SymbolEntry attached, so every allocating
# thing escape analysis sees is a symbol-bearing binding.
#
# v1 scope: string-concat expressions sitting inside element-store call
# arguments (append / insert / push / put) -- the exact surface
# escape_graph's promote_frame_concats! used to stamp via node.storage.
# The pass grows to cover the remaining anonymous allocating shapes.
require "sorbet-runtime"

module Hoist
  extend T::Sig
  module_function

  ELEMENT_STORE = T.let(%w[append insert push put].freeze, T::Array[String])

  sig { params(ast: T.untyped).void }
  def apply!(ast)
    ctr = T.let([0], T::Array[Integer])
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      hoist_body!(stmt.body, ctr)
    end
  end

  # Walk a statement list. For each statement, lift the hoistable
  # sub-expressions into temp decls inserted immediately before it.
  sig { params(body: T.untyped, ctr: T::Array[Integer]).void }
  def hoist_body!(body, ctr)
    return unless body.is_a?(Array)
    i = 0
    while i < body.length
      stmt = body[i]
      hoists = T.let([], T::Array[T.untyped])
      collect_stmt_hoists!(stmt, hoists, ctr)
      hoists.each_with_index { |decl, j| body.insert(i + j, decl) }
      i += hoists.length
      # Recurse into nested statement bodies (control flow). Nested
      # functions / lambdas / BG blocks are separate frames -- each is
      # reached as its own AST::FunctionDef or handled separately.
      child_bodies(stmt).each { |b| hoist_body!(b, ctr) }
      i += 1
    end
  end

  sig { params(stmt: T.untyped).returns(T::Array[T.untyped]) }
  def child_bodies(stmt)
    case stmt
    when AST::ForRange, AST::ForEach           then [stmt.body]
    when AST::WhileLoop, AST::WhileBindLoop    then [stmt.do_branch]
    when AST::IfStatement                     then [stmt.then_branch, stmt.else_branch].compact
    when AST::MatchStatement                  then stmt.cases.map(&:body) + [stmt.default_case].compact
    when AST::WithBlock                       then [stmt.body]
    when AST::DoBlock                         then stmt.branches.map { |b| b[:body] }.compact
    else []
    end
  end

  # Find element-store method calls in this statement's expression tree
  # and hoist the string concats inside their arguments. Restricted to
  # composite-element stores -- the exact surface escape_graph's
  # promote_heapmut_concats! / promote_frame_concats! used to stamp.
  sig { params(stmt: T.untyped, hoists: T::Array[T.untyped], ctr: T::Array[Integer]).void }
  def collect_stmt_hoists!(stmt, hoists, ctr)
    each_method_call(stmt) do |call|
      next unless ELEMENT_STORE.include?(call.name.to_s)
      next unless composite_element_store?(call)
      (call.args || []).each_with_index do |arg, idx|
        if concat?(arg)
          call.args[idx] = make_temp!(arg, hoists, ctr)
        else
          hoist_concats_within!(arg, hoists, ctr)
        end
      end
    end
  end

  # Yield every MethodCall reachable inside one statement's OWN
  # expressions. Must NOT descend into nested statement bodies (loop /
  # branch bodies) -- those are separate statements hoisted by
  # hoist_body!'s own recursion; hoisting a call found there would
  # insert the temp into the wrong scope.
  sig { params(node: T.untyped, blk: T.proc.params(arg0: T.untyped).void).void }
  def each_method_call(node, &blk)
    return if node.nil? || node.is_a?(Array)
    return unless node.is_a?(Struct)
    # Separate frames -- their bodies are walked independently.
    return if node.is_a?(AST::FunctionDef) || node.is_a?(AST::LambdaLit) ||
              node.is_a?(AST::BgBlock) || node.is_a?(AST::WithBlock) ||
              node.is_a?(AST::DoBlock)
    blk.call(node) if node.is_a?(AST::MethodCall)
    # A body-bearing control-flow node: walk only its condition/subject
    # expressions, never its statement bodies.
    children = non_body_exprs(node) || node.to_a
    children.each do |child|
      case child
      when Array then child.each { |c| each_method_call(c, &blk) }
      when Hash  then child.each_value { |v| each_method_call(v, &blk) }
      else each_method_call(child, &blk)
      end
    end
  end

  # For a body-bearing control-flow node, the expression members that
  # are NOT statement bodies. nil for a plain node (recurse normally).
  sig { params(node: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def non_body_exprs(node)
    case node
    when AST::IfStatement                  then [node.condition]
    when AST::ForRange                     then [node.start_expr, node.end_expr]
    when AST::ForEach                      then [node.collection]
    when AST::WhileLoop, AST::WhileBindLoop then [node.condition]
    when AST::MatchStatement               then [node.expr]
    end
  end

  # Replace every string concat directly held by `node` (struct/union
  # field value, list element) with a hoisted temp; recurse otherwise.
  sig { params(node: T.untyped, hoists: T::Array[T.untyped], ctr: T::Array[Integer]).void }
  def hoist_concats_within!(node, hoists, ctr)
    case node
    when AST::StructLit, AST::UnionVariantLit
      node.fields.each_key do |k|
        v = node.fields[k]
        if concat?(v)
          node.fields[k] = make_temp!(v, hoists, ctr)
        else
          hoist_concats_within!(v, hoists, ctr)
        end
      end
    when AST::ListLit
      node.items.each_index do |idx|
        v = node.items[idx]
        if concat?(v)
          node.items[idx] = make_temp!(v, hoists, ctr)
        else
          hoist_concats_within!(v, hoists, ctr)
        end
      end
    end
  end

  # Mirrors escape_graph's promote_heapmut_concats! gate: the receiver is
  # a collection whose element type is composite (non-primitive,
  # non-string). Only those stores went through promote_frame_concats!.
  sig { params(call: T.untyped).returns(T::Boolean) }
  def composite_element_store?(call)
    obj = call.object
    sym = (obj.is_a?(AST::Identifier) || obj.is_a?(AST::GetField)) ? obj.symbol : nil
    ti = sym&.type
    return false unless ti.is_a?(Type) && ti.collection?
    et = ti.element_type
    !!(et.is_a?(Type) && !et.primitive? && !et.string?)
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def concat?(node)
    node.is_a?(AST::StringConcat) ||
      (node.is_a?(AST::BinaryOp) && node.op == :ADD && !!node.string_concat)
  end

  # Build `__hoist_N = <concat>` with a real SymbolEntry, append the decl
  # to `hoists`, and return the Identifier that replaces the concat.
  sig { params(concat: T.untyped, hoists: T::Array[T.untyped], ctr: T::Array[Integer]).returns(T.untyped) }
  def make_temp!(concat, hoists, ctr)
    n = T.must(ctr[0]) + 1
    ctr[0] = n
    name = "__hoist_#{n}"
    tok = concat.respond_to?(:token) ? concat.token : nil
    ti = concat.full_type
    storage = (concat.respond_to?(:storage) && concat.storage) || :frame

    decl = AST::VarDecl.new(tok, name, nil, concat, false)
    decl.full_type = ti
    # decl.storage (a node field) is left as annotation's default; escape
    # analysis records the definitive placement on sym.storage below.
    sym = SymbolEntry.new(reg: decl, type: ti, mutable: false, storage: storage)
    decl.symbol = sym
    hoists << decl

    ident = AST::Identifier.new(tok, name)
    ident.full_type = ti
    ident.symbol = sym
    # The temp replaces a sub-expression in an ownership-consuming
    # position (element-store arg / struct field of one). Stamp the
    # move so ownership dataflow transfers the temp into the container
    # instead of cleaning it up at scope exit.
    ident.was_moved = true if ident.respond_to?(:was_moved=)
    ident
  end
end
