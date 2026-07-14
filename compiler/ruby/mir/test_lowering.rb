# typed: strict
require "sorbet-runtime"
# TestLowering — MIR-side handling of CLEAR's test grammar.
#
# Mixed into MIRLowering. Covers:
#   - lower_test_block            TEST Name DO ... END  →  one MIR::TestDef
#                                 per (WHEN, TEST THAT) tuple, with stubs
#                                 + setup composed in.
#   - lower_assert_raises         ASSERT_RAISES Kind[, ErrorName], expr
#   - lower_stub_decl             STUB fn RETURNS / CAPTURES / SEQUENCE / WITH
#   - lower_benchmark / smash /   placeholder MIR::Comments today; fleshed
#     profile                     out by the benchmark / profile work.
#   - stub_intercept_for          shared helper used at MIR call-site
#                                 lowering (FuncCall + MethodCall) to
#                                 redirect a stubbed call.
#   - stub_local_idents           identifies locals reachable from a
#                                 stubbed call's args so they get an
#                                 explicit MIR::Suppress (otherwise
#                                 Zig flags them as unused).
#
# All methods rely on MIRLowering typed state (runtime name,
# test_state.active_stubs, function_state.current_bindings, function_state.decl_zig_name_map, etc.) and
# call into shared lowering helpers (lower, lower_body, emit_expr).
# This module is purely organizational — zero behavior change from
# the inline definitions it replaces.

