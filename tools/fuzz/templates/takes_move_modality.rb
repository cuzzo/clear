# Template: ownership-transfer move modality x owning collection shape.
#
# An owning collection/array passed to a `TAKES` parameter must transfer the
# owning container. Implicit move into TAKES is valid CLEAR -- `consume(xs)`
# needs NO explicit `GIVE`. Three proven lowering bugs live on this surface:
#
#   #37  @list/@set/@pool/@map via `bare`(implicit) or `COPY` -> mis-lowered
#        (`.items` slice / wrong path) where TAKES expects the owning store.
#        `GIVE` works for these four shapes today.
#   #39  dynamic `Int64[]` (no @list) -> TAKES is broken even with `GIVE`
#        (`expected '[]i64', found 'array_list.Aligned'`).
#   #40  nested `Int64[][]@list` -> TAKES is broken even with `GIVE`
#        (`expected '*T', found '*const T'`).
#
# Why the class went undetected: every TAKES-bearing template hardcoded
# `GIVE` as a literal; the move modality was never a fuzz axis. Worse,
# surface_registry.rb's access_gate baseline claims escape_sinks
# :takes_arg/:give_arg coverage -- true only for a struct (Counter) -- so the
# coverage reporter marked the whole takes/give surface covered, masking the
# collection-shape gap (#41). This template is the truthful owner of
# takes_arg/give_arg across collection shapes (registered in
# surface_registry.rb TEMPLATE_COVERAGE).
#
# Expectations encode the LANGUAGE CONTRACT, not the current broken state.
# Cells the contract says must work but a proven bug breaks are :in_dev
# (generator.rb:40: reserved, skipped, matrix stays green). Flipping a
# shape/modality's :in_dev cells to :pass is the regression acceptance test
# for the bug that gates it:
#
#   shape\modality   give     bare         copy
#   list/set/pool/map :pass    :in_dev #37  :in_dev #37
#   dynarr            :in_dev  :in_dev      :in_dev   (all #39)
#   nested            :in_dev  :in_dev      :in_dev   (all #40)
#
# CLONE is out of scope (CLONE of a non-RC collection is a distinct
# front-end concern, not the implicit-move-into-TAKES class).

# shape => [prelude, param_type, decl_block, mutate_stmt, consume_body]
TAKES_MOVE_SHAPE_SPECS = {
  list: ["", "Int64[]@list",
         "MUTABLE xs: Int64[]@list = [];", "xs.append(4_i64);",
         "RETURN xs.length();"],
  set: ["", "Int64[]@set",
        "MUTABLE xs: Int64[]@set = [];", "xs.insert(4_i64);",
        "RETURN xs.length();"],
  pool: ["STRUCT It { v: Int64 }\n", "It[8]@pool",
         "MUTABLE xs: It[8]@pool = [];", "_ = xs.insert(It{ v: 4_i64 });",
         "RETURN xs.length();"],
  map: ["", "HashMap<Int64>",
        "MUTABLE xs: HashMap<Int64> = {};", "xs[\"k\"] = 4_i64;",
        "RETURN xs.count();"],
  dynarr: ["", "Int64[]",
           "MUTABLE xs: Int64[] = [];", "xs.append(4_i64);",
           "RETURN xs.length();"],
  nested: ["", "Int64[][]@list",
           "MUTABLE inner: Int64[]@list = [];\n    inner.append(5_i64);\n" \
           "    MUTABLE xs: Int64[][]@list = [];", "xs.append(inner);",
           "RETURN xs.length();"],
}.freeze

# give works today only for the four owning @-collections; dynarr/nested
# fail their GIVE baseline via #39/#40 so every modality is :in_dev there.
GIVE_OK_SHAPES = %i[list set pool map].freeze

TAKES_MOVE_CELLS = TAKES_MOVE_SHAPE_SPECS.keys.flat_map do |shape|
  %i[give bare copy].map do |modality|
    expected =
      if GIVE_OK_SHAPES.include?(shape)
        # give + bare both pass (bare fixed by the callee-side
        # collection? discriminator); copy still gated by #37 (separate path).
        modality == :copy ? :in_dev : :pass
      else
        :in_dev                               # dynarr=#39, nested=#40
      end
    { shape: shape, modality: modality, expected: expected }
  end
end

FuzzGenerator.register(:takes_move_modality, cells: TAKES_MOVE_CELLS) do |p|
  prelude, ptype, decl, mutate, body = TAKES_MOVE_SHAPE_SPECS.fetch(p[:shape])

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
