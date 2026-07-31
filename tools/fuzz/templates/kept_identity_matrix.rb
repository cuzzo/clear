# Retained identity v4 keep-edge matrix (docs/agents/retained-identity-design.md).
#
# Cross-product of caller cost model x keep destination x post-call use x
# kept-param arity x callee fallibility. Positive cells embed ASSERT oracles
# and run leak-clean under the testing allocator; negative cells pin the
# declaration-sited KEPT_IDENTITY_NEEDS_MODEL menu and use-after-GIVE.

KEPT_IDENTITY_CELLS = []

POSITIVE_MODELS = %i[multiowned plain_immutable give].freeze
KI_DESTS = %i[direct_field transitive optional_default].freeze
KI_ARITIES = %i[one two].freeze
KI_FALLIBLE = %i[stable failing].freeze

POSITIVE_MODELS.each do |model|
  KI_DESTS.each do |dest|
    uses = model == :give ? %i[none] : %i[none read]
    uses.each do |use|
      KI_ARITIES.each do |arity|
        KI_FALLIBLE.each do |fallible|
          KEPT_IDENTITY_CELLS << { model: model, dest: dest, use: use, arity: arity, fallible: fallible }
        end
      end
    end
  end
end

# Zero-config: omitted optional args construct a fresh identity.
KI_ARITIES.each do |arity|
  KI_FALLIBLE.each do |fallible|
    KEPT_IDENTITY_CELLS << { model: :omitted, dest: :optional_default, use: :none, arity: arity, fallible: fallible }
  end
end

# A plain MUTABLE binding kept at its LAST use simply moves (no GIVE
# ceremony); kept while still used afterward it has no sound default and
# the declaration must pick a model. Anchored at the declaration.
KI_DESTS.each do |dest|
  KI_ARITIES.each do |arity|
    KEPT_IDENTITY_CELLS << { model: :plain_mutable, dest: dest, use: :none, arity: arity, fallible: :stable }
    KEPT_IDENTITY_CELLS << { model: :plain_mutable, dest: dest, use: :read, arity: arity, fallible: :stable, expected: :compile_error }
  end
end

# Expression edges: anonymous constructors move their payload into a fresh
# handle; COPY of a shared identity forks an independent one.
KI_DESTS.each do |dest|
  KI_FALLIBLE.each do |fallible|
    KEPT_IDENTITY_CELLS << { model: :anon_expr, dest: dest, use: :none, arity: :one, fallible: fallible }
  end
  %i[none read].each do |use|
    KEPT_IDENTITY_CELLS << { model: :copy_of_shared, dest: dest, use: use, arity: :one, fallible: :stable }
  end
end

# Assignment AFTER construction is a keep edge too: the reseat shape
# (x.field = provided OR_ELSE fresh) across caller models. The overwritten
# handle must release exactly once.
%i[multiowned plain_immutable omitted].each do |model|
  KEPT_IDENTITY_CELLS << { model: model, dest: :field_assign, use: :read, arity: :one, fallible: :stable }
end
KEPT_IDENTITY_CELLS << { model: :plain_mutable, dest: :field_assign, use: :read, arity: :one, fallible: :stable, expected: :compile_error }

# A keep edge inside a loop retains per iteration and releases per keeper.
KI_DESTS.each do |dest|
  KEPT_IDENTITY_CELLS << { model: :loop_retain, dest: dest, use: :read, arity: :one, fallible: :stable }
end

# Reserved families (design phases B/C): an Arc source cannot feed an Rc
# sink, and the @value sigil is not implemented yet. Both must be rejected,
# never silently mixed.
KEPT_IDENTITY_CELLS << { model: :shared_source, dest: :direct_field, use: :none, arity: :one, fallible: :stable, expected: :compile_error }
KEPT_IDENTITY_CELLS << { model: :value_sigil, dest: :direct_field, use: :none, arity: :one, fallible: :stable, expected: :compile_error }

