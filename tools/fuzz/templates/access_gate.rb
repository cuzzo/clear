# Template: WITH-alias escape rules.
# Verifies CLAUDE.md's non-escaping rule: aliases bound by WITH (EXCLUSIVE,
# BORROWED, RESTRICT, SNAPSHOT) cannot escape their block. The legal
# exception is `RETURN COPY alias`.
#
# Cross-references:
#   - CLAUDE.md "Key rule: WITH ... AS alias aliases are non-escaping"
#   - mir-bugs.md #3 (WITH RESTRICT reassignment UAF)
#   - spec/with_alias_escape_spec.rb / spec/borrowed_escape_spec.rb (named
#     gaps; the matrix exercises cross-products they don't cover)
#
# Cell schema:
#   { alias:, perm:, escape:, expected: }
#
#   alias  ∈ {:exclusive, :borrowed, :restrict, :snapshot}
#   perm   forced by alias kind:
#             :exclusive → :locked, :write_locked
#             :borrowed  → :plain
#             :restrict  → :plain
#             :snapshot  → :versioned
#   escape ∈ 8 patterns (2 baselines + 6 escape attempts)
#   expected = :pass for baselines, :compile_error for escape attempts.
#
# A cell that UNEXPECTED-PASSes on an escape attempt is a real escape-rule
# enforcement gap. A :pass cell that fails is either a syntax issue in the
# template or a baseline regression.

ACCESS_GATE_CELLS = []

ALIAS_PERMS = [
  [:exclusive, :locked],
  [:exclusive, :write_locked],
  [:borrowed,  :plain],
  [:restrict,  :plain],
  [:snapshot,  :versioned],
]

ACCESS_PAYLOADS = [:int, :string]

ESCAPE_PATTERNS = [
  :baseline_use,           # use alias inside WITH, no escape — should :pass
  :baseline_copy_return,   # RETURN COPY alias — legal exception, should :pass
  :return_alias,           # RETURN alias — must reject
  :return_field,           # RETURN alias.value — must reject
  :bg_capture,             # BG { use(alias) } returned — must reject (Gap 1)
  :do_capture,             # DO { BG { use(alias) }, ... } returned — must reject
  :bg_stream_capture,      # BG STREAM { use(alias) } returned — must reject
  :takes_consume,          # consume(GIVE alias) — must reject (alias isn't owned)
  :store_field,            # outer.field = alias — must reject
  :list_append,            # append(some_list, alias) — must reject
]

ALIAS_PERMS.each do |alias_kind, perm|
  ACCESS_PAYLOADS.each do |payload|
    ESCAPE_PATTERNS.each do |escape|
      cell = { alias: alias_kind, perm: perm, payload: payload, escape: escape }
      cell[:expected] = escape.to_s.start_with?('baseline_') ? :pass : :compile_error
      # A WITH alias of Counter{Int64} denotes a Copy value even when its
      # source is locked/versioned. GIVE into TAKES therefore copies the
      # complete value; plain BORROWED field/list stores do too. No alias
      # escapes. String-bearing Counter values remain non-Copy.
      copy_value_escape = payload == :int && (
        escape == :takes_consume ||
        (alias_kind == :borrowed && [:store_field, :list_append].include?(escape))
      )
      cell[:expected] = :pass if copy_value_escape
      ACCESS_GATE_CELLS << cell
    end
  end
end

# ── helpers ───────────────────────────────────────────────────────────

# Source declaration for the locked/snapshotted/plain Counter.
def access_gate_value(payload)
  payload == :int ? "1_i64" : 'COPY "one"'
end

def access_gate_field_type(payload)
  payload == :int ? "Int64" : "String"
end

def access_gate_field_assert(payload, expr)
  payload == :int ? "ASSERT #{expr} == 1_i64, \"alias field\";" : "ASSERT #{expr}.length() == 3_i64, \"alias field\";"
end

def access_gate_source_decl(perm, payload)
  # MUTABLE so RESTRICT (which requires a mutable source) is admissible.
  # Other alias kinds tolerate MUTABLE on the source even if they don't need it.
  value = access_gate_value(payload)
  case perm
  when :locked       then "MUTABLE c = Counter{ value: #{value} } @locked;"
  when :write_locked then "MUTABLE c = Counter{ value: #{value} } @writeLocked;"
  when :versioned    then "MUTABLE c = Counter{ value: #{value} } @versioned;"
  when :plain        then "MUTABLE c = Counter{ value: #{value} };"
  end
end

# The WITH-clause head: which alias keyword + AS form.
def access_gate_with_head(alias_kind)
  case alias_kind
  when :exclusive then "WITH EXCLUSIVE c AS ref"
  when :borrowed  then "WITH BORROWED c AS ref"
  when :restrict  then "WITH RESTRICT c AS MUTABLE ref"
  when :snapshot  then "WITH SNAPSHOT c AS ref"
  end
end

