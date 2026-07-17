# Template: polymorphic-sync admission rules.
# Verifies which (callee signature × caller binding) combinations the
# annotator admits today vs rejects. Surfaces the viralization concern
# from the access-gate / @local discussion: should `LOCAL` be admissible
# alongside `LOCKED` in a polymorphic-sync function's REQUIRES clause?
#
# Cross-references:
#   - docs/sharing-capabilities.md (the canonical Types/Capabilities/
#     Boundaries model)
#   - src/ast/parser.rb:1546 REQUIRES_VALID_FAMILIES
#   - transpile-tests/349_polymorphic_transaction_acceptance.clear
#     (canonical end-to-end pattern)
#   - spec/sync_polymorphism_integration_spec.rb /
#     polymorphic_transaction_acceptance_spec.rb (annotator-level coverage)
#
# Cell shape:
#   { callee:, caller:, expected: }
#
#   callee ∈ {
#     :concrete,       # FN foo(c: Counter) — no REQUIRES, plain param
#     :shared_param,   # FN foo(c: SHARED Counter) — parametric polymorphism
#     :req_locked,     # REQUIRES c: LOCKED
#     :req_versioned,  # REQUIRES c: VERSIONED
#     :req_local,      # REQUIRES c: LOCAL
#     :req_locked_or_local,  # REQUIRES c: LOCKED | LOCAL — viralization risk
#   }
#
#   caller ∈ {
#     :locked,         # MUTABLE c = Counter{...} @locked
#     :write_locked,   # ... @writeLocked
#     :versioned,      # ... @versioned
#     :local,          # ... @local
#     :multiowned,     # ... @multiowned
#     :plain,          # MUTABLE c = Counter{...}  (no perm)
#   }
#
# Expected outcomes per docs/sharing-capabilities.md:
#   - LOCKED admits @locked, @writeLocked
#   - VERSIONED admits @versioned
#   - LOCAL admits @local, @multiowned, plain
#   - LOCKED|LOCAL admits union of LOCKED + LOCAL
#   - SHARED Counter admits any @shared:* variant (locked, writeLocked,
#     versioned, atomic) — NOT @local, NOT @multiowned, NOT plain
#   - Concrete (no REQUIRES) admits plain only
#
# A cell that UNEXPECTED-PASSes is admission too lax. A :pass cell that
# fails compile is admission too strict.

POLYMORPHIC_ADMISSION_CELLS = []

CALLEE_FORMS = [:concrete, :shared_param, :req_locked, :req_versioned, :req_local]
CALLER_BINDINGS = [:locked, :write_locked, :versioned, :local, :multiowned, :plain]

ADMITS = {
  concrete:            [:local, :plain],
  shared_param:        [:locked, :write_locked, :versioned],
  req_locked:          [:locked, :write_locked],
  req_versioned:       [:versioned],
  req_local:           [:local, :multiowned, :plain],
  req_locked_or_local: [:locked, :write_locked, :local, :multiowned, :plain],
}

CALLEE_FORMS.each do |callee|
  CALLER_BINDINGS.each do |caller|
    cell = { callee: callee, caller: caller }
    cell[:expected] = ADMITS[callee].include?(caller) ? :pass : :compile_error
    POLYMORPHIC_ADMISSION_CELLS << cell
  end
end

# ── helpers ───────────────────────────────────────────────────────────

def admission_callee_def(callee)
  body_locked    = "WITH POLYMORPHIC EXCLUSIVE c AS x { x.value = x.value + 1_i64; }"
  body_versioned = "WITH SNAPSHOT c AS MUTABLE x { x.value = x.value + 1_i64; } ON MvccConflict RAISE"
  body_local     = "WITH POLYMORPHIC c AS x { x.value = x.value + 1_i64; }"
  body_match     = <<~CHT.chomp
    WITH MATCH c
        WHEN @locked       -> EXCLUSIVE c AS x { x.value = x.value + 1_i64; }
        WHEN @writeLocked  -> EXCLUSIVE c AS x { x.value = x.value + 1_i64; }
        WHEN @local        -> c.value = c.value + 1_i64;
        WHEN @multiowned   -> c.value = c.value + 1_i64;
        WHEN PLAIN         -> c.value = c.value + 1_i64;
    END
  CHT

  # Match the patterns from transpile-tests/349_polymorphic_transaction_acceptance.clear:
  # - LOCKED/LOCAL/concrete: RETURNS Void (default sync policy handles LockTimeout)
  # - VERSIONED/ATOMIC: RETURNS !Void (MvccConflict surfaces explicitly)
  case callee
  when :concrete
    <<~CHT.chomp
      FN tick(MUTABLE c: Counter) RETURNS Void ->
          c.value = c.value + 1_i64;
          RETURN;
      END
    CHT
  when :shared_param
    <<~CHT.chomp
      FN tick(MUTABLE c: SHARED Counter) RETURNS !Void ->
          #{body_locked}
          RETURN;
      END
    CHT
  when :req_locked
    <<~CHT.chomp
      FN tick(MUTABLE c: Counter) RETURNS !Void
          REQUIRES c: LOCKED
      ->
          #{body_locked}
          RETURN;
      END
    CHT
  when :req_versioned
    <<~CHT.chomp
      FN tick(MUTABLE c: Counter) RETURNS !Void
          REQUIRES c: VERSIONED
      ->
          #{body_versioned}
          RETURN;
      END
    CHT
  when :req_local
    <<~CHT.chomp
      FN tick(MUTABLE c: Counter) RETURNS Void
          REQUIRES c: LOCAL
      ->
          #{body_local}
          RETURN;
      END
    CHT
  when :req_locked_or_local
    <<~CHT.chomp
      FN tick(MUTABLE c: Counter) RETURNS Void
          REQUIRES c: LOCKED | LOCAL
      ->
          #{body_match}
          RETURN;
      END
    CHT
  end
end

def admission_caller_decl(caller)
  case caller
  when :locked       then "MUTABLE c = Counter{ value: 0_i64 } @shared:locked;"
  when :write_locked then "MUTABLE c = Counter{ value: 0_i64 } @shared:writeLocked;"
  when :versioned    then "MUTABLE c = Counter{ value: 0_i64 } @shared:versioned;"
  when :local        then "MUTABLE c = Counter{ value: 0_i64 } @local;"
  when :multiowned   then "MUTABLE c = Counter{ value: 0_i64 } @multiowned;"
  when :plain        then "MUTABLE c = Counter{ value: 0_i64 };"
  end
end

FuzzGenerator.register(:polymorphic_sync_admission, cells: POLYMORPHIC_ADMISSION_CELLS) do |p|
  callee_def = admission_callee_def(p[:callee])
  caller_decl = admission_caller_decl(p[:caller])
  call = %i[shared_param req_locked req_versioned].include?(p[:callee]) ? "tick(&c) OR_ELSE RAISE" : "tick(&c)"

  <<~CHT
    STRUCT Counter { value: Int64 }

    #{callee_def}

    FN main() RETURNS !Void ->
        #{caller_decl}
        #{call};
        RETURN;
    END
  CHT
end