# A retaining function has a handle ABI; a plain FN value type cannot
# carry that contract, so the reference must be rejected at the source.
KEPT_IDENTITY_CELLS << { model: :fn_value, dest: :direct_field, use: :none, arity: :one, fallible: :stable, expected: :compile_error }

# Identity capabilities on generic type parameters are unimplemented and
# must be rejected at the struct declaration, never emitted as invalid Zig.
KEPT_IDENTITY_CELLS << { model: :generic_identity_field, dest: :direct_field, use: :none, arity: :one, fallible: :stable, expected: :compile_error }

# GIVE relinquishes; touching the binding afterwards is use-after-move.
KI_DESTS.each do |dest|
  KI_ARITIES.each do |arity|
    KEPT_IDENTITY_CELLS << { model: :give_then_use, dest: dest, use: :read, arity: arity, fallible: :stable, expected: :compile_error }
  end
end

module KeptIdentityMatrixRender
  module_function

  def keeper_structs(arity)
    if arity == :two
      "STRUCT Budget { count: Int64 }\nSTRUCT Pair { left: Budget @multiowned, right: Budget @multiowned }"
    else
      "STRUCT Budget { count: Int64 }\nSTRUCT Holder { budget: Budget @multiowned }"
    end
  end

  def keeper_fns(dest, arity, fallible)
    fail_param = fallible == :failing ? ", bad: Bool" : ""
    fail_stmt = fallible == :failing ? "    IF bad THEN\n        RAISE GuardFail;\n    END\n" : ""
    ret_bang = fallible == :failing ? "!" : ""

    body_one = "RETURN Holder{ budget: b };"
    body_two = "RETURN Pair{ left: l, right: r };"

    case dest
    when :direct_field
      if arity == :two
        "FN keep2(l: Budget, r: Budget#{fail_param}) RETURNS #{ret_bang}Pair ->\n#{fail_stmt}    #{body_two}\nEND"
      else
        "FN keep1(b: Budget#{fail_param}) RETURNS #{ret_bang}Holder ->\n#{fail_stmt}    #{body_one}\nEND"
      end
    when :transitive
      if arity == :two
        <<~CHT.strip
          FN keepInner2(l: Budget, r: Budget#{fail_param}) RETURNS #{ret_bang}Pair ->
          #{fail_stmt}    #{body_two}
          END

          FN keep2(l: Budget, r: Budget#{fail_param}) RETURNS #{ret_bang}Pair ->
              RETURN keepInner2(l, r#{fallible == :failing ? ', bad' : ''});
          END
        CHT
      else
        <<~CHT.strip
          FN keepInner1(b: Budget#{fail_param}) RETURNS #{ret_bang}Holder ->
          #{fail_stmt}    #{body_one}
          END

          FN keep1(b: Budget#{fail_param}) RETURNS #{ret_bang}Holder ->
              RETURN keepInner1(b#{fallible == :failing ? ', bad' : ''});
          END
        CHT
      end
    when :optional_default
      if arity == :two
        "FN keep2(l: ?Budget = NIL, r: ?Budget = NIL#{fail_param.sub(': Bool', ': Bool = FALSE')}) RETURNS !Pair ->\n#{fail_stmt}    RETURN Pair{ left: l OR_ELSE Budget{ count: 77 }, right: r OR_ELSE Budget{ count: 77 } };\nEND"
      else
        "FN keep1(b: ?Budget = NIL#{fail_param.sub(': Bool', ': Bool = FALSE')}) RETURNS !Holder ->\n#{fail_stmt}    RETURN Holder{ budget: b OR_ELSE Budget{ count: 77 } };\nEND"
      end
    end
  end

  def fallback_fns(arity)
    if arity == :two
      <<~CHT.strip
        FN fallbackPair() RETURNS Pair ->
            l = Budget{ count: 55 } @multiowned;
            r = Budget{ count: 55 } @multiowned;
            RETURN Pair{ left: l, right: r };
        END
      CHT
    else
      <<~CHT.strip
        FN fallbackHolder() RETURNS Holder ->
            h = Budget{ count: 55 } @multiowned;
            RETURN Holder{ budget: h };
        END
      CHT
    end
  end

  def decls(model, arity)
    mut = model == :plain_mutable ? "MUTABLE " : ""
    postfix = case model
    when :multiowned, :copy_of_shared, :loop_retain then " @multiowned"
    when :shared_source then " @shared"
    when :value_sigil then " @value"
    else ""
    end
    return [] if model == :omitted || model == :anon_expr

    if arity == :two
      ["    #{mut}src_l = Budget{ count: 11 }#{postfix};", "    #{mut}src_r = Budget{ count: 22 }#{postfix};"]
    else
      ["    #{mut}src = Budget{ count: 11 }#{postfix};"]
    end
  end

  def call_args(model, arity, dest, fallible)
    give = %i[give give_then_use].include?(model) ? "GIVE " : ""
    base = if model == :omitted
      []
    elsif model == :anon_expr
      ["Budget{ count: 11 }"]
    elsif model == :copy_of_shared || model == :loop_retain
      [model == :copy_of_shared ? "COPY src" : "src"]
    elsif model == :shared_source || model == :value_sigil
      ["src"]
    elsif arity == :two
      ["#{give}src_l", "#{give}src_r"]
    else
      ["#{give}src"]
    end
    if fallible == :failing
      base << "NIL" if model == :omitted && dest == :optional_default
      base << "NIL" if model == :omitted && dest == :optional_default && arity == :two
      base << "TRUE"
    end
    base
  end

  def keeper_call(model, arity, dest, fallible)
    fn = arity == :two ? "keep2" : "keep1"
    args = call_args(model, arity, dest, fallible).join(", ")
    call = "#{fn}(#{args})"
    fallible_result = dest == :optional_default || fallible == :failing
    if fallible == :failing
      fallback = arity == :two ? "fallbackPair()" : "fallbackHolder()"
      "#{call} OR_ELSE #{fallback}"
    elsif fallible_result
      "TRY #{call}"
    else
      call
    end
  end

  def asserts(model, arity, use, fallible)
    expect = if fallible == :failing
      55
    elsif model == :omitted
      77
    else
      11
    end
    expect_r = fallible == :failing ? 55 : (model == :omitted ? 77 : 22)
    out = []
    if arity == :two
      out << "    ASSERT kept.left.count == #{expect}_i64, \"left keeper value\";"
      out << "    ASSERT kept.right.count == #{expect_r}_i64, \"right keeper value\";"
    else
      out << "    ASSERT kept.budget.count == #{expect}_i64, \"keeper value\";"
    end
    if use == :read
      out << "    ASSERT src#{arity == :two ? '_l' : ''}.count == 11_i64, \"caller reads after keep\";"
      out << "    ASSERT src_r.count == 22_i64, \"caller reads right after keep\";" if arity == :two
    end
    out
  end

  def render_field_assign(p)
    decl = case p[:model]
    when :multiowned then "    MUTABLE src = Budget{ count: 11 } @multiowned;"
    when :plain_immutable then "    src = Budget{ count: 11 };"
    when :plain_mutable then "    MUTABLE src = Budget{ count: 11 };"
    else ""
    end
    call = p[:model] == :omitted ? "reseat(&h)" : "reseat(&h, src)"
    expect = p[:model] == :omitted ? 77 : 11
    after = if p[:model] == :multiowned
      "    src.count = 9;\n    ASSERT h.budget.count == 9_i64, \"reseated field shares\";"
    elsif p[:model] == :plain_immutable
      "    ASSERT src.count == 11_i64, \"caller reads after keep\";"
    elsif p[:model] == :plain_mutable
      "    src.count = 9;\n    ASSERT src.count == 9_i64, \"caller mutates after keep\";"
    else
      ""
    end
    <<~CHT
      STRUCT Budget { count: Int64 }
      STRUCT Holder { budget: Budget @multiowned }

      FN reseat(MUTABLE h: Holder, budget: ?Budget = NIL) RETURNS Void ->
          h.budget = budget OR_ELSE Budget{ count: 77 };
          RETURN;
      END

      FN main() RETURNS Void ->
      #{decl}
          seed = Budget{ count: 1 } @multiowned;
          MUTABLE h = Holder{ budget: seed };
          #{call};
          ASSERT h.budget.count == #{expect}_i64, "reseated value";
      #{after}
          RETURN;
      END
    CHT
  end

  def render(p)
    return render_field_assign(p) if p[:dest] == :field_assign
    if p[:model] == :generic_identity_field
      return <<~CHT
        STRUCT Budget { count: Int64 }
        STRUCT Holder<T> { value: T @multiowned }

        FN keep<T>(value: T) RETURNS Holder<T> ->
            RETURN Holder<T>{ value: value };
        END

        FN main() RETURNS Void ->
            src = Budget{ count: 11 } @multiowned;
            kept = keep(src);
            ASSERT kept.value.count == 11_i64, "keeper value";
            RETURN;
        END
      CHT
    end
    if p[:model] == :fn_value
      return <<~CHT
        #{keeper_structs(:one)}

        #{keeper_fns(:direct_field, :one, :stable)}

        FN main() RETURNS Void ->
            cb: FN(Budget) -> Holder = keep1;
            src = Budget{ count: 11 } @multiowned;
            kept = cb(src);
            ASSERT kept.budget.count == 11_i64, "keeper value";
            RETURN;
        END
      CHT
    end
    needs_bang_main = p[:dest] == :optional_default || p[:fallible] == :failing
    main_ret = needs_bang_main ? " RETURNS !Void" : " RETURNS Void"
    parts = [keeper_structs(p[:arity]), keeper_fns(p[:dest], p[:arity], p[:fallible])]
    parts << fallback_fns(p[:arity]) if p[:fallible] == :failing

    body = []
    body.concat(decls(p[:model], p[:arity]))
    if p[:model] == :loop_retain
      body << "    FOR i IN (0_i64 ..< 3) DO"
      body << "        kept = #{keeper_call(p[:model], p[:arity], p[:dest], p[:fallible])};"
      body << "        ASSERT kept.budget.count == 11_i64, \"keeper in iteration\";"
      body << "    END"
      body << "    ASSERT src.count == 11_i64, \"identity survives the loop\";"
    else
      body << "    kept = #{keeper_call(p[:model], p[:arity], p[:dest], p[:fallible])};"
      body.concat(asserts(p[:model], p[:arity], p[:use], p[:fallible]))
    end
    body << "    RETURN;"

    parts << "FN main()#{main_ret} ->\n#{body.join("\n")}\nEND"
    parts.join("\n\n") + "\n"
  end
end

FuzzGenerator.register(:kept_identity_matrix, cells: KEPT_IDENTITY_CELLS) do |p|
  src = KeptIdentityMatrixRender.render(p)
  if p[:expected] == :compile_error
    # Every rejection cell must name the CLEAR diagnostic it expects, and the
    # runner is told to REQUIRE that code (diagnostic_code_required). Without
    # this an invalid-Zig failure would silently count as a passing rejection
    # -- exactly how the @shared->@multiowned family mismatch hid.
    code = case p[:model]
    when :plain_mutable then :KEPT_IDENTITY_NEEDS_MODEL
    when :give_then_use then :USE_OF_MOVED_VALUE
    when :fn_value then :KEPT_FN_VALUE_ABI
    when :generic_identity_field then :GENERIC_IDENTITY_FIELD_UNSUPPORTED
    when :shared_source then :KEPT_IDENTITY_FAMILY_MISMATCH
    when :value_sigil then :PARSER_EXPECTED # @value is reserved, not yet a model
    else raise "kept_identity_matrix: compile_error cell for model #{p[:model].inspect} has no diagnostic code"
    end
    { source: src, error_code: code, diagnostic_code_required: true }
  else
    src
  end
end