FuzzGenerator.register(:access_gate, cells: ACCESS_GATE_CELLS) do |p|
  decl = access_gate_source_decl(p[:perm], p[:payload])
  head = access_gate_with_head(p[:alias])
  field_type = access_gate_field_type(p[:payload])
  zero_value = p[:payload] == :int ? "0_i64" : 'COPY ""'
  field_assert = access_gate_field_assert(p[:payload], "x")
  field_use = p[:payload] == :int ? "ref.value" : "ref.value.length()"
  bg_type = p[:payload] == :int ? "Int64" : "String"
  bg_expr = p[:payload] == :int ? "ref.value" : "COPY ref.value"
  stream_expr = bg_expr

  case p[:escape]
  when :baseline_use
    <<~CHT
      STRUCT Counter { value: #{field_type} }

      FN main() RETURNS Void ->
          #{decl}
          #{head} {
              x: #{field_type} = ref.value;
              #{field_assert}
          }
          RETURN;
      END
    CHT

  when :baseline_copy_return
    <<~CHT
      STRUCT Counter { value: #{field_type} }

      FN extract() RETURNS !Counter ->
          #{decl}
          #{head} {
              RETURN COPY ref;
          }
      END

      FN main() RETURNS Void ->
          c2 = extract();
          #{access_gate_field_assert(p[:payload], 'c2.value')}
          RETURN;
      END
    CHT

  when :return_alias
    <<~CHT
      STRUCT Counter { value: #{field_type} }

      FN leak() RETURNS !Counter ->
          #{decl}
          #{head} {
              RETURN ref;
          }
      END

      FN main() RETURNS Void ->
          c2 = leak();
          RETURN;
      END
    CHT

  when :return_field
    # Alias is a borrow; alias.value is also a borrow (or a Copy primitive
    # for Int64). For Int64 fields this might actually be legal — primitives
    # are Copy. Keep the cell in the matrix to test that distinction:
    # if RETURN ref.value passes for an Int64 field, that's correct (Copy
    # types break the borrow). The escape rule should only apply to non-Copy
    # field types.
    #
    # NOTE: marked :compile_error per the CLAUDE.md rule's literal text
    # ("RETURN alias.field is rejected"); if it actually passes for Int64,
    # that's a correct UNEXPECTED-PASS and the rule should be refined.
    <<~CHT
      STRUCT Counter { value: #{field_type} }

      FN leak() RETURNS !#{field_type} ->
          #{decl}
          #{head} {
              RETURN ref.value;
          }
      END

      FN main() RETURNS Void ->
          v = leak();
          RETURN;
      END
    CHT

  when :bg_capture
    <<~CHT
      STRUCT Counter { value: #{field_type} }

      FN leak() RETURNS ~#{bg_type} ->
          #{decl}
          #{head} {
              RETURN BG { #{bg_expr}; };
          }
      END

      FN main() RETURNS Void ->
          bg = leak();
          v: #{bg_type} = NEXT bg;
          RETURN;
      END
    CHT

  when :do_capture
    # DO branches return Void (implicit join) — wrap in a function and
    # try to leak by storing a result outside the WITH. Test the
    # capture-from-WITH-scope rule, not the DO-return.
    <<~CHT
      STRUCT Counter { value: #{field_type} }

      FN main() RETURNS Void ->
          #{decl}
          MUTABLE handles: ~#{bg_type}[]@list = [];
          #{head} {
              append(handles, BG { #{bg_expr}; });
              append(handles, BG { #{bg_expr}; });
          }
          a: #{bg_type} = NEXT handles[0_i64];
          b: #{bg_type} = NEXT handles[1_i64];
          RETURN;
      END
    CHT

  when :bg_stream_capture
    <<~CHT
      STRUCT Counter { value: #{field_type} }

      FN leak() RETURNS ~#{bg_type}[INF] ->
          #{decl}
          #{head} {
              RETURN BG STREAM {
                  WHILE TRUE DO YIELD #{stream_expr}; END
              };
          }
      END

      FN main() RETURNS Void ->
          s = leak();
          v: #{bg_type} = NEXT s;
          RETURN;
      END
    CHT

  when :takes_consume
    <<~CHT
      STRUCT Counter { value: #{field_type} }

      FN consume(TAKES x: Counter) RETURNS !Int64 ->
          RETURN #{p[:payload] == :int ? 'x.value' : 'x.value.length()'};
      END

      FN main() RETURNS Void ->
          #{decl}
          #{head} {
              v: Int64 = consume(GIVE ref);
          }
          RETURN;
      END
    CHT

  when :store_field
    <<~CHT
      STRUCT Counter { value: #{field_type} }
      STRUCT Holder { c: Counter }

      FN main() RETURNS Void ->
          #{decl}
          MUTABLE h = Holder{ c: Counter{ value: #{zero_value} } };
          #{head} {
              h.c = ref;
          }
          RETURN;
      END
    CHT

  when :list_append
    <<~CHT
      STRUCT Counter { value: #{field_type} }

      FN main() RETURNS Void ->
          #{decl}
          MUTABLE list: Counter[]@list = [];
          #{head} {
              list.append(ref);
          }
          RETURN;
      END
    CHT
  end
end
