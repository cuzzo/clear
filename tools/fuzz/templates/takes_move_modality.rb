# Template: ownership-transfer move modality x owning collection shape.
#
# Bug class #37: an owning collection passed to a `TAKES` parameter must
# transfer the owning container. Implicit move into TAKES is valid CLEAR --
# `consume(xs)` needs NO explicit `GIVE` -- yet lowering only handles the
# explicit-GIVE form: a bare identifier (was_moved via TAKES, not a MoveNode)
# hits mir_lowering.rb:1798 and is passed as a `.items` slice where the TAKES
# cleanup expects the owning ArrayList; `COPY xs` into TAKES is broken via a
# separate path. Only `consume(GIVE xs)` compiles today.
#
# Why no existing template caught it: every TAKES-bearing template hardcodes
# `GIVE` as a literal string (ownership_surface_smoke.rb:315 always writes
# `consume!(GIVE xs)`; or_positional passes an `inner() OR ...` expression,
# never a bare/COPY identifier). The move modality was never a fuzz axis. This
# template makes it one.
#
# Expectations encode the LANGUAGE CONTRACT, not the current broken state:
#   - :give  -> :pass    (proven working today for list/set/pool/map)
#   - :bare  -> :in_dev  (contract-valid; blocked on #37 lowering fix)
#   - :copy  -> :in_dev  (contract-valid; blocked on #37 COPY-into-TAKES path)
# When #37 lands, flip the :bare/:copy cells to :pass -- that flip IS #37's
# regression acceptance test. :in_dev (generator.rb:40) reserves the matrix
# slot and is skipped until then, keeping the matrix green meanwhile.
#
# Shapes are limited to the four owning @-collections with a proven-passing
# GIVE baseline (list/set/pool/map). dynamic Int64[] and nested [][]@list
# fail their GIVE baseline via UNRELATED bugs and are deliberately excluded
# so this template stays a clean #37 signal. CLONE is intentionally out of
# scope (CLONE of a non-RC collection is a distinct front-end concern, not
# the implicit-move-into-TAKES class).

TAKES_MOVE_SHAPES = %i[list set pool map].freeze

# modality => expected outcome under the language contract / current compiler
TAKES_MOVE_MODALITIES = { give: :pass, bare: :in_dev, copy: :in_dev }.freeze

TAKES_MOVE_CELLS = TAKES_MOVE_SHAPES.flat_map do |shape|
  TAKES_MOVE_MODALITIES.map do |modality, expected|
    { shape: shape, modality: modality, expected: expected }
  end
end

FuzzGenerator.register(:takes_move_modality, cells: TAKES_MOVE_CELLS) do |p|
  prelude, ptype, decl, mutate, body =
    case p[:shape]
    when :list
      ["", "Int64[]@list",
       "MUTABLE xs: Int64[]@list = [];", "xs.append(4_i64);",
       "RETURN xs.length();"]
    when :set
      ["", "Int64[]@set",
       "MUTABLE xs: Int64[]@set = [];", "xs.insert(4_i64);",
       "RETURN xs.length();"]
    when :pool
      ["STRUCT It { v: Int64 }\n", "It[8]@pool",
       "MUTABLE xs: It[8]@pool = [];", "_ = xs.insert(It{ v: 4_i64 });",
       "RETURN xs.length();"]
    when :map
      ["", "HashMap<Int64>",
       "MUTABLE xs: HashMap<Int64> = {};", "xs[\"k\"] = 4_i64;",
       "RETURN xs.count();"]
    end

  arg = case p[:modality]
        when :give then "GIVE xs"
        when :copy then "COPY xs"
        when :bare then "xs"
        end

  <<~CHT
    #{prelude}FN consume(TAKES xs: #{ptype}) RETURNS Int64 -> #{body} END

    FN main() RETURNS Void ->
        #{decl}
        #{mutate}
        n: Int64 = consume(#{arg});
        ASSERT n == 1_i64, "takes #{p[:shape]} via #{p[:modality]}";
        RETURN;
    END
  CHT
end