module TestLowering
    extend T::Sig

  MirBody = T.type_alias { T::Array[MIR::Emittable] }
  AstIdentifierSearchNode = T.type_alias { T.nilable(T.any(AST::Node, AST::RawBody, Lexer::Token, Symbol, String, Numeric, TrueClass, FalseClass, Type)) }
  TestDefs = T.type_alias { T::Array[MIR::TestDef] }
  LetAstMap = T.type_alias { T::Hash[String, AST::LetBinding] }
  StubInfo = T.type_alias { T::Hash[Symbol, T.any(Symbol, String)] }

  sig { params(node: AST::TestBlock).returns(TestDefs) }
  def lower_test_block(node)
    T.bind(self, MIRLowering) rescue nil
    ctx = TestBlockCtx.new(node, self)
    tests = []
    ctx.emit_all_hooks(node.before_all || [], "__before_all", "", tests)

    (node.whens || []).each do |when_block|
      lower_when_block(when_block, ctx, tests)
    end

    ctx.emit_all_hooks(node.after_all || [], "__after_all", "", tests)
    tests
  end

  # Emits all MIR::TestDef entries for a single WHEN block (its
  # BEFORE ALL hooks, then each TEST THAT, then benchmarks, then
  # AFTER ALL hooks). Mutates test_state.active_stubs around the body so
  # WHEN-local STUBs don't leak to sibling WHENs.
  sig { params(when_block: AST::WhenBlock, ctx: TestLowering::TestBlockCtx, tests: TestDefs).returns(TestDefs) }
  def lower_when_block(when_block, ctx, tests)
    T.bind(self, MIRLowering) rescue nil
    when_desc = when_block.description

    prev_stubs = test_state.active_stubs.dup
    test_state.active_stubs = prev_stubs.dup
    begin
      stubs, non_stub_setup = when_block.setup.partition { |s| s.is_a?(AST::StubDecl) }
      when_setup_mir = lower_body(non_stub_setup)
      # Don't use `Array(lower(s))` here — MIR nodes are Structs and
      # Struct#to_a unpacks fields, so `Array(MIR::Let.new(...))` would
      # explode into [name, value, mutable, ...]. Explicit
      # array-or-wrap check preserves the node identity.
      stub_mir = stubs.flat_map { |s|
        m = lower(s)
        m.is_a?(Array) ? m : [m]
      }.compact

      when_before_each_mir = (when_block.before_each || []).map { |b| lower_body(b) }
      when_after_each_mir  = (when_block.after_each  || []).map { |b| lower_body(b) }

      # Merge TEST- and WHEN-level LET *AST nodes* (not yet lowered).
      # WHEN-level wins on name collision. Lowering happens per-test
      # below, gated on whether each TEST THAT actually references the
      # name — that's the lazy bit (RSpec semantics: tests that don't
      # reference a LET never pay its construction cost).
      let_ast_map = build_let_ast_map(when_block.lets || [], base: build_let_ast_map(ctx.test_block.lets || []))

      ctx.emit_all_hooks(when_block.before_all || [], "__before_all", "#{when_desc}: ", tests)

      tag_suffix = format_tag_suffix(when_block.tags || [])
      env = TestThatEnv.new(
        ctx: ctx,
        when_block: when_block,
        when_desc: when_desc,
        tag_suffix: tag_suffix,
        stub_mir: stub_mir,
        when_setup_mir: when_setup_mir,
        when_before_each_mir: when_before_each_mir,
        when_after_each_mir: when_after_each_mir,
        let_ast_map: let_ast_map,
      )

      (when_block.tests || []).each { |t| tests << lower_test_that(t, env) }

      (when_block.benchmarks || []).each do |b|
        name = "#{ctx.test_name}: #{when_desc}: benchmark#{tag_suffix}"
        body = [ctx.fresh_preamble] + stub_mir + ctx.setup_mir + when_setup_mir + [lower(b)]
        tests << MIR::TestDef.new(name, body)
      end

      ctx.emit_all_hooks(when_block.after_all || [], "__after_all", "#{when_desc}: ", tests)
    ensure
      test_state.active_stubs = prev_stubs
    end
  end

  # Emits the MIR::TestDef for a single TEST THAT — handles the
  # PENDING short-circuit, scopes function_state.current_bindings to the synthetic
  # wrapper so cleanup classification finds locals, composes hooks
  # around the body, and prepends only the LET decls actually
  # referenced by the body or the active hook bodies (lazy).
  sig { params(test_that: AST::TestThat, env: TestLowering::TestThatEnv).returns(MIR::TestDef) }
  def lower_test_that(test_that, env)
    T.bind(self, MIRLowering) rescue nil
    full_name = "#{env.ctx.test_name}: #{env.when_desc}: #{test_that.description}#{env.tag_suffix}"

    if test_that.pending
      return MIR::TestDef.new(full_name, [
        env.ctx.fresh_preamble,
        MIR::ReturnStmt.new(MIR::FieldGet.new(MIR::Ident.new("error"), "SkipZigTest")),
      ])
    end

    # Scope function_state.current_bindings to the synthesized test wrapper so
    # lower_var_decl finds the cleanup entry MIRPass classified for
    # locals declared inside the TEST THAT body.
    body_mir = with_test_that_bindings(test_that) { lower_body(test_that.body) }

    # Hook composition. Execution order:
    #   TEST::BEFORE EACH (outer-to-inner declaration order)
    #     WHEN::BEFORE EACH (outer-to-inner declaration order)
    #       test body
    #     WHEN::AFTER EACH (declared-last runs first via defer)
    #   TEST::AFTER EACH (declared-last runs first via defer)
    #
    # AFTER EACH bodies wrap in MIR::DeferStmt so they fire on
    # early-RETURN or assertion failure too. Zig's defer is LIFO at
    # exit, so we register outer first / inner last; on exit, inner
    # runs first then outer.
    before_mir = env.ctx.test_before_each_mir.flatten + env.when_before_each_mir.flatten
    after_defers = (env.ctx.test_after_each_mir + env.when_after_each_mir)
      .map { |b| MIR::DeferStmt.new(MIR::ScopeBlock.new(b)) }

    # Lazy LET emission: walk this test's body + active hook bodies
    # for references, transitively pull in dependencies, only emit
    # the names actually used.
    used_let_names = compute_used_let_names(
      env.let_ast_map,
      [test_that.body, env.when_block.before_each, env.when_block.after_each,
       env.ctx.test_block.before_each, env.ctx.test_block.after_each].flatten,
    )
    let_decls_mir = used_let_names
      .map { |n| MIR::Let.new(n, lower(env.let_ast_map.fetch(n).expr), false, nil, nil) }

    body = [env.ctx.fresh_preamble] +
           env.stub_mir + env.ctx.setup_mir + env.when_setup_mir +
           let_decls_mir +
           before_mir +
           after_defers +
           body_mir
    MIR::TestDef.new(full_name, body)
  end

  # Scope function_state.current_bindings to the cleanup-classifier's synthetic FN
  # wrapper for the duration of the block. Restored unconditionally.
  sig { params(test_that: AST::TestThat, blk: T.proc.returns(MirBody)).returns(MirBody) }
  def with_test_that_bindings(test_that, &blk)
    T.bind(self, MIRLowering) rescue nil
    prev = function_state.current_bindings
    synth_fn = test_that.respond_to?(:synthetic_fn) ? test_that.synthetic_fn : nil
    function_state.current_bindings = (synth_fn&.cleanup_bindings) || {}
    blk.call
  ensure
    T.bind(self, MIRLowering) rescue nil
    function_state.current_bindings = T.must(prev)
  end

  # Per-TEST-block context object — pre-lowered TEST-level data
  # plus a `fresh_preamble` builder. Cuts the lambda-call boilerplate
  # and gives lower_when_block / lower_test_that a single argument
  # to thread through.
  class TestBlockCtx
      extend T::Sig

    attr_reader :test_block, :test_name, :setup_mir,
                :test_before_each_mir, :test_after_each_mir

    sig { params(test_block: AST::TestBlock, lowering: MIRLowering).void }
    def initialize(test_block, lowering)
      @test_block = T.let(test_block, AST::TestBlock)
      @test_name  = T.let(test_block.name, String)
      @lowering   = lowering
      @setup_mir  = T.let(lowering.lower_body(test_block.setup), TestLowering::MirBody)
      @test_before_each_mir = T.let(
        (test_block.before_each || []).map { |b| lowering.lower_body(b) },
        T::Array[TestLowering::MirBody],
      )
      @test_after_each_mir = T.let(
        (test_block.after_each || []).map { |b| lowering.lower_body(b) },
        T::Array[TestLowering::MirBody],
      )
    end

    # Build the allocator + Runtime + EBR context preamble for one Zig
    # `test` block.
    sig { returns(MIR::TestPreamble) }
    def fresh_preamble
      MIR::TestPreamble.new(nil)
    end

    # Emit the BEFORE/AFTER ALL hooks in `bodies` as standalone Zig
    # tests. `name_kind` is "__before_all" or "__after_all";
    # `desc_prefix` is "" for TEST-level or "#{when_desc}: " for
    # WHEN-level. Each ALL hook gets its own runtime (no shared
    # state with TEST THATs in v1 — file-scope-var promotion is a
    # deferred follow-up).
    sig { params(bodies: T::Array[T::Array[AST::Node]], name_kind: String, desc_prefix: String, tests: TestDefs).returns(TestDefs) }
    def emit_all_hooks(bodies, name_kind, desc_prefix, tests)
      bodies.each_with_index do |body, idx|
        name = "#{@test_name}: #{desc_prefix}#{name_kind}_#{idx + 1}"
        tests << MIR::TestDef.new(name, [fresh_preamble] + @lowering.lower_body(body))
      end
      tests
    end
  end

  # Per-TEST-THAT environment — captures the WHEN-level + TEST-level
  # data lower_test_that needs without a 9-arg method signature.
  TestThatEnv = Struct.new(
    :ctx, :when_block, :when_desc, :tag_suffix,
    :stub_mir, :when_setup_mir,
    :when_before_each_mir, :when_after_each_mir,
    :let_ast_map,
    keyword_init: true,
  )

  # Format a WHEN-block's tags as a `#tag` suffix string for
  # appending to emitted Zig test names. `clear test --tag slow`
  # translates to `zig test --test-filter "#slow"` which uses Zig's
  # built-in substring filter — no custom test runner required.
  # Returns an empty string when there are no tags.
  sig { params(tags: T::Array[String]).returns(String) }
  def format_tag_suffix(tags)
    T.bind(self, MIRLowering) rescue []
    return "" if tags.empty?
    " " + tags.map { |t| "##{t}" }.join(" ")
  end

  # Build an ordered map of LET-binding name → AST::LetBinding for
  # the given list. Optionally seeded with a parent (TEST-level) map
  # so a WHEN-level binding overrides a same-named outer one. Hash
  # insertion order preserves declaration order for the surviving
  # entries: outer LETs occupy their original indices unless replaced
  # by an inner LET, which then takes the outer's slot.
  sig { params(lets: T::Array[AST::LetBinding], base: LetAstMap).returns(LetAstMap) }
  def build_let_ast_map(lets, base: {})
    T.bind(self, MIRLowering) rescue []
    out = base.dup
    lets.each { |let_node| out[let_node.name] = let_node }
    out
  end

  # RSpec-style lazy semantics. Walks the test body + all relevant hook
  # bodies for AST::Identifier references whose name is in the LET map,
  # then transitively pulls in any LETs that the referenced LETs'
  # RHS expressions depend on. Returns the names in source-declaration
  # order so the emitted Zig declarations resolve cleanly
  # (later LETs may reference earlier ones).
  sig { params(let_ast_map: LetAstMap, ast_subtrees: T::Array[AstIdentifierSearchNode]).returns(T::Array[String]) }
  def compute_used_let_names(let_ast_map, ast_subtrees)
    T.bind(self, MIRLowering) rescue nil
    return [] if let_ast_map.empty?

    # Direct references in test body + hook bodies
    referenced = Set.new
    ast_subtrees.each { |t| collect_identifier_refs(t, let_ast_map, referenced) }

    # Transitive: each referenced LET's RHS may name other LETs.
    # Loop until fixed point.
    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      referenced.to_a.each do |name|
        let_binding = let_ast_map[name]
        next unless let_binding
        rhs = let_binding.expr
        before = referenced.size
        collect_identifier_refs(rhs, let_ast_map, referenced)
        changed = true if referenced.size > before
      end
    end

    # Preserve declaration order — let_ast_map's insertion order is
    # source order with WHEN-level overrides slotted at the original
    # outer index.
    let_ast_map.keys.select { |n| referenced.include?(n) }
  end

  # Walk an AST subtree gathering names from AST::Identifier nodes
  # whose name appears in `name_set`. Adds to the `out` set.
  sig { params(node: AstIdentifierSearchNode, name_set: LetAstMap, out: T::Set[String]).void }
  def collect_identifier_refs(node, name_set, out)
    T.bind(self, MIRLowering) rescue nil
    return if node.nil? || AST.scalar_literal_value?(node) || node.is_a?(Lexer::Token)
    if node.is_a?(Array)
      node.each { |n| collect_identifier_refs(n, name_set, out) }
      return
    end
    if node.is_a?(AST::Identifier) && name_set.key?(node.name)
      out << node.name
    end
    T.unsafe(node).each_pair { |_, v| collect_identifier_refs(v, name_set, out) } if node.respond_to?(:each_pair)
  end

  sig { params(node: AST::AssertRaises).returns(MIR::AssertRaisesCheck) }
  def lower_assert_raises(node)
    T.bind(self, MIRLowering) rescue nil
    MIR::AssertRaisesCheck.new(lower(node.expression), runtime_binding_name, node.kind, node.error_name)
  end

  # Build the MIR replacement for a stubbed call site, or nil if `fn_name`
  # is not currently stubbed. Shared between FuncCall (`receiver` is nil)
  # and UFCS MethodCall (`receiver` is the object). Pure MIR composition
  # -- no raw Zig escape hatch -- so the checker can see what's going
  # on. Locals that would otherwise become "unused" after stub
  # replacement get an explicit MIR::Suppress (`_ = &name;`).
  sig { params(fn_name: String, receiver: T.nilable(AST::Node), args: T::Array[AST::Node]).returns(T.nilable(MIR::Node)) }
  def stub_intercept_for(fn_name, receiver, args)
    T.bind(self, MIRLowering) rescue nil
    stub_info = test_state.active_stubs[fn_name]
    return nil unless stub_info

    call_inputs = [receiver, *args].compact
    suppress_names = call_inputs.flat_map { |n| stub_local_idents(n) }.uniq
    suppress_stmts = suppress_names.map { |nm| MIR::Suppress.new(nm) }

    counter = test_state.stub_label_counter + 1
    test_state.stub_label_counter = counter

    case stub_info[:kind]
    when :returns
      return MIR::Ident.new(stub_info[:var]) if suppress_stmts.empty?
      label = "__stub_ret_#{counter}"
      MIR::BlockExpr.new(label, suppress_stmts +
        [MIR::BreakStmt.new(label, MIR::Ident.new(stub_info[:var]))])

    when :captures
      cnt = MIR::Ident.new(stub_info[:var])
      inc = MIR::Set.new(cnt, MIR::BinOp.new("+", cnt, MIR::Lit.new("1")), false)
      # Void block: no label needed because nothing breaks to it.
      MIR::BlockExpr.new(nil, suppress_stmts + [inc])

    when :sequence
      label = "__stub_seq_#{counter}"
      seq = MIR::Ident.new("#{stub_info[:var]}_seq")
      idx = MIR::Ident.new("#{stub_info[:var]}_idx")
      si  = "__stub_si_#{counter}"
      MIR::BlockExpr.new(label, suppress_stmts + [
        MIR::Let.new(si, idx, false, Type.new("usize"), nil),
        MIR::Set.new(idx, MIR::BinOp.new("+", idx, MIR::Lit.new("1")), false),
        MIR::BreakStmt.new(label, MIR::IndexGet.new(seq, MIR::Ident.new(si))),
      ])

    when :with
      # WITH-stub lambdas are emitted with `rt: *Runtime` as their
      # implicit first parameter (same as every other CLEAR fn). The
      # invocation must thread the runtime through and `try` because
      # the lambda's return type is `anyerror!T`.
      args_mir = call_inputs.map { |a| lower(a) }
      MIR::Call.new(stub_info[:var], [MIR::Ident.new(runtime_binding_name)] + args_mir, true)
    end
  end

  # Names of local Identifiers reachable from a call-input AST node that
  # need MIR::Suppress in a stub replacement (otherwise Zig flags them as
  # unused). Only top-level Identifiers count -- nested expressions
  # (FieldGet, FuncCall, literals, ...) are evaluated implicitly. Routes
  # through function_state.decl_zig_name_map / function_state.fn_name_rename_map so suppressed names
  # match the actual Zig var (cleanup-classification may suffix-rename
  # locals as `name_LN` to disambiguate same-name decls in distinct scopes).
  sig { params(node: AST::Node).returns(T::Array[String]) }
  def stub_local_idents(node)
    T.bind(self, MIRLowering) rescue nil
    return [] unless node.is_a?(AST::Identifier)
    name = node.name
    return [] unless name.is_a?(String)
    decl = node.symbol&.reg
    renamed = (decl && function_state.decl_zig_names[decl.object_id]) ||
              function_state.rename_map[name] ||
              name
    [renamed]
  end

  sig { params(node: AST::StubDecl).returns(T.nilable(MIR::NodeRoot)) }
  def lower_stub_decl(node)
    T.bind(self, MIRLowering) rescue nil
    fn_name = node.function_name
    stub_var = "__stub_#{fn_name}"
    case node.kind
    when :returns
      val = lower(node.value)
      test_state.active_stubs[fn_name] = { kind: :returns, var: stub_var }
      MIR::Let.new(stub_var, val, false, nil, nil)
    when :captures
      cap_name = node.value
      test_state.active_stubs[fn_name] = { kind: :captures, var: cap_name }
      MIR::Let.new(cap_name, MIR::Lit.new("0"), true, Type.new("i64"), "_ = &#{cap_name};")
    when :sequence
      values = node.value
      items_mir = if values.respond_to?(:items)
        values.items.map { |v| lower(v) }
      else
        [lower(values)]
      end
      test_state.active_stubs[fn_name] = { kind: :sequence, var: stub_var }
      [
        MIR::Let.new(
          "#{stub_var}_seq",
          MIR::ArrayInit.new("[]const u8", "_", items_mir),
          false, nil, nil
        ),
        MIR::Let.new(
          "#{stub_var}_idx",
          MIR::Lit.new("0"),
          true, Type.new("usize"), "_ = &#{stub_var}_idx;"
        ),
      ]
    when :with
      val = lower(node.value)
      test_state.active_stubs[fn_name] = { kind: :with, var: stub_var }
      MIR::Let.new(stub_var, val, false, nil, nil)
    else
      raise "MIRLowering: unhandled StubDecl kind: #{node.kind} for #{fn_name}"
    end
  end

  sig { params(node: AST::BenchmarkStmt).returns(MIR::Comment) }
  def lower_benchmark(node)
    T.bind(self, MIRLowering) rescue nil
    MIR::Comment.new("benchmark lowering placeholder")
  end

  sig { params(node: AST::SmashStmt).returns(MIR::Comment) }
  def lower_smash(node)
    T.bind(self, MIRLowering) rescue nil
    MIR::Comment.new("smash test placeholder")
  end

  sig { params(node: AST::ProfileStmt).returns(MIR::Comment) }
  def lower_profile(node)
    T.bind(self, MIRLowering) rescue nil
    MIR::Comment.new("profile placeholder")
  end

  private :lower_when_block
  private :build_let_ast_map
  private :collect_identifier_refs
  private :compute_used_let_names
  private :format_tag_suffix
  private :lower_test_that
  private :stub_local_idents
  private :with_test_that_bindings

end
